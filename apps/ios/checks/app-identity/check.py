"""The iOS app's signing identity must stay on the account that can actually release it.

WHY THIS EXISTS
===============
Opening the project in Xcode on a machine signed into a different Apple account silently
rewrites DEVELOPMENT_TEAM and PRODUCT_BUNDLE_IDENTIFIER in project.pbxproj. That is how
commit 9b51e355 — whose message was entirely about Python video scripts — reverted the
account migration from d2712e10 and put the project back on identifiers the current
account cannot register.

The damage is invisible at build time and only shows up in production:

  * Universal links stop resolving. Apple matches the app's TEAM-PREFIXED id against
    apple-app-site-association; a build signed by another team is simply not in that file,
    so QR/profile links and ticket deep links open Safari instead of the app.
  * Push notifications stop routing. The APNs topic IS the bundle id.

Both fail silently, which is why a human reviewer missed it inside a 3,500-line commit.
"""
from pathlib import Path
import json
import re
import sys

# The account that owns in.voiid.app. The old account still holds every com.voiid.*
# identifier, and Apple identifiers are globally unique, so we cannot go back — see
# d2712e10 ("move both apps to the new Apple account and bundle id").
TEAM = "ZX246KFTQD"
BUNDLE = "in.voiid.app"

root = Path(__file__).resolve().parents[4]
pbxproj = (root / "apps/ios/Voiid/Voiid.xcodeproj/project.pbxproj").read_text()
failures = []

teams = set(re.findall(r"DEVELOPMENT_TEAM = ([A-Za-z0-9]+);", pbxproj))
if teams != {TEAM}:
    failures.append(
        f"DEVELOPMENT_TEAM must be {TEAM} everywhere, found {sorted(teams)}. "
        "Xcode rewrites this when the signed-in Apple account differs; revert it."
    )

bundles = set(re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([A-Za-z0-9.]+);", pbxproj))
wrong = {b for b in bundles if not (b == BUNDLE or b.startswith(BUNDLE + "."))}
if wrong:
    failures.append(
        f"every PRODUCT_BUNDLE_IDENTIFIER must be {BUNDLE} or a suffix of it, found {sorted(wrong)}."
    )

# The AASA is the other half of universal links: it names TEAM.BUNDLE, and a build signed
# by anyone else is not in it. Checking them together is the point — either one alone
# looks fine while links are broken.
aasa = json.loads((root / "infrastructure/deployment/well-known/apple-app-site-association").read_text())
app_ids = {a for d in aasa["applinks"]["details"] for a in d.get("appIDs", [])}
if app_ids != {f"{TEAM}.{BUNDLE}"}:
    failures.append(
        f"apple-app-site-association appIDs must be exactly ['{TEAM}.{BUNDLE}'], found {sorted(app_ids)}."
    )

# Android App Links verify against applicationId, NOT the Kotlin `namespace` (which stays
# com.voiid.app on purpose — moving it would rename every package for nothing).
gradle = (root / "apps/android/app/build.gradle.kts").read_text()
app_id = re.search(r'applicationId\s*=\s*"([^"]+)"', gradle).group(1)
assetlinks = json.loads((root / "infrastructure/deployment/well-known/assetlinks.json").read_text())
packages = {e["target"]["package_name"] for e in assetlinks}
if packages != {app_id}:
    failures.append(
        f"assetlinks.json package_name must match the Android applicationId ({app_id}), found {sorted(packages)}."
    )

if failures:
    print("FAIL: app identity is inconsistent\n")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)

print(f"PASS: iOS {TEAM}.{BUNDLE} and Android {app_id} agree across project, AASA and assetlinks")

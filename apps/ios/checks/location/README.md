# Location sharing checks

Run from repository root:

```sh
xcrun -sdk macosx swiftc -module-cache-path /tmp/voiid-location-cache \
  apps/ios/Voiid/Voiid/Models/LocationModels.swift \
  apps/ios/Voiid/Voiid/Networking/LocationShareEngine.swift \
  apps/ios/checks/location/EngineStubs.swift \
  apps/ios/checks/location/LocationEngineCheck.swift -o /tmp/voiid-location-check
/tmp/voiid-location-check
python3 apps/ios/checks/location/typecheck.py
node --import tsx --test backend/api/test/location.test.ts
```

The engine harness compiles the actual models and sharing engine. Only GPS,
HTTP, crypto, socket, keychain and disk transport seams are stubbed. It uses a unique
test account ID for its temporary UserDefaults queue. The expected failed-start
case logs an offline error. The iOS type-check uses the actual picker and actual
Core Location service, with stubs for branding and the shared engine; SwiftUI macro
expansion needs access outside the tool sandbox. No app is built or launched.

Verified: 28 engine checks; 21 backend coordinate/privacy checks; isolated iOS
SDK type-checks for the sheet/service and engine; Swift syntax and diff checks.

Covered: no share without a fix; failed invitation cleanup; immediate first fix;
local stopping before network completion; persisted offline-stop retry; ended state
from disk; invalid coordinates/accuracy/sequence; sender/share binding; replay and
future timestamp rejection; recipient notification of extended expiry.

The sheet now uses a separate short-lived GPS request, cancellable Apple Maps place
search (no automatic reverse geocoding), explicit selected pins, optional labels,
duration/audience details, and success/error-aware sending. Permission denial leaves
search/manual pin sending available. No backend schema change is required.

Device acceptance still required:
- First permission prompt; Locate me indoors/outdoors; timeout and retry.
- Approximate location; denied/restricted; grant from Settings and return.
- Select a search result or pan while GPS is pending: it must not override selection.
- Send a searched/manual pin while GPS access is denied; test both direct/group chats.
- Offline send remains in the sheet with an error; successful send dismisses once.
- Live start reaches another device, fresh updates arrive, and background behaviour
  matches the granted iOS permission. iOS suspension/force-quit cannot be guaranteed.
- Stop offline, restart/reconnect, stop all, revoke location permission, and expiry.
- Extension reaches recipient; replay cannot move the marker backwards.
- Reduced accuracy, large text, light/dark, and VoiceOver on the redesigned sheet.

Conversation map checks (no app build):

```sh
xcrun swiftc -module-cache-path /private/tmp/voiid-conversation-check-cache \
  apps/ios/Voiid/Voiid/Models/LocationModels.swift \
  apps/ios/checks/location/ConversationMapCheck.swift -o /private/tmp/voiid-conversation-map-check
/private/tmp/voiid-conversation-map-check
python3 apps/ios/checks/location/store_check.py
```

Eight selection checks cover incoming + outgoing shares, direct/group isolation,
selected-share deduplication, stale participants, ended peers and the opened share's
final position. Five SQLite checks exercise the actual inbound upsert SQL, including
extension replay, owner binding and stopped-share preservation during history refresh.

The iOS conversation viewer now includes this device's outgoing shares even when opened
from another member's bubble. It fits all participants until a manual pan, and recenters
on all participants. A member awaiting their first fix can open a map of other sharing
members, without attributing another member's coordinates to the waiting member.

Cross-device acceptance still required: open either user's bubble while both an Android
and iOS device share; repeat in a group with three members; move a distant member; pan
and recenter; stop one participant; confirm unrelated chats never appear on that map.

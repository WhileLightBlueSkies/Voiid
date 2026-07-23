# Overnight build & audit — 2026-07-23

Everything below is **uncommitted** on `main`. Nothing was pushed or deployed. `git status`
shows the full change set.

## TL;DR

Three multi-agent workflows ran (notifications + dialer linking, full iOS Settings, and
Stories + Maps). They produced working code **and** found 52 real problems through adversarial
review. **All 9 criticals are fixed and compile.** The high-impact majors are fixed too. What
remains is: the Stories/Maps client UI (blocked overnight by a session limit), a set of
lower-severity majors documented below, three inputs only you can provide, and device testing
that no amount of compiling can substitute for.

---

## Build status (as left)

| Target | Command | Result |
|---|---|---|
| iOS app | `xcodebuild … -scheme Voiid` | Clean — 0 errors in any file touched. Only the pre-existing environmental errors remain (see note). |
| iOS NSE | (built by the scheme) | **0 errors** — type-checked against the real MLS types. |
| Android | `./gradlew :app:assembleDebug` | **BUILD SUCCESSFUL** |
| backend/api | `npx tsc --noEmit` | **exit 0** |
| backend/websocket | `npx tsc --noEmit` | **exit 0** |

**Environmental note:** the iOS *app* target cannot fully link on this machine. `E2EManager`,
`GroupEngine`, `ChatEngine`, `RecoveryService`, `BackupManager` reference types
(`Identity`, `Session`, `GroupMember`, `PinWrappedSecret`, …) from `packages/e2e-core`, whose
uniffi bindings are gitignored build outputs. Generating them needs a **rustup** toolchain;
only Homebrew `rustc` is installed here (no iOS cross-compile targets). Those errors exist on a
clean checkout too — they are not from this work. To link the app: install rustup, add the iOS
targets, run `packages/e2e-core/build-apple.sh`.

---

## What was built

### Notifications + dialer linking
- **Group message notification previews** — the NSE now decrypts MLS group messages and shows
  "Group name / Sender: message" with the sender resolved to their saved contact name. Found
  and fixed a pre-existing gap: `GroupEngine` had **no** cross-process locking; the
  single-writer discipline was retrofitted onto every group path.
- **Missed-call notifications** — schedule-then-cancel via the notification daemon, so a banner
  survives the app being killed; "Call back" / "Message" actions.
- **Android dialer linking** — self-managed `PhoneAccount` + `ConnectionService` (calls in the
  system log) and an account authenticator + sync adapter (the "Voice/Video call (Voiid)" rows
  inside a contact card).

### iOS Settings (native rebuild)
- Root list: profile header → Linked Devices, Backup → Notifications, Privacy, Storage → About
  → Log Out. Shared `SettingsChrome`, real `StorageProbe` (measures the DB incl. -wal/-shm off
  the main actor), `DeviceDirectoryService` (first iOS client for the linked-devices API),
  `SessionTeardown`.
- **Honesty enforced by design.** The Chats-settings screen shipped **nothing** — every
  candidate control was dead (app pinned to light mode, no auto-download consumer, etc.). About
  invented no policy URLs. Privacy's toggles were traced to real consumers.

### Stories + Maps
- **Specs + backend landed and typecheck clean**: `017_stories.sql`, `018_location_shares.sql`,
  `routes/stories.ts`, `routes/location.ts`, `workers/src/reapStories.ts`, protocol docs.
- Crypto model (no `e2e-core` changes): a story is encrypted **once** with a random key; that
  key is fanned out per-recipient-device over existing sessions — same shape as 1:1 media. The
  server sees ciphertext + who received key material, never content.
- **Client UI, tab-bar wiring, and the feature's own verify pass did NOT run** — the workflow
  hit a session limit (resets 4:30am Asia/Calcutta). A resume was launched overnight; its
  outcome will be in the session when you return.

---

## Criticals — all fixed

| # | Problem | Fix |
|---|---|---|
| 1 | Log out left the previous account's **plaintext messages + live Olm sessions in memory**; next `persist()` rewrote them to disk after deletion | `ChatEngine.wipeInMemoryState()` before file deletion |
| 2 | Log out left `E2EManager.bootstrapped = true` → next account reused the **old identity** | `E2EManager.resetForSignOut()` |
| 3 | Log out left the previous user's contact names/numbers | `UserDirectory.wipe()` |
| 4 | SQLite files **deleted while the pool was open** → WAL checkpoint could resurrect them | `VoiidDatabase.closeForTeardown()` / `reopenAfterTeardown()` |
| 5 | NSE message ledger `.completeFileProtection` unreadable on a **locked device**; failed load → empty store overwrites real history | matched to `…UntilFirstUserAuthentication` (same class as the keychain + DB) |
| 6 | Log-out dialog promised "restore with your recovery phrase" based only on a keychain secret existing | three honest states from `BackupManager.status()`; "check failed" promises nothing |
| 7 | Offer buffer was a **per-user key drained by the first device** → siblings never rang | flush without delete; cleared by call resolution or TTL |
| 8 | `call_taken` (cancels a missed-call banner when a sibling answers) was pub/sub only → **false missed-call** on a push-woken sibling | buffered + flush-on-connect; `busy` no longer mislabelled `decline` |
| 9 | Android reported the **same incoming call to Telecom twice** (push then offer) + leaked a Connection when a call ended before Telecom bound it | added the attach-offer branch; `pendingDisconnects` map finishes a late-bound Connection |

## Majors — fixed
- Missed-call banners now cleared on log out (`MissedCallNotifier.cancelAll`) — were daemon-held
  and could fire for the previous account.
- `UserDirectory.reload()` (Android) no longer empties the map mid-refresh — names stopped
  flickering to "Unknown" for concurrent readers.
- `VoiidContactsWriter.sync()` no longer **wipes every contact-card row** when a transient DB
  read returns empty — a DB failure is now distinct from "no peers" and aborts the destructive
  pass.
- Profile-save failure copy no longer promises a background sync that doesn't exist.
- (Also auto-fixed by the criticals: offer-buffer drain, busy→decline, directory not wiped.)

---

## What YOU need to provide

1. **Google Maps API key** (Android). Maps degrades visibly without it; no key is hardcoded.
2. **Privacy-policy + Help URLs.** None exist in the codebase; the About screen has honest
   placeholders, not plausible-looking dead links.
3. **A `rustup` toolchain** on the build machine so the iOS app can link (see environmental
   note). Independent of this work.

## Remaining majors (documented, not yet fixed)
- **`TelecomBridge` guard #3 is dead code** (`tm.selfManagedPhoneAccounts` throws without a
  privileged permission → swallowed → skipped). The money-losing path (placing a real cellular
  call) is *still* protected by guards #1 and #2, so this is not critical — but I did not rewrite
  it blind because it's platform behaviour I can't verify without a device. **Needs a device.**
- Group-notification NSE has no self-imposed timer despite a comment claiming one (falls back to
  the system's `serviceExtensionTimeWillExpire`, which always delivers — so degraded, not broken).
- `decryptInboundLocked` is not crash-atomic across its two stores (ratchet advances, then
  keychain, then ledger) — a crash in the window loses one group message. MLS-specific; left for
  a careful, device-tested fix.
- Assorted Settings UX polish: Linked-Devices revoke is swipe-only, nav-bar background not
  themed, `BackupRecoveryView` not converted to the shared chrome, avatar hit-target < 44pt.

## Must be tested on a real device (compiling proves nothing here)
- **Android dialer linking end to end**: Settings → Accounts shows "Voiid"; a contact card shows
  both call rows and both launch a real Voiid call; Recents attributes calls correctly on a
  **Pixel and a Samsung/Xiaomi**; Bluetooth/speaker routing survives the Telecom handover; a
  cellular call interrupting a Voiid call and vice-versa.
- **iOS contact linking**: incoming call shows the saved contact (name + photo) with no duplicate
  Recents entries; Siri "call X on Voiid"; tapping a Recents/contact-card row redials via Voiid.
- **Killed-state calls** end to end once the APNs VoIP `.p8` is provisioned (see
  `KILLED_STATE_CALLS_CHECKLIST.md`).
- **Group + missed-call notifications** on a locked, then killed, device.
- **Log out → sign in as a different account**: confirm zero data bleed (the fix above needs
  runtime confirmation, not just compilation).

## Deploy reminders
- Deploy the **websocket** service, not just the API — the call-connect fix and the offer/taken
  buffers live there.
- The R2 backup 503 and the TURN transposition were env-name mismatches fixed locally in root
  `.env`; **the deployed `api-dev` box likely has the same** (`/health` showed
  `media.configured:false`). Audit its env against what the code reads before trusting either.

# 06 — Android durability and compatibility

Baseline: `a2e24e5` · 2026-09-05 · All tasks TODO; fixes specified, not implemented.

Source root: `apps/android/app/src/main/java/com/voiid/app/`. Keep minSdk 24 unless product explicitly changes supported devices. Run release as well as debug checks.

## A01 — Exclude current private stores from Android backup/transfer

**Priority:** P0 · **Evidence:** Confirmed rules gap · **Dependencies:** None

**Location:** `app/src/main/AndroidManifest.xml:84`; `res/xml/backup_rules.xml:7`; `res/xml/data_extraction_rules.xml:8`; `net/ChatEngine.kt:1274`; `store/VoiidDatabase.kt:73`; `net/RecoveryStore.kt:29` (paths beneath Android app).

Backup rules exclude the old `voiid_messages.json` and three preference files, but current message shards live in `files/messages/`, with a Room database and additional recovery/location/profile preferences. The manifest permits backup. These current stores are not covered by the exclusions. Restoring encrypted preferences without their Keystore key is also unsafe.

**Fix:** inventory every persisted private file/database/preference/cache, including account-specific media and all SecurePrefs names. Use explicit allowlisting or complete exclusions for both cloud backup and device transfer on old/new OS rules. Preserve user-authorized encrypted application backup as a separate path. Document the data intentionally portable across devices.

**Done when:** inspect the actual backup/transfer archive using synthetic content: no message plaintext, location material, auth tokens, recovery secrets, or nonportable encrypted preference stores. Restore on a fresh device and verify clean sign-in and explicit encrypted restore. Do not infer safety merely from the presence of backup XML.

## A02 — Stop automatically deleting shared encryption keys

**Priority:** P0 · **Evidence:** Confirmed failure path · **Dependencies:** A01

**Location:** `net/SecurePrefs.kt:34`, `:44`, `:50`, `:74`.

Any open exception deletes a preference file; a second failure deletes `MasterKey.DEFAULT_MASTER_KEY_ALIAS`, which is shared by other stores. A temporary or unrelated storage error can therefore destroy recoverable identity/session data and invalidate other preference files.

**Fix:** distinguish locked/unavailable storage, corrupted ciphertext, invalidated key, and unrecoverable missing-key restore. Return a typed unavailable/recovery state; never overwrite or delete originals during diagnosis. Retry transient errors after unlock. Quarantine corrupted files and offer explicit recovery/reset with its data-loss consequences. Isolate future key aliases where justified, with a verified migration that preserves existing data.

**Done when:** simulated locked device, disk failure, one corrupted preference, and missing-key restore do not silently regenerate identity or delete unrelated keys; explicit reset is the only destructive path.

## A03 — Support java.time on API 24/25

**Priority:** P1 · **Evidence:** Confirmed configuration gap · **Dependencies:** None

**Location:** `apps/android/app/build.gradle.kts:18`, `:78`; `net/ChatEngine.kt:1431`; `net/StoryEngine.kt:470`; `main/CommunityKit.kt:21`; `main/CommunityEventsSection.kt:35`.

The app supports API 24, uses `java.time`, and does not configure core-library desugaring. Some call sites catch failure and substitute current time/null, silently breaking chronological or expiry behavior on older devices.

**Fix:** enable supported core-library desugaring with a compatible pinned dependency in the version catalog, or consistently use a supported date abstraction. Preserve timestamp precision/timezone semantics and stop converting invalid server dates into plausible current timestamps. Verify the chosen configuration against the current Android toolchain documentation.

**Done when:** API 24/25 tests parse/format real UTC timestamps, offsets, invalid dates, event times, story expiry, and location expiry correctly; release lint reports no unsupported date API paths. Run the same fixtures on API 36.

## A04 — Remove destructive Room upgrade fallback

**Priority:** P1 · **Evidence:** Confirmed policy risk · **Dependencies:** A01

**Location:** `store/VoiidDatabase.kt:44`, `:45`, `:86`, `:87`.

Schema export is disabled and `fallbackToDestructiveMigration()` remains enabled despite explicit migrations. A missing future upgrade path can silently erase persistent local state.

**Fix:** export versioned schemas; provide explicit non-destructive migrations for every supported upgrade path. Remove release destructive fallback and surface a recoverable storage-unavailable state if migration fails. Test upgrades from real historical fixtures and preserve outbox/identity linkage. The messages table is not yet the primary chat store; do not claim this change alone migrates chat shards.

**Done when:** versions 1/2/3 upgrade to current without losing conversations, calls, locations, or stories; missing/failed migration leaves the original database intact. Downgrades have an explicit supported or blocked policy.

## A05 — Cancel network work when its coroutine is cancelled

**Priority:** P2 · **Evidence:** Confirmed cancellation gap · **Dependencies:** M01 before changing retry behavior

**Location:** `net/ApiClient.kt:123`, `:140`, `:183`, `:198`.

Blocking OkHttp `execute()` runs on IO, which avoids the main thread but is not tied to coroutine cancellation. Leaving a screen or cancelling an upload can leave work running until its timeout; broad exception wrapping loses cancellation semantics.

**Fix:** use a cancellable callback bridge or a supported coroutine adapter that calls `Call.cancel()` on cancellation and closes responses in all races. Preserve `CancellationException`. Define total call deadlines as well as connect/read/write timeouts. Retry only safe/idempotent operations and honor Retry-After; never replay a payment/message write without its stable key.

**Done when:** cancelling during connect/upload/download promptly cancels the underlying call, leaks no body/socket, and does not show an error toast for intentional cancellation. Offline/reconnect tests do not issue duplicate writes.

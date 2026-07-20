# VOIID — Google / Firebase integration: what still needs to be done

> Scope: all remaining **Google + Firebase** work. Three buckets:
> 1. **Firebase project setup & credentials** — the code (phone-auth OTP, FCM
>    push, the call ring-push) is wired, but it does nothing until the real
>    Firebase config files + credentials + console settings are in place. **Our
>    push notifications and call ringing depend on this.**
> 2. **Google Drive encrypted backup** — the user-facing "cloud backup" option
>    that pairs with our existing server backup. **Not built yet.**
> 3. **Google Sign-In** — required for the Drive OAuth grant (and optionally as a
>    login method). **Not built yet.**
>
> Status today: our own **server backup + PIN/recovery-phrase restore is fully
> built** (e2e-core `encrypt_backup`/`decrypt_backup`, backend `/backup` +
> `/recovery`, and `BackupManager`/`BackupService` on both clients). Firebase
> phone auth + FCM push are wired **in code**; the project/credential steps below
> are what remains. See also the older `FIREBASE_SETUP.md` for the phone-auth
> walkthrough — this doc supersedes/extends it with the full outstanding list.
>
> Last updated: 2026-07-20

---

## 0. The design in one paragraph

Drive backup does **not** invent new crypto. It reuses the exact encrypted blob
we already produce for the server backup: the client serializes its message
store, seals it with `encryptBackup(masterSecret, plaintext)` (e2e-core), and
uploads the **ciphertext** to the user's own Google Drive `appDataFolder`
(a hidden, app-private folder). Restore downloads that ciphertext and runs
`decryptBackup(masterSecret, blob)` after the user recovers the master secret via
PIN or the 24-word recovery phrase — identical to the server-restore path. Google
never sees plaintext or the key; Drive is just a second, user-owned storage
location alongside our R2 server backup. **No backend changes are required** for
the Drive path (it's client ↔ Google direct); optionally store a boolean
"drive backup enabled" flag per device for UX.

---

## 1. Firebase — project setup & credentials (unblocks push, OTP, calls)

The code paths exist; these are the manual project steps. **Until these are done:
no SMS OTP sends, no push notifications deliver, and incoming-call ringing
(`POST /calls/ring` → FCM/APNs wake) does nothing.**

### 1a. Phone auth (OTP) — sign-in
- [ ] Firebase Console → **Authentication → Sign-in method → Phone → Enable**.
- [ ] Add **test phone numbers** (Console → Phone → "Phone numbers for testing")
      for dev so no real SMS / billing is needed.
- [ ] **Blaze (pay-as-you-go)** plan for real SMS at volume.
- [ ] Confirm `FirebaseApp.configure()` runs (iOS `VoiidApp.init`) and the Android
      google-services plugin is synced (both already wired in code).

### 1b. Config files (real, per environment)
- [ ] **iOS `GoogleService-Info.plist`** — real production file added to the Voiid
      target. Currently **gitignored** (each dev/CI supplies it). Must be for the
      SAME GCP/Firebase project as everything else here.
- [ ] **Android `google-services.json`** — present at `apps/android/app/`; confirm
      it matches the project and lists the release SHA (not just debug).
- [ ] The **iOS NSE target** (`VoiidNSE`) and the app must share the app group /
      entitlements already set up — verify the plist/project references still hold
      after adding real config.

### 1c. Push notifications (FCM) — messages + calls depend on this
- [ ] **APNs auth key (.p8)** created in Apple Developer → uploaded to Firebase
      Console → Project Settings → Cloud Messaging. Enable the **Push Notifications**
      + **Background Modes (remote notifications)** capabilities on the iOS target.
      (Without APNs, Firebase phone-auth falls back to reCAPTCHA and push won't work.)
- [ ] **Backend FCM credentials**: `backend/api/src/push.ts` sends FCM (data
      messages) + APNs (alerts). Provision the **Firebase service-account JSON**
      (or FCM HTTP v1 credentials) into the backend env — **never commit it**. Add
      the expected env var(s) to the backend `.env.example`. Verify:
  - a normal message wakes the peer (data push → client decrypts → notification), and
  - `POST /calls/ring` delivers the content-free `type:"call"` wake so an
    offline/backgrounded callee actually rings (iOS via the NSE/CallKit path,
    Android via `VoiidMessagingService`).
- [ ] **iOS VoIP/PushKit (optional but recommended for calls):** for reliable
      lock-screen call ringing, a PushKit VoIP push + CallKit report on a **signed
      build** — the current ring uses a normal alert push, which is best-effort in
      the background. Decide if we add PushKit.

### 1d. SHA fingerprints & App Check
- [ ] Android **SHA-1 + SHA-256** for debug AND release keystores
      (`./gradlew signingReport`) registered in Firebase → Project Settings →
      Android app. Required for phone auth / Google Sign-In / App Check.
- [ ] (Optional hardening) **Firebase App Check** to stop abuse of the auth/push
      endpoints — adds a client attestation; wire later if desired.

---

## 2. Google Drive encrypted backup (the main new feature)

### 2a. Google Cloud / Firebase console (do first — code can't)
- [ ] In the **Google Cloud project** that backs the Firebase project, enable the
      **Google Drive API** (APIs & Services → Library → Drive API → Enable).
- [ ] Configure the **OAuth consent screen** (External): app name, support email,
      logo; add the scope **`https://www.googleapis.com/auth/drive.appdata`**
      (app-folder only — the least-privilege Drive scope; does NOT grant access to
      the user's other files). Add test users while unverified.
- [ ] Create **OAuth 2.0 Client IDs**:
  - **iOS** client ID (bundle id `com.voiid...`) → gives the reversed-client-id
    URL scheme used by Google Sign-In.
  - **Android** client ID (package + **SHA-1** of debug AND release keystores —
    `./gradlew signingReport`).
  - **Web/server** client ID (needed if we ever exchange the Drive refresh token
    server-side; not required for the client-only flow).
- [ ] **Verification:** `drive.appdata` is a *sensitive* scope. For production
      (non-test users) Google requires OAuth app verification — **start this early,
      it has a multi-day/week lead time.** Dev works with test users immediately.

### 2b. iOS (`apps/ios/Voiid`)
- [ ] Add the **GoogleSignIn** SDK (SPM `https://github.com/google/GoogleSignIn-iOS`)
      and the Drive REST calls (either the `GoogleAPIClientForREST/Drive` pod/SPM,
      or plain `URLSession` against the Drive v3 REST endpoints — we already hit
      raw REST for R2 in `BackupService.swift`, so raw REST is fine and dependency-light).
- [ ] Add the **reversed client ID URL scheme** to the target's URL Types, and
      handle the OAuth callback in the app delegate (`GIDSignIn.sharedInstance.handle(url)`).
- [ ] New `Networking/GoogleDriveBackupService.swift`:
  - `signIn()` → request the `drive.appdata` scope, keep the access/refresh token.
  - `uploadBackup(_ blob: Data)` → multipart upload to Drive `files` with
    `parents: ["appDataFolder"]`, fixed name e.g. `voiid-backup.enc`; if it exists,
    `PATCH` (update) the existing file id instead of creating duplicates.
  - `fetchBackupMeta()` → list `appDataFolder` for `voiid-backup.enc` (id, size,
    modifiedTime), or nil.
  - `downloadBackup() -> Data` → `GET files/{id}?alt=media`.
- [ ] Wire into `BackupManager.swift`: it already produces `encryptBackup(...)` →
      today it calls `BackupService.uploadBackup` (server). Add a parallel
      "Back up to Google Drive" path that uploads the **same blob** to
      `GoogleDriveBackupService`, and a restore path that pulls from Drive then runs
      the existing `restore(with:)` tail (`decryptBackup` → `importStore`).
- [ ] UI in `Main/Settings/BackupRecoveryView.swift`: a "Google Drive backup"
      toggle/row (Sign in with Google → enable → shows last Drive backup time), and
      on the login-restore sheet (`Onboarding/RestoreMessagesView.swift`) offer
      "Restore from Google Drive" alongside PIN/phrase.

### 2c. Android (`apps/android`)
- [ ] Add deps in `app/build.gradle.kts` (+ `gradle/libs.versions.toml`):
      `com.google.android.gms:play-services-auth` (Google Sign-In) and either the
      Drive REST client (`com.google.api-client:google-api-client-android` +
      `com.google.apis:google-api-services-drive`) or plain OkHttp against Drive
      v3 REST (OkHttp is already used in `BackupService.kt` — REST keeps deps light).
- [ ] New `net/GoogleDriveBackupService.kt`: `signIn()` requesting scope
      `Scope(DriveScopes.DRIVE_APPDATA)`; `uploadBackup(blob)`,
      `fetchBackupMeta()`, `downloadBackup()` against `appDataFolder` — mirror the
      iOS shapes and the existing `BackupService.kt` blob pattern.
- [ ] Wire into `net/BackupManager.kt` the same way (upload the same
      `encryptBackup(...)` blob; restore via `decryptBackup` → `importStore`).
- [ ] UI in `main/BackupRecoveryScreen.kt` (toggle + status) and the restore flow
      (`onboarding/RestoreFlow.kt`): "Back up to / Restore from Google Drive".
- [ ] Manifest/`google-services.json` already present for Firebase; the Google
      Sign-In client id comes from the **OAuth Android client** created in §2a
      (make sure the release SHA is registered before shipping).

### 2d. Behavior / policy decisions to confirm
- [ ] **Server + Drive together, or user-choice?** Recommended: keep server backup
      as default (works with no Google account), offer Drive as an **additional**
      opt-in location. On restore, if both exist, prefer the newer `modifiedTime`.
- [ ] **Auto-backup cadence** to Drive (on app background / daily) vs manual only —
      match whatever the server backup does.
- [ ] **Sign-out / disable** clears the local Drive token; the blob in the user's
      Drive is theirs to delete (offer a "delete Drive backup" action).

---

## 3. Google Sign-In (prerequisite for Drive; optional as a login method)

Drive backup needs a Google OAuth grant, which means integrating Google Sign-In on
both clients regardless. Separately, we *could* also offer "Sign in with Google" as
an account login method (today auth is Firebase **phone** OTP).

- [ ] **For Drive only (minimum):** the Google Sign-In integration in §2b/§2c is
      enough — it authorizes Drive, it does not have to create a VOIID account.
- [ ] **As a login method (optional, larger):** add Firebase Auth **Google
      provider** (Console → Authentication → Sign-in method → Google → Enable), use
      the Google ID token → `signInWithCredential` → our existing `/auth/firebase`
      → our JWT. This would let users onboard without a phone number. Decide whether
      we want this; if yes it needs its own onboarding-flow wiring on both clients.

---

## 4. Consolidated credentials checklist (single place to track)

Firebase items are detailed in §1; Drive/OAuth items in §2a. Quick roll-up:
- [ ] iOS `GoogleService-Info.plist` (real, in target) — §1b
- [ ] Android `google-services.json` (real, release SHA listed) — §1b/§1d
- [ ] APNs .p8 uploaded to Firebase; Push + Background-Modes capabilities — §1c
- [ ] Backend FCM service-account credentials in env (`push.ts`) — §1c
- [ ] Android SHA-1/SHA-256 (debug + release) registered — §1d
- [ ] Blaze plan (if real SMS needed) — §1a
- [ ] Google Drive API enabled — §2a
- [ ] OAuth consent screen + `drive.appdata` scope + **verification submitted** — §2a
- [ ] OAuth client IDs: iOS (reversed-client URL scheme), Android (SHA), Web — §2a
- [ ] All of the above point at the **same GCP/Firebase project**.

---

## 5. Verification checklist (before calling it done)
- [ ] Fresh install → sign in with Google → enable Drive backup → confirm a
      `voiid-backup.enc` appears in the user's Drive `appDataFolder` (Drive UI won't
      show it directly; verify via the API response / file id + size).
- [ ] Confirm the uploaded object is **ciphertext** (not readable JSON) — the whole
      point.
- [ ] Second device: log in → "Restore from Google Drive" → enter PIN or recovery
      phrase → message history restored and decrypts. (This needs 2 devices, same as
      the server-restore path — not runtime-testable in CI.)
- [ ] Revoke the Google grant / sign out → app degrades gracefully to server backup.
- [ ] Release build: release-keystore SHA registered, OAuth consent screen
      published/verified, no test-user gate.

---

## 6. Out of scope here (tracked elsewhere)
- **iCloud backup** — the Apple-side equivalent of §2 (CloudKit / iCloud Drive).
  Same blob, same crypto, different provider; worth a sibling doc when we do it.
- Google Play billing, Google Analytics/Crashlytics, Maps, etc. — not part of the
  messaging/backup feature set.

# VOIID — Firebase Phone Auth (OTP) setup

> The app code for real OTP is wired (Phone → Firebase sends SMS → OTP screen
> verifies → Firebase ID token → our `/auth/firebase` → our JWT). These are the
> **manual project steps** that code can't do — until they're done, the build
> won't compile (Firebase SDK missing) and no SMS will send.
>
> Last updated: 2026-06-17

## iOS (Xcode)
1. **Add the Firebase SDK** (the build needs it):
   - Xcode → File → Add Package Dependencies → `https://github.com/firebase/firebase-ios-sdk`
   - Add products: **FirebaseAuth** and **FirebaseCore** to the Voiid target.
2. **Add `GoogleService-Info.plist`** to the target (drag in, check "Add to target: Voiid").
   - Note: Firebase expects the file named exactly `GoogleService-Info.plist`. If
     yours is `GoogleService-Info-2.plist`, rename it (or it won't be auto-found).
3. **APNs (required to actually send SMS on a device):**
   - Apple Developer → create an APNs Auth Key (.p8) → upload it in Firebase
     Console → Project Settings → Cloud Messaging.
   - Enable Push Notifications capability on the target.
   - (Without APNs, Firebase falls back to reCAPTCHA in a web view; APNs is the clean path.)
4. Code already does `FirebaseApp.configure()` in `VoiidApp.init`. Build & run.

## Android (Android Studio)
1. **`google-services.json`** → place in `apps/android/app/`. (Gradle plugin reads it.)
2. Gradle is already wired (google-services plugin + firebase-bom + firebase-auth
   + coroutines-play-services). Just **Sync Gradle**.
3. **SHA fingerprints (required for SMS / App Check):**
   - Get debug SHA-1 + SHA-256: `./gradlew signingReport`
   - Add both in Firebase Console → Project Settings → your Android app → "Add fingerprint".
   - (Add the release keystore's SHAs before shipping.)

## Firebase Console (both)
- **Authentication → Sign-in method → Phone → Enable.**
- **Billing:** real SMS may require the **Blaze (pay-as-you-go)** plan on newer
  projects. (Confirm current pricing in your console.)
- **Test without sending SMS / billing:** Authentication → Sign-in method → Phone
  → "Phone numbers for testing" → add e.g. `+91 99999 99999` with code `123456`.
  The SDK returns that code instantly, no real SMS, no Blaze needed. **Use this
  for dev.**

## Backend — turn OFF the dev bypass for real auth
The app now sends a **real Firebase ID token** to `/auth/firebase`. The backend
still also accepts `dev:<phone>` tokens while `AUTH_DEV_BYPASS=1`. For real auth:
- On the server `.env`, set `AUTH_DEV_BYPASS=0` (or remove it) and set
  `FIREBASE_SERVICE_ACCOUNT` (or `_PATH`) to your service-account JSON, then
  restart. (Dev/staging can keep the bypass on for testing.)

## What the code already does (no action needed)
- iOS: `FirebasePhoneAuth.sendCode` / `.verify`; Phone screen sends, OTP screen
  verifies → `AuthService.loginWithFirebase`.
- Android: same via `FirebasePhoneAuth` (callback→coroutine), Phone→OTP wired.
- `loginWithFirebase` posts the Firebase ID token to `/auth/firebase`.

## Order of operations (so the build doesn't break midway)
1. iOS: add the SDK package FIRST (step 1) — otherwise `import FirebaseAuth` fails to compile.
2. Android: sync Gradle (deps resolve).
3. Add the plist/json.
4. Enable Phone provider + (dev) test numbers, or Blaze + APNs/SHA for real SMS.
5. Build, run, test with a test number.

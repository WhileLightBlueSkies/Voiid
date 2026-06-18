# VOIID — Link e2e-core into the apps + smoke test

> The encryption core (`packages/e2e-core`) must be compiled into each app before
> any real E2EE chat can run. This is the one step that needs a build machine.
> Do it once per platform, run the smoke test, and confirm encrypt→decrypt works.
> Then the chat layer gets built on top.
>
> Prereqs: Rust (`cargo`), and the mobile targets/NDK below.

---

## iOS

### 1. Build the XCFramework
```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios   # once
cd packages/e2e-core
./build-apple.sh
```
Produces `target/apple/Voiid.xcframework` and regenerates `bindings/swift/voiid.swift`.

### 2. Add to the Xcode project (apps/ios/Voiid)
- Drag `target/apple/Voiid.xcframework` into the project → add to the **Voiid** target
  (Frameworks, Libraries, and Embedded Content → Embed & Sign).
- Add `packages/e2e-core/bindings/swift/voiid.swift` to the target.
- No `import voiid` needed — `voiid.swift` is compiled into the app target, so
  its `Identity`/`Session`/etc. are already in scope. (The file itself does
  `import voiidFFI`, the Clang module the xcframework's `module.modulemap`
  provides — that resolves once the framework is embedded. Do NOT write
  `import voiid`; there is no such module and it won't compile.)

### 3. Smoke test (drop in anywhere, e.g. a button or `.task`)
```swift
func e2eSmokeTest() {
    let alice = Identity.create()
    var bob = Identity.create()
    let bobBundle = bob.publishBundle(oneTimeKeyCount: 5)
    let aliceBundle = alice.publishBundle(oneTimeKeyCount: 1)

    let session = try! alice.startSession(
        theirIdentityKey: bobBundle.identityKey,
        theirOneTimeKey: bobBundle.oneTimeKeys[0])
    let wire = try! session.encrypt(plaintext: Array("hello bob".utf8))

    let accepted = try! bob.acceptSession(
        theirIdentityKey: aliceBundle.identityKey, firstMessage: wire)
    let text = String(decoding: accepted.plaintext, as: UTF8.self)
    print("E2E SMOKE:", text == "hello bob" ? "✅ PASS" : "❌ FAIL (\(text))")
}
```
Expected console: `E2E SMOKE: ✅ PASS`

---

## Android

### 1. Build the JNI libraries
```bash
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android  # once
cargo install cargo-ndk          # once
export ANDROID_NDK_HOME=/path/to/ndk
cd packages/e2e-core
./build-android.sh
```
Drops `lib voiid_e2e_core.so` under `apps/android/app/src/main/jniLibs/<abi>/` and
generates `apps/android/app/src/main/java/uniffi/voiid/voiid.kt`.

### 2. Gradle — add the JNA runtime (uniffi Kotlin needs it)
In `apps/android/app/build.gradle.kts`:
```kotlin
implementation("net.java.dev.jna:jna:5.14.0@aar")
```
Sync Gradle.

### 3. Smoke test (e.g. in a coroutine on first screen)
```kotlin
import uniffi.voiid.*

fun e2eSmokeTest() {
    val alice = Identity.create()
    val bob = Identity.create()
    val bobBundle = bob.publishBundle(5u)
    val aliceBundle = alice.publishBundle(1u)

    val session = alice.startSession(bobBundle.identityKey, bobBundle.oneTimeKeys[0])
    val wire = session.encrypt("hello bob".toByteArray())

    val accepted = bob.acceptSession(aliceBundle.identityKey, wire)
    val text = accepted.plaintext.toString(Charsets.UTF_8)
    android.util.Log.i("E2E_SMOKE", if (text == "hello bob") "✅ PASS" else "❌ FAIL ($text)")
}
```
Expected Logcat: `E2E_SMOKE ✅ PASS`

---

## When both pass
Ping me. Then I build, in verifiable increments:
1. On login → create identity + publish prekey bundle to the backend.
2. Contacts: device contacts → hash → `/contacts/discover` → match → `/contacts/sync`; invite share-sheet for non-users.
3. Start chat → fetch peer bundle → establish session.
4. Send: encrypt → `/messages/send`; receive: WebSocket → decrypt → local store.
5. Receipts / typing / presence; then media + voice notes.

## If the smoke test fails
Paste the error. Common ones: binding API mismatch (the generated `voiid.swift`/
`voiid.kt` is the source of truth for exact names), missing target/NDK, or the
framework not embedded. All quick to fix.

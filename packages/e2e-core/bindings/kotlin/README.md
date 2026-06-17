# Kotlin binding (Android)

Generated Kotlin/JNI FFI for `voiid-e2e-core`, consumed by `apps/android`.
Crypto is never written here — this is generated glue over the Rust core.

## Build

From `packages/e2e-core`:

```bash
rustup target add aarch64-linux-android armv7-linux-androideabi \
                  x86_64-linux-android i686-linux-android        # once
cargo install cargo-ndk                                          # once
export ANDROID_NDK_HOME=/path/to/ndk
./build-android.sh
```

This places `lib voiid_e2e_core.so` under
`apps/android/app/src/main/jniLibs/<abi>/` and generates the Kotlin glue under
`apps/android/app/src/main/java/uniffi/voiid/voiid.kt`.

## Wire into Gradle (`apps/android/app/build.gradle.kts`)

uniffi's Kotlin runtime uses JNA. Add:

```kotlin
dependencies {
    implementation("net.java.dev.jna:jna:5.14.0@aar")
}
```

The `jniLibs` directory is picked up automatically.

## Usage sketch

```kotlin
import uniffi.voiid.*

// Each device, once:
val me = Identity.create()
val bundle = me.publishBundle(oneTimeKeyCount = 50u)   // upload to backend

// Start a chat with a peer:
val session = me.startSession(peer.identityKey, peer.oneTimeKeys[0])
val wire = session.encrypt("hello".toByteArray())      // -> relay

// Verify no MITM (compare out of band):
val number = safetyNumber(me.fingerprint(), peer.fingerprint)
```

Groups, media, and calls mirror the Rust API one-to-one.

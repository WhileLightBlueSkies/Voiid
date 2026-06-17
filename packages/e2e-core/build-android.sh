#!/usr/bin/env bash
# Build the Voiid E2E core as Android JNI .so libraries for all ABIs, place them
# under apps/android, and generate the Kotlin bindings.
#
# Prereqs (one-time):
#   rustup target add aarch64-linux-android armv7-linux-androideabi \
#                     x86_64-linux-android i686-linux-android
#   cargo install cargo-ndk            # handles NDK linker wiring
#   Install the Android NDK and set ANDROID_NDK_HOME.
#
# Run from packages/e2e-core:
#   ./build-android.sh
set -euo pipefail
cd "$(dirname "$0")"

CRATE=voiid_e2e_core
JNI_OUT=../../apps/android/app/src/main/jniLibs
KOTLIN_OUT=../../apps/android/app/src/main/java

echo "==> Building JNI libraries for all Android ABIs (release)…"
cargo ndk \
  -t arm64-v8a -t armeabi-v7a -t x86_64 -t x86 \
  -o "$JNI_OUT" \
  build --release

echo "==> Generating Kotlin bindings…"
# Use any built .so to introspect the metadata.
SO=$(find "$JNI_OUT/arm64-v8a" -name "lib${CRATE}.so" | head -1)
cargo run --bin uniffi-bindgen -- generate \
  --library "$SO" \
  --language kotlin --out-dir "$KOTLIN_OUT"

echo "==> Done."
echo "    JNI libs : $JNI_OUT/<abi>/lib${CRATE}.so"
echo "    Kotlin   : $KOTLIN_OUT/uniffi/voiid/voiid.kt"
echo
echo "Next: ensure app/build.gradle.kts has net.java.dev.jna:jna (aar) as a"
echo "      dependency (uniffi Kotlin runtime needs JNA). See bindings/kotlin/README.md."

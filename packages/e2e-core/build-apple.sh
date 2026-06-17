#!/usr/bin/env bash
# Build the Voiid E2E core as an XCFramework for iOS + the iOS simulator,
# and copy the generated Swift bindings next to it.
#
# Prereqs (one-time):
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
#
# Run from packages/e2e-core:
#   ./build-apple.sh
set -euo pipefail
cd "$(dirname "$0")"

CRATE=voiid_e2e_core
OUT=bindings/swift
BUILD=target/apple

echo "==> Building for device + simulator (release)…"
cargo build --release --target aarch64-apple-ios          # device
cargo build --release --target aarch64-apple-ios-sim      # Apple-silicon simulator
cargo build --release --target x86_64-apple-ios           # Intel simulator

echo "==> Regenerating Swift bindings…"
cargo run --bin uniffi-bindgen -- generate \
  --library target/aarch64-apple-ios/release/lib${CRATE}.dylib \
  --language swift --out-dir "$OUT"

# uniffi emits a modulemap named <name>FFI.modulemap; XCFramework wants it as
# module.modulemap inside a headers dir.
mkdir -p "$BUILD/headers"
cp "$OUT/${CRATE//_/}FFI.h" "$BUILD/headers/" 2>/dev/null || cp "$OUT/voiidFFI.h" "$BUILD/headers/"
cp "$OUT/voiidFFI.modulemap" "$BUILD/headers/module.modulemap"

echo "==> Creating a fat simulator lib (arm64 + x86_64)…"
mkdir -p "$BUILD/sim"
lipo -create \
  target/aarch64-apple-ios-sim/release/lib${CRATE}.a \
  target/x86_64-apple-ios/release/lib${CRATE}.a \
  -output "$BUILD/sim/lib${CRATE}.a"

echo "==> Assembling XCFramework…"
rm -rf "$BUILD/Voiid.xcframework"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/lib${CRATE}.a -headers "$BUILD/headers" \
  -library "$BUILD/sim/lib${CRATE}.a" -headers "$BUILD/headers" \
  -output "$BUILD/Voiid.xcframework"

echo "==> Done."
echo "    XCFramework: $BUILD/Voiid.xcframework"
echo "    Swift glue : $OUT/voiid.swift"
echo
echo "Next: drag Voiid.xcframework into the Xcode project (apps/ios/Voiid) and add"
echo "      $OUT/voiid.swift to the target. See bindings/swift/README.md."

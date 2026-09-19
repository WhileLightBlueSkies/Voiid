#!/usr/bin/env bash
# Exercises the face-FX maths and pack reader on the HOST -- no device, no
# simulator, no Xcode project. The files under test deliberately avoid
# UIKit/ARKit/Metal so this can run anywhere, including CI.
#
#   tools/check-facefx-geometry.sh
set -euo pipefail
cd "$(dirname "$0")/.."

FX="apps/ios/Voiid/Voiid/Main/Clips/FaceFX"
T="apps/ios/Voiid/VoiidTests/FaceFX"
TMPDIR_="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_"' EXIT

echo "== geometry =="
cat "$FX/FaceGeometry.swift" "$T/FaceGeometryChecks.swift" > "$TMPDIR_/geo.swift"
swift "$TMPDIR_/geo.swift"

echo
echo "== pack format =="
if [ ! -f packages/facefx/dist/shades.voiidfx ]; then
  echo "   building packs first..."
  (cd packages/facefx && python3 build/pack.py >/dev/null)
fi
cat "$FX/FXZip.swift" "$FX/FaceFrame.swift" "$FX/FaceGeometry.swift" \
    "$FX/FXManifest.swift" "$T/FXPackChecks.swift" > "$TMPDIR_/pack.swift"
swift "$TMPDIR_/pack.swift"

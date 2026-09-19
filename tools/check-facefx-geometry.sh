#!/usr/bin/env bash
# Exercises the face-FX geometry maths on the host -- no device, no simulator,
# no Xcode project. FaceGeometry.swift is deliberately free of UIKit/ARKit/Metal
# so this can run anywhere, including CI.
#
#   tools/check-facefx-geometry.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="apps/ios/Voiid/Voiid/Main/Clips/FaceFX/FaceGeometry.swift"
CHK="apps/ios/Voiid/VoiidTests/FaceFX/FaceGeometryChecks.swift"
TMP="$(mktemp -t facefx-geo).swift"
trap 'rm -f "$TMP"' EXIT

cat "$SRC" "$CHK" > "$TMP"
exec swift "$TMP"

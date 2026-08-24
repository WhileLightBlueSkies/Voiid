#!/bin/sh
# Copies the canonical Ludo board fixture into both apps' test bundles
# (LUDO_GAME_SPEC.md §19: one checked-in JSON; no independent hand-entered arrays).
#
#   sh tools/sync-ludo-fixture.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/packages/design-tokens/fixtures/ludo_board_v2.json"

mkdir -p "$ROOT/apps/android/app/src/test/resources"
cp "$SRC" "$ROOT/apps/android/app/src/test/resources/ludo_board_v2.json"

# iOS: the app target's synchronized folder picks this up as a bundled resource; the
# DEBUG geometry self-check loads it from the bundle at first board layout.
mkdir -p "$ROOT/apps/ios/Voiid/Voiid/Games/Ludo/Resources"
cp "$SRC" "$ROOT/apps/ios/Voiid/Voiid/Games/Ludo/Resources/ludo_board_v2.json"

echo "fixture synced:"
echo "  $ROOT/apps/android/app/src/test/resources/ludo_board_v2.json"
echo "  $ROOT/apps/ios/Voiid/Voiid/Games/Ludo/Resources/ludo_board_v2.json"

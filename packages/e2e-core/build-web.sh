#!/usr/bin/env bash
set -euo pipefail
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
core_dir="$(cd "$(dirname "$0")" && pwd)"
wasm-pack build "$core_dir/bindings/wasm" --target web --release --out-dir pkg --out-name voiid_e2e -- --locked

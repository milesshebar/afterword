#!/bin/bash
# Headless UI check: seeds a fake demo archive, renders the main views to PNGs, prints timings.
# Usage: scripts/selfcheck.sh [outdir] [scale]   (default outdir build/selfcheck, scale 1 = a 31,000-message thread)
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/product.env
OUT="${1:-build/selfcheck}"; SCALE="${2:-1}"
swift build -c release >/dev/null
rm -rf "$OUT"; mkdir -p "$OUT"
.build/release/archivectl demo-seed "$OUT/demo-archive" --scale "$SCALE" 2>/dev/null
".build/release/$APP_EXECUTABLE" --archive "$OUT/demo-archive" --snapshot "$OUT/png"

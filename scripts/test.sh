#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BROWSERS=0
PROTOCOLS=0
CROSS_VOLUME=0
for ARG in "$@"; do
  case "$ARG" in
    --browsers) BROWSERS=1 ;;
    --protocols) PROTOCOLS=1 ;;
    --cross-volume) CROSS_VOLUME=1 ;;
    *) printf 'Usage: scripts/test.sh [--browsers] [--protocols] [--cross-volume]\n' >&2; exit 2 ;;
  esac
done
for TOOL in swift node python3 aria2c yt-dlp ffmpeg ffprobe; do
  if ! command -v "$TOOL" >/dev/null; then printf 'Missing test prerequisite: %s\n' "$TOOL" >&2; exit 1; fi
done
mkdir -p .artifacts
swift build --build-system native --product Current
swift build --build-system native --product currentctl
swift build --build-system native --product CurrentCoreTests
.build/debug/CurrentCoreTests
node extensions/build.mjs
node --test tests/extension.test.mjs
python3 tests/fixture_test.py
python3 tests/integration.py
python3 tests/regressions.py
python3 tests/run_media.py
python3 tests/media_service.py
if [[ "$PROTOCOLS" == 1 ]]; then python3 tests/protocols.py; fi
if [[ "$CROSS_VOLUME" == 1 ]]; then python3 tests/cross_volume.py; fi
# Native host manifests are shared per user: run browser suites sequentially.
if [[ "$BROWSERS" == 1 ]]; then
  node tests/browser-e2e.mjs
  node tests/firefox-e2e.mjs
fi

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${CURRENT_VERSION:-0.1.0}"
YT_DLP_VERSION="${CURRENT_YT_DLP_VERSION:-2026.10.26}"
mkdir -p dist .artifacts/tools
if [[ ! -x .artifacts/tools/yt-dlp_macos ]]; then
  gh release download "$YT_DLP_VERSION" --repo yt-dlp/yt-dlp --pattern yt-dlp_macos --dir .artifacts/tools
  chmod +x .artifacts/tools/yt-dlp_macos
fi
if [[ "$(.artifacts/tools/yt-dlp_macos --version)" != "$YT_DLP_VERSION" ]]; then
  printf 'Cached yt-dlp version differs from %s; remove .artifacts/tools/yt-dlp_macos and rebuild.\n' "$YT_DLP_VERSION" >&2; exit 1
fi
python3 - "$YT_DLP_VERSION" <<'PY'
from pathlib import Path
import hashlib,sys,urllib.request
version=sys.argv[1]
base="https://github.com/yt-dlp/yt-dlp/releases/download/"+version+"/"
sums=urllib.request.urlopen(base+"SHA2-256SUMS",timeout=60).read().decode()
expected=next(line.split()[0] for line in sums.splitlines() if line.split()[-1] == "yt-dlp_macos")
if hashlib.sha256(Path(".artifacts/tools/yt-dlp_macos").read_bytes()).hexdigest() != expected:
    raise SystemExit("yt-dlp checksum differs from the pinned upstream release.")
notices=urllib.request.urlopen("https://raw.githubusercontent.com/yt-dlp/yt-dlp/"+version+"/THIRD_PARTY_LICENSES.txt",timeout=60).read()
Path(".artifacts/tools/yt-dlp-THIRD_PARTY_LICENSES.txt").write_bytes(notices)
PY
swift build --build-system native -c release --product Current
swift build --build-system native -c release --product currentctl
BIN_PATH="$(swift build --build-system native -c release --show-bin-path)"
APP="dist/Current.app"
if [[ -d "$APP" ]]; then rm -rf "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Extensions"
cp "$BIN_PATH/Current" "$APP/Contents/MacOS/Current"
cp "$BIN_PATH/currentctl" "$APP/Contents/MacOS/currentctl"
node extensions/build.mjs
ditto extensions/chromium "$APP/Contents/Resources/Extensions/chromium"
ditto extensions/firefox "$APP/Contents/Resources/Extensions/firefox"
cp extensions/README.md "$APP/Contents/Resources/Extensions/README.md"
python3 scripts/bundle-tools.py "$APP" --yt-dlp .artifacts/tools/yt-dlp_macos --yt-dlp-notices .artifacts/tools/yt-dlp-THIRD_PARTY_LICENSES.txt
MIN_OS="$(python3 -c 'import json; print(json.load(open("dist/Current.app/Contents/Resources/build-info.json"))["minimumSystemVersion"])')"
ARCH="$(uname -m)"
python3 - "$APP" "$VERSION" "$MIN_OS" <<'PY'
import plistlib,sys
from pathlib import Path
app,version,min_os=sys.argv[1:]
values={"CFBundleExecutable":"Current","CFBundleIdentifier":"io.current.downloadmanager","CFBundleName":"Current","CFBundleDisplayName":"Current","CFBundlePackageType":"APPL","CFBundleShortVersionString":version,"CFBundleVersion":version,"LSMinimumSystemVersion":min_os,"NSHighResolutionCapable":True,"CFBundleIconFile":"Current","NSHumanReadableCopyright":"Copyright © 2026 Current contributors. GPL-3.0-or-later.","NSDownloadsFolderUsageDescription":"Current saves the files you choose to download.","NSDocumentsFolderUsageDescription":"Current saves downloads in a folder you choose.","NSAppleEventsUsageDescription":"Current uses standard application actions for its window."}
with open(Path(app)/"Contents/Info.plist","wb") as f: plistlib.dump(values,f)
PY
swift scripts/make-icon.swift .artifacts/icon1024.png
mkdir -p .artifacts/Current.iconset
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" .artifacts/icon1024.png --out ".artifacts/Current.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE*2))
  sips -z "$DOUBLE" "$DOUBLE" .artifacts/icon1024.png --out ".artifacts/Current.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns .artifacts/Current.iconset -o "$APP/Contents/Resources/Current.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/bin/yt-dlp"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/Resources/bin/aria2c" --version > .artifacts/bundled-aria2-version.txt
"$APP/Contents/Resources/bin/ffmpeg" -version > .artifacts/bundled-ffmpeg-version.txt
"$APP/Contents/Resources/bin/yt-dlp" --version > .artifacts/bundled-ytdlp-version.txt
ARCHIVE="dist/Current-${VERSION}-macOS${MIN_OS}-${ARCH}.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
ditto -c -k extensions/chromium "dist/Current-Chromium-${VERSION}.zip"
ditto -c -k extensions/firefox "dist/Current-Firefox-${VERSION}.zip"
printf 'Packaged %s\n' "$ARCHIVE"
printf 'Source bundle: python3 scripts/fetch-third-party-sources.py "%s"\n' "$APP"

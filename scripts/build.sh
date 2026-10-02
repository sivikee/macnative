#!/bin/bash
# Builds MacNative.app into ./build.
#
#   scripts/build.sh            Dev build. Data (engines, prefixes, downloads) goes to ./data in this repo.
#   scripts/build.sh --release  Release build (build/release/). Data goes to ~/Library/Application Support/MacNative.
#
# Only needs the Xcode command line tools; nothing is installed on the system.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="dev"
CONFIG="debug"
if [[ "${1:-}" == "--release" ]]; then MODE="release"; CONFIG="release"; fi

VERSION="0.1.0"
# Release builds go to their own folder so they never replace the dev build (which uses ./data).
if [[ "$MODE" == "release" ]]; then APP="$ROOT/build/release/MacNative.app"; else APP="$ROOT/build/MacNative.app"; fi

cd "$ROOT"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacNative" "$APP/Contents/MacOS/MacNative"
cp -R "$ROOT/Sources/MacNative/Resources/Fonts" "$APP/Contents/Resources/Fonts"
cp -R "$ROOT/Sources/MacNative/Resources/Logo" "$APP/Contents/Resources/Logo"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacNative</string>
  <key>CFBundleDisplayName</key><string>MacNative</string>
  <key>CFBundleIdentifier</key><string>app.macnative.MacNative</string>
  <key>CFBundleExecutable</key><string>MacNative</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>GCSupportsControllerUserInteraction</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ "$MODE" == "dev" ]]; then
  # Keep all runtime data inside the repo (gitignored).
  mkdir -p "$ROOT/data"
  echo "$ROOT/data" > "$APP/Contents/Resources/portable-data-path"
fi

# Ad-hoc signature so macOS treats the bundle as one app (no developer account needed).
codesign --force --deep --sign - "$APP" >/dev/null

echo "Built $APP ($MODE)"
[[ "$MODE" == "dev" ]] && echo "Data folder: $ROOT/data"

#!/bin/bash
# Regenerates the app icon from the logo design.
#
#   scripts/make-icon.sh
#
# Source of truth: Resources/Logo/macnative-icon.svg / macnative-mark.svg.
# scripts/render-icon.swift draws the same design with CoreGraphics (NSImage's SVG
# renderer drops filters), so edit both together.
#
# Outputs:
#   Resources/AppIcon.icns                    (copied into the bundle by scripts/build.sh)
#   Resources/Logo/macnative-icon-1024.png    (full icon, for README / store use)
#   Resources/Logo/macnative-mark-256.png     (transparent glyph)
#
# Only uses the Xcode command line tools (swiftc, iconutil); nothing is installed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O "$ROOT/scripts/render-icon.swift" -o "$TMP/render-icon"

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  "$TMP/render-icon" icon "$size" "$SET/icon_${size}x${size}.png"
  "$TMP/render-icon" icon "$((size * 2))" "$SET/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
"$TMP/render-icon" icon 1024 "$ROOT/Resources/Logo/macnative-icon-1024.png"
"$TMP/render-icon" mark 256 "$ROOT/Resources/Logo/macnative-mark-256.png"

echo "Wrote $ROOT/Resources/AppIcon.icns"

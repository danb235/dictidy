#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from Resources/AppIcon.svg (the equalizer logo).
# Run this whenever the icon art changes. Requires rsvg-convert and iconutil (macOS).
set -euo pipefail
cd "$(dirname "$0")/.."

SVG="Resources/AppIcon.svg"
ICNS="Resources/AppIcon.icns"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

# name:size pairs for a full macOS iconset (1x and 2x)
render() { rsvg-convert -w "$2" -h "$2" "$SVG" -o "$SET/$1"; }
render icon_16x16.png       16
render icon_16x16@2x.png     32
render icon_32x32.png        32
render icon_32x32@2x.png     64
render icon_128x128.png     128
render icon_128x128@2x.png  256
render icon_256x256.png     256
render icon_256x256@2x.png  512
render icon_512x512.png     512
render icon_512x512@2x.png 1024

iconutil -c icns "$SET" -o "$ICNS"
rm -rf "$(dirname "$SET")"
echo "Wrote $ICNS ($(du -h "$ICNS" | cut -f1))"

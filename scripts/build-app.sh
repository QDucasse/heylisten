#!/usr/bin/env bash
# Build build/HeyListen.app: swift build + sprites + Info.plist + codesign.
#   scripts/build-app.sh            release build
#   HEYLISTEN_SIGN_ID="My Cert" scripts/build-app.sh   sign with a stable identity
#     (ad-hoc signing makes macOS forget Accessibility permission on every rebuild)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/HeyListen.app"

( cd "$root/app" && swift build -c release )
bin="$(cd "$root/app" && swift build -c release --show-bin-path)/HeyListen"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/sprites"
cp "$bin" "$app/Contents/MacOS/HeyListen"

# Sprites at scale 1 (mask/detail layers for the tinted avatar, plain PNGs for overlays).
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT   # also on failure
# render.py reports problems on stdout: stay quiet on success, show them (and stop) on failure.
render() {
  local out
  out="$(python3 -I "$root/art/render.py" render "$@" 2>&1)" || { echo "$out" >&2; echo "art render failed: $1" >&2; exit 1; }
}
render "$root/art/tiles" "$tmp/tiles" --split --scale 1
render "$root/art/overlays" "$tmp/overlays" --scale 1
cp "$tmp"/tiles/*_mask.png "$tmp"/tiles/*_detail.png "$app/Contents/Resources/sprites/"
for f in "$tmp"/overlays/*.png; do [ "$(basename "$f")" = sheet.png ] || cp "$f" "$app/Contents/Resources/sprites/"; done
# Unread mark (top-left sparkle on "just finished, not seen yet" avatars).
render "$root/art/marks" "$tmp/marks" --scale 1
for f in "$tmp"/marks/*.png; do [ "$(basename "$f")" = sheet.png ] || cp "$f" "$app/Contents/Resources/sprites/"; done
# Menu bar icon (template silhouette) and app icon (.icns from the 32x32 fairy at every size).
render "$root/art/icon/menu" "$tmp/menu" --scale 1
cp "$tmp/menu/fairy_menu.png" "$app/Contents/Resources/sprites/"
iconset="$tmp/AppIcon.iconset"; mkdir -p "$iconset"
for s in 1 2 4 8 16 32; do   # 32, 64, 128, 256, 512, 1024 px (whole-number scales keep pixels crisp)
  render "$root/art/icon/app" "$tmp/icon$s" --scale $s
done
cp "$tmp/icon1/fairy_app.png"  "$iconset/icon_32x32.png"
cp "$tmp/icon1/fairy_app.png"  "$iconset/icon_16x16@2x.png"
cp "$tmp/icon2/fairy_app.png"  "$iconset/icon_32x32@2x.png"
cp "$tmp/icon4/fairy_app.png"  "$iconset/icon_128x128.png"
cp "$tmp/icon8/fairy_app.png"  "$iconset/icon_128x128@2x.png"
cp "$tmp/icon8/fairy_app.png"  "$iconset/icon_256x256.png"
cp "$tmp/icon16/fairy_app.png" "$iconset/icon_256x256@2x.png"
cp "$tmp/icon16/fairy_app.png" "$iconset/icon_512x512.png"
cp "$tmp/icon32/fairy_app.png" "$iconset/icon_512x512@2x.png"
# 16 px gets its own hand-drawn tile: halving the 32 px art would blur it.
render "$root/art/icon/app16" "$tmp/icon16px" --scale 1
cp "$tmp/icon16px/fairy_app16.png" "$iconset/icon_16x16.png"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.heylisten.app</string>
  <key>CFBundleName</key><string>heylisten</string>
  <key>CFBundleDisplayName</key><string>heylisten</string>
  <key>CFBundleExecutable</key><string>HeyListen</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>heylisten focuses and opens iTerm windows for your Claude sessions.</string>
</dict>
</plist>
PLIST

sign="${HEYLISTEN_SIGN_ID:-}"
if [ -z "$sign" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"heylisten-dev"'; then
  sign="heylisten-dev"
fi
codesign --force --sign "${sign:--}" "$app" >/dev/null
echo "built $app (signed: ${sign:-ad-hoc; run scripts/make-signing-identity.sh to keep permissions across rebuilds})"

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
python3 -I "$root/art/render.py" render "$root/art/tiles" "$tmp/tiles" --split --scale 1 >/dev/null
python3 -I "$root/art/render.py" render "$root/art/overlays" "$tmp/overlays" --scale 1 >/dev/null
cp "$tmp"/tiles/*_mask.png "$tmp"/tiles/*_detail.png "$app/Contents/Resources/sprites/"
for f in "$tmp"/overlays/*.png; do [ "$(basename "$f")" = sheet.png ] || cp "$f" "$app/Contents/Resources/sprites/"; done
rm -rf "$tmp"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.heylisten.app</string>
  <key>CFBundleName</key><string>heylisten</string>
  <key>CFBundleDisplayName</key><string>heylisten</string>
  <key>CFBundleExecutable</key><string>HeyListen</string>
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

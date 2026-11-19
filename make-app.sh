#!/bin/zsh
# Builds "Betta Lite.app" (with an icon the fish draws itself) and puts it in ~/Applications.
#
#   ./make-app.sh
#
# Then open it from there (or Spotlight), and turn on "Open at Login" in the fish's menu.

set -e
cd "$(dirname "$0")"

# UNIVERSAL=1: for Apple silicon and Intel both; INSTALL=0: only build it, into dist/
ARCHS=()
[[ -n "$UNIVERSAL" ]] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/BettaLite"
NAME="Betta Lite"
APP="dist/$NAME.app"

rm -rf "$APP" dist/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist/AppIcon.iconset
cp "$BIN" "$APP/Contents/MacOS/BettaLite"

# the icon: the fish just after it has drawn itself
"$BIN" --icon dist/icon_1024.png
for s in 16 32 128 256 512; do
    sips -z $s $s dist/icon_1024.png --out "dist/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) dist/icon_1024.png --out "dist/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns dist/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>io.github.mjasevicius.betta-lite</string>
    <key>CFBundleExecutable</key><string>BettaLite</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" 2>/dev/null

[[ "$INSTALL" == 0 ]] && { echo "Built $APP"; exit 0; }

mkdir -p ~/Applications
rm -rf ~/Applications/"$NAME.app"
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/$NAME.app"

#!/bin/bash
# Package the built binary as a menu bar app (LSUIElement = no Dock icon).
set -e
cd "$(dirname "$0")"
swift build -c release --product soundcorectl
APP="build/SoundcoreBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/soundcorectl "$APP/Contents/MacOS/SoundcoreBridge"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>          <string>com.mervin.soundcorebridge</string>
    <key>CFBundleName</key>                <string>SoundcoreBridge</string>
    <key>CFBundleDisplayName</key>         <string>SoundcoreBridge</string>
    <key>CFBundleExecutable</key>          <string>SoundcoreBridge</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>0.2</string>
    <key>CFBundleVersion</key>             <string>2</string>
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>SoundcoreBridge talks to your Soundcore headset to read and change its settings.</string>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "built $APP"

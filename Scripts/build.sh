#!/usr/bin/env bash
# Build sudoor.app (menu bar agent + island-prompt helper) into ~/Applications.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/sudoor.app"

echo "==> swift build -c release"
( cd "$REPO" && swift build -c release )
BIN="$(cd "$REPO" && swift build -c release --show-bin-path)"

echo "==> assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SudoorBar"    "$APP/Contents/MacOS/sudoor"
cp "$BIN/IslandPrompt" "$APP/Contents/MacOS/island-prompt"
cp "$REPO/assets/menubar.png" "$APP/Contents/Resources/menubar.png"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>        <string>com.sudoor.app</string>
    <key>CFBundleName</key>              <string>sudoor</string>
    <key>CFBundleDisplayName</key>       <string>sudoor</string>
    <key>CFBundleExecutable</key>        <string>sudoor</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>  <string>sudoor — Stop babysitting the terminal.</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc signing (required for SMAppService login item)"
codesign --force --sign - --identifier com.sudoor.app "$APP" >/dev/null 2>&1 \
  || echo "   (codesign failed — login item may not register)"

echo "==> done: $APP"

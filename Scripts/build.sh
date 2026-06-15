#!/usr/bin/env bash
# Build sudoor.app (menu bar agent + island-prompt helper) into ~/Applications.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="${SUDOOR_APP_OUT:-$HOME/Applications/sudoor.app}"
ARCHS=""; [ "${SUDOOR_UNIVERSAL:-0}" = "1" ] && ARCHS="--arch arm64 --arch x86_64"

echo "==> swift build -c release ${ARCHS}"
( cd "$REPO" && swift build -c release $ARCHS )
BIN="$(cd "$REPO" && swift build -c release $ARCHS --show-bin-path)"

echo "==> assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SudoorBar"    "$APP/Contents/MacOS/sudoor"
cp "$BIN/IslandPrompt" "$APP/Contents/MacOS/island-prompt"
cp "$REPO/assets/menubar.png" "$APP/Contents/Resources/menubar.png"
cp "$REPO/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>        <string>com.sudoor.app</string>
    <key>CFBundleName</key>              <string>sudoor</string>
    <key>CFBundleDisplayName</key>       <string>sudoor</string>
    <key>CFBundleExecutable</key>        <string>sudoor</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
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

echo "==> code signing"
# Prefer Developer ID (notarizable), then Apple Development (stable local
# identity — keeps TCC grants + login item across rebuilds), else ad-hoc.
SIGN_ID="${SUDOOR_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning | awk -F\" '/Developer ID Application/{print $2; exit}')"
  [ -z "$SIGN_ID" ] && SIGN_ID="$(security find-identity -v -p codesigning | awk -F\" '/Apple Development/{print $2; exit}')"
fi
HARDEN=""; [ "${SUDOOR_HARDENED:-0}" = "1" ] && HARDEN="--options runtime --timestamp"
if [ -n "$SIGN_ID" ]; then
  codesign --force $HARDEN --sign "$SIGN_ID" "$APP/Contents/MacOS/island-prompt" >/dev/null 2>&1 || true
  codesign --force $HARDEN --sign "$SIGN_ID" "$APP" >/dev/null 2>&1 \
    && echo "   signed: $SIGN_ID" || echo "   sign failed, falling back to ad-hoc"
else
  codesign --force --sign - --identifier com.sudoor.app "$APP" >/dev/null 2>&1 || true
  echo "   ad-hoc signed (no Developer ID / Apple Development cert found)"
fi

echo "==> done: $APP"

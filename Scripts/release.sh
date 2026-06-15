#!/usr/bin/env bash
# Build a universal, Developer ID-signed, notarized, stapled sudoor.app + zip.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your keychain.
#      Xcode → Settings → Accounts → (your Apple ID) → Manage Certificates
#        → + → "Developer ID Application".
#   2. A stored notarytool credential profile named "sudoor":
#      xcrun notarytool store-credentials sudoor \
#        --apple-id "<your-apple-id>" --team-id "<TEAMID>" \
#        --password "<app-specific-password from appleid.apple.com>"
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$REPO/dist"
APP="$DIST/sudoor.app"
ZIP="$DIST/sudoor.zip"
PROFILE="${SUDOOR_NOTARY_PROFILE:-sudoor}"

DEVID="$(security find-identity -v -p codesigning | awk -F\" '/Developer ID Application/{print $2; exit}')"
if [ -z "$DEVID" ]; then
  echo "ERROR: no 'Developer ID Application' certificate found."
  echo "Create one: Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application"
  exit 1
fi
echo "==> Developer ID: $DEVID"

# Build universal + hardened + Developer-ID signed into dist/ (reuses build.sh).
rm -rf "$DIST"; mkdir -p "$DIST"
SUDOOR_APP_OUT="$APP" SUDOOR_UNIVERSAL=1 SUDOOR_HARDENED=1 SUDOOR_SIGN_ID="$DEVID" \
  bash "$REPO/Scripts/build.sh"

echo "==> verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> notarizing (this uploads the zip to Apple and waits)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Re-zip the stapled app for distribution.
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> done: $ZIP (universal · Developer ID · notarized · stapled)"

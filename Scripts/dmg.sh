#!/usr/bin/env bash
# Wrap a built sudoor.app into a drag-to-install sudoor.dmg.
#
# Usage:  Scripts/dmg.sh [path/to/sudoor.app]   (defaults to dist/sudoor.app)
# Output: dist/sudoor.dmg
#
# Note: this only packages the .app — it does not sign or notarize. For a
# Gatekeeper-clean download, build the app via Scripts/release.sh first
# (Developer ID + notarization), then point this at dist/sudoor.app.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$REPO/dist/sudoor.app}"
DMG="$REPO/dist/sudoor.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

[ -d "$APP" ] || { echo "ERROR: app not found: $APP (run Scripts/build.sh first)"; exit 1; }

echo "==> staging $APP"
cp -R "$APP" "$STAGE/sudoor.app"
ln -s /Applications "$STAGE/Applications"

echo "==> building $DMG"
rm -f "$DMG"
hdiutil create -volname "sudoor" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> done: $DMG"
hdiutil verify "$DMG" >/dev/null && echo "==> verified"

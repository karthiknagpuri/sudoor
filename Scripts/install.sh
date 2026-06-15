#!/usr/bin/env bash
# Build + install sudoor: the app to ~/Applications and the hook to ~/bin.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# 1. Build the app bundle.
bash "$REPO/Scripts/build.sh"

# 2. Install the Claude Code permission hook.
mkdir -p "$HOME/bin"
cp "$REPO/hooks/claude-permission-hook.sh" "$HOME/bin/claude-permission-hook.sh"
chmod +x "$HOME/bin/claude-permission-hook.sh"
echo "==> hook installed: ~/bin/claude-permission-hook.sh"

# 3. Launch (registers the SMAppService login item on first run).
open "$HOME/Applications/sudoor.app"

cat <<'NOTE'

==> Almost done. Add this to ~/.claude/settings.json (merge with existing hooks):

  { "hooks": { "PermissionRequest": [
      { "hooks": [ { "type": "command",
          "command": "~/bin/claude-permission-hook.sh" } ] } ] } }

Then restart Claude Code (hooks load at session start).
NOTE

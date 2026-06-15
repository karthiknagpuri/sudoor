# Install

## Requirements
- macOS 14+ (Apple silicon), Xcode command-line tools (`swift`), Python 3 (ships with the CLT).
- Claude Code with `PermissionRequest` hook support.

## 1. Build & install

```sh
./Scripts/install.sh
```

This compiles the package, assembles `~/Applications/sudoor.app` (ad-hoc signed), installs the hook to `~/bin/claude-permission-hook.sh`, and launches the app (which registers itself as a login item).

## 2. Register the hook

Add this to `~/.claude/settings.json` (merge with any existing `hooks`):

```json
{
  "hooks": {
    "PermissionRequest": [
      { "hooks": [ { "type": "command", "command": "~/bin/claude-permission-hook.sh" } ] }
    ]
  }
}
```

## 3. Restart Claude Code

Hooks load at session start. Your next permission prompt drops out of the notch.

## 4. Grant permissions (one-time)

The first prompt in each terminal triggers a macOS permission dialog:
- **Terminal / iTerm** → "Terminal wants to control …" (Automation). Approve it.
- **Cursor / VS Code** → an Accessibility prompt. Approve it (or minimize silently no-ops).

## Configuration

- Toggle **Show requesting terminal** from the menu bar (also gates the window raise/minimize).
- `CLAUDE_PERMISSION_TIMEOUT` (default 30) — seconds before the island defers to the CLI prompt.
- `ISLAND_PROMPT` — override the path to the `island-prompt` binary.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.sudoor.app 2>/dev/null   # remove login item
rm -rf ~/Applications/sudoor.app ~/bin/claude-permission-hook.sh ~/.island
```
Then remove the `PermissionRequest` block from `~/.claude/settings.json`.

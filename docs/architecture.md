# Architecture

sudoor is three small pieces plus a shared state directory.

```
Claude Code ──(PermissionRequest)──▶ hooks/claude-permission-hook.sh
                                          │
                          writes ~/.island/pending/<pid>.json
                                          │ launches
                                          ▼
                            Sources/IslandPrompt  (the notch popup)
                                          │ prints "Approve" | "Disapprove" | ""
                                          ▼
                          hook emits {"behavior":"allow"|"deny"} on stdout
                                          │ updates (flock) ~/.island/config.json + history.jsonl
                                          ▼
                            Sources/SudoorBar  (menu bar agent, polls ~/.island)
```

## Components

### `hooks/claude-permission-hook.sh`
The Claude Code `PermissionRequest` hook. Reads the tool request JSON on stdin, detects the requesting terminal (`$TERM_PROGRAM` + ancestor-walked tty), writes a `pending` record, raises that window, launches `island-prompt`, then emits the decision on stdout and minimizes the window. On timeout it prints nothing → Claude falls back to the normal CLI prompt.

- **tty detection** — hooks are spawned detached (no controlling tty), so it walks the process tree to find the ancestor (Claude Code) that holds the terminal's tty.
- **window control** — Terminal & iTerm by tty via AppleScript (Automation); Cursor & VS Code front-window via System Events (Accessibility).

### `Sources/IslandPrompt`
A faceless SwiftUI/AppKit binary. Draws the black pill at the notch with a genie animation, shows `app · project · tty` + the command + Approve/Disapprove, and prints the choice to **stdout** (the hook captures it). Times out → prints nothing.

### `Sources/SudoorBar`
The menu bar agent. Shows the alien template icon, a blinking dot + handled counter, a live "Requesting now" list (reads `~/.island/pending/`), recent history, a "Show requesting terminal" toggle, and a "Start at login" `SMAppService` item. Built into `sudoor.app`; `island-prompt` ships as a sibling binary in `Contents/MacOS/`.

## State — `~/.island/`

| Path | What |
|---|---|
| `config.json` | `{ showTerminal, count }` — atomic, flock-protected (shared by hook + app) |
| `pending/<pid>.json` | one record per in-flight prompt (terminal, project, tool, detail) |
| `history.jsonl` | last 20 resolved requests with outcome |
| `.state.lock` | flock file guarding `config.json` + `history.jsonl` |

## Permissions

- **Automation** — control Terminal / iTerm to raise & minimize windows by tty.
- **Accessibility** — minimize Cursor / VS Code front windows (Electron, not scriptable by tty).

Nothing leaves the machine.

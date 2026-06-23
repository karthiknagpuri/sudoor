# Architecture

sudoor is three small pieces plus a shared state directory.

```
Claude Code ──(PermissionRequest)──▶ hooks/claude-permission-hook.sh
                                          │
                               loads policy + classifies risk
                                          │
                    ┌──────── auto allow/deny/delegate ────────┐
                    │                                           │
                    │      writes ~/.island/pending/<pid>.json  │
                    │                       │ launches          │
                    │                       ▼                   │
                    │         Sources/IslandPrompt  (notch UI)  │
                    │                       │                   │
                    └─────────────── emits decision ◀───────────┘
                                          │
                  updates (flock) ~/.island/config.json + history.jsonl
                                          ▼
                            Sources/SudoorBar  (menu bar agent, polls ~/.island)
```

## Components

### `hooks/claude-permission-hook.sh`
The Claude Code `PermissionRequest` hook. Reads the tool request JSON on stdin, detects the requesting terminal (`$TERM_PROGRAM` + ancestor-walked tty), evaluates policy/risk, writes a `pending` record when human input is needed, raises that window, launches `island-prompt`, then emits the decision on stdout and minimizes the window. On timeout it prints nothing → Claude falls back to the normal CLI prompt.

- **tty detection** — hooks are spawned detached (no controlling tty), so it walks the process tree to find the ancestor (Claude Code) that holds the terminal's tty.
- **window control** — Terminal & iTerm by tty via AppleScript (Automation); Cursor & VS Code front-window via System Events (Accessibility).
- **policy evaluation** — loads managed/user JSON policy before prompting. Rules can auto-allow, auto-deny, ask, or delegate high-risk actions.
- **risk classification** — tags destructive commands, privilege escalation, package installs, publishing, remote scripts, network/cloud commands, file writes, and possible secret exposure.
- **agent normalization** — accepts Claude's `tool_name`/`tool_input` shape and a generic adapter shape: `agent`, `tool`, `command`, `detail`, `cwd`, `workdir`. Set `SUDOOR_AGENT` when an adapter cannot include the agent name in JSON.

### `Sources/IslandPrompt`
A faceless SwiftUI/AppKit binary. Draws the black pill at the notch with a genie animation, shows `app · project · tty` + the command + Approve/Disapprove, and prints the choice to **stdout** (the hook captures it). Times out → prints nothing.

### `Sources/SudoorBar`
The menu bar agent. Shows the alien template icon, a blinking dot + handled counter, a live permission queue (reads `~/.island/pending/`), recent history, a "Show requesting terminal" toggle (window raise/minimize only), and a "Start at login" `SMAppService` item. Optional extras (GitHub heatmap, arXiv tips, X followers, bookmarks) may call external APIs when configured. Built into `sudoor.app`; `island-prompt` ships as a sibling binary in `Contents/MacOS/`.

## State — `~/.island/`

| Path | What |
|---|---|
| `config.json` | `{ showTerminal, count }` — atomic, flock-protected (shared by hook + app) |
| `policy.json` | user/team policy rules |
| `policies/*.json` | additional policy fragments |
| `pending/<pid>.json` | one record per in-flight prompt (terminal, project, tool, detail, risk, policy metadata) |
| `history.jsonl` | last 200 resolved requests with outcome, risk, rule, delegate, and source |
| `.state.lock` | flock file guarding `config.json` + `history.jsonl` |

Managed enterprise policy can also live at:

| Path | What |
|---|---|
| `/Library/Application Support/sudoor/policy.json` | centrally deployed policy, read before user policy |

## Policy

Policy files are JSON:

```json
{
  "version": 1,
  "rules": [
    {
      "id": "deny-recursive-root-delete",
      "effect": "deny",
      "match": {
        "tool": "Bash",
        "commandRegex": "(^|[;&|]\\s*)rm\\s+(-[A-Za-z]*r[A-Za-z]*f|-rf|-fr)\\s+(/|~|\\$HOME)(\\s|$)"
      }
    }
  ],
  "projects": {
    "sudoor": {
      "rules": [
        {
          "id": "ask-before-release",
          "effect": "ask",
          "match": { "commandContains": "Scripts/release.sh" }
        }
      ]
    }
  }
}
```

Rule effects:

| Effect | Behavior |
|---|---|
| `allow` | Emits Claude's allow decision immediately; no UI prompt. |
| `deny` | Emits Claude's deny decision immediately; no UI prompt. |
| `ask` | Shows the Sudoor prompt. |
| `delegate` | Calls `$SUDOOR_DELEGATE_COMMAND` with request JSON. If it returns `{"behavior":"allow"}` or `{"behavior":"deny"}`, Sudoor uses that decision. Otherwise it falls back to the local prompt. |

Supported match keys: `tool`, `project`, `commandContains`, `commandRegex`, `cwdPrefix`, `cwdRegex`, `minRisk`.

`docs/policy.example.json` is a starter policy.

## Agent Adapters

The current hook is wired for Claude Code, but the policy engine is agent-agnostic. Other tools can reuse it by sending a normalized JSON request on stdin:

```json
{
  "agent": "codex",
  "tool": "Bash",
  "command": "npm install",
  "cwd": "/Users/example/project"
}
```

If the upstream tool cannot include `agent`, set `SUDOOR_AGENT=cursor`, `SUDOOR_AGENT=goose`, `SUDOOR_AGENT=cline`, or another stable name in the wrapper environment. The hook will record that value in pending records and audit history.

## Audit Export

`Scripts/audit-export.sh` exports the local history:

```sh
Scripts/audit-export.sh jsonl
Scripts/audit-export.sh csv
```

For SIEM or centralized collection, run this over the managed fleet and ingest the CSV/JSONL output. The history is intentionally local-first; Sudoor does not send it anywhere by default.

## Permissions

- **Automation** — control Terminal / iTerm to raise & minimize windows by tty.
- **Accessibility** — minimize Cursor / VS Code front windows (Electron, not scriptable by tty).

Nothing leaves the machine.

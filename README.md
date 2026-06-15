<div align="center">
  <img src="assets/logo-black.png#gh-light-mode-only" height="84" alt="sudoor">
  <img src="assets/logo-white.png#gh-dark-mode-only" height="84" alt="sudoor">
  <h1>sudoor</h1>
  <p><b>Stop babysitting the terminal.</b></p>
  <p>Catch your AI coding agent's permission prompts in a Dynamic Island at the notch.<br>Approve or deny at a glance — then get back to work.</p>
  <p><a href="https://sudoor.bar">sudoor.bar</a> · macOS 14+ · Apple silicon · MIT</p>
</div>

---

## What it is

When Claude Code wants to run a command, edit a file, or hit the network, it asks for permission. `sudoor` intercepts that ask with a **PermissionRequest hook**, drops it into a **Dynamic Island at your MacBook notch**, raises the exact terminal window that's asking, and lets you **Approve / Disapprove** in one click. Decide, and the window tucks itself away. You never break flow or babysit a terminal again.

Works with **Claude Code** running in Terminal, iTerm, Cursor, and VS Code.

## How it works

```
agent asks → hook fires → island genies out of the notch → you nod → decision returns to the agent
```

1. **Your agent knocks** — the `PermissionRequest` hook intercepts before the CLI prompt.
2. **sudoor opens the door** — the Dynamic Island shows the terminal · project · tty and the command; that window comes forward.
3. **You nod, it runs** — Approve → `{"behavior":"allow"}`, Disapprove → `{"behavior":"deny"}`, ignore → it times out and defers to the normal CLI prompt. The window minimizes.

## Features

- **Dynamic Island at the notch** — genie-in / genie-out, no modal dialog.
- **Knows who's asking** — every prompt is tagged `app · project · ttys004` and raises that exact window (Terminal & iTerm by tty; Cursor & VS Code by app).
- **Menu bar agent** — an 👽 alien mark with a blinking dot when a terminal is waiting, a live "Requesting now" list across sessions, recent history, and a handled counter.
- **Auto window control** — raises the requesting window, minimizes it after you decide.
- **Local & private** — all state in `~/.island/config.json` (atomic, flock-protected). No accounts, no telemetry, no network.

## Install

```sh
git clone https://github.com/karthiknagapuri/sudoor.git
cd sudoor
./Scripts/install.sh
```

Then add the hook to `~/.claude/settings.json` and restart Claude Code — see [docs/install.md](docs/install.md).

## Build

```sh
swift build -c release      # compiles IslandPrompt + SudoorBar
./Scripts/build.sh          # assembles ~/Applications/sudoor.app (ad-hoc signed)
```

## Layout

```
Sources/IslandPrompt/   the notch popup (SwiftUI/AppKit, returns the decision on stdout)
Sources/SudoorBar/      the menu bar agent (AppKit + SMAppService login item)
hooks/                  claude-permission-hook.sh — the PermissionRequest hook
Scripts/                build.sh, install.sh
assets/                 logo, menu-bar icon, OG image
site/                   the sudoor.bar landing page
docs/                   architecture + install guides
```

## License

MIT © Karthik Nagapuri

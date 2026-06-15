# Contributing to sudoor

Thanks for helping out. sudoor is small — three files do the real work — so getting in is quick.

## Setup

```sh
git clone https://github.com/karthiknagapuri/sudoor.git
cd sudoor
make build        # compile both targets
make app          # assemble ~/Applications/sudoor.app
make install      # build + install the hook too
```

## Before you push

```sh
make check        # SwiftLint + hook-contract test
```

CI (macOS) runs the same: `swift build`, `swiftlint`, the contract test, and a packaging step. Keep them green.

## Where things live

| Path | What |
|---|---|
| `Sources/IslandPrompt/` | the notch popup (returns the decision on stdout) |
| `Sources/SudoorBar/` | the menu bar agent |
| `hooks/claude-permission-hook.sh` | the Claude Code `PermissionRequest` hook |
| `Tests/hook-contract.sh` | headless contract test (stubs `island-prompt`) |

See [docs/architecture.md](docs/architecture.md) for how they fit together.

## Style

- SwiftLint config in `.swiftlint.yml`. Run `make lint`.
- Match the existing terse, comment-light style. These are compact single-file executables, not a framework.
- Shell: keep `set -euo pipefail`; guard external calls with `|| true`; never interpolate untrusted text into AppleScript (pass it as `argv`).

## Commits & PRs

- Small, focused commits. Imperative subject ("Add X", "Fix Y").
- One logical change per PR. Update `CHANGELOG.md` for user-facing changes.
- New behavior that touches the hook contract → add/extend `Tests/hook-contract.sh`.

## Scope

sudoor is intentionally minimal: permission control at the notch for Claude Code. Quota tracking, multi-provider dashboards, and widgets are out of scope by design.

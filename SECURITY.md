# Security Policy

sudoor sits in a sensitive spot — it decides whether an AI agent's command runs. Security reports are taken seriously.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Email **19h61a3538@cvsr.ac.in** with:

- what the issue is and where (`hooks/`, `Sources/IslandPrompt`, `Sources/SudoorBar`),
- steps to reproduce,
- impact (e.g. a path that could auto-approve, leak the command, or escalate).

You'll get an acknowledgement within a few days.

## Trust model

- **Permission path is local.** The `PermissionRequest` hook, policy evaluation, island UI, and audit history never leave your machine. State lives in `~/.island/`.
- **Menu bar extras may use the network.** Optional SudoorBar features (GitHub contributions heatmap, arXiv research tips, X follower count, bookmark favicons) call external APIs only when you configure them. They do not affect allow/deny decisions. X API bearer tokens are stored in the macOS Keychain (`sudoor` service), not in plaintext config.
- **The hook decides permissions.** A bug that makes it emit `allow` without your click is a high-severity issue.
- **Untrusted input.** Tool commands/args come from the agent and are treated as untrusted: passed to `island-prompt` and window-control `osascript` as **argv only** (never interpolated into AppleScript source). Dialog fallbacks also pass message and timeout as argv.
- **macOS permissions.** Automation (Terminal/iTerm) and Accessibility (Cursor/VS Code) are requested only to raise/minimize the requesting window.

## Known non-issues

- The app is **ad-hoc signed** for local builds. Distribution builds should be Developer ID signed + notarized; an unsigned local build is expected.
- **`SUDOOR_DELEGATE_COMMAND`** runs a user-configured binary during policy evaluation — intentional for enterprise deployments; misconfiguration can auto-allow/deny without UI.

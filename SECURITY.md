# Security Policy

sudoor sits in a sensitive spot — it decides whether an AI agent's command runs. Security reports are taken seriously.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Email **19h61a3538@cvsr.ac.in** with:

- what the issue is and where (`hooks/`, `Sources/IslandPrompt`, `Sources/SudoorBar`),
- steps to reproduce,
- impact (e.g. a path that could auto-approve, leak the command, or escalate).

You'll get an acknowledgement within a few days.

## Trust model

- **Local only.** sudoor makes no network calls. State lives in `~/.island/` and never leaves the machine.
- **The hook decides permissions.** A bug that makes it emit `allow` without your click is a high-severity issue.
- **Untrusted input.** The tool command/args come from the agent and are treated as untrusted: passed to `island-prompt` and `osascript` as **argv only** (never interpolated into a shell or AppleScript string). The one legacy `osascript` *dialog* fallback path is the exception — flag any injection there.
- **macOS permissions.** Automation (Terminal/iTerm) and Accessibility (Cursor/VS Code) are requested only to raise/minimize the requesting window.

## Known non-issues

- The app is **ad-hoc signed** for local builds. Distribution builds should be Developer ID signed + notarized; an unsigned local build is expected.

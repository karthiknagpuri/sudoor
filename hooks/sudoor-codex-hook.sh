#!/usr/bin/env bash
set -euo pipefail

export SUDOOR_AGENT=codex

in="$(cat)"
LOG_DIR="${SUDOOR_STATE_DIR:-$HOME/.island}"
HOOK="${SUDOOR_HOOK:-$HOME/bin/claude-permission-hook.sh}"
mkdir -p "$LOG_DIR" 2>/dev/null || true

rotate_log() {
  local file="$1" max="${2:-5000}"
  [ -f "$file" ] || return 0
  local n
  n="$(wc -l < "$file" 2>/dev/null | tr -d '[:space:]')"
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [ "$n" -le "$max" ] && return 0
  tail -n "$max" "$file" > "${file}.rotate.tmp" 2>/dev/null && mv "${file}.rotate.tmp" "$file"
}

rotate_log "$LOG_DIR/codex-raw.log"
{ echo "--- $(date '+%T') IN ---"; printf '%s\n' "$in"; } >> "$LOG_DIR/codex-raw.log" 2>/dev/null

# Island decision window. Kept under Codex's hook `timeout` (config.toml, 30s) so
# the island returns before Codex kills the hook. Mirrors Claude's ~30s feel.
claude_out="$(printf '%s' "$in" | CLAUDE_PERMISSION_TIMEOUT="${CLAUDE_PERMISSION_TIMEOUT:-25}" "$HOOK")"
behavior="$(printf '%s' "$claude_out" | /usr/bin/python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("hookSpecificOutput", {}).get("decision", {}).get("behavior", ""))
except Exception:
    print("")' 2>/dev/null || true)"

# Codex's PermissionRequest hook contract (codex-cli 0.140) expects the decision
# inside hookSpecificOutput.permissionDecision (allow|deny|ask), matching Claude
# Code. A bare {"decision":"allow"} string is rejected as "invalid permission-request
# JSON output" and the decision is silently dropped.
case "$behavior" in
  allow)
    out='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","permissionDecision":"allow"}}'
    ;;
  deny)
    out='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","permissionDecision":"deny","permissionDecisionReason":"Denied by Sudoor"}}'
    ;;
  *)
    out='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","permissionDecision":"ask"}}'
    ;;
esac

{ echo "--- OUT ---"; printf '%s\n' "$out"; } >> "$LOG_DIR/codex-raw.log" 2>/dev/null
printf '%s' "$out"

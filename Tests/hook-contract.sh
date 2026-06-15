#!/usr/bin/env bash
# Contract test for hooks/claude-permission-hook.sh — runs headless by stubbing
# island-prompt (via ISLAND_PROMPT) so no GUI is needed. CI-safe on macOS.
set -uo pipefail
cd "$(dirname "$0")/.."
HOOK="hooks/claude-permission-hook.sh"
REQ='{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp"}'
fails=0

echo "1. syntax"
bash -n "$HOOK" && echo "   ok" || { echo "   FAIL: syntax"; exit 1; }

run() { # $1 = stub choice -> echoes hook stdout
  local stub; stub="$(mktemp)"
  printf '#!/bin/sh\n[ -n "%s" ] && echo "%s"\n' "$1" "$1" > "$stub"; chmod +x "$stub"
  printf '%s' "$REQ" | CLAUDE_PERMISSION_TIMEOUT=1 ISLAND_PROMPT="$stub" bash "$HOOK"
  rm -f "$stub"
}

check() { # $1 desc, $2 actual, $3 expected-substring (empty = expect no output)
  if [ -z "$3" ]; then
    [ -z "$2" ] && echo "   ok: $1" || { echo "   FAIL: $1 (expected empty, got: $2)"; fails=$((fails+1)); }
  else
    case "$2" in *"$3"*) echo "   ok: $1";; *) echo "   FAIL: $1 (missing $3 in: $2)"; fails=$((fails+1));; esac
  fi
}

echo "2. decision contract"
check "Approve -> allow"      "$(run Approve)"     '"behavior":"allow"'
check "Disapprove -> deny"    "$(run Disapprove)"  '"behavior":"deny"'
check "timeout -> defer (no output)" "$(run '')"   ''

echo
[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }

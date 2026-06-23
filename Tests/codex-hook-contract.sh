#!/usr/bin/env bash
# Contract test for hooks/sudoor-codex-hook.sh — the Codex adapter.
# Codex (codex-cli 0.140+) PermissionRequest hooks must emit the decision inside
# hookSpecificOutput.permissionDecision (allow|deny|ask). A bare {"decision":"allow"}
# string is rejected as "invalid permission-request JSON output" and dropped.
# This test stubs the underlying island hook (via SUDOOR_HOOK) so no GUI is needed.
set -uo pipefail
cd "$(dirname "$0")/.."
WRAP="hooks/sudoor-codex-hook.sh"
EVENT='{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}'
fails=0

echo "1. syntax"
bash -n "$WRAP" && echo "   ok" || { echo "   FAIL: syntax"; exit 1; }

# Stub the island hook to emit the real claude-permission-hook.sh output shape
# ({"hookSpecificOutput":{...,"decision":{"behavior":"<b>"}}}) for a given behavior.
run() { # $1 = allow|deny|"" (empty = defer)
  local stub state out
  stub="$(mktemp)"; state="$(mktemp -d)"
  if [ -n "$1" ]; then
    printf '#!/bin/sh\nprintf %s\n' \
      "'{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"$1\"}}}'" > "$stub"
  else
    printf '#!/bin/sh\ntrue\n' > "$stub"  # underlying hook defers (no output)
  fi
  chmod +x "$stub"
  out="$(printf '%s' "$EVENT" | SUDOOR_STATE_DIR="$state" SUDOOR_HOOK="$stub" bash "$WRAP")"
  rm -f "$stub"; rm -rf "$state"
  printf '%s' "$out"
}

# Validate output is a Codex-accepted PermissionRequest decision.
codex_decision() { # stdin = wrapper output; echoes allow|deny|ask|INVALID|EMPTY
  /usr/bin/python3 -c '
import json,sys
s=sys.stdin.read().strip()
if not s: print("EMPTY"); sys.exit(0)
try: o=json.loads(s)
except Exception: print("INVALID"); sys.exit(0)
hso=o.get("hookSpecificOutput")
if isinstance(hso,dict) and hso.get("hookEventName")=="PermissionRequest" \
   and hso.get("permissionDecision") in ("allow","deny","ask"):
    print(hso["permissionDecision"]); sys.exit(0)
d=o.get("decision")
if isinstance(d,dict) and d.get("behavior") in ("allow","deny"):
    print(d["behavior"]); sys.exit(0)
print("INVALID")'
}

check() { # $1 desc, $2 actual, $3 expected
  if [ "$2" = "$3" ]; then echo "   ok: $1"
  else echo "   FAIL: $1 (expected '$3', got '$2')"; fails=$((fails+1)); fi
}

echo "2. codex decision contract"
check "allow -> permissionDecision allow" "$(run allow | codex_decision)" "allow"
check "deny  -> permissionDecision deny"  "$(run deny  | codex_decision)" "deny"
check "defer -> permissionDecision ask"       "$(run ''    | codex_decision)" "ask"

echo
[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }

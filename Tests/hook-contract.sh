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

run() { # $1 = stub choice, $2 = request json, $3 = optional policy json
  local stub tmp_state req policy
  req="${2:-$REQ}"
  policy="${3:-}"
  stub="$(mktemp)"
  tmp_state="$(mktemp -d)"
  [ -n "$policy" ] && printf '%s' "$policy" > "$tmp_state/policy.json"
  printf '#!/bin/sh\n[ -n "%s" ] && echo "%s"\n' "$1" "$1" > "$stub"; chmod +x "$stub"
  printf '%s' "$req" | HOME="$tmp_state" SUDOOR_STATE_DIR="$tmp_state" CLAUDE_PERMISSION_TIMEOUT=1 ISLAND_PROMPT="$stub" bash "$HOOK"
  rm -f "$stub"
  rm -rf "$tmp_state"
}

check() { # $1 desc, $2 actual, $3 expected-substring (empty = expect no output)
  if [ -z "$3" ]; then
    [ -z "$2" ] && echo "   ok: $1" || { echo "   FAIL: $1 (expected empty, got: $2)"; fails=$((fails+1)); }
  else
    case "$2" in *"$3"*) echo "   ok: $1";; *) echo "   FAIL: $1 (missing $3 in: $2)"; fails=$((fails+1));; esac
  fi
}

echo "2. decision contract"
check "Approve -> allow"      "$(run Approve "$REQ")"     '"behavior":"allow"'
check "Disapprove -> deny"    "$(run Disapprove "$REQ")"  '"behavior":"deny"'
check "timeout -> defer (no output)" "$(run '' "$REQ")"   ''

echo "3. policy contract"
ALLOW_POLICY='{"version":1,"rules":[{"id":"allow-ls","effect":"allow","match":{"tool":"Bash","commandRegex":"^ls(\\s|$)"}}]}'
DENY_POLICY='{"version":1,"rules":[{"id":"deny-rm","effect":"deny","match":{"tool":"Bash","commandContains":"rm -rf /"}}]}'
RISK_REQ='{"tool_name":"Bash","tool_input":{"command":"rm -rf /"},"cwd":"/tmp"}'
GENERIC_REQ='{"agent":"codex","tool":"Bash","command":"ls","cwd":"/tmp"}'
check "policy allow -> allow without prompt" "$(run '' "$REQ" "$ALLOW_POLICY")" '"behavior":"allow"'
check "policy deny -> deny without prompt" "$(run '' "$RISK_REQ" "$DENY_POLICY")" '"behavior":"deny"'
check "generic adapter request -> allow" "$(run '' "$GENERIC_REQ" "$ALLOW_POLICY")" '"behavior":"allow"'

echo "4. risk classification (minRisk:high deny gate)"
# A minRisk gate only fires if the classifier scores the command high/critical.
# Recursive force-deletes of root, system dirs, or home must be >= high.
HIRISK_DENY='{"version":1,"rules":[{"id":"deny-highrisk","effect":"deny","match":{"minRisk":"high"}}]}'
req_rm() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"/tmp"}' "$1"; }
check "rm -rf / -> high-risk -> denied"           "$(run '' "$(req_rm 'rm -rf /')" "$HIRISK_DENY")"            '"behavior":"deny"'
check "rm -rf /home -> high-risk -> denied"       "$(run '' "$(req_rm 'rm -rf /home')" "$HIRISK_DENY")"        '"behavior":"deny"'
check "rm -rf /usr -> high-risk -> denied"        "$(run '' "$(req_rm 'rm -rf /usr')" "$HIRISK_DENY")"         '"behavior":"deny"'
check "rm -rf /Users/me -> high-risk -> denied"   "$(run '' "$(req_rm 'rm -rf /Users/me')" "$HIRISK_DENY")"    '"behavior":"deny"'
check "rm -fr ~/Documents -> high-risk -> denied" "$(run '' "$(req_rm 'rm -fr ~/Documents')" "$HIRISK_DENY")"  '"behavior":"deny"'
# Negative: deleting a relative build dir is medium, must NOT trip the high gate.
check "rm -rf ./build -> not high-risk -> prompt" "$(run '' "$(req_rm 'rm -rf ./build')" "$HIRISK_DENY")"      ''

echo "5. stale-island supersede (same terminal session)"
# A new request from the SAME session must dismiss a still-showing island left
# over from the previous request (the case where you answered in the terminal
# and Claude moved on). Stub island records its PID then blocks like a real one.
supersede_test() {
  local state stub key island_pid
  state="$(mktemp -d)"
  key="ttytest"
  stub="$state/island-prompt-stub.sh"   # name contains "island" for the ps guard
  printf '#!/bin/sh\necho $$ > "%s/island.running"\nsleep 30\n' "$state" > "$stub"
  chmod +x "$stub"
  # First request: hook shows the (blocking) island in the background.
  printf '%s' "$REQ" | HOME="$state" SUDOOR_STATE_DIR="$state" SUDOOR_SESSION_KEY="$key" \
    CLAUDE_PERMISSION_TIMEOUT=30 ISLAND_PROMPT="$stub" bash "$HOOK" >/dev/null 2>&1 &
  local hook1=$!
  local i=0; while [ ! -f "$state/island.running" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  island_pid="$(cat "$state/island.running" 2>/dev/null || true)"
  # Second request, same session: should kill the stale island above.
  printf '%s' "$REQ" | HOME="$state" SUDOOR_STATE_DIR="$state" SUDOOR_SESSION_KEY="$key" \
    CLAUDE_PERMISSION_TIMEOUT=1 ISLAND_PROMPT=/usr/bin/true bash "$HOOK" >/dev/null 2>&1
  sleep 0.4
  if [ -n "$island_pid" ] && kill -0 "$island_pid" 2>/dev/null; then
    echo "   FAIL: stale island ($island_pid) still alive after new same-session request"; fails=$((fails+1))
  else
    echo "   ok: stale island dismissed by new same-session request"
  fi
  kill -TERM "$island_pid" "$hook1" 2>/dev/null || true
  wait "$hook1" 2>/dev/null || true
  rm -rf "$state"
}
supersede_test

echo "6. delegate effect"
run_with_delegate() { # $1 = allow|deny, $2 = optional req json
  local delegate tmp_state req out behavior
  behavior="$1"
  delegate="$(mktemp)"
  cat > "$delegate" <<EOF
#!/bin/sh
printf '%s\n' '{"behavior":"$behavior"}'
EOF
  chmod +x "$delegate"
  tmp_state="$(mktemp -d)"
  printf '%s' '{"version":1,"rules":[{"id":"delegate-rule","effect":"delegate"}]}' > "$tmp_state/policy.json"
  req="${2:-$REQ}"
  out="$(printf '%s' "$req" | HOME="$tmp_state" SUDOOR_STATE_DIR="$tmp_state" CLAUDE_PERMISSION_TIMEOUT=1 \
    ISLAND_PROMPT=/usr/bin/false SUDOOR_DELEGATE_COMMAND="$delegate" bash "$HOOK")"
  rm -f "$delegate"
  rm -rf "$tmp_state"
  printf '%s' "$out"
}
check "delegate allow -> allow without prompt" "$(run_with_delegate allow)" '"behavior":"allow"'
check "delegate deny  -> deny without prompt"  "$(run_with_delegate deny)"  '"behavior":"deny"'

echo
[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }

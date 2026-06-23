#!/usr/bin/env bash
# Contract test for Scripts/audit-export.sh
set -uo pipefail
cd "$(dirname "$0")/.."
EXPORT="Scripts/audit-export.sh"
fails=0

echo "1. syntax"
bash -n "$EXPORT" && echo "   ok" || { echo "   FAIL: syntax"; exit 1; }

state="$(mktemp -d)"
hist="$state/history.jsonl"
printf '%s\n' \
  '{"time":1,"agent":"claude-code","term":"Terminal","project":"demo","cwd":"/tmp/demo","tool":"Bash","detail":"ls","outcome":"approved","risk":"low","riskReasons":[],"policyEffect":"ask","ruleId":"","delegate":"","policySource":"","gitBase":"abc123"}' \
  > "$hist"

check_contains() { # $1 desc, $2 haystack, $3 needle
  case "$2" in *"$3"*) echo "   ok: $1";; *) echo "   FAIL: $1 (missing '$3')"; fails=$((fails+1));; esac
}

echo "2. csv export fields"
csv="$(SUDOOR_STATE_DIR="$state" bash "$EXPORT" csv)"
check_contains "csv header has cwd" "$csv" "cwd"
check_contains "csv header has gitBase" "$csv" "gitBase"
check_contains "csv row has /tmp/demo" "$csv" "/tmp/demo"
check_contains "csv row has abc123" "$csv" "abc123"

echo "3. jsonl passthrough"
jsonl="$(SUDOOR_STATE_DIR="$state" bash "$EXPORT" jsonl)"
check_contains "jsonl includes record" "$jsonl" '"outcome":"approved"'

rm -rf "$state"
echo
[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }

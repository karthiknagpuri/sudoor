#!/usr/bin/env bash
# Export sudoor approval history as jsonl or csv.
set -euo pipefail

STATE_DIR="${SUDOOR_STATE_DIR:-$HOME/.island}"
FORMAT="${1:-jsonl}"
HISTORY="$STATE_DIR/history.jsonl"

if [ ! -f "$HISTORY" ]; then
  exit 0
fi

case "$FORMAT" in
  jsonl)
    cat "$HISTORY"
    ;;
  csv)
    /usr/bin/python3 - "$HISTORY" <<'PY'
import csv, json, sys

fields = [
    "time", "agent", "term", "project", "cwd", "tool", "detail", "outcome",
    "risk", "riskReasons", "policyEffect", "ruleId", "delegate", "policySource", "gitBase",
]
writer = csv.DictWriter(sys.stdout, fieldnames=fields)
writer.writeheader()
with open(sys.argv[1]) as f:
    for line in f:
        try:
            row = json.loads(line)
        except Exception:
            continue
        if isinstance(row.get("riskReasons"), list):
            row["riskReasons"] = "; ".join(row["riskReasons"])
        writer.writerow({key: row.get(key, "") for key in fields})
PY
    ;;
  *)
    echo "usage: $0 [jsonl|csv]" >&2
    exit 2
    ;;
esac

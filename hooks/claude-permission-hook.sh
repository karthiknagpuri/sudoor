#!/usr/bin/env bash
#
# claude-permission-hook.sh — Claude Code PermissionRequest hook.
#
# Evaluates policy/risk, shows the Dynamic Island prompt (island-prompt) at the
# notch when human input is needed, and emits Claude's decision contract:
#   Approve     -> {"behavior":"allow"}
#   Disapprove  -> {"behavior":"deny"}
#   dismiss/TO  -> no decision, exit 0  (falls back to normal CLI prompt)
#
# UI order: island-prompt (preferred) -> alerter -> osascript dialog (argv-safe).
#
# Wire it up in ~/.claude/settings.json:
#   {
#     "hooks": {
#       "PermissionRequest": [
#         { "hooks": [ { "type": "command",
#             "command": "~/bin/claude-permission-hook.sh" } ] }
#       ]
#     }
#   }

set -euo pipefail

TIMEOUT="${CLAUDE_PERMISSION_TIMEOUT:-30}"   # seconds before falling back to CLI
# Clamp to a positive integer — used in UI timeouts (no string interpolation).
case "$TIMEOUT" in
  ''|*[!0-9]*) TIMEOUT=30 ;;
  *) [ "$TIMEOUT" -lt 1 ] && TIMEOUT=30; [ "$TIMEOUT" -gt 300 ] && TIMEOUT=300 ;;
esac
SUDOOR_STATE_DIR="${SUDOOR_STATE_DIR:-$HOME/.island}"

# Keep local debug logs bounded (last N lines).
rotate_log() {
  local file="$1" max="${2:-5000}"
  [ -f "$file" ] || return 0
  local n
  n="$(wc -l < "$file" 2>/dev/null | tr -d '[:space:]')"
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [ "$n" -le "$max" ] && return 0
  tail -n "$max" "$file" > "${file}.rotate.tmp" 2>/dev/null && mv "${file}.rotate.tmp" "$file"
}

# --- read the request Claude sent on stdin -------------------------------
INPUT="$(cat)"
parse() { printf '%s' "$INPUT" | /usr/bin/python3 -c "import json,sys
d=json.load(sys.stdin)
$1" 2>/dev/null || true; }

agent_name="$(parse 'print(d.get("agent") or d.get("source") or "")')"
tool="$(parse 'print(d.get("tool_name") or d.get("tool") or d.get("name") or "")')"
detail="$(parse 'ti=d.get("tool_input",{}); print(ti.get("command") or ti.get("file_path") or ti.get("url") or d.get("command") or d.get("detail") or "")')"
cwd="$(parse 'print(d.get("cwd") or d.get("workdir") or "")')"

[ -z "$agent_name" ] && agent_name="${SUDOOR_AGENT:-claude-code}"
[ -z "$tool" ] && tool="a tool"

# Invocation log — proves whether Claude Code actually calls this hook.
mkdir -p "$SUDOOR_STATE_DIR" 2>/dev/null || true
rotate_log "$SUDOOR_STATE_DIR/invocations.log"
echo "$(date '+%F %T') pid=$$ agent=$agent_name TERM_PROGRAM=${TERM_PROGRAM:-none} tool=$tool" >> "$SUDOOR_STATE_DIR/invocations.log" 2>/dev/null || true

# --- which terminal is asking? -------------------------------------------
# term = friendly label; app = macOS app name to raise; proc = process name
# for System Events minimize (Electron editors aren't AppleScript-scriptable).
case "${TERM_PROGRAM:-}" in
  Apple_Terminal)  term="Terminal"; app="Terminal"; proc="Terminal" ;;
  iTerm.app)       term="iTerm";    app="iTerm";    proc="iTerm2" ;;
  vscode)
    # Cursor and VS Code both report "vscode" — disambiguate via env hints
    # inherited from the editor (bundle id / askpass / ipc paths).
    hint="${__CFBundleIdentifier:-}|${VSCODE_GIT_ASKPASS_NODE:-}|${VSCODE_GIT_ASKPASS_MAIN:-}|${VSCODE_GIT_IPC_HANDLE:-}|${VSCODE_CWD:-}"
    case "$hint" in
      *[Cc]ursor*|*todesktop*) term="Cursor";  app="Cursor";              proc="Cursor" ;;
      *)                       term="VS Code"; app="Visual Studio Code";  proc="Code" ;;
    esac
    ;;
  ghostty|Ghostty) term="Ghostty"; app="Ghostty"; proc="Ghostty" ;;
  WezTerm)         term="WezTerm"; app="WezTerm"; proc="WezTerm" ;;
  "")              term="Terminal"; app=""; proc="" ;;
  *)               term="$TERM_PROGRAM"; app="$TERM_PROGRAM"; proc="$TERM_PROGRAM" ;;
esac
project="$(basename "${cwd:-$PWD}")"

# Capture the tracked repository state before the requested tool runs. For a
# dirty worktree, `stash create` writes an unreachable snapshot without moving
# files or changing the index. A clean worktree falls back to HEAD.
git_base=""
if /usr/bin/git -C "${cwd:-$PWD}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_base="$(/usr/bin/git -C "${cwd:-$PWD}" stash create "sudoor-before-request" 2>/dev/null || true)"
  [ -n "$git_base" ] || git_base="$(/usr/bin/git -C "${cwd:-$PWD}" rev-parse HEAD 2>/dev/null || true)"
fi

# Workspace registry — powers the Sudoor menu bar launcher even when there is
# no active permission request. Keep it small and path-backed.
/usr/bin/python3 - "$SUDOOR_STATE_DIR" "$project" "${cwd:-$PWD}" <<'PY' 2>/dev/null || true
import json, os, sys, time, fcntl
base, project, cwd = sys.argv[1:4]
if not cwd:
    raise SystemExit
os.makedirs(base, exist_ok=True)
path = os.path.join(base, "workspaces.json")
lock = os.path.join(base, ".state.lock")
with open(lock, "w") as lf:
    fcntl.flock(lf, fcntl.LOCK_EX)
    try:
        root = json.load(open(path))
    except Exception:
        root = {}
    items = root.get("workspaces", [])
    by_path = {item.get("path"): item for item in items if isinstance(item, dict) and item.get("path")}
    by_path[cwd] = {"name": project or os.path.basename(cwd), "path": cwd, "lastSeen": int(time.time())}
    ordered = sorted(by_path.values(), key=lambda item: item.get("lastSeen", 0), reverse=True)[:30]
    tmp = path + ".tmp"
    json.dump({"workspaces": ordered}, open(tmp, "w"), sort_keys=True)
    os.replace(tmp, path)
PY

# Controlling terminal (e.g. ttys003) — pins the exact window/tab that's asking.
# Hooks are spawned detached (no controlling tty), so walk up the process tree:
# an ancestor (Claude Code, running in the terminal) carries the real tty.
detect_tty() {
  local pid=$$ t
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    t="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    case "$t" in ttys*) printf '%s' "$t"; return 0 ;; esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    case "$pid" in ""|0|1) return 1 ;; esac
  done
  return 1
}
tty_dev="$(detect_tty || true)"
source="$term · $project"
case "$tty_dev" in ""|"?"|"??") : ;; *) source="$source · $tty_dev" ;; esac

# The command / file being requested (shown separately from the source).
cmd="$tool"
[ -n "$detail" ] && cmd="$tool: $detail"
cmd="${cmd:0:200}"

# Combined string for the alerter / osascript fallbacks (no --source support).
msg="$source — $cmd"
msg="${msg:0:240}"

# --- policy + risk evaluation -------------------------------------------
# Policies are JSON files. Managed policy is read first, then user/team policy:
#   /Library/Application Support/sudoor/policy.json
#   ~/.island/policy.json
#   ~/.island/policies/*.json
#
# Supported rule fields:
#   id, effect: "allow" | "deny" | "ask" | "delegate"
#   match.tool, match.project, match.commandContains, match.commandRegex
#   match.cwdPrefix, match.cwdRegex, match.minRisk
#
# effect=delegate calls $SUDOOR_DELEGATE_COMMAND with the request JSON on stdin
# and expects {"behavior":"allow"|"deny"|"ask"}.
POLICY_JSON="$(/usr/bin/python3 - "$SUDOOR_STATE_DIR" "$agent_name" "$term" "$project" "${cwd:-$PWD}" "$tool" "$detail" "$INPUT" <<'PY' 2>/dev/null || printf '{}'
import glob, json, os, re, shlex, subprocess, sys, time

state_dir, agent, term, project, cwd, tool, detail, raw = sys.argv[1:9]
managed = "/Library/Application Support/sudoor/policy.json"
paths = [managed, os.path.join(state_dir, "policy.json")]
paths.extend(sorted(glob.glob(os.path.join(state_dir, "policies", "*.json"))))

rank = {"low": 0, "medium": 1, "high": 2, "critical": 3}

def risk_for(tool, detail):
    text = detail or ""
    reasons = []
    score = 0
    checks = [
        ("critical", r"(^|[;&|]\s*)rm\s+(-[A-Za-z]*r[A-Za-z]*f|-[A-Za-z]*f[A-Za-z]*r)\s+(--\s+)?[\"']?(/(\s|$|\*)|/(home|usr|etc|var|bin|sbin|lib|lib64|opt|boot|dev|proc|sys|root|srv|mnt|media|System|Library|Applications|Users|private|cores|Volumes)(/|\s|$|\*)|~|\$\{?HOME)", "recursive delete against root/system/home"),
        ("critical", r"\b(dd|mkfs|diskutil\s+erase|srm)\b", "destructive disk command"),
        ("high", r"\bsudo\b", "privilege escalation"),
        ("high", r"\b(chmod\s+777|chown\s+-R|chmod\s+-R)\b", "broad permission change"),
        ("high", r"\b(curl|wget)\b.*\|\s*(sh|bash|zsh)\b", "remote script execution"),
        ("high", r"\b(git\s+push|gh\s+release|npm\s+publish|pnpm\s+publish)\b", "publishing or remote write"),
        ("medium", r"\b(rm\s+(-r|-rf|-fr)|mv\s+|cp\s+)\b", "filesystem mutation"),
        ("medium", r"\b(npm|pnpm|yarn|pip|brew)\s+(install|add|update|upgrade)\b", "dependency or package install"),
        ("medium", r"\b(curl|wget|ssh|scp|rsync|aws|gcloud|az)\b", "network or cloud command"),
        ("medium", r"\b[A-Z0-9_]*(TOKEN|SECRET|PASSWORD|KEY)\b", "possible secret exposure"),
    ]
    if tool.lower() != "bash":
        if tool.lower() in {"write", "edit", "multiedit", "notebookedit"}:
            score = max(score, 1)
            reasons.append("file write")
        if tool.lower() in {"webfetch", "websearch"}:
            score = max(score, 1)
            reasons.append("network read")
    for level, pattern, reason in checks:
        if re.search(pattern, text, re.I):
            score = max(score, rank[level])
            reasons.append(reason)
    level = next(k for k, v in rank.items() if v == score)
    return level, sorted(set(reasons))

def load_policy(path):
    try:
        with open(path) as f:
            data = json.load(f)
        if isinstance(data, dict):
            data["_source"] = path
            return data
    except Exception:
        return None
    return None

def rule_matches(rule, risk_level):
    m = rule.get("match", {}) if isinstance(rule.get("match", {}), dict) else {}
    command = detail or ""
    tests = [
        ("tool", lambda v: str(v).lower() == tool.lower()),
        ("project", lambda v: str(v) == project),
        ("commandContains", lambda v: str(v).lower() in command.lower()),
        ("commandRegex", lambda v: re.search(str(v), command, re.I) is not None),
        ("cwdPrefix", lambda v: cwd.startswith(str(v))),
        ("cwdRegex", lambda v: re.search(str(v), cwd, re.I) is not None),
        ("minRisk", lambda v: rank.get(risk_level, 0) >= rank.get(str(v), 0)),
    ]
    for key, fn in tests:
        if key in m:
            try:
                if not fn(m[key]):
                    return False
            except Exception:
                return False
    return True

risk_level, risk_reasons = risk_for(tool, detail)
rules = []
for p in filter(None, map(load_policy, paths)):
    source = p.get("_source", "")
    for r in p.get("rules", []):
        if isinstance(r, dict):
            item = dict(r)
            item["_source"] = source
            rules.append(item)
    projects = p.get("projects", {})
    if isinstance(projects, dict):
        project_policy = projects.get(project, {})
        for r in project_policy.get("rules", []) if isinstance(project_policy, dict) else []:
            if isinstance(r, dict):
                item = dict(r)
                item["_source"] = source
                item["_project"] = project
                rules.append(item)

matched = None
for rule in rules:
    if rule_matches(rule, risk_level):
        matched = rule
        break

effect = (matched or {}).get("effect", "ask")
rule_id = (matched or {}).get("id", "")
policy_source = (matched or {}).get("_source", "")
delegate = (matched or {}).get("delegate", "")
decision = ""
outcome = ""

if effect == "allow":
    decision, outcome = "allow", "auto_allowed"
elif effect == "deny":
    decision, outcome = "deny", "auto_denied"
elif effect == "delegate":
    cmd = os.environ.get("SUDOOR_DELEGATE_COMMAND", "").strip()
    if cmd:
        payload = {
            "agent": agent, "term": term, "project": project, "cwd": cwd,
            "tool": tool, "detail": detail, "risk": risk_level,
            "riskReasons": risk_reasons, "ruleId": rule_id, "delegate": delegate,
            "time": int(time.time())
        }
        try:
            proc = subprocess.run(
                shlex.split(cmd), input=json.dumps(payload), text=True,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30
            )
            response = json.loads(proc.stdout or "{}")
            behavior = response.get("behavior")
            if behavior in ("allow", "deny"):
                decision, outcome = behavior, "delegated_" + ("allowed" if behavior == "allow" else "denied")
            else:
                outcome = "delegated_ask"
        except Exception:
            outcome = "delegated_unavailable"
    else:
        outcome = "delegated_unavailable"

print(json.dumps({
    "agent": agent,
    "risk": risk_level,
    "riskReasons": risk_reasons,
    "effect": effect,
    "ruleId": rule_id,
    "policySource": policy_source,
    "delegate": delegate,
    "decision": decision,
    "outcome": outcome,
}, separators=(",", ":")))
PY
)"

policy_field() {
  printf '%s' "$POLICY_JSON" | /usr/bin/python3 -c 'import json,sys
try:
    v=json.load(sys.stdin).get(sys.argv[1],"")
    print(",".join(v) if isinstance(v,list) else v)
except Exception:
    print("")' "$1" 2>/dev/null || true
}
risk_level="$(policy_field risk)"
risk_reasons="$(policy_field riskReasons)"
policy_effect="$(policy_field effect)"
policy_rule_id="$(policy_field ruleId)"
policy_source="$(policy_field policySource)"
policy_delegate="$(policy_field delegate)"
policy_decision="$(policy_field decision)"
policy_outcome="$(policy_field outcome)"

if [ -n "$risk_level" ] && [ "$risk_level" != "low" ]; then
  cmd="[$risk_level risk] $cmd"
  [ -n "$risk_reasons" ] && cmd="$cmd — $risk_reasons"
  cmd="${cmd:0:240}"
  msg="$source — $cmd"
  msg="${msg:0:260}"
fi

# --- record this pending request so the menu bar can show it -------------
PENDING_DIR="$SUDOOR_STATE_DIR/pending"
req_file=""
active_pid_file=""
island_pid=""
cleanup() {
  [ -n "${req_file:-}" ] && rm -f "$req_file" 2>/dev/null || true
  # Clear the per-session island marker only if it still points at our island.
  if [ -n "${active_pid_file:-}" ] && [ -n "${active_lock:-}" ]; then
    (
      flock 9
      if [ -f "$active_pid_file" ] && [ "$(cat "$active_pid_file" 2>/dev/null || true)" = "${island_pid:-}" ]; then
        rm -f "$active_pid_file" 2>/dev/null || true
      fi
    ) 9>"$active_lock" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if [ -z "$policy_decision" ]; then
mkdir -p "$PENDING_DIR"
req_file="$PENDING_DIR/$$-${RANDOM}.json"
/usr/bin/python3 - "$req_file" "$agent_name" "$term" "$project" "${cwd:-$PWD}" "$tool" "$detail" "$risk_level" "$risk_reasons" "$policy_effect" "$policy_rule_id" "$policy_delegate" <<'PY' 2>/dev/null || true
import json, sys, time, os
path, agent, term, project, cwd, tool, detail, risk, reasons, effect, rule_id, delegate = sys.argv[1:13]
json.dump({"agent": agent, "term": term, "project": project, "cwd": cwd, "tool": tool,
           "detail": detail[:160], "risk": risk, "riskReasons": reasons,
           "policyEffect": effect, "ruleId": rule_id, "delegate": delegate,
           "time": int(time.time())}, open(path, "w"))
PY

  # --- supersede any stale island from THIS terminal session -------------
  # Claude shows its own in-terminal permission prompt alongside our island.
  # If you answer in the terminal, Claude just proceeds and fires the next
  # tool — but the previous island is still hanging at the notch. A new
  # request from the same terminal (tty) means the previous one was resolved
  # out-of-band, so tear its island down. Keyed by tty so other terminals'
  # islands are left alone.
  SESSION_KEY="${SUDOOR_SESSION_KEY:-$tty_dev}"
  if [ -n "$SESSION_KEY" ]; then
    ACTIVE_DIR="$SUDOOR_STATE_DIR/active"
    mkdir -p "$ACTIVE_DIR" 2>/dev/null || true
    active_pid_file="$ACTIVE_DIR/${SESSION_KEY}.pid"
    active_lock="$ACTIVE_DIR/${SESSION_KEY}.lock"
    (
      flock 9
      if [ -f "$active_pid_file" ]; then
        old_pid="$(cat "$active_pid_file" 2>/dev/null || true)"
        case "$old_pid" in
          ''|*[!0-9]*) : ;;
          *) if ps -p "$old_pid" -o command= 2>/dev/null | grep -qE '[/ ]island-prompt'; then
               kill -TERM "$old_pid" 2>/dev/null || true
             fi ;;
        esac
      fi
    ) 9>"$active_lock"
  fi
fi

# --- bring the requesting terminal WINDOW to the front -------------------
# Gated on the menu bar "Show requesting terminal" toggle (shared file,
# default on). Raises the exact window/tab matching this tty for scriptable
# terminals; falls back to app-level activation otherwise. The tty is passed
# as an argv to osascript (no string interpolation → no AppleScript injection).
raise_window() {
  local tty_full="/dev/${tty_dev}"
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal)
      osascript - "$tty_full" >/dev/null 2>&1 <<'OSA' || open -a "Terminal" >/dev/null 2>&1 || true
on run argv
  set targetTTY to item 1 of argv
  tell application "Terminal"
    activate
    repeat with w in windows
      repeat with t in tabs of w
        try
          if tty of t is targetTTY then
            set selected of t to true
            set index of w to 1
          end if
        end try
      end repeat
    end repeat
  end tell
end run
OSA
      ;;
    iTerm.app)
      osascript - "$tty_full" >/dev/null 2>&1 <<'OSA' || open -a "iTerm" >/dev/null 2>&1 || true
on run argv
  set targetTTY to item 1 of argv
  tell application "iTerm"
    activate
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          try
            if tty of s is targetTTY then
              select w
              select t
              select s
            end if
          end try
        end repeat
      end repeat
    end repeat
  end tell
end run
OSA
      ;;
    *)
      [ -n "${app:-}" ] && open -a "$app" >/dev/null 2>&1 || true
      ;;
  esac
}

# Minimize the same window back after a decision (mirror of raise_window).
minimize_window() {
  local tty_full="/dev/${tty_dev}"
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal)
      osascript - "$tty_full" >/dev/null 2>&1 <<'OSA' || true
on run argv
  set targetTTY to item 1 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        try
          if tty of t is targetTTY then set miniaturized of w to true
        end try
      end repeat
    end repeat
  end tell
end run
OSA
      ;;
    iTerm.app)
      osascript - "$tty_full" >/dev/null 2>&1 <<'OSA' || true
on run argv
  set targetTTY to item 1 of argv
  tell application "iTerm"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          try
            if tty of s is targetTTY then set miniaturized of w to true
          end try
        end repeat
      end repeat
    end repeat
  end tell
end run
OSA
      ;;
    *)
      # Electron editors (VS Code, Cursor) and other non-scriptable terminals:
      # minimize the front window via System Events. Not tty-specific (Electron
      # has one OS window per workspace), so it minimizes the frontmost window.
      [ -n "${proc:-}" ] && osascript - "$proc" >/dev/null 2>&1 <<'OSA' || true
on run argv
  set p to item 1 of argv
  tell application "System Events"
    tell process p
      try
        set value of attribute "AXMinimized" of window 1 to true
      end try
    end tell
  end tell
end run
OSA
      ;;
  esac
}

show_term="$(/usr/bin/python3 -c 'import json,sys
try:
    print("1" if json.load(open(sys.argv[1])).get("showTerminal", True) else "0")
except Exception:
    print("1")' "$SUDOOR_STATE_DIR/config.json" 2>/dev/null || echo 1)"
[ -z "$policy_decision" ] && [ "$show_term" = "1" ] && raise_window || true

# --- ask the human -------------------------------------------------------
ISLAND="${ISLAND_PROMPT:-$HOME/Applications/sudoor.app/Contents/MacOS/island-prompt}"
[ -x "$ISLAND" ] || ISLAND="$HOME/IslandPrompt/island-prompt"
choice=""
if [ "$policy_decision" = "allow" ]; then
  choice="Approve"
elif [ "$policy_decision" = "deny" ]; then
  choice="Disapprove"
elif [ -x "$ISLAND" ]; then
  # Dynamic Island at the notch (preferred). Source = which terminal is asking.
  # Launched in the background so we can record its PID — a later same-session
  # request (above) uses it to dismiss this island if you answered in the
  # terminal instead. We still block on it via `wait` to capture the click.
  island_out="$(mktemp)"
  "$ISLAND" "$cmd" --source "$source" --timeout "$TIMEOUT" >"$island_out" 2>/dev/null &
  island_pid=$!
  if [ -n "$active_pid_file" ] && [ -n "$active_lock" ]; then
    (
      flock 9
      printf '%s' "$island_pid" > "$active_pid_file"
    ) 9>"$active_lock" 2>/dev/null || true
  fi
  wait "$island_pid" 2>/dev/null || true
  choice="$(cat "$island_out" 2>/dev/null || true)"
  rm -f "$island_out" 2>/dev/null || true
elif command -v alerter >/dev/null 2>&1; then
  # alerter prints the clicked action (or @CLOSED / @TIMEOUT) to stdout
  choice="$(alerter \
    -title "Claude needs permission" \
    -message "$msg" \
    -actions Approve \
    -closeLabel Disapprove \
    -timeout "$TIMEOUT" \
    -sound Glass 2>/dev/null || true)"
else
  # fallback: modal dialog via osascript (msg + timeout passed as argv — no injection)
  choice="$(osascript - "$msg" "$TIMEOUT" <<'OSA' 2>/dev/null || true
on run argv
  set msgText to item 1 of argv
  set timeoutSecs to (item 2 of argv) as integer
  try
    set a to button returned of (display dialog msgText with title "Claude needs permission" \
      buttons {"Disapprove","Approve"} default button "Approve" cancel button "Disapprove" \
      with icon caution giving up after timeoutSecs)
    return a
  on error number -128
    return "Disapprove"
  end try
end run
OSA
)"
fi

# --- translate the click into Claude's decision contract -----------------
emit() { printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"%s"}}}\n' "$1"; }

outcome="deferred"
decided=0
case "$choice" in
  Approve)     emit allow; outcome="$([ -n "$policy_decision" ] && printf '%s' "$policy_outcome" || printf approved)"; decided=1 ;;
  Disapprove)  emit deny;  outcome="$([ -n "$policy_decision" ] && printf '%s' "$policy_outcome" || printf denied)";   decided=1 ;;
  *)           : ;;   # @CLOSED / @TIMEOUT / empty -> no decision, defer to CLI
esac

# Hide the terminal window back once you've decided — but NOT on timeout,
# since that defers to the in-terminal CLI prompt, which must stay visible.
[ "$decided" = "1" ] && [ "$show_term" = "1" ] && minimize_window || true

# Atomically update the handled counter (config.json) AND append bounded
# history (history.jsonl), under one exclusive flock shared with IslandBar.app.
# This is the fix for the counter/history races under concurrent terminals.
/usr/bin/python3 - "$SUDOOR_STATE_DIR" "$agent_name" "$term" "$project" "${cwd:-$PWD}" "$tool" "$detail" "$outcome" "$decided" "$risk_level" "$risk_reasons" "$policy_effect" "$policy_rule_id" "$policy_source" "$policy_delegate" "$git_base" <<'PY' 2>/dev/null || true
import json, os, sys, time, fcntl
base, agent, term, project, cwd, tool, detail, outcome, decided, risk, reasons, effect, rule_id, policy_source, delegate, git_base = sys.argv[1:17]
os.makedirs(base, exist_ok=True)
cfgp  = os.path.join(base, "config.json")
histp = os.path.join(base, "history.jsonl")
with open(os.path.join(base, ".state.lock"), "w") as lf:
    fcntl.flock(lf, fcntl.LOCK_EX)
    try:    cfg = json.load(open(cfgp))
    except Exception: cfg = {}
    cfg.setdefault("showTerminal", True)
    cfg["count"] = int(cfg.get("count", 0)) + (1 if decided == "1" else 0)
    tmp = cfgp + ".tmp"; json.dump(cfg, open(tmp, "w"), sort_keys=True); os.replace(tmp, cfgp)
    try:    lines = open(histp).read().splitlines()
    except Exception: lines = []
    lines.append(json.dumps({"agent": agent, "term": term, "project": project, "cwd": cwd, "tool": tool,
                             "detail": detail[:120], "outcome": outcome, "risk": risk,
                             "riskReasons": [x for x in reasons.split(",") if x],
                             "policyEffect": effect, "ruleId": rule_id,
                             "policySource": policy_source, "delegate": delegate,
                             "gitBase": git_base,
                             "time": int(time.time())}, sort_keys=True))
    lines = lines[-200:]
    tmph = histp + ".tmp"; open(tmph, "w").write("\n".join(lines) + "\n"); os.replace(tmph, histp)
PY
exit 0

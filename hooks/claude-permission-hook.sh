#!/usr/bin/env bash
#
# claude-permission-hook.sh — Claude Code PermissionRequest hook.
#
# When Claude wants to run a tool, this pops a native macOS notification
# with Approve / Disapprove buttons. Your click is fed back to Claude:
#   Approve     -> {"behavior":"allow"}
#   Disapprove  -> {"behavior":"deny"}
#   dismiss/TO  -> no decision, exit 0  (falls back to normal CLI prompt)
#
# Requires `alerter` (real notification buttons that block for a click):
#   brew install alerter
# Falls back to an osascript dialog if alerter isn't installed.
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

# --- read the request Claude sent on stdin -------------------------------
INPUT="$(cat)"
parse() { printf '%s' "$INPUT" | /usr/bin/python3 -c "import json,sys
d=json.load(sys.stdin)
$1" 2>/dev/null || true; }

tool="$(parse 'print(d.get("tool_name",""))')"
detail="$(parse 'ti=d.get("tool_input",{}); print(ti.get("command") or ti.get("file_path") or ti.get("url") or "")')"
cwd="$(parse 'print(d.get("cwd",""))')"

[ -z "$tool" ] && tool="a tool"

# Invocation log — proves whether Claude Code actually calls this hook.
echo "$(date '+%F %T') pid=$$ TERM_PROGRAM=${TERM_PROGRAM:-none} tool=$tool" >> "$HOME/.island/invocations.log" 2>/dev/null || true

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

# --- record this pending request so the menu bar can show it -------------
PENDING_DIR="$HOME/.island/pending"
mkdir -p "$PENDING_DIR"
req_file="$PENDING_DIR/$$-${RANDOM}.json"
/usr/bin/python3 - "$req_file" "$term" "$project" "${cwd:-$PWD}" "$tool" "$detail" <<'PY' 2>/dev/null || true
import json, sys, time, os
path, term, project, cwd, tool, detail = sys.argv[1:7]
json.dump({"term": term, "project": project, "cwd": cwd, "tool": tool,
           "detail": detail[:160], "time": int(time.time())}, open(path, "w"))
PY
cleanup() { rm -f "$req_file" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

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
    print("1")' "$HOME/.island/config.json" 2>/dev/null || echo 1)"
[ "$show_term" = "1" ] && raise_window || true

# --- ask the human -------------------------------------------------------
ISLAND="${ISLAND_PROMPT:-$HOME/Applications/sudoor.app/Contents/MacOS/island-prompt}"
[ -x "$ISLAND" ] || ISLAND="$HOME/IslandPrompt/island-prompt"
choice=""
if [ -x "$ISLAND" ]; then
  # Dynamic Island at the notch (preferred). Source = which terminal is asking.
  choice="$("$ISLAND" "$cmd" --source "$source" --timeout "$TIMEOUT" 2>/dev/null || true)"
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
  # fallback: modal dialog via osascript
  choice="$(osascript <<EOF 2>/dev/null || true
try
  set a to button returned of (display dialog "$msg" with title "Claude needs permission" \
    buttons {"Disapprove","Approve"} default button "Approve" cancel button "Disapprove" \
    with icon caution giving up after $TIMEOUT)
  return a
on error number -128
  return "Disapprove"
end try
EOF
)"
fi

# --- translate the click into Claude's decision contract -----------------
emit() { printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"%s"}}}\n' "$1"; }

outcome="deferred"
decided=0
case "$choice" in
  Approve)     emit allow; outcome="approved"; decided=1 ;;
  Disapprove)  emit deny;  outcome="denied";   decided=1 ;;
  *)           : ;;   # @CLOSED / @TIMEOUT / empty -> no decision, defer to CLI
esac

# Hide the terminal window back once you've decided — but NOT on timeout,
# since that defers to the in-terminal CLI prompt, which must stay visible.
[ "$decided" = "1" ] && [ "$show_term" = "1" ] && minimize_window || true

# Atomically update the handled counter (config.json) AND append bounded
# history (history.jsonl), under one exclusive flock shared with IslandBar.app.
# This is the fix for the counter/history races under concurrent terminals.
/usr/bin/python3 - "$HOME/.island" "$term" "$project" "$tool" "$detail" "$outcome" "$decided" <<'PY' 2>/dev/null || true
import json, os, sys, time, fcntl
base, term, project, tool, detail, outcome, decided = sys.argv[1:8]
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
    lines.append(json.dumps({"term": term, "project": project, "tool": tool,
                             "detail": detail[:120], "outcome": outcome, "time": int(time.time())}))
    lines = lines[-20:]
    tmph = histp + ".tmp"; open(tmph, "w").write("\n".join(lines) + "\n"); os.replace(tmph, histp)
PY
exit 0

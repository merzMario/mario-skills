#!/bin/bash
# wfc_preflight.sh — make the browser bridge actually able to open a page.
#
# Agent-runnable. It reads state, repairs the failure modes that are known and
# mechanical, and prints ONE compact JSON line. Nothing here needs a human to
# read a log and reason about it — that reasoning is exactly what used to cost
# tens of thousands of tokens per run.
#
#   bash scripts/wfc_preflight.sh [--json] [--session <name>] [--no-verify]
#
# What it repairs:
#   1. the opencli daemon is down
#   2. no Chrome profile is selected (the extension is connected but
#      `profile list` says "none selected")
#   3. a stale session lease from a previous run is holding a dead tab
#
# What it cannot repair: Chrome not running at all, or the OpenCLI extension
# not installed. Those get reported with the exact command to run.
#
# Exit codes:
#   0  the bridge can open a page
#   1  it cannot, and the receipt says why
#   2  bad arguments

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SKILL_DIR/scripts/wfc_env.sh"

FMT="json"
SESSION="wxscrape"
VERIFY="1"
OPENCLI="opencli"

while [ $# -gt 0 ]; do
  case "$1" in
    --json) FMT="json" ;;
    --text) FMT="text" ;;
    --session) shift; SESSION="${1:-wxscrape}" ;;
    --session=*) SESSION="${1#--session=}" ;;
    --no-verify) VERIFY="0" ;;
    --opencli) shift; OPENCLI="${1:-opencli}" ;;
    --opencli=*) OPENCLI="${1#--opencli=}" ;;
    *) printf '{"ok":false,"error":"unknown_arg","arg":"%s"}\n' "$(wfc_json_escape "$1")"; exit 2 ;;
  esac
  shift
done

ACTIONS=""
NOTE=""

note() { [ -n "$NOTE" ] && NOTE="$NOTE; $1" || NOTE="$1"; }

run_cli() {
  # run_cli ARGS... — never let a CLI failure abort the script
  "$OPENCLI" "$@" 2>&1
}

# --- 1. binary present ------------------------------------------------------
if ! command -v "$OPENCLI" >/dev/null 2>&1; then
  printf '{"ok":false,"error":"opencli_missing","fix":"npm install -g @jackwener/opencli"}\n'
  exit 1
fi

# --- 2. daemon ---------------------------------------------------------------
# `opencli daemon status` prints "Daemon: not running" when it is down — and
# that string CONTAINS "running", so a naive `"running" not in out` test says
# the daemon is up when it is not. Test for "not running" explicitly.
daemon_out="$(run_cli daemon status)"
if printf '%s' "$daemon_out" | grep -qi "not running"; then
  note "daemon 未运行，已重启"
  run_cli daemon restart >/dev/null
  sleep 2
  daemon_out="$(run_cli daemon status)"
  if printf '%s' "$daemon_out" | grep -qi "not running"; then
    printf '{"ok":false,"error":"daemon_start_failed","detail":"%s","fix":"确认 Chrome 已启动且 OpenCLI 扩展已连接，再跑 opencli doctor"}\n' \
      "$(wfc_json_escape "$daemon_out")"
    exit 1
  fi
  ACTIONS="${ACTIONS}daemon_restart,"
fi

# --- 3. profile --------------------------------------------------------------
# The extension can be connected while no profile is selected; `browser open`
# then fails with "Debugger is not attached to the tab".
profile_out="$(run_cli profile list)"
if printf '%s' "$profile_out" | grep -qi "none selected"; then
  # Pick the first connected profile id.
  chosen="$(printf '%s\n' "$profile_out" | grep -oE '[0-9a-f]{8,}' | head -1)"
  if [ -n "$chosen" ]; then
    run_cli profile use "$chosen" >/dev/null
    note "已选中 Chrome profile $chosen"
    ACTIONS="${ACTIONS}profile_selected,"
  else
    printf '{"ok":false,"error":"no_profile_connected","detail":"%s","fix":"打开 Chrome，确认 OpenCLI 扩展已连接（opencli doctor）"}\n' \
      "$(wfc_json_escape "$profile_out")"
    exit 1
  fi
fi

# --- 4. stale session lease -------------------------------------------------
# A previous run that died mid-fetch leaves a dead tab holding the session
# lease; the next `open` fails with "Debugger is not attached to the tab".
# Releasing it is cheap and idempotent.
run_cli browser "$SESSION" close >/dev/null 2>&1
ACTIONS="${ACTIONS}session_released,"

# --- 5. can it render a page? ------------------------------------------------
VERIFIED="skipped"
if [ "$VERIFY" = "1" ]; then
  probe="$(run_cli browser "$SESSION" eval "document.title" 2>&1)"
  if printf '%s' "$probe" | grep -qiE "not attached|error|failed|Daemon is not running"; then
    printf '{"ok":false,"error":"browser_not_usable","detail":"%s","actions":"%s","fix":"opencli doctor 看扩展是否连上；必要时 opencli daemon restart"}\n' \
      "$(wfc_json_escape "$probe")" "$ACTIONS"
    exit 1
  fi
  VERIFIED="ok"
fi

if [ "$FMT" = "json" ]; then
  printf '{"ok":true,"session":"%s","daemon":"running","profile":"selected","browser":"%s","actions":"%s","note":"%s"}\n' \
    "$(wfc_json_escape "$SESSION")" "$VERIFIED" "$ACTIONS" "$(wfc_json_escape "$NOTE")"
else
  echo "opencli 环境：可用"
  echo "  session : $SESSION"
  echo "  daemon  : running"
  echo "  profile : selected"
  echo "  browser : $VERIFIED"
  echo "  动作    : $ACTIONS"
  [ -n "$NOTE" ] && echo "  说明    : $NOTE"
fi
exit 0

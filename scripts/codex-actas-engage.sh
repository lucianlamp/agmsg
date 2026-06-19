#!/usr/bin/env bash
set -euo pipefail

# Engage a per-session RECEIVE identity for a running Codex session.
#
# Usage: codex-actas-engage.sh <project_path> <name>
#
# Codex's `actas` is otherwise send-side only: there is no stable session_id
# during a slash command, so the Claude-Code receive lock cannot be reused. But
# the codex *thread_id* is a stable per-session key, and the monitor bridge can
# resume any thread on the project's app-server. So `/agmsg actas <name>` can
# bind THIS session's receive side to <name> by arming a bridge for
# (<name>, this thread, the app-server this session is attached to).
#
# This is the in-session counterpart to launching with `AGMSG_CODEX_NAME=<name>
# codex` (which arms the same bridge from the SessionStart hook). Use it to pick
# or switch a receive identity without relaunching.
#
# Exit codes:
#   0  bridge armed for <name> on this thread (prints status=ok)
#   2  <name> is not a registered codex identity for this project
#   3  <name> is already held by a live bridge on another thread (prints owner)
#   4  could not resolve this session's thread or app-server (no monitor session?)
#
# Prints key=value diagnostics to stdout; the slash-command template surfaces them.

PROJECT="${1:?Usage: codex-actas-engage.sh <project_path> <name>}"
NAME="${2:?Missing name}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
PROJECT="$(cd "$PROJECT" && pwd)"
PROJECT_HASH="$(printf '%s' "$PROJECT" | shasum | awk '{print $1}')"

# --- Resolve this session's Codex thread id (same approach as session-start.sh:
# CODEX_THREAD_ID on the interactive --remote path, else newest rollout whose
# session_meta cwd matches the project). ---
resolve_thread() {
  if [ -n "${CODEX_THREAD_ID:-}" ]; then printf '%s' "$CODEX_THREAD_ID"; return 0; fi
  local sessions_dir="$HOME/.codex/sessions" f first esc cwd tid
  [ -d "$sessions_dir" ] || return 0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    first=$(head -1 "$f" 2>/dev/null)
    case "$first" in *'"session_meta"'*) ;; *) continue ;; esac
    esc=$(printf '%s' "$first" | sed "s/'/''/g")
    cwd=$(sqlite3 ":memory:" "SELECT COALESCE(json_extract('$esc','\$.payload.cwd'),'')" 2>/dev/null)
    [ "$cwd" = "$PROJECT" ] || continue
    tid=$(sqlite3 ":memory:" "SELECT COALESCE(json_extract('$esc','\$.payload.id'),'')" 2>/dev/null)
    [ -n "$tid" ] && { printf '%s' "$tid"; return 0; }
  done <<EOF
$(ls -t "$sessions_dir"/*/*/*/rollout-*.jsonl 2>/dev/null | head -20)
EOF
  return 0
}

THREAD="$(resolve_thread)"
[ -n "$THREAD" ] || { echo "status=no_thread"; exit 4; }

# --- Validate <name> is a registered codex identity for this project; resolve team. ---
PAIRS=$("$SCRIPT_DIR/identities.sh" "$PROJECT" codex 2>/dev/null || true)
TEAM=$(printf '%s\n' "$PAIRS" | awk -v n="$NAME" 'NF >= 2 && $2 == n { print $1; exit }')
[ -n "$TEAM" ] || { echo "status=not_registered name=$NAME"; exit 2; }

# --- Resolve the app-server this session is attached to. Prefer the bridge env
# (set when launched through codex-monitor.sh), else the project-wide socket. ---
APP_SERVER="${AGMSG_CODEX_BRIDGE_APP_SERVER:-}"
if [ -z "$APP_SERVER" ]; then
  sock="$RUN_DIR/codex-app-server.$PROJECT_HASH.sock"
  [ -S "$sock" ] && APP_SERVER="unix://$sock"
fi
[ -n "$APP_SERVER" ] || { echo "status=no_app_server"; exit 4; }

bridge_alive() { # <pidfile> -> echoes live pid or empty
  local pf="$1" p
  [ -f "$pf" ] || return 0
  p=$(cat "$pf" 2>/dev/null || true)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && printf '%s' "$p"
}

# --- Exclusivity: refuse if <name> is already armed by a live bridge on a
# DIFFERENT thread (another session owns this identity). ---
name_pid=$(bridge_alive "$RUN_DIR/codex-bridge.$TEAM.$NAME.pid")
if [ -n "$name_pid" ]; then
  cur_thread=$(ps -o args= -p "$name_pid" 2>/dev/null | sed -n 's/.*--thread \([0-9a-f-][0-9a-f-]*\).*/\1/p')
  if [ -n "$cur_thread" ] && [ "$cur_thread" != "$THREAD" ]; then
    echo "status=held name=$NAME owner_thread=$cur_thread owner_pid=$name_pid"
    exit 3
  fi
  # Same thread already armed for this name → nothing to do.
  echo "status=ok name=$NAME team=$TEAM thread=$THREAD note=already-armed"
  exit 0
fi

# --- Identity switch: if some OTHER bridge is already arming THIS thread under a
# different name, retire it so the thread receives as <name> only. ---
for pf in "$RUN_DIR"/codex-bridge.*.pid; do
  [ -f "$pf" ] || continue
  p=$(bridge_alive "$pf"); [ -n "$p" ] || continue
  t=$(ps -o args= -p "$p" 2>/dev/null | sed -n 's/.*--thread \([0-9a-f-][0-9a-f-]*\).*/\1/p')
  if [ "$t" = "$THREAD" ]; then
    kill "$p" 2>/dev/null || true
    rm -f "$pf"
  fi
done

# --- Record the thread→name binding (also feeds session-start.sh precedence #2
# on a later re-fire) and hand the bridge off to the out-of-sandbox launcher. ---
# A slash command runs INSIDE the Codex sandbox, where a directly-spawned bridge
# cannot reach the app-server unix socket (#41) — exactly why session-start.sh
# writes a request file for the launcher rather than spawning. We do the same:
# write a request keyed by the app-server socket, and the launcher that
# codex-monitor.sh started for this session arms the bridge out-of-sandbox.
mkdir -p "$RUN_DIR" 2>/dev/null || true
marker="$RUN_DIR/codex-name.$PROJECT_HASH.$THREAD"
tmp_marker="$marker.$$"
printf '%s\n' "$NAME" > "$tmp_marker" && mv "$tmp_marker" "$marker"

# Same server_key derivation as session-start.sh / codex-bridge-launcher.sh.
server_key="${APP_SERVER##*/}"; server_key="${server_key#codex-app-server.}"; server_key="${server_key%.sock}"
[ -n "$server_key" ] || server_key="$PROJECT_HASH"
request_file="$RUN_DIR/codex-bridge-request.$server_key"
tmp_request="$request_file.$$"
printf '%s\t%s\t%s\t%s\t%s\n' codex "$TEAM" "$NAME" "$THREAD" "$APP_SERVER" > "$tmp_request"
mv "$tmp_request" "$request_file"

echo "status=ok name=$NAME team=$TEAM thread=$THREAD app_server=$APP_SERVER via=launcher"
exit 0

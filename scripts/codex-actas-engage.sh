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
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
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
# (set when launched through codex-monitor.sh), then recover the native Windows
# ws:// endpoint from the .port file that codex-monitor.sh wrote. ---
SERVER_KEY="${AGMSG_CODEX_SERVER_KEY:-}"
if [ -z "$SERVER_KEY" ] && [ -n "${AGMSG_CODEX_NAME:-}" ]; then
  _id=$(printf '%s' "$AGMSG_CODEX_NAME" | tr -c 'A-Za-z0-9._-' '_')
  SERVER_KEY="${PROJECT_HASH:0:12}.${_id:0:24}"
fi

APP_SERVER="${AGMSG_CODEX_BRIDGE_APP_SERVER:-}"
if [ -z "$APP_SERVER" ]; then
  if [ -n "$SERVER_KEY" ] && [ -f "$RUN_DIR/codex-app-server.$SERVER_KEY.port" ]; then
    bridge_port=$(tr -d '[:space:]' < "$RUN_DIR/codex-app-server.$SERVER_KEY.port" 2>/dev/null || true)
    [ -n "$bridge_port" ] && APP_SERVER="ws://127.0.0.1:$bridge_port"
  fi
fi
if [ -z "$APP_SERVER" ] && [ -f "$RUN_DIR/codex-app-server.$PROJECT_HASH.port" ]; then
  bridge_port=$(tr -d '[:space:]' < "$RUN_DIR/codex-app-server.$PROJECT_HASH.port" 2>/dev/null || true)
  if [ -n "$bridge_port" ]; then
    APP_SERVER="ws://127.0.0.1:$bridge_port"
    [ -n "$SERVER_KEY" ] || SERVER_KEY="$PROJECT_HASH"
  fi
fi
if [ -z "$APP_SERVER" ]; then
  sock="$RUN_DIR/codex-app-server.$PROJECT_HASH.sock"
  if [ -S "$sock" ]; then
    APP_SERVER="unix://$sock"
    [ -n "$SERVER_KEY" ] || SERVER_KEY="$PROJECT_HASH"
  fi
fi
[ -n "$APP_SERVER" ] || { echo "status=no_app_server"; exit 4; }

meta_value() { # <key> <file>
  awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$2" 2>/dev/null
}

pid_is_alive() { # <pid>
  local pid="$1"
  kill -0 "$pid" 2>/dev/null && return 0
  if command -v tasklist >/dev/null 2>&1; then
    tasklist //FI "PID eq $pid" //NH 2>/dev/null \
      | awk -v pid="$pid" '$2 == pid { found=1 } END { exit found ? 0 : 1 }' \
      && return 0
  fi
  return 1
}

bridge_meta_is_for() { # <pidfile> <pid> <team> <name> <type>
  local pidfile="$1" pid="$2" team="$3" name="$4" type="$5" meta meta_pid meta_team meta_name meta_type
  meta="${pidfile%.pid}.meta"
  [ -f "$meta" ] || return 1
  meta_pid="$(meta_value pid "$meta")"
  meta_team="$(meta_value team "$meta")"
  meta_name="$(meta_value name "$meta")"
  meta_type="$(meta_value type "$meta")"
  [ "$meta_pid" = "$pid" ] || return 1
  [ "$meta_team" = "$team" ] || return 1
  [ "$meta_name" = "$name" ] || return 1
  [ -z "$type" ] || [ -z "$meta_type" ] || [ "$meta_type" = "$type" ] || return 1
  return 0
}

bridge_alive_for() { # <pidfile> <team> <name> <type> -> echoes live matching pid or empty
  local pf="$1" team="$2" name="$3" type="$4" p args
  [ -f "$pf" ] || return 0
  p=$(cat "$pf" 2>/dev/null || true)
  [ -n "$p" ] || return 0
  pid_is_alive "$p" || return 0
  args="$(ps -o args= -p "$p" 2>/dev/null || true)"
  if _args_is_bridge_for "$args" "$team" "$name"; then
    printf '%s' "$p"
    return 0
  fi
  if [ -z "$args" ] && bridge_meta_is_for "$pf" "$p" "$team" "$name" "$type"; then
    printf '%s' "$p"
  fi
}

bridge_live_pid() { # <pidfile> -> echoes live pid or empty
  local pf="$1" p
  [ -f "$pf" ] || return 0
  p=$(cat "$pf" 2>/dev/null || true)
  [ -n "$p" ] && pid_is_alive "$p" && printf '%s' "$p"
}

bridge_thread() { # <pidfile> <pid> -> echoes thread id if known
  local pf="$1" p="$2" t
  t=$(ps -o args= -p "$p" 2>/dev/null | sed -n 's/.*--thread \([0-9A-Za-z._:-][0-9A-Za-z._:-]*\).*/\1/p' | head -1)
  if [ -z "$t" ] && [ -f "${pf%.pid}.meta" ]; then
    t="$(meta_value thread "${pf%.pid}.meta")"
  fi
  printf '%s' "$t"
}

stop_bridge_pid() { # <pid>
  local p="$1"
  kill "$p" 2>/dev/null && return 0
  if command -v taskkill >/dev/null 2>&1; then
    taskkill //PID "$p" //F >/dev/null 2>&1 && return 0
  fi
  return 1
}

# --- Exclusivity: refuse if <name> is already armed by a live bridge on a
# DIFFERENT thread (another session owns this identity). ---
target_pidfile="$RUN_DIR/codex-bridge.$TEAM.$NAME.pid"
name_pid=$(bridge_alive_for "$target_pidfile" "$TEAM" "$NAME" codex)
if [ -n "$name_pid" ]; then
  cur_thread=$(bridge_thread "$target_pidfile" "$name_pid")
  if [ -n "$cur_thread" ] && [ "$cur_thread" != "$THREAD" ]; then
    echo "status=held name=$NAME owner_thread=$cur_thread owner_pid=$name_pid"
    exit 3
  fi
  if [ -z "$cur_thread" ]; then
    echo "status=held name=$NAME owner_thread=unknown owner_pid=$name_pid"
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
  p=$(bridge_live_pid "$pf"); [ -n "$p" ] || continue
  t=$(bridge_thread "$pf" "$p")
  if [ "$t" = "$THREAD" ]; then
    stop_bridge_pid "$p" || true
    rm -f "$pf" "${pf%.pid}.meta"
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

# Same server key derivation as session-start.sh / codex-bridge-launcher.sh.
# For ws:// endpoints the filename-safe key must come from codex-monitor.sh
# (or from the .port file we resolved above); parsing host:port would produce a
# different request file from the one the launcher watches on Windows.
if [ -z "$SERVER_KEY" ]; then
  case "$APP_SERVER" in
    unix://*)
      SERVER_KEY="${APP_SERVER##*/}"
      SERVER_KEY="${SERVER_KEY#codex-app-server.}"
      SERVER_KEY="${SERVER_KEY%.sock}"
      ;;
    ws://*)
      bridge_port=$(printf '%s\n' "$APP_SERVER" | sed -n 's#^ws://[^:][^:]*:\([0-9][0-9]*\).*$#\1#p')
      if [ -n "$bridge_port" ]; then
        for port_file in "$RUN_DIR"/codex-app-server.*.port; do
          [ -f "$port_file" ] || continue
          if [ "$(tr -d '[:space:]' < "$port_file" 2>/dev/null || true)" = "$bridge_port" ]; then
            SERVER_KEY="${port_file##*/codex-app-server.}"
            SERVER_KEY="${SERVER_KEY%.port}"
            break
          fi
        done
      fi
      ;;
  esac
fi
[ -n "$SERVER_KEY" ] || SERVER_KEY="$PROJECT_HASH"
request_file="$RUN_DIR/codex-bridge-request.$SERVER_KEY"
tmp_request="$request_file.$$"
printf '%s\t%s\t%s\t%s\t%s\n' codex "$TEAM" "$NAME" "$THREAD" "$APP_SERVER" > "$tmp_request"
mv "$tmp_request" "$request_file"

echo "status=ok name=$NAME team=$TEAM thread=$THREAD app_server=$APP_SERVER via=launcher"
exit 0

#!/usr/bin/env bash
set -euo pipefail

# Runs outside Codex's tool sandbox, waiting for SessionStart to publish the
# current thread id. The hook only writes a request file; this launcher owns the
# app-server socket connection and starts codex-bridge.js from the unsandboxed
# codex-monitor.sh wrapper process.

TYPE="${1:?Usage: codex-bridge-launcher.sh <type> <project_path> <app_server> <parent_pid>}"
PROJECT="${2:?Missing project_path}"
APP_SERVER="${3:?Missing app_server}"
PARENT_PID="${4:?Missing parent_pid}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
PROJECT_HASH="$(printf '%s' "$PROJECT" | shasum | awk '{print $1}')"
# Key the request file by the app-server socket so a per-identity server has its
# own launcher inbox; the shared single-identity socket's key is the project
# hash, so this is unchanged for the common case. Must match the writer key in
# session-start.sh.
server_key="${APP_SERVER##*/}"; server_key="${server_key#codex-app-server.}"; server_key="${server_key%.sock}"
[ -n "$server_key" ] || server_key="$PROJECT_HASH"
REQUEST_FILE="$RUN_DIR/codex-bridge-request.$server_key"

mkdir -p "$RUN_DIR"

last_request=""
while kill -0 "$PARENT_PID" 2>/dev/null; do
  if [ -f "$REQUEST_FILE" ]; then
    request="$(cat "$REQUEST_FILE" 2>/dev/null || true)"
    if [ -n "$request" ] && [ "$request" != "$last_request" ]; then
      last_request="$request"
      IFS="$(printf '\t')" read -r req_type team name thread_id req_app_server <<EOF
$request
EOF
      [ -n "${req_type:-}" ] || req_type="$TYPE"
      [ -n "${req_app_server:-}" ] || req_app_server="$APP_SERVER"
      if [ -n "${team:-}" ] && [ -n "${name:-}" ] && [ -n "${thread_id:-}" ]; then
        pidfile="$RUN_DIR/codex-bridge.$team.$name.pid"
        if [ -f "$pidfile" ]; then
          bridge_pid="$(cat "$pidfile" 2>/dev/null || true)"
          if [ -n "$bridge_pid" ] && kill -0 "$bridge_pid" 2>/dev/null; then
            sleep 0.2
            continue
          fi
        fi
        log="$RUN_DIR/codex-bridge.$team.$name.log"
        bridge_cmd="${AGMSG_CODEX_BRIDGE_CMD:-$SCRIPT_DIR/codex-bridge.js}"
        nohup "$bridge_cmd" \
          --project "$PROJECT" \
          --type "$req_type" \
          --team "$team" \
          --name "$name" \
          --thread "$thread_id" \
          --app-server "$req_app_server" \
          --inline-inbox \
          >>"$log" 2>&1 &
      fi
    fi
  fi
  sleep 0.2
done

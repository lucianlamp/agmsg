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
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/actas-lock.sh"
PROJECT_HASH="$(printf '%s' "$PROJECT" | shasum | awk '{print $1}')"
# Key the request file by the app-server socket so a per-identity server has its
# own launcher inbox; the shared single-identity socket's key is the project
# hash, so this is unchanged for the common case. Must match the writer key in
# session-start.sh.
# Prefer the key codex-monitor.sh exported (AGMSG_CODEX_SERVER_KEY); fall back to
# deriving it from the endpoint filename (unix:// ".sock") for back-compat. A
# ws:// endpoint has no ".sock" to parse, so the explicit key is required there.
server_key="${AGMSG_CODEX_SERVER_KEY:-}"
if [ -z "$server_key" ]; then
  server_key="${APP_SERVER##*/}"; server_key="${server_key#codex-app-server.}"; server_key="${server_key%.sock}"
fi
[ -n "$server_key" ] || server_key="$PROJECT_HASH"
REQUEST_FILE="$RUN_DIR/codex-bridge-request.$server_key"

mkdir -p "$RUN_DIR"

# Advance `last_request` ONLY after a request is genuinely handled (bridge
# already live, or a fresh bridge confirmed up). A spawn that never comes up must
# stay retriable on the same request, so we do NOT mark it done up front.
last_request=""

meta_value() { # <key> <file>
  awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$2" 2>/dev/null
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

bridge_process_is_for() { # <pidfile> <team> <name> <type>
  local pidfile="$1" team="$2" name="$3" type="$4" bridge_pid args
  [ -f "$pidfile" ] || return 1
  bridge_pid="$(cat "$pidfile" 2>/dev/null || true)"
  [ -n "$bridge_pid" ] || return 1
  pid_is_alive "$bridge_pid" || return 1
  args="$(ps -o args= -p "$bridge_pid" 2>/dev/null || true)"
  if _args_is_bridge_for "$args" "$team" "$name"; then
    return 0
  fi
  # Native Windows fallback: the bridge writes a real Windows node.exe PID, but
  # Git Bash/MSYS ps can fail to return argv for that native process. In that
  # case, accept the bridge-owned meta file as the identity proof.
  [ -z "$args" ] && bridge_meta_is_for "$pidfile" "$bridge_pid" "$team" "$name" "$type"
}

while kill -0 "$PARENT_PID" 2>/dev/null; do
  if [ -f "$REQUEST_FILE" ]; then
    request="$(cat "$REQUEST_FILE" 2>/dev/null || true)"
    if [ -n "$request" ] && [ "$request" != "$last_request" ]; then
      IFS="$(printf '\t')" read -r req_type team name thread_id req_app_server <<EOF
$request
EOF
      [ -n "${req_type:-}" ] || req_type="$TYPE"
      [ -n "${req_app_server:-}" ] || req_app_server="$APP_SERVER"
      if [ -z "${team:-}" ] || [ -z "${name:-}" ] || [ -z "${thread_id:-}" ]; then
        last_request="$request"   # malformed request — don't reprocess
      else
        pidfile="$RUN_DIR/codex-bridge.$team.$name.pid"
        if bridge_process_is_for "$pidfile" "$team" "$name" "$req_type"; then
          last_request="$request"   # our bridge for this identity is already live
          sleep 0.2
          continue
        fi
        if [ -f "$pidfile" ]; then
          # Stale pidfile: dead, PID-reused by an unrelated process, OR pointing
          # at a DIFFERENT identity's bridge. A bare kill -0 would skip this
          # request forever. Drop it and (re)arm.
          rm -f "$pidfile" "${pidfile%.pid}.meta"
        fi
        # No live bridge for this identity → about to (re)arm. A respawn leaves
        # the prior session's actas lock behind, anchored to the shared,
        # long-lived app-server pid, so it never expires and would block this new
        # bridge ("held by other sessions"). Release it now — after confirming no
        # live bridge — keeping it only if another live receiver still serves it.
        actas_lock_release_superseded "$team" "$name" "$thread_id" >/dev/null 2>&1 || true

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

        # The bridge writes its own pidfile on startup. Confirm it actually came
        # up (and is our bridge) before committing last_request; a failed launch
        # then stays retriable on the same request.
        for _ in $(seq 1 25); do
          if bridge_process_is_for "$pidfile" "$team" "$name" "$req_type"; then
            last_request="$request"
            break
          fi
          sleep 0.1
        done
      fi
    fi
  fi
  sleep 0.2
done

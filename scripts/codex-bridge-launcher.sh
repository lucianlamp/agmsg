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
        if [ -f "$pidfile" ]; then
          bridge_pid="$(cat "$pidfile" 2>/dev/null || true)"
          if [ -n "$bridge_pid" ] && kill -0 "$bridge_pid" 2>/dev/null \
              && _args_is_bridge_for "$(ps -o args= -p "$bridge_pid" 2>/dev/null || true)" "$team" "$name"; then
            last_request="$request"   # our bridge for this identity is already live
            sleep 0.2
            continue
          fi
          # Stale pidfile: dead, PID-reused by an unrelated process, OR pointing
          # at a DIFFERENT identity's bridge. A bare kill -0 would skip this
          # request forever. Drop it and (re)arm.
          rm -f "$pidfile"
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
          if [ -f "$pidfile" ]; then
            bridge_pid="$(cat "$pidfile" 2>/dev/null || true)"
            if [ -n "$bridge_pid" ] && kill -0 "$bridge_pid" 2>/dev/null \
                && _args_is_bridge_for "$(ps -o args= -p "$bridge_pid" 2>/dev/null || true)" "$team" "$name"; then
              last_request="$request"
              break
            fi
          fi
          sleep 0.1
        done
      fi
    fi
  fi
  sleep 0.2
done

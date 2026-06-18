#!/usr/bin/env bash
set -euo pipefail

# Launch Codex with agmsg's app-server bridge enabled.
#
# This is a beta convenience wrapper: it hides the shared app-server socket and
# lets session-start.sh launch codex-bridge.js in the background once Codex
# exposes CODEX_THREAD_ID to hooks.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"

PROJECT="$(pwd)"
SOCKET_PATH=""
CODEX_COMMAND="resume"
CODEX_ARGS=()
REAL_CODEX="${AGMSG_REAL_CODEX:-codex}"

usage() {
  cat <<EOF
Usage: codex-monitor.sh [--project <path>] [--socket-path <path>] [--codex-command <codex|resume>] [-- <args...>]

Starts/reuses an agmsg-managed Codex app-server socket, enables agmsg Codex
bridge hooks for this project, then execs:
  codex resume --remote <socket>
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --project)
      PROJECT="${2:?--project requires a path}"
      shift 2
      ;;
    --socket-path)
      SOCKET_PATH="${2:?--socket-path requires a path}"
      shift 2
      ;;
    --codex-command)
      CODEX_COMMAND="${2:?--codex-command requires codex or resume}"
      shift 2
      ;;
    --)
      shift
      CODEX_ARGS=("$@")
      break
      ;;
    *)
      CODEX_ARGS+=("$1")
      shift
      ;;
  esac
done

case "$CODEX_COMMAND" in
  codex|resume) ;;
  *)
    echo "codex-monitor: --codex-command must be 'codex' or 'resume'" >&2
    exit 1
    ;;
esac

PROJECT="$(cd "$PROJECT" && pwd)"
PROJECT_HASH="$(printf '%s' "$PROJECT" | shasum | awk '{print $1}')"
[ -n "$SOCKET_PATH" ] || SOCKET_PATH="$RUN_DIR/codex-app-server.$PROJECT_HASH.sock"
case "$SOCKET_PATH" in
  /*) ;;
  *) SOCKET_PATH="$PROJECT/$SOCKET_PATH" ;;
esac
SOCKET_URL="unix://$SOCKET_PATH"
SERVER_LOG="$RUN_DIR/codex-app-server.$PROJECT_HASH.log"
SERVER_PID="$RUN_DIR/codex-app-server.$PROJECT_HASH.pid"

mkdir -p "$RUN_DIR" "$(dirname "$SOCKET_PATH")"

if [ ! -S "$SOCKET_PATH" ]; then
  "$REAL_CODEX" app-server --listen "$SOCKET_URL" >>"$SERVER_LOG" 2>&1 &
  echo "$!" > "$SERVER_PID"
  for _ in $(seq 1 50); do
    [ -S "$SOCKET_PATH" ] && break
    sleep 0.1
  done
fi

if [ ! -S "$SOCKET_PATH" ]; then
  echo "codex-monitor: app-server socket did not appear: $SOCKET_PATH" >&2
  echo "codex-monitor: see $SERVER_LOG" >&2
  exit 1
fi

"$SCRIPT_DIR/delivery.sh" set monitor codex "$PROJECT" >/dev/null

export AGMSG_CODEX_BRIDGE=1
export AGMSG_CODEX_BRIDGE_APP_SERVER="$SOCKET_URL"
export AGMSG_CODEX_BRIDGE_LAUNCHER=1

launcher_cmd="${AGMSG_CODEX_BRIDGE_LAUNCHER_CMD:-$SCRIPT_DIR/codex-bridge-launcher.sh}"
"$launcher_cmd" codex "$PROJECT" "$SOCKET_URL" "$$" >/dev/null 2>&1 &

cd "$PROJECT"
case "$CODEX_COMMAND" in
  codex)
    exec "$REAL_CODEX" --remote "$SOCKET_URL" "${CODEX_ARGS[@]}"
    ;;
  resume)
    exec "$REAL_CODEX" resume --remote "$SOCKET_URL" "${CODEX_ARGS[@]}"
    ;;
esac

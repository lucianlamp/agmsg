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
# Per-identity app-server. A project-wide server is shared across every codex
# session in the project, and it fires SessionStart hooks from the environment
# of whichever session launched it FIRST — so a later session's chosen identity
# (AGMSG_CODEX_NAME) never reaches the hook, and the bridge cannot tell the
# sessions apart. When a session names itself at launch
# (`AGMSG_CODEX_NAME=kimura codex`), give it its own server keyed by that name:
# this session launches it, so the hooks it fires inherit this session's
# identity. Unset → the project-wide socket as before (single-identity
# back-compat; no extra server processes for the common case).
SERVER_KEY="$PROJECT_HASH"
if [ -n "${AGMSG_CODEX_NAME:-}" ]; then
  # Per-identity socket. Keep the path under the unix-domain SUN_LEN limit
  # (~104 bytes on macOS): the full 40-char project hash + ".<identity>" overflows
  # it, so use a 12-char project prefix (48 bits — ample to separate projects)
  # plus a sanitized, length-capped identity. session-start.sh and
  # codex-bridge-launcher.sh derive the same key back from the socket filename,
  # so request-file routing stays consistent.
  _id=$(printf '%s' "$AGMSG_CODEX_NAME" | tr -c 'A-Za-z0-9._-' '_')
  SERVER_KEY="${PROJECT_HASH:0:12}.${_id:0:24}"
fi
SERVER_LOG="$RUN_DIR/codex-app-server.$SERVER_KEY.log"
SERVER_PID="$RUN_DIR/codex-app-server.$SERVER_KEY.pid"
mkdir -p "$RUN_DIR"

# Export the bridge environment BEFORE the app-server is launched below: the
# app-server is the parent of the SessionStart hooks, so the hooks only inherit
# these when they are already exported at launch time. AGMSG_CODEX_SERVER_KEY
# lets session-start.sh / codex-bridge-launcher.sh agree on the request-file key
# without parsing it back out of the endpoint string — a ws:// endpoint has no
# ".sock" filename to key on, and its ":" is not a legal Windows filename char.
export AGMSG_CODEX_BRIDGE=1
export AGMSG_CODEX_BRIDGE_LAUNCHER=1
export AGMSG_CODEX_SERVER_KEY="$SERVER_KEY"

# Pick the app-server transport. Codex's app-server speaks WebSocket over either
# a unix-domain socket (unix://PATH) or TCP (ws://HOST:PORT). On native Windows
# (Git Bash/MSYS) the unix path does not work: codex.exe cannot bind the MSYS
# "/c/..." path, Git Bash's `-S` does not see a Windows AF_UNIX file as a socket,
# and Node's net.createConnection treats a path as a named pipe. ws://127.0.0.1
# over TCP loopback sidesteps all three. macOS/Linux keep the unix socket.
# Override for tests with AGMSG_CODEX_TRANSPORT=ws|unix.
case "${AGMSG_CODEX_TRANSPORT:-}" in
  ws|unix) _transport="$AGMSG_CODEX_TRANSPORT" ;;
  *)
    case "$(uname -s 2>/dev/null || echo unknown)" in
      MINGW*|MSYS*|CYGWIN*) _transport=ws ;;
      *) _transport=unix ;;
    esac
    ;;
esac

if [ "$_transport" = ws ]; then
  # TCP loopback. codex binds an ephemeral port (ws://127.0.0.1:0) and prints the
  # chosen port; we record it in a .port file so a later session for the same key
  # can reuse the running server, and so the in-sandbox SessionStart hook can
  # recover the endpoint (it does not inherit _APP_SERVER — the port is only known
  # after launch).
  PORT_FILE="$RUN_DIR/codex-app-server.$SERVER_KEY.port"
  _ready() {
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -o /dev/null "http://127.0.0.1:$1/readyz" 2>/dev/null
    else
      return 0
    fi
  }
  PORT=""
  if [ -f "$SERVER_PID" ] && [ -f "$PORT_FILE" ]; then
    _spid="$(cat "$SERVER_PID" 2>/dev/null || true)"
    _sport="$(cat "$PORT_FILE" 2>/dev/null || true)"
    if [ -n "$_spid" ] && [ -n "$_sport" ] && kill -0 "$_spid" 2>/dev/null && _ready "$_sport"; then
      PORT="$_sport"
    fi
  fi
  if [ -z "$PORT" ]; then
    : > "$SERVER_LOG"
    "$REAL_CODEX" app-server --listen "ws://127.0.0.1:0" >>"$SERVER_LOG" 2>&1 &
    echo "$!" > "$SERVER_PID"
    for _ in $(seq 1 100); do
      PORT="$(sed -n 's#.*listening on: ws://127\.0\.0\.1:\([0-9][0-9]*\).*#\1#p' "$SERVER_LOG" 2>/dev/null | head -1)"
      [ -n "$PORT" ] && break
      sleep 0.1
    done
    if [ -z "$PORT" ]; then
      echo "codex-monitor: app-server did not report a listening port" >&2
      echo "codex-monitor: see $SERVER_LOG" >&2
      exit 1
    fi
    printf '%s\n' "$PORT" > "$PORT_FILE"
    for _ in $(seq 1 50); do _ready "$PORT" && break; sleep 0.1; done
  fi
  SOCKET_URL="ws://127.0.0.1:$PORT"
  export AGMSG_CODEX_BRIDGE_APP_SERVER="$SOCKET_URL"
else
  [ -n "$SOCKET_PATH" ] || SOCKET_PATH="$RUN_DIR/codex-app-server.$SERVER_KEY.sock"
  case "$SOCKET_PATH" in
    /*) ;;
    *) SOCKET_PATH="$PROJECT/$SOCKET_PATH" ;;
  esac
  SOCKET_URL="unix://$SOCKET_PATH"
  export AGMSG_CODEX_BRIDGE_APP_SERVER="$SOCKET_URL"
  mkdir -p "$(dirname "$SOCKET_PATH")"

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
fi

"$SCRIPT_DIR/delivery.sh" set monitor codex "$PROJECT" >/dev/null

launcher_cmd="${AGMSG_CODEX_BRIDGE_LAUNCHER_CMD:-$SCRIPT_DIR/codex-bridge-launcher.sh}"
"$launcher_cmd" codex "$PROJECT" "$SOCKET_URL" "$$" >/dev/null 2>&1 &

cd "$PROJECT"
case "$CODEX_COMMAND" in
  codex)
    exec "$REAL_CODEX" --remote "$SOCKET_URL" ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"}
    ;;
  resume)
    exec "$REAL_CODEX" resume --remote "$SOCKET_URL" ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"}
    ;;
esac

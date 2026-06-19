#!/usr/bin/env bash
set -euo pipefail

# despawn.sh — tear down a spawned crew member, the inverse of spawn.sh.
#
# Usage:
#   despawn.sh <team> <from> <name> [--force] [--timeout <secs>]
#
#   <team>   team the member is in
#   <from>   the leader's own agent name (sender of the control message)
#   <name>   the member to tear down
#
# Default (graceful): send a `ctrl:despawn` control message to <name>. The
# member's watcher (watch.sh) sees it, drops its own role (releasing the actas
# lock) and closes its own tmux pane — ending its CLI. We block until the lock
# is released, up to --timeout (default 30s); on timeout the member didn't
# respond (dead watcher, or a codex member with no Monitor) — re-run with
# --force.
#
# --force: skip the message and tear the member down from here using the
# placement recorded at spawn time — kill its tmux pane/window and drop its
# registration. For when the member's watcher can't respond.
#
# See #109. Graceful teardown's full pane-close is tmux-only (the member needs a
# tmux pane to close); an OS-terminal member drops its role but its window must
# be closed by hand.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"  # actas-lock.sh requires SKILL_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"

die() { echo "despawn: $*" >&2; exit 1; }

TEAM="${1:-}"; FROM="${2:-}"; NAME="${3:-}"
[ -n "$TEAM" ] && [ -n "$FROM" ] && [ -n "$NAME" ] \
  || die "Usage: despawn.sh <team> <from> <name> [--force] [--timeout <secs>]"
shift 3 || true

FORCE=0
TIMEOUT=30
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be a whole number of seconds" ;; esac

SPAWN_REC="$(agmsg_spawn_path "$TEAM" "$NAME")"
# The spawn record's 3rd field is the agent type — the authoritative "is this a
# spawned codex member" signal. A codex-bridge pidfile alone is NOT: it can be
# stale/mislabeled and would wrongly divert a claude-code member off its graceful
# (watcher) path.
SPAWN_TYPE=""
[ -f "$SPAWN_REC" ] && IFS=$'\t' read -r _ _ SPAWN_TYPE < "$SPAWN_REC" 2>/dev/null || true

# Kill the recorded tmux target. ids are self-describing: %N pane, @N window.
kill_recorded_placement() {
  [ -f "$SPAWN_REC" ] || return 1
  local id _proj _type
  IFS=$'\t' read -r id _proj _type < "$SPAWN_REC"
  [ -n "$id" ] || return 1
  if command -v tmux >/dev/null 2>&1; then
    case "$id" in
      %*) tmux kill-pane   -t "$id" 2>/dev/null || true ;;
      @*) tmux kill-window -t "$id" 2>/dev/null || true ;;
    esac
  fi
  printf '%s\t%s\t%s' "$id" "$_proj" "$_type"   # echo back for the caller
}

if [ "$FORCE" = "1" ]; then
  [ -f "$SPAWN_REC" ] || die "no placement record for '$TEAM/$NAME' — nothing to force (was it launched via 'spawn'? graceful despawn does not need this)"
  IFS=$'\t' read -r _id _proj _type < "$SPAWN_REC"
  kill_recorded_placement >/dev/null
  # Kill the monitor bridge too, but ONLY for a codex member — the same
  # spawn-type contract the graceful path honours. A claude-code member must
  # never tear down a codex bridge that happens to share its team/name (that
  # bridge belongs to a different, live codex session). Done after the placement
  # so the launcher/TUI is already gone and can't re-arm it.
  if [ "$SPAWN_TYPE" = "codex" ]; then
    stop_codex_bridge_for "$TEAM" "$NAME" >/dev/null
  fi
  # Drop the member's registration, and release its (now-stale) lock.
  if [ -n "${_proj:-}" ] && [ -n "${_type:-}" ]; then
    "$SCRIPT_DIR/reset.sh" "$_proj" "$_type" "$NAME" >/dev/null 2>&1 || true
  fi
  owner="$(actas_lock_owner "$TEAM" "$NAME")"
  [ -n "$owner" ] && actas_lock_release "$TEAM" "$NAME" "$owner" 2>/dev/null || true
  rm -f "$SPAWN_REC" 2>/dev/null || true
  echo "status=forced name=$NAME team=$TEAM"
  exit 0
fi

# --- Graceful ---
# A spawned codex member has no watcher to act on ctrl:despawn, so tear it down
# directly instead of waiting (which would always time out). Order avoids a
# re-arm race: stop the placement (launcher/TUI) first, then the verified bridge,
# then registration + lock. A codex bridge with no spawn record is outside spawn
# management — leave it to `drop` / `delivery off`, not despawn.
if [ -f "$SPAWN_REC" ] && [ "$SPAWN_TYPE" = "codex" ]; then
  IFS=$'\t' read -r _id _proj _type < "$SPAWN_REC"
  kill_recorded_placement >/dev/null || true
  stop_codex_bridge_for "$TEAM" "$NAME" >/dev/null
  if [ -n "${_proj:-}" ] && [ -n "${_type:-}" ]; then
    "$SCRIPT_DIR/reset.sh" "$_proj" "$_type" "$NAME" >/dev/null 2>&1 || true
  fi
  owner="$(actas_lock_owner "$TEAM" "$NAME")"
  [ -n "$owner" ] && actas_lock_release "$TEAM" "$NAME" "$owner" 2>/dev/null || true
  rm -f "$SPAWN_REC" 2>/dev/null || true
  echo "status=ok name=$NAME team=$TEAM note=codex-teardown"
  exit 0
fi

state="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null || echo free)"
case "$state" in
  free)
    echo "despawn: '$NAME' holds no live actas lock — nothing to confirm a teardown against (a codex member has no watcher; a tmux member may already be gone). If a window remains, use --force." >&2
    rm -f "$SPAWN_REC" 2>/dev/null || true
    echo "status=ok name=$NAME team=$TEAM note=no-live-lock"
    exit 0
    ;;
esac

"$SCRIPT_DIR/send.sh" "$TEAM" "$FROM" "$NAME" "ctrl:despawn" >/dev/null

waited=0
while true; do
  state="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null || echo free)"
  [ "$state" = "free" ] && break
  if [ "$waited" -ge "$TIMEOUT" ]; then
    echo "status=timeout name=$NAME team=$TEAM after=${TIMEOUT}s"
    echo "despawn: '$NAME' did not tear down within ${TIMEOUT}s — its watcher may be dead. Retry with --force." >&2
    exit 3
  fi
  sleep 1
  waited=$((waited + 1))
done

rm -f "$SPAWN_REC" 2>/dev/null || true
echo "status=ok name=$NAME team=$TEAM after=${waited}s"

#!/usr/bin/env bash
# actas-lock.sh — per-(team, agent) exclusivity locks.
#
# Background: agmsg supports a project being registered with multiple agent
# identities of the same type (claude-code/codex/...). Without ownership
# tracking, every concurrent CC session in that project would subscribe to
# every registered identity's messages — duplicate delivery, confused mark-
# read semantics, and the `actas` "exclusive role" model breaking down.
#
# This file implements a small filesystem-based ownership protocol:
#
#   Lock file: $SKILL_DIR/run/actas.<team>__<agent>.session
#   Content  : one line — the owner session_id.
#
# A session_id is alive iff some $SKILL_DIR/run/cc-instance.<pid> file
# currently contains it AND that PID is alive. The same primitive used by
# session-start.sh's orphan-watcher cleanup. Stale locks (owner is no
# longer alive) are reclaimable.
#
# Atomic claim is implemented via `ln` of a per-call tmp file. POSIX
# guarantees the link target either appears or doesn't, even under
# concurrent claim attempts.
#
# Required caller-set variable:
#   SKILL_DIR — agmsg skill root.

: "${SKILL_DIR:?actas-lock.sh requires SKILL_DIR}"

# Owner tokens are per-process instance ids (see instance-id.sh), not bare
# session_ids — this is what keeps parallel --continue/--resume sessions that
# share a session_id from each appearing to own the other's locks (#93). The
# liveness check (actas_lock_sid_alive) delegates to agmsg_instance_alive.
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/instance-id.sh"

_actas_lock_dir() { printf '%s/run' "$SKILL_DIR"; }

# Encode a team or agent name into a filesystem-safe form. Anything outside
# [A-Za-z0-9._-] is percent-encoded byte-by-byte (UTF-8 safe, reversible).
# An earlier underscore-replacement scheme was lossy: "foo bar" and "foo_bar"
# collided on the same lock file, as did every Japanese team name (every
# non-ASCII byte mapped to "_"). #65 review, finding 2.
_actas_lock_encode() {
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { for (n = 0; n < 256; n++) ord[sprintf("%c", n)] = n }
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c ~ /[A-Za-z0-9._\-]/) printf "%s", c
        else printf "%%%02X", ord[c]
      }
    }
  '
}

# Compute the lock file path for (team, agent).
actas_lock_path() {
  local team="$1" agent="$2"
  local t a; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  printf '%s/actas.%s__%s.session' "$(_actas_lock_dir)" "$t" "$a"
}

# Readiness sentinel path for (team, agent). watch.sh creates this when an
# exclusive (actas) watcher attaches and removes it on exit, so the file is
# present iff a live watcher is currently receiving for that role. `spawn`
# uses it to block until a freshly launched agent is actually listening,
# instead of racing the agent's first push. Same encoding as the lock path so
# both scripts agree without env plumbing. See #108.
agmsg_ready_path() {
  local team="$1" agent="$2"
  local t a; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  printf '%s/ready.%s__%s' "$(_actas_lock_dir)" "$t" "$a"
}

# Placement record path for a spawned (team, agent). `spawn` writes the
# member's tmux target id + project + type here at launch time so that
# `despawn --force` can tear the member down (kill its pane/window, drop its
# registration) even when the member's own watcher is dead and can't respond
# to a ctrl:despawn. Same encoding as the lock path. See #109.
agmsg_spawn_path() {
  local team="$1" agent="$2"
  local t a; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  printf '%s/spawn.%s__%s' "$(_actas_lock_dir)" "$t" "$a"
}

# Read the owner session_id of a lock file. Empty if no lock or unreadable.
actas_lock_owner() {
  local lock; lock="$(actas_lock_path "$1" "$2")"
  [ -f "$lock" ] || { printf ''; return 0; }
  head -1 "$lock" 2>/dev/null
}

# Return 0 if the given owner token is alive. The token is a per-process
# instance id (composite "<sid>.<pid>" or bare "<sid>" fallback); liveness is
# delegated to agmsg_instance_alive (composite → kill -0 the embedded pid; bare
# → live cc-instance.<pid> scan, with upgrade compat). Kept as a thin wrapper
# so existing callers (gc_stale, watch.sh subscription, session-start GC) need
# no change. Empty token → not alive.
actas_lock_sid_alive() {
  agmsg_instance_alive "$1"
}

# Internal: attempt one atomic claim. Echoes "ok" on success, "held:<sid>"
# when another sid currently owns it, or "stale" when the existing lock's
# owner is dead (caller should retry after removing).
_actas_lock_try_claim() {
  local team="$1" agent="$2" sid="$3"
  local lock dir tmp existing
  lock="$(actas_lock_path "$team" "$agent")"
  dir="$(_actas_lock_dir)"
  mkdir -p "$dir" 2>/dev/null || true

  tmp="$(mktemp "$dir/.actas-claim.XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n' "$sid" > "$tmp"

  if ln "$tmp" "$lock" 2>/dev/null; then
    rm -f "$tmp"
    echo "ok"
    return 0
  fi
  rm -f "$tmp"

  existing="$(actas_lock_owner "$team" "$agent")"
  if [ "$existing" = "$sid" ]; then
    echo "ok"
    return 0
  fi
  if [ -z "$existing" ] || ! actas_lock_sid_alive "$existing"; then
    echo "stale"
    return 0
  fi
  printf 'held:%s\n' "$existing"
  return 0
}

# Claim (team, agent) for session_id.
# Exit codes:
#   0  — claimed (now owned by this sid, was already ours, or stale-replaced).
#   1  — held by another live session. Stdout: "held:<other_sid>".
actas_lock_claim() {
  local team="$1" agent="$2" sid="$3"
  local attempts=0 result lock_path reclaim_dir _owner
  lock_path="$(actas_lock_path "$team" "$agent")"
  reclaim_dir="${lock_path}.reclaim.d"
  while [ "$attempts" -lt 3 ]; do
    result="$(_actas_lock_try_claim "$team" "$agent" "$sid")"
    case "$result" in
      ok) return 0 ;;
      stale)
        # Stale removal needs a re-check-under-mutex. A naked rm (or even an
        # atomic mv) reads-then-removes whatever sits at lock_path, with no
        # guard that the contents are still the stale value we decided on
        # earlier. So two concurrent callers can both see stale, A can
        # successfully install a live lock, and B's later rm/mv would delete
        # A's fresh lock — the original blocker from #65 review finding 1,
        # and the same hazard the mv-only variant inherited.
        #
        # Per-lock mutex via `mkdir` (atomic on POSIX). Re-check inside it:
        # only remove the lock if its current owner is still dead. If a peer
        # snuck a live owner in between our stale decision and the mutex,
        # leave it — the next try_claim observes it as held.
        if mkdir "$reclaim_dir" 2>/dev/null; then
          _owner="$(actas_lock_owner "$team" "$agent")"
          if [ -z "$_owner" ] || ! actas_lock_sid_alive "$_owner"; then
            rm -f "$lock_path"
          fi
          rmdir "$reclaim_dir" 2>/dev/null
        fi
        # If mkdir failed, another caller is mid-reclaim. Loop without
        # touching anything; the next try_claim sees whichever state they
        # end up in (live → held, or empty → we ln-claim).
        attempts=$((attempts + 1))
        continue
        ;;
      held:*)
        printf '%s\n' "$result"
        return 1
        ;;
    esac
    return 1
  done
  return 1
}

# Release a lock if we own it. Idempotent.
actas_lock_release() {
  local team="$1" agent="$2" sid="$3"
  local lock owner
  lock="$(actas_lock_path "$team" "$agent")"
  [ -f "$lock" ] || return 0
  owner="$(actas_lock_owner "$team" "$agent")"
  [ "$owner" = "$sid" ] && rm -f "$lock"
  return 0
}

# Release every lock currently owned by the given session_id. Used by
# session-end.sh when a CC session exits.
actas_lock_release_all() {
  local sid="$1"
  local dir; dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || return 0
  local f owner
  for f in "$dir"/actas.*.session; do
    [ -f "$f" ] || continue
    owner="$(head -1 "$f" 2>/dev/null || true)"
    [ "$owner" = "$sid" ] && rm -f "$f"
  done
  return 0
}

# Garbage-collect locks whose owner session_id is no longer alive.
# Returns the number of locks reclaimed on stdout (for observability).
actas_lock_gc_stale() {
  local dir; dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || { echo 0; return 0; }
  local f owner count=0
  for f in "$dir"/actas.*.session; do
    [ -f "$f" ] || continue
    owner="$(head -1 "$f" 2>/dev/null || true)"
    if [ -z "$owner" ] || ! actas_lock_sid_alive "$owner"; then
      rm -f "$f"
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# True iff the given process argv is OUR codex bridge for (team, agent): the
# codex-bridge.js program AND a matching --team/--name. A recycled pid that lands
# on a DIFFERENT identity's live bridge must not count. The --team/--name values
# are extracted and compared LITERALLY (agent names may contain glob/regex
# metachars — join.sh accepts a.b, a*, a|b, …).
_args_is_bridge_for() {
  local args="$1" team="$2" agent="$3" v
  # KNOWN LIMITATION (accepted, low probability): this matches "codex-bridge.js"
  # as a substring of the argv rather than verifying the executable. A stale
  # pidfile whose pid was reused by an UNRELATED process that merely carries the
  # string "codex-bridge.js" (plus a matching --team/--name) in its argv would be
  # mis-read as a live receiver. Closing this fully needs a per-launch identity
  # token (or start-time) the bridge records and we compare — deferred. The far
  # more common reuse case (pid reused by a *different identity's* real bridge)
  # IS rejected by the --team/--name checks below.
  case "$args" in *codex-bridge.js*) ;; *) return 1 ;; esac
  # Extract the --team / --name VALUES up to the next " --<opt>" boundary, not the
  # next space: team/agent names may legitimately contain spaces (the contract is
  # arbitrary UTF-8 minus path-dangerous chars, e.g. "team one"). The values are
  # then compared with literal `[ = ]`, so glob/regex metachars in them are inert.
  case " $args " in *" --team "*) ;; *) return 1 ;; esac
  v="${args##*--team }"; v="${v%% --*}"; [ "$v" = "$team" ] || return 1
  case " $args " in *" --name "*) ;; *) return 1 ;; esac
  v="${args##*--name }"; v="${v%% --*}"; [ "$v" = "$agent" ] || return 1
  return 0
}

# Stop the codex monitor bridge for (team, agent): kill its process and remove
# its pidfile/meta/log. The pid is killed ONLY after confirming the live process
# is actually OUR bridge for this identity (_args_is_bridge_for) — a recycled or
# mislabeled pidfile must never make us kill an unrelated process; in that case we
# clean only the stale artifacts. No-op (echoes 0) when there is no pidfile (e.g.
# a non-codex member). Echoes 1 if a bridge process was signalled, else 0.
# Same KNOWN LIMITATION as _args_is_bridge_for: identity is matched from argv, not
# a per-launch token; a start_time/nonce in the bridge meta would close it.
stop_codex_bridge_for() {
  local team="$1" agent="$2" dir pidfile bpid i killed=0
  dir="$(_actas_lock_dir)"
  pidfile="$dir/codex-bridge.$team.$agent.pid"
  [ -f "$pidfile" ] || { echo 0; return 0; }
  bpid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -n "$bpid" ] && kill -0 "$bpid" 2>/dev/null \
      && _args_is_bridge_for "$(ps -o args= -p "$bpid" 2>/dev/null || true)" "$team" "$agent"; then
    kill "$bpid" 2>/dev/null || true
    i=0
    while kill -0 "$bpid" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 0.1; i=$((i + 1)); done
    kill -0 "$bpid" 2>/dev/null && kill -9 "$bpid" 2>/dev/null || true
    killed=1
  fi
  rm -f "$pidfile" "${pidfile%.pid}.meta" "${pidfile%.pid}.log"
  echo "$killed"
}

# True iff some LIVE process is actually receiving for codex (team, agent):
# either the monitor bridge (codex-bridge.<team>.<agent>.pid pointing at a live
# codex-bridge.js for THIS identity) or a host-managed / claude-code watcher
# (a live watch.sh whose final arg is exactly <agent>). Decides whether an
# exclusivity lock still has a real owner. False "no" could strip a live owner's
# lock, AND for codex a stray false "yes" keeps a stale lock that then blocks
# subscription — so both directions are matched precisely (identity-checked,
# literal), never by loose substring/regex.
_actas_has_live_receiver() {
  local team="$1" agent="$2" dir pf p procs line
  dir="$(_actas_lock_dir)"
  pf="$dir/codex-bridge.$team.$agent.pid"
  if [ -f "$pf" ]; then
    p="$(cat "$pf" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      _args_is_bridge_for "$(ps -o args= -p "$p" 2>/dev/null || true)" "$team" "$agent" \
        && return 0
    fi
  fi
  # A live watch.sh whose LAST positional arg is exactly <agent>. Capture ps into
  # a variable and iterate via a here-doc (never `ps | grep`, whose pipe under the
  # caller's `set -o pipefail` turns grep's early exit into a SIGPIPE → false "no
  # receiver"). The last-word equality is literal, so glob/regex metachars in
  # <agent> can't over- or under-match.
  procs="$(ps -eo args= 2>/dev/null || true)"
  while IFS= read -r line; do
    case "$line" in *watch.sh*) ;; *) continue ;; esac
    # The watcher's trailing positional arg is the agent; it may contain spaces,
    # so test "line ends with ' <agent>'" via a LITERAL (quoted) suffix strip
    # rather than taking only the last whitespace-delimited word.
    [ "${line%" $agent"}" != "$line" ] && return 0
  done <<RECV
$procs
RECV
  return 1
}

# Release a SUPERSEDED exclusivity lock for (team, agent) when a new session
# (this_sid) is taking over the identity. Background: codex actas-lock liveness
# is anchored to a pid, and for codex that pid is the SHARED, long-lived
# app-server — which outlives the session that claimed the lock. So a dead
# predecessor's lock stays "alive" under actas_lock_sid_alive and blocks the new
# session forever ("held by other sessions"); actas_lock_gc_stale never reaps it
# because the app-server pid is genuinely running.
#
# Safe by construction (addresses the codex review):
#   - never touches a lock owned by THIS session (owner_sid == this_sid);
#   - keeps the lock whenever a LIVE receiver (bridge or watcher) is actually
#     serving the identity — so it can't strip a live owner (no "is the pid an
#     app-server" guessing, which both over-matched unrelated processes and
#     missed pid reuse);
#   - releases under a mkdir mutex with a compare-and-delete: it re-reads the
#     owner and re-checks liveness inside the mutex and only unlinks if nothing
#     changed, so it can't clobber a fresh re-claim.
# Echoes 1 if released, else 0.
actas_lock_release_superseded() {
  local team="$1" agent="$2" this_sid="$3"
  local lock owner owner_sid mutex holder released=0
  lock="$(actas_lock_path "$team" "$agent")"
  [ -f "$lock" ] || { echo 0; return 0; }
  owner="$(head -1 "$lock" 2>/dev/null || true)"
  [ -n "$owner" ] || { echo 0; return 0; }
  owner_sid="${owner%.*}"
  [ "$owner_sid" != "$this_sid" ] || { echo 0; return 0; }
  _actas_has_live_receiver "$team" "$agent" && { echo 0; return 0; }

  mutex="$lock.reclaim"
  if ! mkdir "$mutex" 2>/dev/null; then
    # Mutex held. Recover it if its holder died mid-reclaim (otherwise the lock
    # could never be reclaimed again): take it over only when the recorded holder
    # pid is gone. mkdir stays the atomic arbiter, so a concurrent recoverer just
    # loses the re-mkdir and yields.
    holder="$(cat "$mutex/owner" 2>/dev/null || true)"
    # Empty owner == a reclaimer that just won mkdir and hasn't written its pid
    # yet. Indistinguishable from a live holder mid-setup, so YIELD rather than
    # risk deleting an in-progress mutex. Only recover when a recorded holder pid
    # is provably dead.
    if [ -z "$holder" ] || kill -0 "$holder" 2>/dev/null; then
      echo 0; return 0
    fi
    rm -rf "$mutex" 2>/dev/null || true
    mkdir "$mutex" 2>/dev/null || { echo 0; return 0; }
  fi
  printf '%s\n' "$$" > "$mutex/owner" 2>/dev/null || true
  if [ "$(head -1 "$lock" 2>/dev/null || true)" = "$owner" ] \
      && ! _actas_has_live_receiver "$team" "$agent"; then
    rm -f "$lock"
    released=1
  fi
  rm -rf "$mutex" 2>/dev/null || true
  echo "$released"
}

# Classify a (team, agent) pair relative to the calling session.
# Echoes one of: free | mine | other:<sid>
actas_lock_state() {
  local team="$1" agent="$2" sid="$3"
  local owner
  owner="$(actas_lock_owner "$team" "$agent")"
  if [ -z "$owner" ]; then
    echo "free"; return 0
  fi
  if [ "$owner" = "$sid" ]; then
    echo "mine"; return 0
  fi
  if actas_lock_sid_alive "$owner"; then
    printf 'other:%s\n' "$owner"
  else
    echo "free"  # stale owner — effectively free, GC will remove it later
  fi
}

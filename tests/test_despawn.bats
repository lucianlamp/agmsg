#!/usr/bin/env bats

# Tests for despawn (#109): a leader tears down a spawned member. Graceful path
# is watcher-driven (watch.sh sees ctrl:despawn, drops its own role); --force is
# leader-driven from the recorded placement.

load test_helper

setup() {
  setup_test_env
  export PROJ="/tmp/agmsg-despawn-proj"
  export RUN="$TEST_SKILL_DIR/run"
  mkdir -p "$RUN"
}

teardown() {
  teardown_test_env
}

@test "despawn: graceful — ctrl:despawn makes the member drop its role" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  # Make the member session look alive so the leader sees a live lock to wait on.
  setup_live_owner "$RUN" sess-m

  # Unset TMUX_PANE: the ctrl:despawn handler runs `tmux kill-pane -t $TMUX_PANE`,
  # and a watcher launched from inside the developer's tmux would inherit the
  # REAL pane id and close the session running the tests. With TMUX_PANE empty,
  # the handler takes the "close manually" branch — role-drop is still asserted.
  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE bash "$SCRIPTS/watch.sh" sess-m "$PROJ" claude-code alice \
    >/dev/null 2>&1 &
  local wpid=$! i
  # Wait for the watcher to attach (it claims the lock + writes the ready sentinel).
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$RUN/ready.team__alice" ] && break; sleep 0.5; done
  [ -e "$RUN/ready.team__alice" ]
  [ -f "$RUN/actas.team__alice.session" ]

  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok"* ]]

  # Member dropped its role: lock released and registration gone.
  [ ! -f "$RUN/actas.team__alice.session" ]
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" != *alice* ]]

  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
}

@test "despawn --force: kills recorded placement and drops registration without the member" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  # Placement as spawn would have recorded it (pane %99 doesn't exist; kill is
  # best-effort/no-op here — we assert the registration + lock + record effects).
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.team__alice"
  printf 'somesid\n' > "$RUN/actas.team__alice.session"

  run bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  [ ! -f "$RUN/spawn.team__alice" ]                 # placement record cleaned
  [ ! -f "$RUN/actas.team__alice.session" ]         # lock released
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" != *alice* ]]                        # registration dropped
}

@test "despawn --force: errors when there is no placement record" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  run bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no placement record" ]]
}

@test "despawn: times out (exit 3) when the member never drops" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  setup_live_owner "$RUN" sess-m
  printf 'sess-m\n' > "$RUN/actas.team__alice.session"   # held live, no watcher to act

  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 2
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout"* ]]
}

@test "despawn: a broad (non-actas) watcher ignores ctrl:despawn and does not self-destruct" {
  # Regression for the self-kill bug: a leader's default watcher subscribes to
  # EVERY project role. If it acted on a ctrl:despawn addressed to one of them,
  # it would run `tmux kill-pane -t $TMUX_PANE` against the leader's OWN pane and
  # take down the leader session. A broad watcher must skip the control message.
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null

  # Broad watcher (no actas arg) — subscribes to both alice and leader.
  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE bash "$SCRIPTS/watch.sh" sess-broad "$PROJ" claude-code \
    >/dev/null 2>&1 &
  local wpid=$! i
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$wpid" 2>/dev/null && break; sleep 0.5; done

  # Deliver a despawn aimed at alice straight into the stream.
  bash "$SCRIPTS/send.sh" team boss alice "ctrl:despawn" >/dev/null
  sleep 2

  kill -0 "$wpid" 2>/dev/null            # watcher still alive — did NOT self-destruct
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" == *alice* ]]             # broad watcher did not drop alice's role

  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
}

@test "despawn: graceful no-op when the member holds no live lock (e.g. codex)" {
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  run bash "$SCRIPTS/despawn.sh" team leader alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-live-lock"* ]]
}

@test "despawn: graceful — a spawned codex member is torn down directly (no watcher wait)" {
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '@99' "$PROJ" codex > "$RUN/spawn.team__alice"
  printf 'somesid\n' > "$RUN/actas.team__alice.session"
  echo 999999 > "$RUN/codex-bridge.team.alice.pid"      # stale (dead pid)

  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex-teardown"* ]]
  [ ! -f "$RUN/codex-bridge.team.alice.pid" ]
  [ ! -f "$RUN/actas.team__alice.session" ]
  [ ! -f "$RUN/spawn.team__alice" ]
  run bash "$SCRIPTS/identities.sh" "$PROJ" codex
  [[ "$output" != *alice* ]]
}

@test "despawn: a stale codex pidfile does NOT divert a claude-code member off graceful (review)" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.team__alice"
  echo 999999 > "$RUN/codex-bridge.team.alice.pid"      # stale codex pidfile, but member is claude-code

  run bash "$SCRIPTS/despawn.sh" team leader alice
  [ "$status" -eq 0 ]
  [[ "$output" != *"codex-teardown"* ]]                 # NOT the codex direct path
}

@test "despawn --force: also stops the codex monitor bridge" {
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '@99' "$PROJ" codex > "$RUN/spawn.team__alice"
  printf 'somesid\n' > "$RUN/actas.team__alice.session"
  echo 999999 > "$RUN/codex-bridge.team.alice.pid"

  run bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  [ ! -f "$RUN/codex-bridge.team.alice.pid" ]
  [ ! -f "$RUN/spawn.team__alice" ]
  [ ! -f "$RUN/actas.team__alice.session" ]
}

@test "despawn --force: stops a LIVE codex bridge (verified kill, not just pidfile cleanup)" {
  # The prior test uses a dead pid, so it only proves pidfile cleanup. Here the
  # bridge is a real live process whose argv matches team/alice — force must
  # actually kill it.
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '@99' "$PROJ" codex > "$RUN/spawn.team__alice"
  printf 'somesid\n' > "$RUN/actas.team__alice.session"

  printf '#!/usr/bin/env bash\nsleep 30\n' > "$TEST_SKILL_DIR/codex-bridge.js"
  chmod +x "$TEST_SKILL_DIR/codex-bridge.js"
  bash "$TEST_SKILL_DIR/codex-bridge.js" --team team --name alice --thread tX &
  local bpid=$!
  echo "$bpid" > "$RUN/codex-bridge.team.alice.pid"

  run bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  ! kill -0 "$bpid" 2>/dev/null                     # the live bridge was killed
  [ ! -f "$RUN/codex-bridge.team.alice.pid" ]
  [ ! -f "$RUN/spawn.team__alice" ]

  kill "$bpid" 2>/dev/null || true; wait "$bpid" 2>/dev/null || true
}

@test "despawn --force: a claude-code member does NOT kill a same-name codex bridge (spawn-type gate)" {
  # A claude-code 'alice' plus an unrelated, LIVE codex bridge that happens to
  # share team/alice (a different codex session). Forcing the claude-code member
  # must NOT tear that bridge down — the bridge teardown is gated on spawn type,
  # not on the mere presence of a matching pidfile.
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.team__alice"
  printf 'somesid\n' > "$RUN/actas.team__alice.session"

  printf '#!/usr/bin/env bash\nsleep 30\n' > "$TEST_SKILL_DIR/codex-bridge.js"
  chmod +x "$TEST_SKILL_DIR/codex-bridge.js"
  bash "$TEST_SKILL_DIR/codex-bridge.js" --team team --name alice --thread tX &
  local bpid=$!
  echo "$bpid" > "$RUN/codex-bridge.team.alice.pid"

  run bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  kill -0 "$bpid" 2>/dev/null                       # the codex bridge survived
  [ -f "$RUN/codex-bridge.team.alice.pid" ]         # its pidfile left intact

  kill "$bpid" 2>/dev/null || true; wait "$bpid" 2>/dev/null || true
}

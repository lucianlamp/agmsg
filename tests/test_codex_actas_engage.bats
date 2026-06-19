#!/usr/bin/env bats
# codex-actas-engage.sh — in-session `/agmsg actas <name>` receive-side engage.
#
# Binds a running Codex session's receive identity to <name> by arming a bridge
# for (<name>, this thread, the session's app-server). The bridge itself is
# stubbed via AGMSG_CODEX_BRIDGE_CMD so we assert HOW it is armed, not that codex
# actually runs.

load test_helper

setup() {
  setup_test_env
  PROJECT="$TEST_SKILL_DIR/proj"; mkdir -p "$PROJECT"
  RUN_DIR="$TEST_SKILL_DIR/run"; mkdir -p "$RUN_DIR"
  PROJECT_HASH="$(printf '%s' "$PROJECT" | shasum | awk '{print $1}')"
  THREAD="thread-xyz-1"
  # Stub bridge: record argv so we can assert name/thread, then exit.
  BRIDGE_STUB="$TEST_SKILL_DIR/stub-bridge.sh"
  BRIDGE_ARGS="$TEST_SKILL_DIR/bridge-args.txt"
  cat > "$BRIDGE_STUB" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$BRIDGE_ARGS"
EOF
  chmod +x "$BRIDGE_STUB"
  # A real (non-bridge) socket file so the app-server resolution succeeds.
  : > "$RUN_DIR/codex-app-server.$PROJECT_HASH.sock"
}

teardown() { teardown_test_env; }

engage() { # extra KEY=VAL exports then <name>
  CODEX_THREAD_ID="$THREAD" \
  AGMSG_CODEX_BRIDGE_APP_SERVER="unix://$RUN_DIR/codex-app-server.$PROJECT_HASH.sock" \
  AGMSG_CODEX_BRIDGE_CMD="$BRIDGE_STUB" \
  bash "$SCRIPTS/codex-actas-engage.sh" "$PROJECT" "$1"
}

wait_for() { local f="$1" i=0; while [ ! -s "$f" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done; }

@test "refuses a name that is not a registered codex identity" {
  run engage ghost
  [ "$status" -eq 2 ]
  [[ "$output" == *"status=not_registered"* ]]
  [ ! -f "$RUN_DIR/codex-name.$PROJECT_HASH.$THREAD" ]
}

@test "writes a launcher request for the name on this thread and records the marker" {
  bash "$SCRIPTS/join.sh" dev kimura codex "$PROJECT"

  run engage kimura
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok"* ]]
  [[ "$output" == *"name=kimura"* ]]
  [[ "$output" == *"via=launcher"* ]]

  # marker records the thread→name binding
  [ "$(cat "$RUN_DIR/codex-name.$PROJECT_HASH.$THREAD")" = "kimura" ]

  # the launcher request (keyed by the app-server socket) carries the identity +
  # thread; the out-of-sandbox launcher arms the bridge from it (#41).
  req="$RUN_DIR/codex-bridge-request.$PROJECT_HASH"
  [ -f "$req" ]
  [ "$(awk -F'\t' '{print $3}' "$req")" = "kimura" ]
  [ "$(awk -F'\t' '{print $4}' "$req")" = "$THREAD" ]
}

@test "fails cleanly when this session's thread cannot be resolved" {
  bash "$SCRIPTS/join.sh" dev kimura codex "$PROJECT"
  # No CODEX_THREAD_ID and a sandboxed empty $HOME/.codex → unresolvable.
  run env -u CODEX_THREAD_ID \
    AGMSG_CODEX_BRIDGE_APP_SERVER="unix://$RUN_DIR/codex-app-server.$PROJECT_HASH.sock" \
    AGMSG_CODEX_BRIDGE_CMD="$BRIDGE_STUB" \
    bash "$SCRIPTS/codex-actas-engage.sh" "$PROJECT" kimura
  [ "$status" -eq 4 ]
  [[ "$output" == *"status=no_thread"* ]]
}

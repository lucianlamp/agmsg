#!/usr/bin/env bats
# session-start.sh — codex per-session receive identity resolution.
#
# Exercises the launcher-mode request-file path: with
# AGMSG_CODEX_BRIDGE_LAUNCHER=1 the codex block resolves (team, name) and writes
# run/codex-bridge-request.<project_hash> as "type\tteam\tname\tthread\tapp".
# We assert the selected NAME field across the selector precedence:
#   AGMSG_CODEX_NAME env  >  thread-keyed marker  >  sole-pair back-compat.

load test_helper

setup() {
  setup_test_env
  PROJECT="$TEST_SKILL_DIR/proj"
  mkdir -p "$PROJECT"
  RUN_DIR="$TEST_SKILL_DIR/run"
  PROJECT_HASH="$(printf '%s' "$PROJECT" | shasum | awk '{print $1}')"
  REQUEST_FILE="$RUN_DIR/codex-bridge-request.$PROJECT_HASH"
  THREAD="thread-abc-123"
}

teardown() { teardown_test_env; }

# Run session-start.sh on the codex launcher path with a forced thread + socket.
# Extra "KEY=VAL" args are exported for the invocation (e.g. AGMSG_CODEX_NAME).
run_session_start() {
  AGMSG_CODEX_BRIDGE_LAUNCHER=1 \
  AGMSG_CODEX_BRIDGE_APP_SERVER="unix:///tmp/fake-codex.sock" \
  CODEX_THREAD_ID="$THREAD" \
  env "$@" bash "$SCRIPTS/session-start.sh" codex "$PROJECT" </dev/null
}

# Echo the NAME field (3rd tab-column) of the written request file.
request_name() { awk -F'\t' '{print $3}' "$REQUEST_FILE"; }

@test "env AGMSG_CODEX_NAME selects its identity among multiple" {
  bash "$SCRIPTS/join.sh" dev kimura codex "$PROJECT"
  bash "$SCRIPTS/join.sh" dev goro   codex "$PROJECT"

  run_session_start AGMSG_CODEX_NAME=kimura
  [ -f "$REQUEST_FILE" ]
  [ "$(request_name)" = "kimura" ]

  run_session_start AGMSG_CODEX_NAME=goro
  [ "$(request_name)" = "goro" ]
}

@test "env naming an unregistered identity engages no bridge and leaves a breadcrumb" {
  bash "$SCRIPTS/join.sh" dev kimura codex "$PROJECT"

  run run_session_start AGMSG_CODEX_NAME=nobody
  [ "$status" -eq 0 ]
  [ ! -f "$REQUEST_FILE" ]
  [ -f "$RUN_DIR/codex-bridge.unknown.nobody.log" ]
}

@test "thread-keyed marker selects identity when no env is set" {
  bash "$SCRIPTS/join.sh" dev kimura codex "$PROJECT"
  bash "$SCRIPTS/join.sh" dev goro   codex "$PROJECT"

  mkdir -p "$RUN_DIR"
  printf 'goro\n' > "$RUN_DIR/codex-name.$PROJECT_HASH.$THREAD"

  run_session_start
  [ "$(request_name)" = "goro" ]
}

@test "env wins over the thread-keyed marker" {
  bash "$SCRIPTS/join.sh" dev kimura codex "$PROJECT"
  bash "$SCRIPTS/join.sh" dev goro   codex "$PROJECT"

  mkdir -p "$RUN_DIR"
  printf 'goro\n' > "$RUN_DIR/codex-name.$PROJECT_HASH.$THREAD"

  run_session_start AGMSG_CODEX_NAME=kimura
  [ "$(request_name)" = "kimura" ]
}

@test "no selector with multiple codex identities bails (no guess)" {
  bash "$SCRIPTS/join.sh" dev kimura codex "$PROJECT"
  bash "$SCRIPTS/join.sh" dev goro   codex "$PROJECT"

  run run_session_start
  [ "$status" -eq 0 ]
  [ ! -f "$REQUEST_FILE" ]
}

@test "back-compat: single codex identity needs no selector" {
  bash "$SCRIPTS/join.sh" dev kimura codex "$PROJECT"

  run_session_start
  [ "$(request_name)" = "kimura" ]
}

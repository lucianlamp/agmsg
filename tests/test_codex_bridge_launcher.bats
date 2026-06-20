#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export PROJ="$TEST_SKILL_DIR/proj"
  mkdir -p "$PROJ" "$TEST_SKILL_DIR/bin" "$TEST_SKILL_DIR/run"
  export LAUNCH_LOG="$TEST_SKILL_DIR/bridge-launches.log"
}

teardown() {
  if [ -f "$LAUNCH_LOG" ]; then
    while read -r pid _; do
      case "$pid" in
        ''|*[!0-9]*) continue ;;
      esac
      kill "$pid" 2>/dev/null || true
    done < "$LAUNCH_LOG"
  fi
  teardown_test_env
}

@test "codex bridge launcher accepts matching pidfile/meta when ps cannot read bridge argv" {
  cat > "$TEST_SKILL_DIR/bin/ps" <<'EOF'
#!/usr/bin/env bash
echo "ps: unknown option -- o" >&2
exit 1
EOF
  chmod +x "$TEST_SKILL_DIR/bin/ps"
  cat > "$TEST_SKILL_DIR/bin/tasklist" <<'EOF'
#!/usr/bin/env bash
cat <<OUT
Image Name                     PID Session Name        Session#    Mem Usage
========================= ======== ================ =========== ============
node.exe                    999999 Console                    1     32,156 K
OUT
EOF
  chmod +x "$TEST_SKILL_DIR/bin/tasklist"

  local fake_bridge="$TEST_SKILL_DIR/fake-codex-bridge"
  cat > "$fake_bridge" <<'EOF'
#!/usr/bin/env bash
team=""
name=""
type=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) team="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --type) type="$2"; shift 2 ;;
    *) shift ;;
  esac
done
run_dir="$TEST_SKILL_DIR/run"
native_pid=999999
printf '%s launch\n' "$native_pid" >> "$LAUNCH_LOG"
printf '%s\n' "$native_pid" > "$run_dir/codex-bridge.$team.$name.pid"
{
  printf 'pid=%s\n' "$native_pid"
  printf 'team=%s\n' "$team"
  printf 'name=%s\n' "$name"
  printf 'type=%s\n' "$type"
} > "$run_dir/codex-bridge.$team.$name.meta"
EOF
  chmod +x "$fake_bridge"

  local request="$TEST_SKILL_DIR/run/codex-bridge-request.testkey"
  printf 'codex\tteam\talice\tthread-1\tws://127.0.0.1:12345\n' > "$request"

  sleep 30 &
  local parent_pid="$!"

  PATH="$TEST_SKILL_DIR/bin:$PATH" \
  AGMSG_CODEX_SERVER_KEY=testkey \
  AGMSG_CODEX_BRIDGE_CMD="$fake_bridge" \
    bash "$SCRIPTS/codex-bridge-launcher.sh" codex "$PROJ" ws://127.0.0.1:12345 "$parent_pid" &
  local launcher_pid="$!"

  sleep 3.5
  kill "$launcher_pid" 2>/dev/null || true
  kill "$parent_pid" 2>/dev/null || true
  wait "$launcher_pid" 2>/dev/null || true

  [ -f "$LAUNCH_LOG" ]
  [ "$(wc -l < "$LAUNCH_LOG" | tr -d '[:space:]')" -eq 1 ]
}

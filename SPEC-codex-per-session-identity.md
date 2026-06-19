# Spec: codex bridge per-session receive identity

## Problem

In a project with **multiple** codex identities registered (e.g. `kimura` and
`goro` both `type=codex` for `/Users/ysk411/dev`), every codex session collapses
onto a single bridge identity. `scripts/session-start.sh` (codex block) bails when
there is more than one codex pair:

```sh
pair_count=$(printf '%s\n' "$PAIRS" | awk 'NF >= 2 { c++ } END { print c + 0 }')
[ "$pair_count" = "1" ] || exit 0        # <-- multi-identity disengages the bridge
team=$(... print $1; exit)                # first pair only
name=$(... print $2; exit)
```

Result: a message addressed to `kimura` is received by whichever single session
holds the (arbitrarily first-picked) subscription; a second codex session for the
same project never engages a bridge. The user wants the obvious behavior:
**`kimura`宛 → the kimura session, `goro`宛 → the goro session.**

## Root constraint (by design, see SKILL.md:96-99)

- Claude Code: `actas` claims a session_id-keyed exclusivity lock per identity.
- **Codex: actas is send-side only** — "no stable session_id during slash
  commands", so the CC receive-side lock cannot be reused for codex.

However codex **does** have a stable per-session key that `session-start.sh`
already resolves and the bridge already consumes: the **thread_id**
(`CODEX_THREAD_ID` / resolved from the newest matching rollout, see `#41`).
That key lets us bind a session → receive identity without needing a session_id
during slash commands.

## Design (env primary, slash secondary)

### A. Primary: launch-time env `AGMSG_CODEX_NAME`

The user names each codex session at launch:

```sh
AGMSG_CODEX_NAME=kimura codex     # this session receives kimura's mail
AGMSG_CODEX_NAME=goro   codex     # this session receives goro's mail
```

`session-start.sh` codex block resolves the bridge identity as:

1. `want="${AGMSG_CODEX_NAME:-}"`.
2. If `want` is set:
   - Validate it is a registered codex pair for this project (`$PAIRS`). Resolve
     its `team`. If not registered → emit a one-line hint to the bridge log and
     `exit 0` (do not guess).
   - Use `(team, want)`. **Skip the `pair_count==1` guard entirely.**
3. If `want` is empty:
   - Keep current behavior: `pair_count==1` → use the sole pair; else `exit 0`.

Back-compat: single-identity projects with no env behave exactly as today.

#### env propagation (MUST verify)

`AGMSG_CODEX_NAME` is set in the user's shell before `codex`. The agmsg shim
(`codex-monitor.sh`) `exec`s the real codex, so codex inherits it. The codex
**SessionStart hook** must also inherit it for `session-start.sh` to read it.
- If codex passes its process env to hook commands → works as-is.
- If codex sanitizes hook env → fallback: `codex-monitor.sh` writes the value to
  a per-thread marker `run/codex-name.<project_hash>.<thread_id>` (or exports via
  the launcher/request-file path) that `session-start.sh` reads.
- **Action for implementer: determine which holds and wire the reliable path.**

### B. Secondary: in-session `/agmsg actas <name>` for codex

Convenience entry point so a running codex session can (re)select its identity
without relaunch. Because there is no stable session_id mid-slash-command, key the
selection by **thread_id** instead:

1. Resolve current thread_id the same way `session-start.sh` does
   (`CODEX_THREAD_ID` or newest matching rollout).
2. Write `run/codex-name.<project_hash>.<thread_id>` = `<name>` (atomic tmp+mv).
3. `session-start.sh` precedence becomes: `AGMSG_CODEX_NAME` env **>** thread-keyed
   marker **>** `pair_count==1` fallback.
4. Re-arm the bridge under the new name (the launcher already re-spawns from the
   request file; ensure a name change triggers a fresh request + supersedes the
   old bridge for that thread).

Slash is additive; ship A first and gate B behind A working.

### Exclusivity (prevent two sessions claiming the same name)

The launcher (`codex-bridge-launcher.sh`) already skips spawning when a live
`codex-bridge.<team>.<name>.pid` exists. Keep that as the guard: a second session
requesting an already-live name gets no duplicate bridge. Emit a hint to its log
("identity <name> already held by a live bridge — relaunch with a free name").
v1 does not need cross-session preemption.

## Files in scope

- `scripts/session-start.sh` — identity resolution in the codex block
  (lines ~108-144). The only required change for A.
- `scripts/codex-monitor.sh` — env propagation fallback if needed.
- `scripts/check-inbox.sh` / actas command template — for B (slash) only.
- Tests: `tests/` bats suite — add cases for env-selected identity + back-compat.

## Acceptance (verified locally, 2 real codex sessions)

1. Register `kimura` and `goro` (codex) for one project.
2. Launch session K: `AGMSG_CODEX_NAME=kimura codex`; session G:
   `AGMSG_CODEX_NAME=goro codex`. Each turn once.
3. Expect two live bridges: `codex-bridge.<team>.kimura.pid` and
   `...goro.pid`, distinct threads, neither log shows "held by other sessions".
4. `send.sh <team> nakai kimura "ping-K"` → delivered as a turn to **session K only**.
5. `send.sh <team> nakai goro "ping-G"` → delivered to **session G only**.
6. Back-compat: a single-identity project with no env still engages its one bridge.

## Out of scope

- Cross-session preemption / migration of a held identity.
- Reworking the CC actas-lock model (lucianlamp's `feat/actas-drop` is a separate
  upstream direction; this PR targets fujibee's existing codex bridge beta).

# Multiple Codex identities in one project

> Extends the [Codex monitor bridge (beta)](codex-monitor-beta.md). Read that first.

By default a project registers one Codex identity, and the monitor bridge binds
the session to it. If you register **more than one** Codex identity for the same
project (e.g. `kimura` and `goro`, both `type=codex`), you can run several Codex
sessions in that project and have each one **receive only its own mail** —
`kimura`-addressed messages reach the `kimura` session, `goro`-addressed messages
reach the `goro` session.

There are two ways to tell a session which identity it receives as.

## 1. At launch — `AGMSG_CODEX_NAME` (recommended)

Name the session when you start it:

```bash
AGMSG_CODEX_NAME=kimura codex     # this session receives kimura's mail
AGMSG_CODEX_NAME=goro   codex     # a second session, receives goro's mail
```

Each named session gets its **own app-server**, so the SessionStart hook it fires
inherits that session's identity and arms a bridge for it. Send a first message
to start the bridge (as with any monitor session).

Requires monitor mode — i.e. launched through the agmsg `codex` shim with
`~/.agents/bin` first on `PATH` (see [codex-monitor-beta.md](codex-monitor-beta.md)).
Unset `AGMSG_CODEX_NAME` → unchanged single-identity behaviour.

## 2. In-session — `$agmsg actas <name>`

Inside a running Codex session, switch or pick the receive identity without
relaunching:

```
$agmsg actas kimura
```

This sets the send-from name **and** binds the receive side to `kimura` for this
session (it arms a bridge for `kimura` on this session's thread). On success it
reports `status=ok`. If another live session already receives as `kimura` it
reports `status=held` and leaves your receive identity unchanged — drop it there
or pick a different name.

`actas` receive-binding needs a monitor-mode session; on a non-monitor session it
falls back to send-only (receive still covers all your registered roles), exactly
as before.

## Registering the identities

Both ways need the names registered as `codex` for the project first. `actas`
auto-joins an unregistered name; otherwise:

```bash
~/.agents/skills/agmsg/scripts/join.sh <team> kimura codex "$(pwd)"
~/.agents/skills/agmsg/scripts/join.sh <team> goro   codex "$(pwd)"
```

## How it works

The monitor bridge resumes one Codex thread on an app-server socket and
subscribes as one identity. The hard part is letting two sessions in one project
each pick a *different* identity:

- **Per-identity app-server.** A project-wide app-server is shared across every
  session and fires SessionStart hooks from the environment of whichever session
  started it *first*, so a later session's `AGMSG_CODEX_NAME` never reaches the
  hook. Naming a session gives it its own app-server (socket keyed by the name),
  whose hooks inherit that session's identity. The per-identity socket uses a
  shortened project hash to stay under the unix-domain `SUN_LEN` path limit.
- **Thread-keyed selection.** Codex `actas` has no stable session_id during a
  slash command, but the Codex *thread_id* is a stable per-session key the hook
  already resolves. Selection (env or `actas`) is keyed by it, and a thread→name
  marker records the binding.
- **Out-of-sandbox arming.** A slash command runs inside the Codex sandbox, where
  a directly-spawned bridge can't reach the app-server socket. `actas` therefore
  writes a request for the out-of-sandbox launcher (the same hand-off the
  SessionStart path uses), and the launcher arms the bridge.

## Verifying

After launching/binding two identities and sending a first message in each:

```bash
RUN=~/.agents/skills/agmsg/run
# one bridge per identity, on distinct threads:
ps aux | grep '[c]odex-bridge.js' | sed -E 's/.*--name ([a-z]+) --thread ([0-9a-f-]+).*/\1 \2/'
# their per-identity app-server sockets:
ls "$RUN"/codex-app-server.*.sock
```

Send a test to one identity and confirm only its bridge wakes:

```bash
~/.agents/skills/agmsg/scripts/send.sh <team> <from> kimura "ping"
tail -2 "$RUN"/codex-bridge.<team>.kimura.log   # → "wakeup ... started turn"
tail -1 "$RUN"/codex-bridge.<team>.goro.log     # → still just "armed" (no cross-delivery)
```

## Notes & limits

- One identity, one live receiver: a name already received by a live session is
  refused for a second session (`status=held`). Use a different name or `$agmsg
  drop` it on the other session.
- Switching identity mid-session via `actas` retires the bridge on that thread and
  arms the new one.
- Single-identity projects are entirely unaffected — no extra app-server is
  started and behaviour is byte-for-byte unchanged.

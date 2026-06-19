#!/usr/bin/env bash
# validate.sh — input validation for values that become filesystem paths.
#
# Team names are used directly as path segments in the team registry
# (teams/<name>/config.json). A name containing "/", "\", or equal to "." / ".."
# can escape teams/ and create/read/move/delete files outside the agmsg state
# tree (#140). Validate at every entry point that turns a team name into a path:
# join.sh, leave.sh, team.sh, rename.sh, rename-team.sh.
#
# Team names are intentionally allowed to be arbitrary UTF-8 (e.g. Japanese team
# names like "testチーム" exist in the wild), so this is a deny-list of
# path-dangerous constructs, NOT an ASCII allow-list. Multibyte UTF-8 bytes are
# all >= 0x80, so they never match the control-character range below.

# Guard against double-source.
[ -n "${_AGMSG_VALIDATE_SH:-}" ] && return 0
_AGMSG_VALIDATE_SH=1

# Return 0 if <name> is safe to use as a single path segment, else print a
# specific error (labelled with <kind>) to stderr and return 1.
agmsg_validate_name_segment() {
  local kind="$1" name="$2"
  if [ -z "$name" ]; then
    echo "agmsg: invalid $kind name: must not be empty" >&2
    return 1
  fi
  case "$name" in
    .|..)
      echo "agmsg: invalid $kind name '$name': '.' and '..' are not allowed" >&2
      return 1 ;;
    */*|*\\*)
      echo "agmsg: invalid $kind name '$name': must not contain '/' or '\\' (path traversal)" >&2
      return 1 ;;
    -*)
      # Leading '-' would be parsed as an option by downstream tools.
      echo "agmsg: invalid $kind name '$name': must not start with '-'" >&2
      return 1 ;;
    *--*)
      # A name carrying '--' (e.g. "foo --thread x", "x--name y") becomes
      # indistinguishable from an option boundary once the name is flattened into
      # a process argv string, which the codex bridge self-heal reads back to
      # confirm a live receiver. Forbidding consecutive dashes keeps that readback
      # unambiguous (single dashes, spaces, and arbitrary UTF-8 stay allowed).
      echo "agmsg: invalid $kind name '$name': must not contain '--'" >&2
      return 1 ;;
  esac
  # Reject control characters (NUL can't reach a shell var, but newline / tab /
  # other C0 + DEL can corrupt paths, configs, and row-counting output).
  case "$name" in
    *[[:cntrl:]]*)
      echo "agmsg: invalid $kind name: must not contain control characters" >&2
      return 1 ;;
  esac
  return 0
}

# Team and agent names both become path segments — team/<team>/config.json and
# run/codex-bridge.<team>.<agent>.{pid,meta} — so both need the same path-safety
# checks. Spaces and arbitrary UTF-8 stay allowed (Japanese names exist in the
# wild); only path-dangerous constructs are denied.
agmsg_validate_team_name()  { agmsg_validate_name_segment team "$1"; }
agmsg_validate_agent_name() { agmsg_validate_name_segment agent "$1"; }

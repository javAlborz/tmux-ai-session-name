#!/usr/bin/env bash
# Fork the agent session running in a tmux window into a NEW window (prefix + B).
#
# The point is to never handle a session id by hand. Codex mints a new thread id
# every turn and carries the session NAME onto each one, so resuming by name
# resolves to "whichever thread most recently held that name" -- never the point
# you meant to branch from. The id is the only stable anchor, and the naming
# plugin already records it per window in @ai-session-name-thread-id, so this
# reads it from there instead of asking you to type a UUID.
#
# Forking never disturbs the source: every client mints a new session id for the
# fork and leaves the original untouched, so the same window can be branched
# from repeatedly.
#
# Usage: agent-fork.sh <window-id> [fork-name]
# Set AGENT_FORK_DRY_RUN=1 to print the composed command instead of running it.
set -u

# Errors go to the tmux status line, where the binding's user will see them --
# and additionally to stdout under dry run, so a test can observe them.
note() {
  tmux display-message "agent-fork: $1" 2>/dev/null
  [ "${AGENT_FORK_DRY_RUN:-}" = "1" ] && printf 'agent-fork: %s\n' "$1"
  return 0
}

win="${1:-}"
fork_name="${2:-}"
[ -n "$win" ] || { note "no window given"; exit 0; }

pane_pid="$(tmux display-message -pt "$win" -p '#{pane_pid}' 2>/dev/null)"
pane_cwd="$(tmux display-message -pt "$win" -p '#{pane_current_path}' 2>/dev/null)"
target_session="$(tmux display-message -pt "$win" -p '#{session_name}' 2>/dev/null)"
thread_id="$(tmux show-options -wqv -t "$win" @ai-session-name-thread-id 2>/dev/null)"
[ -n "$pane_pid" ] || { note "cannot resolve pane"; exit 0; }

# Walk the pane's process tree. The client is identified from the actual
# processes rather than from the plugin's tool label, because that label reports
# every session-dir client (Pi included) as "task", which is not enough to pick
# a fork command.
descendants() {
  local frontier="$1" next child seen=" $1 "
  while [ -n "$frontier" ]; do
    next=""
    for p in $frontier; do
      for child in $(pgrep -P "$p" 2>/dev/null); do
        case "$seen" in
          *" $child "*) ;;
          *) printf '%s\n' "$child"; seen="$seen$child "; next="$next $child" ;;
        esac
      done
    done
    frontier="$next"
  done
}

# The pane process itself is included: a pane usually runs a shell with the
# agent as a child, but tmux will exec a command directly when one is given, and
# then the agent IS the pane process.
client=""
for p in "$pane_pid" $(descendants "$pane_pid"); do
  comm="$(cat "/proc/$p/comm" 2>/dev/null)"
  case "$comm" in
    codex) client=codex; break ;;
    claude) client=claude; break ;;
    pi) client=pi; break ;;
  esac
  # Node-launched clients report the wrapper as comm, so fall back to argv.
  args="$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null)"
  case "$args" in
    */bin/codex\ *|*/bin/codex) client=codex; break ;;
    */bin/claude\ *|*/bin/claude) client=claude; break ;;
    */bin/pi\ *|*/bin/pi) client=pi; break ;;
  esac
done

[ -n "$client" ] || { note "no agent session in $win"; exit 0; }

# A synthetic pane:<pid> identity is the generic provider's fallback when it
# could not read a real session id; it is not forkable, so treat it as unknown
# and let the client's own picker resolve it.
case "$thread_id" in pane:*) thread_id="" ;; esac

# Ask for a name only where one can actually be applied. Codex takes no name
# flag, so prompting for it there meant typing the name twice: once into a
# prompt that could not use it, then again as /rename inside the fork. The
# prompt therefore happens AFTER the client is known, by re-entering this script
# with the answer -- which is also why the binding passes no name itself.
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if [ -z "$fork_name" ] && [ "$client" != codex ]; then
  if [ "${AGENT_FORK_DRY_RUN:-}" = "1" ]; then
    printf 'client=%s would prompt for a name\n' "$client"
    exit 0
  fi
  tmux command-prompt -p "fork name:" \
    "run-shell '$self \"$win\" \"%%\"'" 2>/dev/null
  exit 0
fi

# Only Claude and Pi accept a display name at launch. Codex's second positional
# is an opening PROMPT, not a name, so a codex fork is renamed from inside the
# session -- which matters, because it will otherwise arrive carrying the source
# session's name and immediately recreate the duplicate-name problem.
case "$client" in
  codex)
    if [ -n "$thread_id" ]; then cmd="codex fork $thread_id"; else cmd="codex fork"; fi
    ;;
  claude)
    # The plugin records no identity for Claude windows, so the picker resolves
    # it. Claude session ids are stable, so there is no ambiguity to fear here.
    cmd="claude --resume --fork-session"
    [ -n "$fork_name" ] && cmd="$cmd -n $(printf '%q' "$fork_name")"
    ;;
  pi)
    if [ -n "$thread_id" ]; then cmd="pi --fork $thread_id"; else cmd="pi --resume"; fi
    [ -n "$fork_name" ] && cmd="$cmd --name $(printf '%q' "$fork_name")"
    ;;
esac

if [ "${AGENT_FORK_DRY_RUN:-}" = "1" ]; then
  printf 'client=%s thread=%s name=%s cwd=%s\n  %s\n' \
    "$client" "${thread_id:-<none>}" "${fork_name:-<none>}" "$pane_cwd" "$cmd"
  exit 0
fi

tmux new-window -a -t "$target_session" -c "$pane_cwd" "$cmd"
if [ "$client" = codex ] && [ -n "$fork_name" ]; then
  tmux display-message "forked; run /rename $fork_name inside it (codex takes no name flag)"
fi
exit 0

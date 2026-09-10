#!/usr/bin/env bash
# Fork the agent session running in a tmux window into a NEW window (prefix + B).
#
# Resolve the session again when the key is pressed. A process may have switched
# sessions since the naming daemon last ran, even if the window name is correct.
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

# Read names directly from the popup's terminal. Never substitute prompt input
# into a tmux run-shell template: quoting the final launch command is too late
# once command-prompt has already evaluated a name containing $(...) or quotes.
prompt=0
if [ "${1:-}" = --prompt ]; then
  prompt=1
  shift
fi
win="${1:-}"
fork_name="${2:-}"
[ -n "$win" ] || { note "no window given"; exit 0; }
if [ "$prompt" = 1 ]; then
  IFS= read -r -p 'Fork name (empty to cancel): ' fork_name || exit 0
  [ -n "$fork_name" ] || exit 0
fi

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

# Secure Pi uses an in-memory session and a narrow host-only fork endpoint.
# Keep its lane/workspace policy instead of launching the normal `pi` alias,
# which may select a different lane and rejects raw --fork/--resume arguments.
secure_pi_run=""
if [ "$client" = pi ]; then
  secure_pi_run="$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | sed -n 's/^PI_SAFE_TMUX_RUN=//p' | head -1)"
  secure_pi_lane="$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | sed -n 's/^PI_SAFE_LANE=//p' | head -1)"
  if [ -n "$secure_pi_lane" ] && [ -z "$secure_pi_run" ]; then
    note "restart this secure Pi session to enable tmux branching"
    exit 0
  fi
fi

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
  printf -v prompt_cmd '%q --prompt %q' "$self" "$win"
  tmux display-popup -E -w 60 -h 5 -T 'Branch agent session' "$prompt_cmd" 2>/dev/null
  exit 0
fi

# Only Claude and Pi accept a display name at launch. Codex's second positional
# is an opening PROMPT, not a name, so a codex fork is renamed from inside the
# session -- which matters, because it will otherwise arrive carrying the source
# session's name and immediately recreate the duplicate-name problem.
case "$client" in
  codex)
    # Cached window IDs and resume arguments can refer to a previous session.
    result="$(env -u AI_SESSION_NAME_PROCESS_TABLE_FILE AI_SESSION_NAME_CACHE_FILE= AI_SESSION_NAME_REPORT_ID=1 \
      "${self%/*}/session-name-for-pane.sh" "$pane_pid" "$pane_cwd" "" 2>/dev/null || true)"
    rest="${result#*$'\t'}"
    thread_id="${rest%%$'\t'*}"
    if [ "${result%%$'\t'*}" != codex ] || [ "${result##*$'\t'}" != live ] || [ -z "$thread_id" ]; then
      note "cannot verify the current Codex session; no branch was created"
      exit 0
    fi
    if [ -n "$thread_id" ]; then
      if [[ ! "$thread_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
        note "invalid recorded Codex session ID; wait for tmux to detect the session"
        exit 0
      fi
      printf -v cmd 'codex fork %q' "$thread_id"
    fi
    ;;
  claude)
    # The plugin records no identity for Claude windows, so the picker resolves
    # it. Claude session ids are stable, so there is no ambiguity to fear here.
    cmd="claude --resume --fork-session"
    [ -n "$fork_name" ] && cmd="$cmd -n $(printf '%q' "$fork_name")"
    ;;
  pi)
    if [ -n "$secure_pi_run" ]; then
      if [ "${AGENT_FORK_DRY_RUN:-}" = 1 ]; then
        printf 'client=pi secure branch via pi-safe-tmux\n'
        exit 0
      fi
      ticket="$("$HOME/bin/pi-safe-tmux" fork "$secure_pi_run" "$fork_name" 2>&1)" || {
        note "$ticket"
        exit 0
      }
      printf -v cmd '%q --tmux-branch %q' "$HOME/bin/pi-safe" "$ticket"
    elif [ -n "$thread_id" ]; then
      # On hosts with a safe `pi` alias, a trusted upstream session must continue
      # through its own executable. It must never switch an existing safe lane.
      pi_executable="$(readlink -f "/proc/$p/exe" 2>/dev/null)"
      pi_script="$(tr '\0' '\n' <"/proc/$p/cmdline" 2>/dev/null | sed -n '2p')"
      if [ "${pi_executable##*/}" = node ] && [ -f "$pi_script" ]; then
        printf -v cmd '%q %q --fork %q --name %q' "$pi_executable" "$pi_script" "$thread_id" "$fork_name"
      else
        printf -v cmd 'pi --fork %q --name %q' "$thread_id" "$fork_name"
      fi
    else
      note "Pi has no recorded session ID; name the session and wait for tmux to detect it"
      exit 0
    fi
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

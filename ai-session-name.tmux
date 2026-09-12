#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

get_tmux_option() {
  local option="$1"
  local default_value="$2"
  local value

  value="$(tmux show-option -gqv "$option")"
  if [ -z "$value" ]; then
    echo "$default_value"
  else
    echo "$value"
  fi
}

tmux set-environment -g AI_SESSION_NAME_PLUGIN_DIR "$CURRENT_DIR"

# Self-heal: re-spawn the daemon on common tmux events. Launching via setsid
# detaches the daemon from tmux's process tree, so tmux won't print a
# "terminated by signal N" status when the daemon eventually exits. The
# daemon's own flock+pid guard makes repeated invocations a fast no-op.
spawn_cmd="run-shell -b 'setsid -f bash \"$CURRENT_DIR/scripts/rename-daemon.sh\" </dev/null >/dev/null 2>&1'"

# Older releases appended an unindexed hook on every config reload. Remove only
# entries owned by this plugin, retain other integrations, and reserve one
# stable index so sourcing the plugin is idempotent.
hook_index=92
for hook in client-attached session-created after-new-window; do
  while IFS= read -r hook_line; do
    hook_entry="${hook_line%% *}"
    case "$hook_line" in
      *"$CURRENT_DIR/scripts/rename-daemon.sh"*)
        if [ "$hook_entry" != "${hook}[$hook_index]" ]; then
          tmux set-hook -gu "$hook_entry"
        fi
        ;;
    esac
  done < <(tmux show-hooks -g "$hook" 2>/dev/null || true)
done

enabled="$(get_tmux_option "@ai-session-name-enabled" "on")"
# Remove only bindings still owned by this plugin, including older installs
# without ownership metadata. Preserve user replacements on the same key.
fork_key="$(get_tmux_option "@ai-session-name-fork-key" "")"
while IFS= read -r binding; do
  case "$binding" in
    *"$CURRENT_DIR/scripts/agent-fork.sh"*)
      key="$(printf '%s\n' "$binding" | awk '{print $4}')"
      if [ "$enabled" != on ] || [ "$key" != "$fork_key" ]; then
        tmux unbind-key "$key"
      fi
      ;;
  esac
done < <(tmux list-keys -T prefix 2>/dev/null)
if [ "$enabled" != "on" ]; then
  tmux set-hook -gu "after-rename-window[$hook_index]" 2>/dev/null || true
  for hook in client-attached session-created after-new-window; do
    tmux set-hook -gu "${hook}[$hook_index]" 2>/dev/null || true
  done
  exit 0
fi

# Capture the command even when the chosen name equals the current title.
# A synchronous hook observes the internal-rename marker before its writer
# clears it. Pass only tmux's stable window ID through the shell.
tmux set-hook -g "after-rename-window[$hook_index]" \
  "run-shell 'bash \"$CURRENT_DIR/scripts/manual-name.sh\" \"#{window_id}\"'"

setsid -f bash "$CURRENT_DIR/scripts/rename-daemon.sh" </dev/null >/dev/null 2>&1
for hook in client-attached session-created after-new-window; do
  tmux set-hook -g "${hook}[$hook_index]" "$spawn_cmd"
done

# Optional key that branches the agent session in the current window into a new
# window. It lives here because it consumes this plugin's own record of which
# session is in which window (@ai-session-name-thread-id): launch names can outlive a session switch, so Codex
# branching also verifies the current open session when the key is pressed.
#
# Unset by default. A plugin that otherwise only observes should not claim a key
# or spawn processes without being asked, so the binding is opt-in:
#   set -g @ai-session-name-fork-key B
fork_key="$(get_tmux_option "@ai-session-name-fork-key" "")"
if [ -n "$fork_key" ]; then
  tmux bind-key "$fork_key" run-shell "'$CURRENT_DIR/scripts/agent-fork.sh' '#{window_id}'"
fi

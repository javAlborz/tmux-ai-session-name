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

enabled="$(get_tmux_option "@ai-session-name-enabled" "on")"
if [ "$enabled" != "on" ]; then
  exit 0
fi

tmux set-environment -g AI_SESSION_NAME_PLUGIN_DIR "$CURRENT_DIR"
setsid -f bash "$CURRENT_DIR/scripts/rename-daemon.sh" </dev/null >/dev/null 2>&1

# Self-heal: re-spawn the daemon on common tmux events. Launching via setsid
# detaches the daemon from tmux's process tree, so tmux won't print a
# "terminated by signal N" status when the daemon eventually exits. The
# daemon's own flock+pid guard makes repeated invocations a fast no-op.
spawn_cmd="run-shell -b 'setsid -f bash \"$CURRENT_DIR/scripts/rename-daemon.sh\" </dev/null >/dev/null 2>&1'"
for hook in client-attached session-created after-new-window; do
  tmux set-hook -ga "$hook" "$spawn_cmd"
done


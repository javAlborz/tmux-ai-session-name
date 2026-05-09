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
tmux run-shell -b "$CURRENT_DIR/scripts/rename-daemon.sh"


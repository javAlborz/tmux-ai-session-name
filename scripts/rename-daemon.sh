#!/usr/bin/env bash
set -u

plugin_dir="${AI_SESSION_NAME_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
rename_script="$plugin_dir/scripts/rename-windows.sh"

tmux_option() {
  local option="$1"
  local default_value="$2"
  local value

  value="$(tmux show-option -gqv "$option" 2>/dev/null || true)"
  if [ -z "$value" ]; then
    printf '%s\n' "$default_value"
  else
    printf '%s\n' "$value"
  fi
}

server_pid="$(tmux display-message -p '#{pid}' 2>/dev/null || echo unknown)"
pid_file="${TMPDIR:-/tmp}/tmux-ai-session-name.${server_pid}.pid"
lock_file="${pid_file}.lock"

# Serialise the check-and-write so concurrent hook firings can't spawn duplicates.
exec 9>"$lock_file"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || exit 0
fi

if [ -r "$pid_file" ]; then
  old_pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    exit 0
  fi
fi

echo "$$" >"$pid_file"
trap 'rm -f "$pid_file" "$lock_file"' EXIT INT TERM

while tmux list-sessions >/dev/null 2>&1; do
  enabled="$(tmux_option "@ai-session-name-enabled" "on")"
  if [ "$enabled" = "on" ]; then
    "$rename_script" >/dev/null 2>&1 || true
  fi

  interval="$(tmux_option "@ai-session-name-interval" "5")"
  case "$interval" in
    ''|*[!0-9]*) interval=5 ;;
  esac
  [ "$interval" -lt 1 ] && interval=1
  sleep "$interval"
done

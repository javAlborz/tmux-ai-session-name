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

runtime_dir="${AI_SESSION_NAME_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}}"
if [ ! -d "$runtime_dir" ] || [ ! -w "$runtime_dir" ]; then
  runtime_dir="${TMPDIR:-/tmp}"
fi

server_pid="$(tmux display-message -p '#{pid}' 2>/dev/null || echo unknown)"
pid_file="$runtime_dir/tmux-ai-session-name.${server_pid}.pid"
lock_file="${pid_file}.lock"

# Serialise startup so concurrent hook firings can't spawn duplicates. Keep the
# lock file itself in place: unlinking a flocked path lets a later process lock
# a new inode at the same name and creates two live daemons.
exec 9>"$lock_file"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || exit 0
elif [ -r "$pid_file" ]; then
  old_pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    exit 0
  fi
fi

# Every file here is named after the tmux server it belongs to, and the per-pass
# process table adds the pass pid too. A server that exits without its daemon
# running the cleanup below -- killed, or gone with the machine -- leaves its set
# behind, and nothing ever reclaimed them: ~150 had accumulated over a few days
# of short-lived servers. Reap once at startup, which is often enough and costs
# nothing during the loop.
reap_dead_runtime_files() {
  local f base rest owner pass

  for f in "$runtime_dir"/tmux-ai-session-name.*; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    rest="${base#tmux-ai-session-name.}"
    owner="${rest%%.*}"
    case "$owner" in ''|*[!0-9]*) continue ;; esac
    [ "$owner" = "$server_pid" ] || { kill -0 "$owner" 2>/dev/null && continue; }

    # A .proc snapshot belongs to one pass of one server; it is stale as soon as
    # either is gone, so a live server's abandoned snapshots are reclaimed too.
    case "$base" in
      *.proc)
        pass="${rest#*.}"
        pass="${pass%%.*}"
        case "$pass" in
          ''|*[!0-9]*) ;;
          *) kill -0 "$pass" 2>/dev/null && continue ;;
        esac
        ;;
      *)
        [ "$owner" = "$server_pid" ] && continue
        ;;
    esac
    rm -f "$f" 2>/dev/null || true
  done
}
reap_dead_runtime_files

echo "$$" >"$pid_file"
cleanup() {
  local recorded_pid

  recorded_pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [ "$recorded_pid" = "$$" ]; then
    rm -f "$pid_file"
  fi
}
trap cleanup EXIT
trap 'exit 0' INT TERM

while tmux list-sessions >/dev/null 2>&1; do
  enabled="$(tmux_option "@ai-session-name-enabled" "on")"
  [ "$enabled" = "on" ] || break
  "$rename_script" >/dev/null 2>&1 || true

  interval="$(tmux_option "@ai-session-name-interval" "5")"
  case "$interval" in
    ''|*[!0-9]*) interval=5 ;;
  esac
  [ "$interval" -lt 1 ] && interval=1
  sleep "$interval"
done

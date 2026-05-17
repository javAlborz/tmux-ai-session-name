#!/usr/bin/env bash
set -u

plugin_dir="${AI_SESSION_NAME_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
detect_script="$plugin_dir/scripts/session-name-for-pane.sh"

# Shared per-pass state: cache file and a single process-table snapshot
# so per-pane subscripts don't each re-fork `ps -eo`.
state_dir="${TMPDIR:-/tmp}"
server_pid="$(tmux display-message -p '#{pid}' 2>/dev/null || echo standalone)"

if [ -z "${AI_SESSION_NAME_CACHE_FILE:-}" ]; then
  AI_SESSION_NAME_CACHE_FILE="$state_dir/tmux-ai-session-name.${server_pid}.cache"
fi
export AI_SESSION_NAME_CACHE_FILE

process_table_file="$state_dir/tmux-ai-session-name.${server_pid}.$$.proc"
ps -eo pid=,ppid=,comm=,args= >"$process_table_file" 2>/dev/null || true
trap 'rm -f "$process_table_file"' EXIT INT TERM
export AI_SESSION_NAME_PROCESS_TABLE_FILE="$process_table_file"

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

sanitize_name() {
  local name="$1"
  local max_length="$2"

  name="${name//$'\r'/ }"
  name="${name//$'\n'/ }"
  name="$(printf '%s' "$name" | sed -E 's/^[[:space:]]*✳[[:space:]]*//; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
  if [ "${#name}" -gt "$max_length" ]; then
    name="${name:0:max_length}"
    name="${name%"${name##*[![:space:]]}"}"
  fi
  printf '%s\n' "$name"
}

max_length="$(tmux_option "@ai-session-name-max-length" "60")"
case "$max_length" in
  ''|*[!0-9]*) max_length=60 ;;
esac

format="$(tmux_option "@ai-session-name-format" "#{tool}: #{session}")"
restore="$(tmux_option "@ai-session-name-restore" "off")"
fallback="$(tmux_option "@ai-session-name-fallback" "")"
restore_unnamed="$(tmux_option "@ai-session-name-restore-unnamed" "on")"
release_unnamed_after="$(tmux_option "@ai-session-name-release-unnamed-after" "60")"
case "$release_unnamed_after" in
  ''|*[!0-9]*) release_unnamed_after=60 ;;
esac
owned_option="@ai-session-name-owned"
previous_name_option="@ai-session-name-previous-name"
current_name_option="@ai-session-name-current-name"
unresolved_since_option="@ai-session-name-unresolved-since"

window_option() {
  local target="$1"
  local option="$2"

  tmux show-option -w -t "$target" -qv "$option" 2>/dev/null ||
    tmux show-window-option -t "$target" -v "$option" 2>/dev/null ||
    true
}

restore_plugin_owned_window() {
  local target="$1"
  local pane_path="$2"
  local current_name="$3"
  local owned
  local previous_name
  local new_name

  owned="$(window_option "$target" "$owned_option")"
  [ "$owned" = "1" ] || return 0

  previous_name="$(window_option "$target" "$previous_name_option")"
  if [ -n "$previous_name" ]; then
    new_name="$previous_name"
  else
    new_name="$(basename "$pane_path" 2>/dev/null || true)"
  fi
  new_name="$(sanitize_name "$new_name" "$max_length")"

  tmux set-window-option -t "$target" -u "$owned_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$previous_name_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$current_name_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$unresolved_since_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" allow-rename on >/dev/null 2>&1 || true

  if [ -n "$new_name" ] && [ "$new_name" != "$current_name" ]; then
    tmux rename-window -t "$target" "$new_name"
  fi
}

release_unresolved_plugin_owned_window() {
  local target="$1"
  local pane_path="$2"
  local current_name="$3"
  local owned
  local previous_name
  local plugin_name
  local unresolved_since
  local now
  local new_name

  owned="$(window_option "$target" "$owned_option")"
  [ "$owned" = "1" ] || return 0
  [ "$release_unnamed_after" -gt 0 ] || return 0

  now="$(date +%s)"
  unresolved_since="$(window_option "$target" "$unresolved_since_option")"
  case "$unresolved_since" in
    ''|*[!0-9]*)
      tmux set-window-option -t "$target" "$unresolved_since_option" "$now" >/dev/null 2>&1 || true
      return 0
      ;;
  esac

  [ $((now - unresolved_since)) -ge "$release_unnamed_after" ] || return 0

  previous_name="$(window_option "$target" "$previous_name_option")"
  plugin_name="$(window_option "$target" "$current_name_option")"
  if [ -n "$previous_name" ]; then
    new_name="$previous_name"
  else
    new_name="$(basename "$pane_path" 2>/dev/null || true)"
  fi
  new_name="$(sanitize_name "$new_name" "$max_length")"

  tmux set-window-option -t "$target" -u "$owned_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$previous_name_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$current_name_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$unresolved_since_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" allow-rename on >/dev/null 2>&1 || true

  if [ -n "$new_name" ] && [ "$new_name" != "$current_name" ]; then
    if [ -z "$plugin_name" ] || [ "$current_name" = "$plugin_name" ]; then
      tmux rename-window -t "$target" "$new_name"
    fi
  fi
}

seen_ai_window_names=""
tmux list-panes -a -F '#{session_id}	#{window_id}	#{pane_id}	#{pane_active}	#{pane_pid}	#{pane_current_path}	#{pane_title}	#{window_name}' |
while IFS=$'\t' read -r _session_id window_id pane_id pane_active pane_pid pane_cwd pane_title window_name; do
  [ "$pane_active" = "1" ] || continue

  result="$("$detect_script" "$pane_pid" "$pane_cwd" "$pane_title" 2>/dev/null || true)"
  if [ -z "$result" ]; then
    tool_only="$(AI_SESSION_NAME_REPORT_TOOL_ONLY=1 "$detect_script" "$pane_pid" "$pane_cwd" "$pane_title" 2>/dev/null || true)"
    if [ -n "$tool_only" ]; then
      owned="$(window_option "$window_id" "$owned_option")"
      if [ "$restore_unnamed" = "on" ] && [ "$owned" != "1" ]; then
        new_name="$(basename "$pane_cwd" 2>/dev/null || true)"
        [ -n "$new_name" ] || new_name="$(tmux display-message -pt "$pane_id" -p '#{pane_current_command}' 2>/dev/null || true)"
        new_name="$(sanitize_name "$new_name" "$max_length")"
        if [ -n "$new_name" ] && [ "$new_name" != "$window_name" ]; then
          tmux set-window-option -t "$window_id" allow-rename on >/dev/null 2>&1 || true
          tmux rename-window -t "$window_id" "$new_name"
        fi
        continue
      fi
      release_unresolved_plugin_owned_window "$window_id" "$pane_cwd" "$window_name"
      continue
    fi

    restore_plugin_owned_window "$window_id" "$pane_cwd" "$window_name"

    generic_window_name="$(printf '%s' "$window_name" | sed -E 's/^[[:space:]]*✳[[:space:]]*//; s/[[:space:]]+/ /g; s/^ //; s/ $//' | tr '[:upper:]' '[:lower:]')"
    case "$generic_window_name" in
      codex|claude|"claude code")
        new_name="$(basename "$pane_cwd" 2>/dev/null || true)"
        [ -n "$new_name" ] || new_name="$(tmux display-message -pt "$pane_id" -p '#{pane_current_command}' 2>/dev/null || true)"
        new_name="$(sanitize_name "$new_name" "$max_length")"
        if [ -n "$new_name" ]; then
          tmux set-window-option -t "$window_id" allow-rename on >/dev/null 2>&1 || true
          tmux rename-window -t "$window_id" "$new_name"
        fi
        continue
        ;;
    esac

    if [ "$restore" = "on" ] && printf '%s' "$window_name" | grep -Eq '^(claude|codex): '; then
      if [ -n "$fallback" ]; then
        new_name="$fallback"
      else
        new_name="$(tmux display-message -pt "$pane_id" -p '#{pane_current_command}' 2>/dev/null || true)"
      fi
      new_name="$(sanitize_name "$new_name" "$max_length")"
      if [ -n "$new_name" ]; then
        tmux set-window-option -t "$window_id" allow-rename on >/dev/null 2>&1 || true
        tmux rename-window -t "$window_id" "$new_name"
      fi
    fi
    continue
  fi

  tool="${result%%	*}"
  session="${result#*	}"
  [ -n "$tool" ] || continue
  [ -n "$session" ] || session="$tool"

  new_name="${format//\#\{tool\}/$tool}"
  new_name="${new_name//\#\{session\}/$session}"
  new_name="$(sanitize_name "$new_name" "$max_length")"

  case "$seen_ai_window_names" in
    *"
$new_name
"*)
      release_unresolved_plugin_owned_window "$window_id" "$pane_cwd" "$window_name"
      continue
      ;;
  esac
  seen_ai_window_names="${seen_ai_window_names}
$new_name
"

  if [ -n "$new_name" ] && [ "$new_name" != "$window_name" ]; then
    owned="$(window_option "$window_id" "$owned_option")"
    if [ "$owned" != "1" ]; then
      tmux set-window-option -t "$window_id" "$previous_name_option" "$window_name" >/dev/null 2>&1 || true
    fi
    tmux set-window-option -t "$window_id" "$owned_option" "1" >/dev/null 2>&1 || true
    tmux set-window-option -t "$window_id" "$current_name_option" "$new_name" >/dev/null 2>&1 || true
    tmux set-window-option -t "$window_id" -u "$unresolved_since_option" >/dev/null 2>&1 || true
    tmux set-window-option -t "$window_id" allow-rename off >/dev/null 2>&1 || true
    tmux rename-window -t "$window_id" "$new_name"
  fi
done

#!/usr/bin/env bash
set -u

plugin_dir="${AI_SESSION_NAME_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
detect_script="$plugin_dir/scripts/session-name-for-pane.sh"

# Shared per-pass state: cache file and a single process-table snapshot
# so per-pane subscripts don't each re-fork `ps -eo`.
state_dir="${TMPDIR:-/tmp}"
server_pid="$(tmux display-message -p '#{pid}' 2>/dev/null || echo standalone)"

lock_dir="${AI_SESSION_NAME_LOCK_DIR:-/tmp}"
lock_file="$lock_dir/tmux-ai-session-name.${server_pid}.rename.lock"
exec 8>"$lock_file"
if command -v flock >/dev/null 2>&1; then
  flock -n 8 || exit 0
fi

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
restore_unnamed="$(tmux_option "@ai-session-name-restore-unnamed" "off")"
release_unnamed_after="$(tmux_option "@ai-session-name-release-unnamed-after" "10")"
case "$release_unnamed_after" in
  ''|*[!0-9]*) release_unnamed_after=0 ;;
esac
debounce_ticks="$(tmux_option "@ai-session-name-debounce-ticks" "2")"
case "$debounce_ticks" in
  ''|*[!0-9]*) debounce_ticks=2 ;;
esac
owned_option="@ai-session-name-owned"
previous_name_option="@ai-session-name-previous-name"
previous_auto_option="@ai-session-name-previous-auto"
current_name_option="@ai-session-name-current-name"
thread_id_option="@ai-session-name-thread-id"
unresolved_since_option="@ai-session-name-unresolved-since"
pending_name_option="@ai-session-name-pending-name"
pending_thread_id_option="@ai-session-name-pending-thread-id"
pending_count_option="@ai-session-name-pending-count"
manual_identity_option="@ai-session-name-manual-identity"

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
  local previous_auto
  local plugin_name
  local new_name

  owned="$(window_option "$target" "$owned_option")"
  [ "$owned" = "1" ] || return 0

  previous_name="$(window_option "$target" "$previous_name_option")"
  previous_auto="$(window_option "$target" "$previous_auto_option")"
  plugin_name="$(window_option "$target" "$current_name_option")"
  if [ -n "$previous_name" ]; then
    new_name="$previous_name"
  else
    new_name="$(basename "$pane_path" 2>/dev/null || true)"
  fi
  new_name="$(sanitize_name "$new_name" "$max_length")"

  tmux set-window-option -t "$target" -u "$owned_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$previous_name_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$previous_auto_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$current_name_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$thread_id_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$unresolved_since_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$pending_name_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$pending_thread_id_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$pending_count_option" >/dev/null 2>&1 || true

  # A manual rename made while the plugin owned the window wins. Do not turn
  # automatic naming back on underneath that explicit choice.
  if [ -n "$plugin_name" ] && [ "$current_name" != "$plugin_name" ]; then
    tmux set-window-option -t "$target" automatic-rename off >/dev/null 2>&1 || true
    return 0
  fi

  if [ -n "$new_name" ] && [ "$new_name" != "$current_name" ]; then
    tmux rename-window -t "$target" "$new_name"
  fi
  case "$previous_auto" in
    1|on)
      tmux set-window-option -t "$target" automatic-rename on >/dev/null 2>&1 || true
      ;;
    0|off)
      tmux set-window-option -t "$target" automatic-rename off >/dev/null 2>&1 || true
      ;;
    *)
      # Migration for windows claimed by older plugin versions, which saved
      # only the previous name. Directory-basename names were automatic.
      if [ -n "$previous_name" ] && [ "$previous_name" = "$(basename "$pane_path" 2>/dev/null || true)" ]; then
        tmux set-window-option -t "$target" automatic-rename on >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

identity_owned_by_other_window() {
  local target="$1"
  local identity="$2"
  [ -n "$identity" ] || return 1
  tmux list-windows -a -F "#{window_id} #{@ai-session-name-thread-id}" 2>/dev/null |
    grep -Fv "$target " | grep -Fq " $identity"
}

clear_pending_candidate() {
  local target="$1"

  tmux set-window-option -t "$target" -u "$pending_name_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$pending_thread_id_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$pending_count_option" >/dev/null 2>&1 || true
}

release_for_manual_override() {
  local target="$1"
  local detection_identity="$2"

  tmux set-window-option -t "$target" -u "$owned_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$previous_name_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$previous_auto_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$current_name_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$thread_id_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$unresolved_since_option" >/dev/null 2>&1 || true
  clear_pending_candidate "$target"
  tmux set-window-option -t "$target" automatic-rename off >/dev/null 2>&1 || true
  if [ -n "$detection_identity" ]; then
    tmux set-window-option -t "$target" "$manual_identity_option" "$detection_identity" >/dev/null 2>&1 || true
  fi
}

weak_candidate_ready() {
  local target="$1"
  local identity="$2"
  local name="$3"
  local confidence="$4"
  local owned
  local current_name
  local current_identity
  local pending_name
  local pending_identity
  local pending_count

  if [ "$confidence" != "weak" ] || [ "$debounce_ticks" -le 1 ]; then
    clear_pending_candidate "$target"
    return 0
  fi

  owned="$(window_option "$target" "$owned_option")"
  current_name="$(window_option "$target" "$current_name_option")"
  current_identity="$(window_option "$target" "$thread_id_option")"
  if [ "$owned" = "1" ] && [ "$current_name" = "$name" ] && { [ -z "$identity" ] || [ "$current_identity" = "$identity" ]; }; then
    clear_pending_candidate "$target"
    return 0
  fi

  pending_name="$(window_option "$target" "$pending_name_option")"
  pending_identity="$(window_option "$target" "$pending_thread_id_option")"
  pending_count="$(window_option "$target" "$pending_count_option")"
  case "$pending_count" in
    ''|*[!0-9]*) pending_count=0 ;;
  esac

  if [ "$pending_name" = "$name" ] && [ "$pending_identity" = "$identity" ]; then
    pending_count=$((pending_count + 1))
  else
    pending_count=1
  fi

  tmux set-window-option -t "$target" "$pending_name_option" "$name" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" "$pending_thread_id_option" "$identity" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" "$pending_count_option" "$pending_count" >/dev/null 2>&1 || true

  [ "$pending_count" -ge "$debounce_ticks" ]
}

release_unresolved_plugin_owned_window() {
  local target="$1"
  local pane_path="$2"
  local current_name="$3"
  local owned
  local previous_name
  local previous_auto
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
  previous_auto="$(window_option "$target" "$previous_auto_option")"
  plugin_name="$(window_option "$target" "$current_name_option")"
  if [ -n "$previous_name" ]; then
    new_name="$previous_name"
  else
    new_name="$(basename "$pane_path" 2>/dev/null || true)"
  fi
  new_name="$(sanitize_name "$new_name" "$max_length")"

  tmux set-window-option -t "$target" -u "$owned_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$previous_name_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$previous_auto_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$current_name_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$thread_id_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$unresolved_since_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$pending_name_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$pending_thread_id_option" >/dev/null 2>&1 || true
  tmux set-window-option -t "$target" -u "$pending_count_option" >/dev/null 2>&1 || true

  if [ -n "$new_name" ] && [ "$new_name" != "$current_name" ]; then
    if [ -z "$plugin_name" ] || [ "$current_name" = "$plugin_name" ]; then
      tmux rename-window -t "$target" "$new_name"
    fi
  fi
  if [ -n "$plugin_name" ] && [ "$current_name" != "$plugin_name" ]; then
    tmux set-window-option -t "$target" automatic-rename off >/dev/null 2>&1 || true
  else
    case "$previous_auto" in
      1|on) tmux set-window-option -t "$target" automatic-rename on >/dev/null 2>&1 || true ;;
      0|off) tmux set-window-option -t "$target" automatic-rename off >/dev/null 2>&1 || true ;;
      *)
        if [ -n "$previous_name" ] && [ "$previous_name" = "$(basename "$pane_path" 2>/dev/null || true)" ]; then
          tmux set-window-option -t "$target" automatic-rename on >/dev/null 2>&1 || true
        fi
        ;;
    esac
  fi
}

tmux list-panes -a -F '#{session_id}	#{window_id}	#{pane_id}	#{pane_active}	#{pane_pid}	#{pane_current_path}	#{pane_title}	#{window_name}' |
while IFS=$'\t' read -r _session_id window_id pane_id pane_active pane_pid pane_cwd pane_title window_name; do
  [ "$pane_active" = "1" ] || continue
  owned="$(window_option "$window_id" "$owned_option")"
  existing_identity="$(window_option "$window_id" "$thread_id_option")"
  if [ "$owned" = "1" ] && [ -n "$existing_identity" ] && identity_owned_by_other_window "$window_id" "$existing_identity"; then
    restore_plugin_owned_window "$window_id" "$pane_cwd" "$window_name"
    continue
  fi

  result="$(AI_SESSION_NAME_REPORT_ID=1 "$detect_script" "$pane_pid" "$pane_cwd" "$pane_title" 2>/dev/null || true)"
  if [ -z "$result" ]; then
    tmux set-window-option -t "$window_id" -u "$manual_identity_option" >/dev/null 2>&1 || true
    tool_only="$(AI_SESSION_NAME_REPORT_TOOL_ONLY=1 "$detect_script" "$pane_pid" "$pane_cwd" "$pane_title" 2>/dev/null || true)"
    if [ -n "$tool_only" ]; then
      owned="$(window_option "$window_id" "$owned_option")"
      if [ "$restore_unnamed" = "on" ] && [ "$owned" != "1" ]; then
        new_name="$(tmux display-message -pt "$pane_id" -p '#{pane_current_command}' 2>/dev/null || true)"
        new_name="$(sanitize_name "$new_name" "$max_length")"
        if [ -n "$new_name" ] && [ "$new_name" != "$window_name" ]; then
          tmux rename-window -t "$window_id" "$new_name"
        fi
        continue
      fi
      release_unresolved_plugin_owned_window "$window_id" "$pane_cwd" "$window_name"
      continue
    fi

    owned="$(window_option "$window_id" "$owned_option")"
    if [ "$owned" = "1" ]; then
      if [ "$restore" = "on" ]; then
        restore_plugin_owned_window "$window_id" "$pane_cwd" "$window_name"
      fi
      continue
    fi

    generic_window_name="$(printf '%s' "$window_name" | sed -E 's/^[[:space:]]*✳[[:space:]]*//; s/[[:space:]]+/ /g; s/^ //; s/ $//' | tr '[:upper:]' '[:lower:]')"
    case "$generic_window_name" in
      codex|claude|"claude code")
        new_name="$(tmux display-message -pt "$pane_id" -p '#{pane_current_command}' 2>/dev/null || true)"
        new_name="$(sanitize_name "$new_name" "$max_length")"
        if [ -n "$new_name" ]; then
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
        tmux rename-window -t "$window_id" "$new_name"
      fi
    fi
    continue
  fi

  tool="${result%%	*}"
  rest="${result#*	}"
  if [ "$rest" = "$result" ]; then
    identity=""
    session=""
    confidence=""
  else
    identity="${rest%%	*}"
    rest="${rest#*	}"
    session="${rest%%	*}"
    if [ "$session" = "$rest" ]; then
      confidence=""
    else
      confidence="${rest#*	}"
    fi
    if [ -z "$session" ]; then
      session=""
    fi
  fi
  [ -n "$tool" ] || continue
  [ -n "$session" ] || session="$tool"

  detection_identity="$identity"
  [ -n "$detection_identity" ] || detection_identity="${tool}:${session}"
  manual_identity="$(window_option "$window_id" "$manual_identity_option")"
  if [ -n "$manual_identity" ]; then
    if [ "$manual_identity" = "$detection_identity" ]; then
      continue
    fi
    tmux set-window-option -t "$window_id" -u "$manual_identity_option" >/dev/null 2>&1 || true
  fi

  new_name="${format//\#\{tool\}/$tool}"
  new_name="${new_name//\#\{session\}/$session}"
  new_name="$(sanitize_name "$new_name" "$max_length")"

  owned="$(window_option "$window_id" "$owned_option")"
  plugin_name="$(window_option "$window_id" "$current_name_option")"
  if [ "$owned" = "1" ] && [ -n "$plugin_name" ] && [ "$window_name" != "$plugin_name" ]; then
    release_for_manual_override "$window_id" "$detection_identity"
    continue
  fi

  if [ -n "$identity" ] && identity_owned_by_other_window "$window_id" "$identity"; then
    restore_plugin_owned_window "$window_id" "$pane_cwd" "$window_name"
    continue
  fi
  if ! weak_candidate_ready "$window_id" "$identity" "$new_name" "${confidence:-}"; then
    continue
  fi

  if [ -n "$new_name" ]; then
    owned="$(window_option "$window_id" "$owned_option")"
    if [ "$owned" != "1" ]; then
      tmux set-window-option -t "$window_id" "$previous_name_option" "$window_name" >/dev/null 2>&1 || true
      previous_auto="$(window_option "$window_id" "automatic-rename")"
      tmux set-window-option -t "$window_id" "$previous_auto_option" "$previous_auto" >/dev/null 2>&1 || true
    elif [ -n "$identity" ]; then
      previous_identity="$(window_option "$window_id" "$thread_id_option")"
      if [ -n "$previous_identity" ] && [ "$previous_identity" != "$identity" ]; then
        plugin_name="$(window_option "$window_id" "$current_name_option")"
        if [ -n "$plugin_name" ] && [ "$window_name" = "$plugin_name" ]; then
          :
        else
          tmux set-window-option -t "$window_id" "$previous_name_option" "$window_name" >/dev/null 2>&1 || true
          tmux set-window-option -t "$window_id" "$previous_auto_option" "off" >/dev/null 2>&1 || true
        fi
      fi
    fi
    tmux set-window-option -t "$window_id" "$owned_option" "1" >/dev/null 2>&1 || true
    tmux set-window-option -t "$window_id" -u "$manual_identity_option" >/dev/null 2>&1 || true
    tmux set-window-option -t "$window_id" "$current_name_option" "$new_name" >/dev/null 2>&1 || true
    if [ -n "$identity" ]; then
      tmux set-window-option -t "$window_id" "$thread_id_option" "$identity" >/dev/null 2>&1 || true
    else
      tmux set-window-option -t "$window_id" -u "$thread_id_option" >/dev/null 2>&1 || true
    fi
    tmux set-window-option -t "$window_id" -u "$unresolved_since_option" >/dev/null 2>&1 || true
    clear_pending_candidate "$window_id"
    tmux set-window-option -t "$window_id" automatic-rename off >/dev/null 2>&1 || true
    if [ "$new_name" != "$window_name" ]; then
      tmux rename-window -t "$window_id" "$new_name"
    fi
  fi
done

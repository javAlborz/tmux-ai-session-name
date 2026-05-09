#!/usr/bin/env bash
set -u

plugin_dir="${AI_SESSION_NAME_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
detect_script="$plugin_dir/scripts/session-name-for-pane.sh"

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

abbreviate_generated_name() {
  local name="$1"
  local words

  if ! printf '%s\n' "$name" | grep -Eq '[[:space:]]' && printf '%s\n' "$name" | grep -Eq '[-_/]'; then
    printf '%s\n' "$name"
    return
  fi

  words="$(printf '%s\n' "$name" | awk '{
    if (NF < 2) {
      print $0
      next
    }
    for (i = 1; i <= NF; i++) {
      word = $i
      gsub(/^[^[:alnum:]]+|[^[:alnum:]]+$/, "", word)
      if (word != "") {
        printf "%s", tolower(substr(word, 1, 1))
      }
    }
    printf "\n"
  }')"

  if printf '%s\n' "$name" | grep -Eq '[[:space:]]'; then
    words="${words:0:5}"
  fi

  if [ -n "$words" ]; then
    printf '%s\n' "$words"
  else
    printf '%s\n' "$name"
  fi
}

max_length="$(tmux_option "@ai-session-name-max-length" "60")"
case "$max_length" in
  ''|*[!0-9]*) max_length=60 ;;
esac

format="$(tmux_option "@ai-session-name-format" "#{tool}: #{session}")"
restore="$(tmux_option "@ai-session-name-restore" "off")"
fallback="$(tmux_option "@ai-session-name-fallback" "")"

tmux list-panes -a -F '#{session_id}	#{window_id}	#{pane_id}	#{pane_active}	#{pane_pid}	#{pane_current_path}	#{pane_title}	#{window_name}' |
while IFS=$'\t' read -r _session_id window_id pane_id pane_active pane_pid pane_cwd pane_title window_name; do
  [ "$pane_active" = "1" ] || continue

  result="$("$detect_script" "$pane_pid" "$pane_cwd" "$pane_title" 2>/dev/null || true)"
  if [ -z "$result" ]; then
    generic_window_name="$(printf '%s' "$window_name" | sed -E 's/^[[:space:]]*✳[[:space:]]*//; s/[[:space:]]+/ /g; s/^ //; s/ $//' | tr '[:upper:]' '[:lower:]')"
    case "$generic_window_name" in
      codex|claude|"claude code")
        new_name="$(basename "$pane_cwd" 2>/dev/null || true)"
        [ -n "$new_name" ] || new_name="$(tmux display-message -pt "$pane_id" -p '#{pane_current_command}' 2>/dev/null || true)"
        new_name="$(sanitize_name "$new_name" "$max_length")"
        [ -n "$new_name" ] && tmux rename-window -t "$window_id" "$new_name"
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
      [ -n "$new_name" ] && tmux rename-window -t "$window_id" "$new_name"
    fi
    continue
  fi

  tool="${result%%	*}"
  session="${result#*	}"
  [ -n "$tool" ] || continue
  [ -n "$session" ] || session="$tool"

  new_name="${format//\#\{tool\}/$tool}"
  new_name="${new_name//\#\{session\}/$session}"
  new_name="$(abbreviate_generated_name "$new_name")"
  new_name="$(sanitize_name "$new_name" "$max_length")"

  if [ -n "$new_name" ] && [ "$new_name" != "$window_name" ]; then
    tmux rename-window -t "$window_id" "$new_name"
  fi
done

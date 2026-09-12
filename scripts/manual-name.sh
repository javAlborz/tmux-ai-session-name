#!/usr/bin/env bash
set -u

window="${1:-}"
[[ "$window" =~ ^@[0-9]+$ ]] || exit 0
[ "$(tmux show-option -wqv -t "$window" @ai-session-name-internal-rename)" != 1 ] || exit 0
name="$(tmux display-message -pt "$window" '#{window_name}')" || exit 0
previous="$(tmux show-option -wqv -t "$window" @ai-session-name-manual-name)"
[ "$name" != "$previous" ] || exit 0
tmux set-window-option -t "$window" @ai-session-name-manual-name "$name" || exit 0
[ "$(tmux show-option -gqv @ai-session-name-diagnostics)" != off ] || exit 0
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$script_dir/name-audit.py" \
  "$(tmux display-message -p '#{pid}')" "$window" \
  "$(tmux display-message -pt "$window" '#{pane_id}')" \
  manual-name "$previous" "$name" >/dev/null 2>&1 || true

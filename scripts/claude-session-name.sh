#!/usr/bin/env bash
set -u

_pane_pid="${1:-}"
_pane_cwd="${2:-}"
pane_title="${3:-}"
rows="${4:-}"

clean_title() {
  local title="$1"

  title="$(printf '%s' "$title" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  title="$(printf '%s' "$title" | sed -E 's/^(claude|Claude Code|Claude)[[:space:]:-]+//')"
  printf '%s\n' "$title"
}

title="$(clean_title "$pane_title")"
if [ -n "$title" ] && [ "$title" != "bash" ] && [ "$title" != "zsh" ] && [ "$title" != "fish" ]; then
  printf '%s\n' "$title"
  exit 0
fi

name_from_args="$(printf '%s\n' "$rows" | sed -nE 's/.*(^|[[:space:]])(-n|--name)(=|[[:space:]])"?([^"[:space:]]([^"]*[^"[:space:]])?)"?.*/\4/p' | head -1)"
if [ -n "$name_from_args" ]; then
  printf '%s\n' "$name_from_args"
  exit 0
fi

printf '%s\n' "claude"


#!/usr/bin/env bash
set -u

pane_pid="${1:-}"
pane_cwd="${2:-}"
pane_title="${3:-}"
rows="${4:-}"
claude_home="${CLAUDE_HOME:-$HOME/.claude}"

clean_title() {
  local title="$1"

  title="$(printf '%s' "$title" | sed -E 's/^[[:space:]]*✳[[:space:]]*//; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
  title="$(printf '%s' "$title" | sed -E 's/^(claude|Claude Code|Claude)[[:space:]:-]+//')"
  printf '%s\n' "$title"
}

name_from_args="$(printf '%s\n' "$rows" | sed -nE 's/.*(^|[[:space:]])(-n|--name)(=|[[:space:]])"?([^"[:space:]]([^"]*[^"[:space:]])?)"?.*/\4/p' | head -1)"
if [ -n "$name_from_args" ]; then
  printf '%s\n' "$name_from_args"
  exit 0
fi

project_dir_for_cwd() {
  local cwd="$1"
  local encoded

  [ -n "$cwd" ] || return 1
  encoded="$(printf '%s' "$cwd" | sed 's#/#-#g')"
  printf '%s/projects/%s\n' "$claude_home" "$encoded"
}

claude_process_start_ms() {
  local pid
  local start_ticks
  local boot_time
  local hz

  command -v getconf >/dev/null 2>&1 || return 1
  hz="$(getconf CLK_TCK 2>/dev/null || true)"
  [ -n "$hz" ] || return 1

  boot_time="$(awk '$1 == "btime" { print $2 }' /proc/stat 2>/dev/null)"
  [ -n "$boot_time" ] || return 1

  printf '%s\n' "$rows" | awk '$3 == "claude" { print $1 }' |
  while read -r pid; do
    [ -r "/proc/$pid/stat" ] || continue
    start_ticks="$(awk '{ print $22 }' "/proc/$pid/stat" 2>/dev/null)"
    [ -n "$start_ticks" ] || continue
    printf '%s\n' $(( (boot_time * 1000) + (start_ticks * 1000 / hz) ))
  done |
    sort -n |
    head -1
}

pane_title_has_rename_record() {
  local title="$1"
  local start_ms="$2"
  local project_dir
  local escaped_title
  local newest_files
  local lower_sec
  local upper_sec
  local line
  local timestamp
  local timestamp_sec
  local matches

  [ -n "$title" ] || return 1
  [ -n "$start_ms" ] || return 1
  command -v date >/dev/null 2>&1 || return 1
  project_dir="$(project_dir_for_cwd "$pane_cwd")"
  [ -d "$project_dir" ] || return 1
  lower_sec=$((start_ms / 1000 - 60))
  upper_sec=$(($(date -u +%s) + 300))

  newest_files="$(find "$project_dir" -maxdepth 1 -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null |
    awk -v low="$lower_sec" '$1 >= low { print }' |
    sort -rn |
    head -10 |
    cut -d' ' -f2-)"
  [ -n "$newest_files" ] || return 1

  escaped_title="$(printf '%s\n' "$title" | sed 's/[.[\*^$()+?{|\\]/\\&/g')"
  while read -r file; do
    [ -r "$file" ] || continue
    matches="$(grep -Eh "<local-command-stdout>Session renamed to: ${escaped_title}</local-command-stdout>" "$file" 2>/dev/null || true)"
    [ -n "$matches" ] || continue

    while IFS= read -r line; do
      timestamp="$(printf '%s\n' "$line" | sed -nE 's/.*"timestamp":"([^"]+)".*/\1/p')"
      [ -n "$timestamp" ] || continue
      timestamp_sec="$(date -u -d "$timestamp" +%s 2>/dev/null || true)"
      [ -n "$timestamp_sec" ] || continue
      [ "$timestamp_sec" -ge "$lower_sec" ] || continue
      [ "$timestamp_sec" -le "$upper_sec" ] || continue

      printf '%s\n' "$title"
      return 0
    done <<EOF_MATCHES
$matches
EOF_MATCHES
  done <<EOF
$newest_files
EOF

  return 1
}

start_ms="$(claude_process_start_ms || true)"
title="$(clean_title "$pane_title")"
case "$title" in
  ""|bash|zsh|fish|claude|"Claude Code")
    ;;
  *)
    if [ -n "$start_ms" ]; then
      title="$(pane_title_has_rename_record "$title" "$start_ms" || true)"
      if [ -n "$title" ]; then
        printf '%s\n' "$title"
        exit 0
      fi
    fi
    ;;
esac

exit 1

#!/usr/bin/env bash
set -u

pane_pid="${1:-}"
pane_cwd="${2:-}"
_pane_title="${3:-}"
rows="${4:-}"
claude_home="${CLAUDE_HOME:-$HOME/.claude}"

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

renamed_title_from_recent_session() {
  local start_ms="$1"
  local project_dir
  local lower_sec
  local upper_sec
  local title

  command -v find >/dev/null 2>&1 || return 1
  project_dir="$(project_dir_for_cwd "$pane_cwd")"
  [ -d "$project_dir" ] || return 1
  [ -n "$start_ms" ] || return 1

  lower_sec=$((start_ms / 1000 - 60))
  upper_sec=$((start_ms / 1000 + 300))

  find "$project_dir" -maxdepth 1 -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null |
    awk -v low="$lower_sec" -v high="$upper_sec" '$1 >= low && $1 <= high { $1=""; sub(/^ /, ""); print }' |
    sort |
    while read -r file; do
      [ -r "$file" ] || continue
      title="$(sed -nE 's/.*<local-command-stdout>Session renamed to: ([^<]+)<\/local-command-stdout>.*/\1/p' "$file" | tail -1)"
      if [ -n "$title" ]; then
        printf '%s\n' "$title"
        break
      fi
    done
}

start_ms="$(claude_process_start_ms || true)"
if [ -n "$start_ms" ]; then
  title="$(renamed_title_from_recent_session "$start_ms" || true)"
  if [ -n "$title" ]; then
    printf '%s\n' "$title"
    exit 0
  fi
fi

exit 1

#!/usr/bin/env bash
set -u

pane_pid="${1:-}"
pane_cwd="${2:-}"
pane_title="${3:-}"
rows="${4:-}"
claude_home="${CLAUDE_HOME:-$HOME/.claude}"

# Upper bound on transcripts scanned per lookup, newest first. A busy project
# directory accumulates them (one per session), so this has to sit well above
# the number of sessions that realistically share one working directory.
max_transcripts="${AI_SESSION_NAME_MAX_TRANSCRIPTS:-50}"
case "$max_transcripts" in
  ''|*[!0-9]*|0) max_transcripts=50 ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$script_dir/cache-lib.sh" ]; then
  # shellcheck disable=SC1091
  . "$script_dir/cache-lib.sh"
fi

clean_title() {
  local title="$1"

  title="$(printf '%s' "$title" | sed -E 's/^[[:space:]]*[^[:alnum:][:space:]]+[[:space:]]+//; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
  title="$(printf '%s' "$title" | sed -E 's/^(claude|Claude Code|Claude)[[:space:]:-]+//')"
  printf '%s\n' "$title"
}

name_from_args="$(printf '%s\n' "$rows" | awk '$3 == "claude"' | sed -nE 's/.*(^|[[:space:]])(-n|--name)(=|[[:space:]])"?([^"[:space:]]([^"]*[^"[:space:]])?)"?.*/\4/p' | head -1)"
if [ -n "$name_from_args" ]; then
  printf '%s\n' "$name_from_args"
  exit 0
fi

project_dir_for_cwd() {
  local cwd="$1"
  local encoded

  [ -n "$cwd" ] || return 1
  encoded="$(printf '%s' "$cwd" | sed 's#[^A-Za-z0-9]#-#g')"
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
  local project_dir
  local candidate_files
  local needle
  local match

  [ -n "$title" ] || return 1
  project_dir="$(project_dir_for_cwd "$pane_cwd")"
  [ -d "$project_dir" ] || return 1

  # Newest transcripts first, so a live session matches on the first file read.
  # The whole project directory is in scope and no lower time bound applies: a
  # session named in an earlier run (--resume, --continue, a restored tmux
  # server) keeps its rename record at the timestamp of that earlier run, in a
  # transcript that busier neighbours can push well down the mtime order. Both
  # bounds silently discarded those names even though the pane title was right.
  candidate_files="$(find "$project_dir" -maxdepth 1 -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn |
    head -n "$max_transcripts" |
    cut -d' ' -f2-)"
  [ -n "$candidate_files" ] || return 1

  # The record is a fixed string, so match it literally: -l stops reading each
  # file at its first hit and head closes the pipe once any file matches.
  needle="<local-command-stdout>Session renamed to: ${title}</local-command-stdout>"
  match="$(printf '%s\n' "$candidate_files" |
    tr '\n' '\0' |
    xargs -0 -r grep -lF -e "$needle" 2>/dev/null |
    head -n 1)"
  [ -n "$match" ] || return 1

  printf '%s\n' "$title"
}

start_ms="$(claude_process_start_ms || true)"
title="$(clean_title "$pane_title")"
case "$title" in
  ""|bash|zsh|fish|claude|"Claude Code")
    ;;
  *)
    # start_ms only scopes the cache entry to this process incarnation; it is no
    # longer a precondition for resolving a name.
    cache_key="claude|${pane_pid}|${start_ms}|${title}"
    if command -v cache_lookup >/dev/null 2>&1; then
      cached_value="$(cache_lookup "$cache_key" 30)"
      cache_rc=$?
      if [ "$cache_rc" -eq 0 ]; then
        printf '%s\n' "$cached_value"
        exit 0
      elif [ "$cache_rc" -eq 2 ]; then
        exit 1
      fi
    fi

    verified="$(pane_title_has_rename_record "$title" || true)"
    if command -v cache_store >/dev/null 2>&1; then
      cache_store "$cache_key" "$verified"
    fi
    if [ -n "$verified" ]; then
      printf '%s\n' "$verified"
      exit 0
    fi
    ;;
esac

exit 1

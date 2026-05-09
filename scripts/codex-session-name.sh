#!/usr/bin/env bash
set -u

pane_pid="${1:-}"
pane_cwd="${2:-}"
pane_title="${3:-}"
rows="${4:-}"

codex_home="${CODEX_HOME:-$HOME/.codex}"

clean_title() {
  local title="$1"

  title="$(printf '%s' "$title" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  title="$(printf '%s' "$title" | sed -E 's/^(codex|Codex)[[:space:]:-]+//')"
  printf '%s\n' "$title"
}

has_codex_title_prefix() {
  local title="$1"

  printf '%s\n' "$title" | grep -Eq '^(codex|Codex)[[:space:]:-]+'
}

thread_id_from_env() {
  local pid
  local environ

  printf '%s\n' "$rows" | awk '{print $1}' |
  while read -r pid; do
    [ -r "/proc/$pid/environ" ] || continue
    environ="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null || true)"
    printf '%s\n' "$environ" | sed -nE 's/^CODEX_THREAD_ID=(.+)$/\1/p' | head -1
  done | head -1
}

thread_id_from_shell_snapshot_args() {
  printf '%s\n' "$rows" |
    sed -nE 's#.*\.codex/shell_snapshots/([0-9a-fA-F-]{36})\.[^[:space:]]*\.sh.*#\1#p' |
    head -1
}

codex_process_start_ms() {
  local pid
  local comm
  local start_ticks
  local boot_time
  local hz
  local start_ms

  command -v getconf >/dev/null 2>&1 || return 1
  hz="$(getconf CLK_TCK 2>/dev/null || true)"
  [ -n "$hz" ] || return 1

  boot_time="$(awk '$1 == "btime" { print $2 }' /proc/stat 2>/dev/null)"
  [ -n "$boot_time" ] || return 1

  printf '%s\n' "$rows" |
  while read -r pid _ppid comm _args; do
    case "$comm" in
      codex|MainThread|node) ;;
      *) continue ;;
    esac
    [ -r "/proc/$pid/stat" ] || continue
    start_ticks="$(awk '{ print $22 }' "/proc/$pid/stat" 2>/dev/null)"
    [ -n "$start_ticks" ] || continue
    start_ms=$(( (boot_time * 1000) + (start_ticks * 1000 / hz) ))
    printf '%s\n' "$start_ms"
  done |
    sort -n |
    head -1
}

sqlite_title_for_thread() {
  local thread_id="$1"
  local db="$codex_home/state_5.sqlite"

  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -r "$db" ] || return 1

  sqlite3 "$db" "select nullif(title,'') from threads where id = '$thread_id' limit 1;" 2>/dev/null |
    head -1
}

sqlite_title_for_process_start() {
  local start_ms="$1"
  local db="$codex_home/state_5.sqlite"
  local escaped_cwd
  local lower_bound
  local upper_bound

  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -r "$db" ] || return 1
  [ -n "$pane_cwd" ] || return 1
  [ -n "$start_ms" ] || return 1

  escaped_cwd="${pane_cwd//\'/\'\'}"
  lower_bound=$((start_ms - 60000))
  upper_bound=$((start_ms + 300000))

  sqlite3 "$db" "select nullif(title,'') from threads where archived = 0 and cwd = '$escaped_cwd' and title != '' and ((created_at_ms between $lower_bound and $upper_bound) or (updated_at_ms between $lower_bound and $upper_bound)) order by case when created_at_ms between $lower_bound and $upper_bound then abs(created_at_ms - $start_ms) else abs(updated_at_ms - $start_ms) + 60000 end asc limit 1;" 2>/dev/null |
    head -1
}

title="$(clean_title "$pane_title")"
if has_codex_title_prefix "$pane_title" && [ -n "$title" ]; then
  printf '%s\n' "$title"
  exit 0
fi

thread_id="$(thread_id_from_env || true)"
[ -n "$thread_id" ] || thread_id="$(thread_id_from_shell_snapshot_args || true)"
if [ -n "$thread_id" ]; then
  title="$(sqlite_title_for_thread "$thread_id" || true)"
  if [ -n "$title" ]; then
    printf '%s\n' "$title"
    exit 0
  fi
fi

start_ms="$(codex_process_start_ms || true)"
if [ -n "$start_ms" ]; then
  title="$(sqlite_title_for_process_start "$start_ms" || true)"
  if [ -n "$title" ]; then
    printf '%s\n' "$title"
    exit 0
  fi
fi

exit 1

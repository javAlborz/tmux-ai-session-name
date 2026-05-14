#!/usr/bin/env bash
set -u

pane_pid="${1:-}"
pane_cwd="${2:-}"
_pane_title="${3:-}"
rows="${4:-}"

codex_home="${CODEX_HOME:-$HOME/.codex}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$script_dir/cache-lib.sh" ]; then
  # shellcheck disable=SC1091
  . "$script_dir/cache-lib.sh"
fi

state_db_mtime="$(stat -c %Y "$codex_home/state_5.sqlite" 2>/dev/null || printf '0\n')"
logs_db_mtime="$(stat -c %Y "$codex_home/logs_2.sqlite" 2>/dev/null || printf '0\n')"
cache_key="codex|${pane_pid}|${state_db_mtime}|${logs_db_mtime}"

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

thread_id_from_resume_args() {
  printf '%s\n' "$rows" |
    sed -nE 's#.*(^|[[:space:]/.-])codex([[:space:]/.-]|.*[[:space:]])resume[[:space:]]+([0-9a-fA-F-]{36})([[:space:]].*)?$#\3#p' |
    head -1
}

thread_id_from_process_logs() {
  local db="$codex_home/logs_2.sqlite"
  local pid
  local thread_id

  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -r "$db" ] || return 1

  printf '%s\n' "$rows" |
  grep -Ei '(^|[ /.-])codex([ /.-]|$)|@openai/codex' |
  awk '{print $1}' |
  while read -r pid; do
    [ -n "$pid" ] || continue
    thread_id="$(sqlite3 "$db" "select thread_id from (select thread_id, max(ts) as last_ts, max(ts_nanos) as last_ts_nanos from logs where process_uuid like 'pid:$pid:%' and thread_id is not null and thread_id != '' group by thread_id order by last_ts desc, last_ts_nanos desc limit 5);" 2>/dev/null)"
    [ -n "$thread_id" ] || continue
    printf '%s\n' "$thread_id"
    break
  done
}

candidate_thread_ids() {
  {
    thread_id_from_env || true
    thread_id_from_resume_args || true
    thread_id_from_shell_snapshot_args || true
    thread_id_from_process_logs || true
  } | awk 'NF && !seen[$0]++'
}

sqlite_user_title_for_thread() {
  local thread_id="$1"
  local db="$codex_home/state_5.sqlite"

  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -r "$db" ] || return 1

  sqlite3 "$db" "select nullif(title,'') from threads where id = '$thread_id' and title != '' and (first_user_message = '' or title != first_user_message) limit 1;" 2>/dev/null |
    head -1
}

title=""
candidates="$(candidate_thread_ids || true)"
while read -r thread_id; do
  [ -n "$thread_id" ] || continue
  title="$(sqlite_user_title_for_thread "$thread_id" || true)"
  [ -n "$title" ] && break
done <<<"$candidates"

if command -v cache_store >/dev/null 2>&1; then
  cache_store "$cache_key" "$title"
fi

if [ -n "$title" ]; then
  printf '%s\n' "$title"
  exit 0
fi

exit 1

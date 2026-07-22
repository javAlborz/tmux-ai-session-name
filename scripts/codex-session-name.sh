#!/usr/bin/env bash
set -u

pane_pid="${1:-}"
pane_cwd="${2:-}"
_pane_title="${3:-}"
rows="${4:-}"
report_id="${AI_SESSION_NAME_REPORT_ID:-}"

codex_home="${CODEX_HOME:-$HOME/.codex}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$script_dir/cache-lib.sh" ]; then
  # shellcheck disable=SC1091
  . "$script_dir/cache-lib.sh"
fi

state_db_mtime="$(stat -c %Y "$codex_home/state_5.sqlite" 2>/dev/null || printf '0\n')"
logs_db_mtime="$(stat -c %Y "$codex_home/logs_2.sqlite" 2>/dev/null || printf '0\n')"
session_index_mtime="$(stat -c %Y "$codex_home/session_index.jsonl" 2>/dev/null || printf '0\n')"
cache_key="codex|${pane_pid}|${state_db_mtime}|${logs_db_mtime}|${session_index_mtime}|id:${report_id}"

if command -v cache_lookup >/dev/null 2>&1; then
  cached_value="$(cache_lookup "$cache_key" 30)"
  cache_rc=$?
  if [ "$cache_rc" -eq 0 ]; then
    printf '%s\n' "${cached_value//$'\x1f'/$'\t'}"
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
  local logs_db="$codex_home/logs_2.sqlite"
  local state_db="$codex_home/state_5.sqlite"
  local pid

  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -r "$logs_db" ] || return 1
  [ -r "$state_db" ] || return 1

  printf '%s\n' "$rows" |
  grep -Ei '(^|[ /.-])codex([ /.-]|$)|@openai/codex' |
  awk '{print $1}' |
  while read -r pid; do
    local candidate_thread_ids

    [ -n "$pid" ] || continue
    candidate_thread_ids="$(sqlite3 "$logs_db" "attach database '$state_db' as state;
      with candidates as (
        select
          l.thread_id,
          max(l.ts) as last_ts,
          max(l.ts_nanos) as last_ts_nanos
        from logs l
        join state.threads t on t.id = l.thread_id
        where l.process_uuid like 'pid:$pid:%'
          and l.thread_id is not null
          and l.thread_id != ''
        group by l.thread_id
      )
      select c.thread_id
      from candidates c
      join state.threads t on t.id = c.thread_id
      order by
        case when t.title != '' and (t.first_user_message = '' or t.title != t.first_user_message) then 0 else 1 end,
        t.updated_at desc,
        c.last_ts desc,
        c.last_ts_nanos desc
      limit 5;" 2>/dev/null)"
    [ -n "$candidate_thread_ids" ] || continue
    printf '%s\n' "$candidate_thread_ids"
    break
  done
}

candidate_thread_refs() {
  local authoritative

  authoritative="$({
    thread_id_from_env || true
    thread_id_from_resume_args || true
    thread_id_from_shell_snapshot_args || true
  } | awk 'NF && !seen[$0]++')"

  if [ -n "$authoritative" ]; then
    printf '%s\n' "$authoritative" | awk 'NF { print "strong\t" $0 }'
    return 0
  fi

  thread_id_from_process_logs | awk 'NF && !seen[$0]++ { print "weak\t" $0 }'
}

sqlite_user_title_for_thread() {
  local thread_id="$1"
  local db="$codex_home/state_5.sqlite"

  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -r "$db" ] || return 1

  sqlite3 "$db" "select nullif(title,'') from threads where id = '$thread_id' and title != '' and (first_user_message = '' or title != first_user_message) limit 1;" 2>/dev/null |
    head -1
}

sqlite_first_user_message_for_thread() {
  local thread_id="$1"
  local db="$codex_home/state_5.sqlite"

  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -r "$db" ] || return 1

  sqlite3 "$db" "select first_user_message from threads where id = '$thread_id' limit 1;" 2>/dev/null |
    head -1
}

session_index_title_for_thread() {
  local thread_id="$1"
  local index_file="$codex_home/session_index.jsonl"
  local title
  local first_user_message

  [ -r "$index_file" ] || return 1

  title="$(awk -v id="$thread_id" '
    index($0, "\"id\":\"" id "\"") { line = $0 }
    END {
      if (line == "") {
        exit
      }
      if (match(line, /"thread_name":"([^"\\]|\\.)*"/)) {
        value = substr(line, RSTART + 15, RLENGTH - 16)
        gsub(/\\"/, "\"", value)
        gsub(/\\\\/, "\\", value)
        print value
      }
    }
  ' "$index_file" 2>/dev/null | head -1)"
  [ -n "$title" ] || return 1

  first_user_message="$(sqlite_first_user_message_for_thread "$thread_id" || true)"
  if [ -n "$first_user_message" ] && [ "$title" = "$first_user_message" ]; then
    return 1
  fi

  printf '%s\n' "$title"
}

title=""
selected_thread_id=""
selected_confidence=""
candidates="$(candidate_thread_refs || true)"
while IFS=$'\t' read -r confidence thread_id; do
  [ -n "$thread_id" ] || continue
  title="$(session_index_title_for_thread "$thread_id" || true)"
  [ -n "$title" ] || title="$(sqlite_user_title_for_thread "$thread_id" || true)"
  if [ -n "$title" ]; then
    selected_thread_id="$thread_id"
    selected_confidence="$confidence"
    break
  fi
done <<<"$candidates"

output="$title"
if [ -n "$title" ] && [ "$report_id" = "1" ]; then
  output="$(printf '%s\t%s\t%s' "$selected_thread_id" "$title" "$selected_confidence")"
fi

if command -v cache_store >/dev/null 2>&1; then
  cache_store "$cache_key" "${output//$'\t'/$'\x1f'}"
fi

if [ -n "$output" ]; then
  printf '%s\n' "$output"
  exit 0
fi

exit 1

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

# These files are shared by every codex session on the machine, so any codex
# activity anywhere changes all three mtimes. Carrying them in the cache KEY
# minted a fresh row per pane on every write and pushed the claude and pane
# entries out of the bounded cache; carrying them in the VALUE keeps the same
# invalidate-on-write behaviour with one row per pane.
cache_stamp="${state_db_mtime}:${logs_db_mtime}:${session_index_mtime}"
cache_key="codex|${pane_pid}|id:${report_id}"

if command -v cache_lookup >/dev/null 2>&1; then
  cached_value="$(cache_lookup "$cache_key" 30)"
  cache_rc=$?
  if [ "$cache_rc" -eq 0 ] && [ "${cached_value%%$'\x1e'*}" = "$cache_stamp" ]; then
    cached_output="${cached_value#*$'\x1e'}"
    if [ -n "$cached_output" ]; then
      printf '%s\n' "${cached_output//$'\x1f'/$'\t'}"
      exit 0
    fi
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

is_uuid() {
  printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

resume_aliases_from_args() {
  printf '%s\n' "$rows" |
    sed -nE 's#.*(^|[[:space:]/.-])codex([[:space:]/.-]|.*[[:space:]])resume[[:space:]]+([^[:space:]]+)([[:space:]].*)?$#\3#p' |
    while read -r alias; do
      [ -n "$alias" ] || continue
      case "$alias" in -*) continue ;; esac
      is_uuid "$alias" && continue
      printf '%s\n' "$alias"
    done |
    awk 'NF && !seen[$0]++'
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

session_index_thread_ids_for_alias() {
  local alias="$1"
  local index_file="$codex_home/session_index.jsonl"

  [ -r "$index_file" ] || return 1

  awk -v alias="$alias" '
    function unescape(value) {
      gsub(/\\"/, "\"", value)
      gsub(/\\\\/, "\\", value)
      return value
    }
    {
      id = ""
      title = ""
      updated = ""
      if (match($0, /"id":"([^"\\]|\\.)*"/)) {
        id = substr($0, RSTART + 6, RLENGTH - 7)
        id = unescape(id)
      }
      if (match($0, /"thread_name":"([^"\\]|\\.)*"/)) {
        title = substr($0, RSTART + 15, RLENGTH - 16)
        title = unescape(title)
      }
      if (match($0, /"updated_at":"([^"\\]|\\.)*"/)) {
        updated = substr($0, RSTART + 14, RLENGTH - 15)
        updated = unescape(updated)
      }
      if (id != "" && title == alias) {
        if (updated > best_updated || (updated == best_updated && NR > best_nr)) {
          best_id = id
          best_updated = updated
          best_nr = NR
        }
      }
    }
    END {
      if (best_id != "") {
        print best_id
      }
    }
  ' "$index_file" 2>/dev/null
}

sqlite_thread_ids_for_alias() {
  local alias="$1"
  local db="$codex_home/state_5.sqlite"
  local escaped_alias

  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -r "$db" ] || return 1

  escaped_alias="$(sql_escape "$alias")"
  sqlite3 "$db" "select id from threads where title = '$escaped_alias' and title != '' and (first_user_message = '' or title != first_user_message) order by updated_at desc limit 1;" 2>/dev/null
}

thread_ids_from_resume_aliases() {
  local alias

  resume_aliases_from_args |
  while read -r alias; do
    [ -n "$alias" ] || continue
    {
      session_index_thread_ids_for_alias "$alias" || true
      sqlite_thread_ids_for_alias "$alias" || true
    } | awk 'NF && !seen[$0]++'
  done |
  awk 'NF && !seen[$0]++'
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

# Codex can leave the thread it was launched on: compaction and new turns fork
# a fresh thread id inside the same running process. After that, the launch-time
# `resume <uuid>` argument names a thread the session has abandoned, and a name
# the user sets now lands on a thread id nothing here ever asks about.
#
# The logs tie every thread a process incarnation touched to one stable
# process_uuid ("pid:<pid>:<uuid>"), so threads sharing a process_uuid with an
# authoritative ref belong to this same session and are safe to follow. A pid
# that an unrelated codex run merely reused carries a different process_uuid and
# is still rejected, which is what keeps a stale name from being stolen.
successor_thread_ids() {
  local anchor_ids="$1"
  local logs_db="$codex_home/logs_2.sqlite"
  local in_list=""
  local pid_clause=""
  local id
  local pid

  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -r "$logs_db" ] || return 1
  [ -n "$anchor_ids" ] || return 1

  while read -r id; do
    [ -n "$id" ] || continue
    in_list="$in_list${in_list:+,}'$(sql_escape "$id")'"
  done <<EOF_ANCHORS
$anchor_ids
EOF_ANCHORS
  [ -n "$in_list" ] || return 1

  # The anchor incarnation must be one of THIS pane's codex processes. A thread
  # outlives the run that created it, so matching on "any incarnation that ever
  # touched the anchor" reaches back into unrelated older sessions and adopts
  # their names.
  while read -r pid; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    pid_clause="$pid_clause${pid_clause:+ or }l2.process_uuid like 'pid:${pid}:%'"
  done <<EOF_PIDS
$(printf '%s\n' "$rows" |
  grep -Ei '(^|[ /.-])codex([ /.-]|$)|@openai/codex' |
  awk '{ print $1 }')
EOF_PIDS
  [ -n "$pid_clause" ] || return 1

  sqlite3 "$logs_db" "
    select l.thread_id
    from logs l
    where l.thread_id is not null
      and l.thread_id != ''
      and l.process_uuid in (
        select distinct l2.process_uuid
        from logs l2
        where l2.thread_id in ($in_list)
          and l2.process_uuid is not null
          and l2.process_uuid != ''
          and ($pid_clause)
      )
    group by l.thread_id
    order by max(l.ts) desc, max(l.ts_nanos) desc;" 2>/dev/null
}

candidate_thread_refs() {
  local authoritative
  local alias_refs

  authoritative="$({
    thread_id_from_env || true
    thread_id_from_resume_args || true
    thread_id_from_shell_snapshot_args || true
  } | awk 'NF && !seen[$0]++')"

  if [ -n "$authoritative" ]; then
    # Authoritative refs first so a named launch thread still wins outright;
    # same-incarnation successors follow, newest first, as weak candidates so
    # the renamer debounces them before claiming a window.
    {
      printf '%s\n' "$authoritative" | awk 'NF { print "strong\t" $0 }'
      successor_thread_ids "$authoritative" | awk 'NF { print "weak\t" $0 }'
    } | awk -F'\t' 'NF > 1 && !seen[$2]++'
    return 0
  fi

  alias_refs="$(thread_ids_from_resume_aliases || true)"
  if [ -n "$alias_refs" ]; then
    printf '%s\n' "$alias_refs" | awk 'NF { print "strong\t" $0 }'
    return 0
  fi

  thread_id_from_process_logs | awk 'NF && !seen[$0]++ { print "weak\t" $0 }'
}

sqlite_user_title_for_thread() {
  local thread_id="$1"
  local db="$codex_home/state_5.sqlite"

  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -r "$db" ] || return 1

  sqlite3 "$db" "select nullif(title,'') from threads where id = '$(sql_escape "$thread_id")' and title != '' and (first_user_message = '' or title != first_user_message) limit 1;" 2>/dev/null |
    head -1
}

sqlite_first_user_message_for_thread() {
  local thread_id="$1"
  local db="$codex_home/state_5.sqlite"

  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -r "$db" ] || return 1

  sqlite3 "$db" "select first_user_message from threads where id = '$(sql_escape "$thread_id")' limit 1;" 2>/dev/null |
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
  cache_store "$cache_key" "${cache_stamp}"$'\x1e'"${output//$'\t'/$'\x1f'}"
fi

if [ -n "$output" ]; then
  printf '%s\n' "$output"
  exit 0
fi

exit 1

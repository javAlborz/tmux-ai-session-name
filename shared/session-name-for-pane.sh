#!/usr/bin/env bash
set -u

pane_pid="${1:-}"
pane_cwd="${2:-}"
pane_title="${3:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -n "$pane_pid" ] || exit 1

if [ -r "$script_dir/cache-lib.sh" ]; then
  # shellcheck disable=SC1091
  . "$script_dir/cache-lib.sh"
fi

# Resolve identity on every pass: PID/title survive in-process session switches.
report_tool_only="${AI_SESSION_NAME_REPORT_TOOL_ONLY:-}"
report_id="${AI_SESSION_NAME_REPORT_ID:-}"

process_table() {
  if [ -n "${AI_SESSION_NAME_PROCESS_TABLE_FILE:-}" ] && [ -r "${AI_SESSION_NAME_PROCESS_TABLE_FILE}" ]; then
    cat "$AI_SESSION_NAME_PROCESS_TABLE_FILE"
    return 0
  fi
  ps -eo pid=,ppid=,comm=,args= 2>/dev/null || true
}

descendant_rows() {
  local root_pid="$1"
  local frontier="$root_pid"
  local seen=" $root_pid "
  local table
  local next
  local pid
  local ppid
  local rest

  table="$(process_table)"
  while [ -n "$frontier" ]; do
    next=""
    while read -r pid ppid rest; do
      [ -n "${pid:-}" ] || continue
      case " $frontier " in
        *" $ppid "*)
          case "$seen" in
            *" $pid "*) ;;
            *)
              printf '%s %s %s\n' "$pid" "$ppid" "$rest"
              seen="$seen$pid "
              next="$next $pid"
              ;;
          esac
          ;;
      esac
    done <<EOF
$table
EOF
    frontier="$(printf '%s' "$next" | sed -E 's/^ +//; s/ +$//')"
  done
}

negative_exit() { exit 1; }

rows="$(descendant_rows "$pane_pid")"
rows_with_root="$(process_table | awk -v pid="$pane_pid" '$1 == pid { print }'; printf '%s\n' "$rows")"

result="$("$script_dir/session-dir-session-name.sh" "$pane_pid" "$pane_cwd" "$pane_title" "$rows_with_root" 2>/dev/null || true)"
[ -n "$result" ] || exit 1
printf 'task\t%s\n' "$result"

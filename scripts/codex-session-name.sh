#!/usr/bin/env bash
set -u

pane_pid="${1:-}"
pane_cwd="${2:-}"
_pane_title="${3:-}"
rows="${4:-}"

codex_home="${CODEX_HOME:-$HOME/.codex}"

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

sqlite_user_title_for_thread() {
  local thread_id="$1"
  local db="$codex_home/state_5.sqlite"

  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -r "$db" ] || return 1

  sqlite3 "$db" "select nullif(title,'') from threads where id = '$thread_id' and title != '' and (first_user_message = '' or title != first_user_message) limit 1;" 2>/dev/null |
    head -1
}

thread_id="$(thread_id_from_env || true)"
[ -n "$thread_id" ] || thread_id="$(thread_id_from_shell_snapshot_args || true)"
if [ -n "$thread_id" ]; then
  title="$(sqlite_user_title_for_thread "$thread_id" || true)"
  if [ -n "$title" ]; then
    printf '%s\n' "$title"
    exit 0
  fi
fi

exit 1

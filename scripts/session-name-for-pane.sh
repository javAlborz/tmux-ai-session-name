#!/usr/bin/env bash
set -u

pane_pid="${1:-}"
pane_cwd="${2:-}"
pane_title="${3:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -n "$pane_pid" ] || exit 1

process_table() {
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

rows="$(descendant_rows "$pane_pid")"
rows_with_root="$(process_table | awk -v pid="$pane_pid" '$1 == pid { print }'; printf '%s\n' "$rows")"

tool=""
if printf '%s\n' "$rows_with_root" | grep -Eiq '(^|[ /.-])claude([ /.-]|$)|claude-code|@anthropic-ai/claude-code'; then
  tool="claude"
elif printf '%s\n' "$rows_with_root" | grep -Eiq '(^|[ /.-])codex([ /.-]|$)|@openai/codex'; then
  tool="codex"
else
  exit 1
fi

case "$tool" in
  claude)
    session="$("$script_dir/claude-session-name.sh" "$pane_pid" "$pane_cwd" "$pane_title" "$rows_with_root" || true)"
    ;;
  codex)
    session="$("$script_dir/codex-session-name.sh" "$pane_pid" "$pane_cwd" "$pane_title" "$rows_with_root" || true)"
    ;;
esac

[ -n "${session:-}" ] || exit 1
session="$(printf '%s' "$session" | sed -E 's/^[[:space:]]*✳[[:space:]]*//; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
[ -n "$session" ] || exit 1

generic_session="$(printf '%s' "$session" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]-]+/ /g; s/^ //; s/ $//')"
case "$generic_session" in
  codex|claude|"claude code")
    exit 1
    ;;
esac

printf '%s\t%s\n' "$tool" "$session"

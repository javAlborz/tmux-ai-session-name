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

# Outer cache: key by pane_pid + cleaned title. Cache the full output of
# detection (tool<TAB>session). On hit we skip the process-tree walk and
# the tool-specific scripts entirely.
report_tool_only="${AI_SESSION_NAME_REPORT_TOOL_ONLY:-}"
report_id="${AI_SESSION_NAME_REPORT_ID:-}"
cleaned_pane_title="$(printf '%s' "$pane_title" | sed -E 's/^[[:space:]]*[^[:alnum:][:space:]]+[[:space:]]+//; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
outer_cache_key="pane|${pane_pid}|${cleaned_pane_title}|id:${report_id}"

if [ "$report_tool_only" != "1" ] && command -v cache_lookup >/dev/null 2>&1; then
  cached_value="$(cache_lookup "$outer_cache_key" 10)"
  cache_rc=$?
  if [ "$cache_rc" -eq 0 ]; then
    printf '%s\n' "${cached_value//$'\x1f'/$'\t'}"
    exit 0
  elif [ "$cache_rc" -eq 2 ]; then
    exit 1
  fi
fi

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

negative_exit() {
  if [ "$report_tool_only" != "1" ] && command -v cache_store >/dev/null 2>&1; then
    cache_store "$outer_cache_key" ""
  fi
  exit 1
}

rows="$(descendant_rows "$pane_pid")"
rows_with_root="$(process_table | awk -v pid="$pane_pid" '$1 == pid { print }'; printf '%s\n' "$rows")"

tool=""
identity=""
confidence=""

# Prefer the product-neutral JSONL provider when a descendant advertises a
# session directory. It reads only the stable session id, cwd, and the latest
# explicit display name; conversation records are never inspected.
session_dir_result="$(
  AI_SESSION_NAME_REPORT_TOOL_ONLY="$report_tool_only" \
  AI_SESSION_NAME_REPORT_ID="$report_id" \
    "$script_dir/session-dir-session-name.sh" \
      "$pane_pid" "$pane_cwd" "$pane_title" "$rows_with_root" 2>/dev/null || true
)"
if [ "$report_tool_only" = "1" ] && [ "$session_dir_result" = "1" ]; then
  printf 'task\t\n'
  exit 2
elif [ -n "$session_dir_result" ]; then
  tool="task"
  if [ "$report_id" = "1" ] && printf '%s' "$session_dir_result" | grep -q "$(printf '\t')"; then
    identity="${session_dir_result%%	*}"
    rest="${session_dir_result#*	}"
    session="${rest%%	*}"
    confidence="${rest#*	}"
    if [ "$confidence" = "$rest" ]; then
      confidence=""
    fi
  else
    session="$session_dir_result"
  fi
elif printf '%s\n' "$rows_with_root" | grep -Eiq '(^|[ /.-])claude([ /.-]|$)|claude-code|@anthropic-ai/claude-code'; then
  tool="claude"
elif printf '%s\n' "$rows_with_root" | grep -Eiq '(^|[ /.-])codex([ /.-]|$)|@openai/codex'; then
  tool="codex"
else
  negative_exit
fi

case "$tool" in
  task)
    ;;
  claude)
    session="$("$script_dir/claude-session-name.sh" "$pane_pid" "$pane_cwd" "$pane_title" "$rows_with_root" || true)"
    ;;
  codex)
    session_result="$(AI_SESSION_NAME_REPORT_ID="$report_id" "$script_dir/codex-session-name.sh" "$pane_pid" "$pane_cwd" "$pane_title" "$rows_with_root" || true)"
    if [ "$report_id" = "1" ] && printf '%s' "$session_result" | grep -q "$(printf '\t')"; then
      identity="${session_result%%	*}"
      rest="${session_result#*	}"
      session="${rest%%	*}"
      confidence="${rest#*	}"
      if [ "$confidence" = "$rest" ]; then
        confidence=""
      fi
    else
      session="$session_result"
    fi
    ;;
esac

if [ -z "${session:-}" ] && [ "$report_tool_only" = "1" ]; then
  printf '%s\t\n' "$tool"
  exit 2
fi

[ -n "${session:-}" ] || negative_exit
session="$(printf '%s' "$session" | sed -E 's/^[[:space:]]*[^[:alnum:][:space:]]+[[:space:]]+//; s/[[:space:]]+/ /g; s/^ //; s/ $//')"
[ -n "$session" ] || negative_exit

generic_session="$(printf '%s' "$session" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]-]+/ /g; s/^ //; s/ $//')"
case "$generic_session" in
  codex|claude|"claude code")
    if [ "$report_tool_only" = "1" ]; then
      printf '%s\t\n' "$tool"
      exit 2
    fi
    negative_exit
    ;;
esac

if [ "$report_id" = "1" ]; then
  if [ -n "${confidence:-}" ]; then
    output="$(printf '%s\t%s\t%s\t%s' "$tool" "$identity" "$session" "$confidence")"
  else
    output="$(printf '%s\t%s\t%s' "$tool" "$identity" "$session")"
  fi
else
  output="$(printf '%s\t%s' "$tool" "$session")"
fi
if [ "$report_tool_only" != "1" ] && command -v cache_store >/dev/null 2>&1; then
  cache_store "$outer_cache_key" "${output//$'\t'/$'\x1f'}"
fi
printf '%s\n' "$output"

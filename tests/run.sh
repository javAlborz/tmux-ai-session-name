#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
provider="$repo_dir/scripts/session-dir-session-name.sh"
detector="$repo_dir/scripts/session-name-for-pane.sh"
renamer="$repo_dir/scripts/rename-windows.sh"
tmp_dir="$(mktemp -d)"
socket_name="tmux-ai-session-name-test-$$"
real_tmux="$(command -v tmux)"

cleanup() {
  env -u TMUX "$real_tmux" -L "$socket_name" kill-server >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [ "$actual" != "$expected" ]; then
    printf 'not ok - %s\nexpected: %q\nactual:   %q\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
  printf 'ok - %s\n' "$label"
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -n "$real_tmux" ] || fail "tmux is required"

while IFS= read -r script; do
  bash -n "$script"
done < <(find "$repo_dir" -maxdepth 2 -type f \( -name '*.sh' -o -name '*.tmux' \) -print)
printf 'ok - shell syntax\n'

fixture_proc="$tmp_dir/proc"
fixture_sessions="$tmp_dir/sessions"
fixture_cwd="$tmp_dir/work"
fixture_pid=4242
fixture_id="6d28ba43-32ca-49f8-8174-9183c3e45211"
fixture_name="Review deployment"
fixture_file="$fixture_sessions/session.jsonl"
mkdir -p "$fixture_proc/$fixture_pid/fd" "$fixture_sessions" "$fixture_cwd"
printf 'TASK_SESSION_DIR=%s\0' "$fixture_sessions" >"$fixture_proc/$fixture_pid/environ"
{
  jq -nc --arg id "$fixture_id" --arg cwd "$fixture_cwd" \
    '{type:"session",version:3,id:$id,timestamp:"2026-07-23T00:00:00Z",cwd:$cwd}'
  jq -nc --arg name "$fixture_name" \
    '{type:"session_info",id:"fixture-name",parentId:null,timestamp:"2026-07-23T00:00:01Z",name:$name}'
} >"$fixture_file"
ln -s "$fixture_file" "$fixture_proc/$fixture_pid/fd/7"

provider_result="$(
  AI_SESSION_NAME_PROC_ROOT="$fixture_proc" AI_SESSION_NAME_REPORT_ID=1 \
    "$provider" "$fixture_pid" "$fixture_cwd" "" "$fixture_pid 1 task task"
)"
assert_eq "$(printf '%s\t%s\tstrong' "$fixture_id" "$fixture_name")" "$provider_result" \
  "generic provider reads only explicit session metadata"

tool_result="$(
  AI_SESSION_NAME_PROC_ROOT="$fixture_proc" AI_SESSION_NAME_REPORT_TOOL_ONLY=1 \
    "$provider" "$fixture_pid" "$fixture_cwd" "" "$fixture_pid 1 task task"
)"
assert_eq "1" "$tool_result" "generic provider detects unnamed-capable client"

unnamed_pid=4343
unnamed_file="$fixture_sessions/current-unnamed.jsonl"
mkdir -p "$fixture_proc/$unnamed_pid/fd"
printf 'TASK_SESSION_DIR=%s\0' "$fixture_sessions" >"$fixture_proc/$unnamed_pid/environ"
jq -nc --arg id "7e22799e-5429-4c1d-bbd2-f042116b64ef" --arg cwd "$fixture_cwd" \
  '{type:"session",version:3,id:$id,timestamp:"2026-07-23T00:01:00Z",cwd:$cwd}' >"$unnamed_file"
touch -d '2026-07-22T00:00:00Z' "$fixture_file"
touch -d '2026-07-23T00:00:00Z' "$unnamed_file"
unnamed_result="$(
  AI_SESSION_NAME_PROC_ROOT="$fixture_proc" \
    "$provider" "$unnamed_pid" "$fixture_cwd" "" "$unnamed_pid 1 task task" || true
)"
assert_eq "" "$unnamed_result" "new unnamed session does not borrow an older name"

title_pid=4444
other_name="Different session"
other_file="$fixture_sessions/newer-named.jsonl"
{
  jq -nc --arg id "6fd2c204-c456-4747-b160-e66bf32892eb" --arg cwd "$fixture_cwd" \
    '{type:"session",version:3,id:$id,timestamp:"2026-07-24T00:02:00Z",cwd:$cwd}'
  jq -nc --arg name "$other_name" \
    '{type:"session_info",id:"other-name",parentId:null,timestamp:"2026-07-24T00:02:01Z",name:$name}'
} >"$other_file"
touch -d '2026-07-24T00:02:00Z' "$other_file"
mkdir -p "$fixture_proc/$title_pid/fd"
printf 'TASK_SESSION_DIR=%s\0' "$fixture_sessions" >"$fixture_proc/$title_pid/environ"
title_result="$(
  AI_SESSION_NAME_PROC_ROOT="$fixture_proc" AI_SESSION_NAME_REPORT_ID=1 \
    "$provider" "$title_pid" "$fixture_cwd" "π - $fixture_name - work" "$title_pid 1 task task"
)"
assert_eq "$(printf 'pane:%s\t%s\tstrong' "$title_pid" "$fixture_name")" "$title_result" \
  "pane title selects the correct session among a shared cwd"

pi_pid=4545
pi_home="$tmp_dir/pi-home"
safe_cwd="${fixture_cwd#/}"
safe_cwd="${safe_cwd//\//-}"
pi_sessions="$pi_home/.pi/agent/sessions/--${safe_cwd}--"
pi_name="Hermes session"
pi_file="$pi_sessions/pi.jsonl"
mkdir -p "$fixture_proc/$pi_pid/fd" "$pi_sessions"
printf 'HOME=%s\0' "$pi_home" >"$fixture_proc/$pi_pid/environ"
{
  jq -nc --arg id "110f4024-27a9-447f-881e-8e12ff784f15" --arg cwd "$fixture_cwd" \
    '{type:"session",version:3,id:$id,timestamp:"2026-07-24T00:00:00Z",cwd:$cwd}'
  jq -nc --arg name "$pi_name" \
    '{type:"session_info",id:"pi-name",parentId:null,timestamp:"2026-07-24T00:00:01Z",name:$name}'
} >"$pi_file"
pi_result="$(
  AI_SESSION_NAME_PROC_ROOT="$fixture_proc" AI_SESSION_NAME_REPORT_ID=1 \
    "$provider" "$pi_pid" "$fixture_cwd" "π - $pi_name - work" "$pi_pid 1 pi pi"
)"
assert_eq "$(printf 'pane:%s\t%s\tstrong' "$pi_pid" "$pi_name")" "$pi_result" \
  "stock Pi default session directory is discovered"

process_table="$tmp_dir/process-table"
printf '%s\n' "$fixture_pid 1 task task" >"$process_table"
detector_result="$(
  AI_SESSION_NAME_PROC_ROOT="$fixture_proc" \
  AI_SESSION_NAME_PROCESS_TABLE_FILE="$process_table" \
  AI_SESSION_NAME_CACHE_FILE="$tmp_dir/detector-cache" \
  AI_SESSION_NAME_REPORT_ID=1 \
    "$detector" "$fixture_pid" "$fixture_cwd" ""
)"
assert_eq "$(printf 'task\t%s\t%s\tstrong' "$fixture_id" "$fixture_name")" "$detector_result" \
  "dispatcher exposes generic provider identity"

wrapper_dir="$tmp_dir/bin"
mkdir -p "$wrapper_dir"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "${1:-}" in' \
  '  set-window-option|rename-window)' \
  '    if [ -n "${TMUX_AI_TEST_MUTATION_LOG:-}" ]; then' \
  '      printf "%q " "$@" >>"$TMUX_AI_TEST_MUTATION_LOG"' \
  '      printf "\n" >>"$TMUX_AI_TEST_MUTATION_LOG"' \
  '    fi' \
  '    ;;' \
  'esac' \
  'exec env -u TMUX "$TMUX_AI_TEST_REAL" -L "$TMUX_AI_TEST_SOCKET" "$@"' \
  >"$wrapper_dir/tmux"
chmod +x "$wrapper_dir/tmux"
export TMUX_AI_TEST_REAL="$real_tmux"
export TMUX_AI_TEST_SOCKET="$socket_name"
export PATH="$wrapper_dir:$PATH"

session_name="ai-name-test"
tmux -f /dev/null new-session -d -s "$session_name" -c "$fixture_cwd" 'bash --noprofile --norc'
tmux set-option -g automatic-rename on
tmux set-option -g automatic-rename-format '#{pane_current_command}'
tmux set-option -g allow-rename off
tmux set-window-option -g automatic-rename on
tmux set-window-option -g allow-rename off
tmux set-option -g @ai-session-name-format '#{session}'
tmux set-option -g @ai-session-name-restore on
tmux set-option -g @ai-session-name-release-unnamed-after 1
tmux set-option -g @ai-session-name-debounce-ticks 1

live_sessions="$tmp_dir/live-sessions"
live_file="$live_sessions/live.jsonl"
live_id="f30d482d-39bf-4eba-ad51-c540c0f7f78c"
live_name="Ship concise names"
mkdir -p "$live_sessions"
{
  jq -nc --arg id "$live_id" --arg cwd "$fixture_cwd" \
    '{type:"session",version:3,id:$id,timestamp:"2026-07-23T00:00:00Z",cwd:$cwd}'
  jq -nc --arg name "$live_name" \
    '{type:"session_info",id:"live-name",parentId:null,timestamp:"2026-07-23T00:00:01Z",name:$name}'
} >"$live_file"

start_live_task() {
  tmux send-keys -t "$session_name:" "env TASK_SESSION_DIR='$live_sessions' sleep 30" Enter
  for _attempt in 1 2 3 4 5; do
    if [ "$(tmux display-message -pt "$session_name:" '#{pane_current_command}')" = "sleep" ]; then
      tmux select-pane -t "$session_name:" -T "π - $live_name - work"
      return 0
    fi
    sleep 0.1
  done
  fail "test task did not start"
}

stop_live_task() {
  tmux send-keys -t "$session_name:" C-c
  for _attempt in 1 2 3 4 5; do
    [ "$(tmux display-message -pt "$session_name:" '#{pane_current_command}')" = "bash" ] && return 0
    sleep 0.1
  done
  fail "test task did not stop"
}

cache_file="$tmp_dir/live-cache"
export AI_SESSION_NAME_CACHE_FILE="$cache_file"
export AI_SESSION_NAME_PLUGIN_DIR="$repo_dir"

start_live_task
rm -f "$cache_file"
"$renamer"
assert_eq "$live_name" "$(tmux display-message -pt "$session_name:" '#{window_name}')" \
  "named task claims window"
assert_eq "off" "$(tmux show-window-option -t "$session_name:" -v automatic-rename)" \
  "claimed window pauses automatic naming"
assert_eq "off" "$(tmux show-window-option -g -v allow-rename)" \
  "application-driven rename remains disabled"

mutation_log="$tmp_dir/mutations"
: >"$mutation_log"
export TMUX_AI_TEST_MUTATION_LOG="$mutation_log"
rm -f "$cache_file"
"$renamer"
assert_eq "" "$(sed -n '1p' "$mutation_log")" \
  "stable named task does not rewrite unchanged tmux state"
unset TMUX_AI_TEST_MUTATION_LOG

stop_live_task
rm -f "$cache_file"
"$renamer"
assert_eq "bash" "$(tmux display-message -pt "$session_name:" '#{window_name}')" \
  "finished task restores command fallback"
assert_eq "on" "$(tmux show-window-option -g -v automatic-rename)" \
  "finished task returns to enabled global automatic naming"
assert_eq "" "$(tmux show-option -w -t "$session_name:" -qv automatic-rename)" \
  "finished task restores inherited automatic naming"

start_live_task
rm -f "$cache_file"
"$renamer"
tmux rename-window -t "$session_name:" "ops"
rm -f "$cache_file"
"$renamer"
assert_eq "ops" "$(tmux display-message -pt "$session_name:" '#{window_name}')" \
  "manual rename wins while task is active"
assert_eq "" "$(tmux show-option -w -t "$session_name:" -qv @ai-session-name-owned)" \
  "manual rename releases plugin ownership"

tmux set-option -g @ai-session-name-enabled on
bash "$repo_dir/ai-session-name.tmux"
bash "$repo_dir/ai-session-name.tmux"
for hook in client-attached session-created after-new-window; do
  hook_lines="$(tmux show-hooks -g "$hook" | grep -F "$repo_dir/scripts/rename-daemon.sh" || true)"
  assert_eq "${hook}[92]" "${hook_lines%% *}" \
    "$hook uses one stable plugin hook"
  assert_eq "1" "$(printf '%s\n' "$hook_lines" | awk 'NF { count++ } END { print count + 0 }')" \
    "$hook is not duplicated after reload"
done

printf 'all tests passed\n'

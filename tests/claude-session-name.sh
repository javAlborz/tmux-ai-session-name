#!/usr/bin/env bash
set -euo pipefail

plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$plugin_dir/scripts/claude-session-name.sh"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local name="$1"
  local expected="$2"
  local actual="$3"

  if [ "$actual" != "$expected" ]; then
    printf 'not ok - %s\nexpected: %s\nactual:   %s\n' "$name" "$expected" "$actual" >&2
    exit 1
  fi
  printf 'ok - %s\n' "$name"
}

# The pane pid is never a live process here, so the resolver cannot read a
# process start time. That is deliberate: a start time must not be a
# precondition for resolving a name.
fixture_pid=4242
fixture_rows=$'4242 1 bash -bash\n4243 4242 claude claude'

new_claude_home() {
  local home
  local cwd
  local encoded

  home="$(mktemp -d "$tmp_root/claude.XXXXXX")"
  cwd="$1"
  encoded="$(printf '%s' "$cwd" | sed 's#[^A-Za-z0-9]#-#g')"
  mkdir -p "$home/projects/$encoded"
  printf '%s\n' "$home"
}

project_dir_for() {
  local home="$1"
  local cwd="$2"

  printf '%s/projects/%s\n' "$home" "$(printf '%s' "$cwd" | sed 's#[^A-Za-z0-9]#-#g')"
}

write_transcript() {
  local file="$1"
  local session_name="$2"
  local timestamp="$3"

  {
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"/rename"}}\n' "$timestamp"
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"<local-command-stdout>Session renamed to: %s</local-command-stdout>"}}\n' \
      "$timestamp" "$session_name"
  } >"$file"
}

run_resolver() {
  local home="$1"
  local cwd="$2"
  local title="$3"

  CLAUDE_HOME="$home" "$script" "$fixture_pid" "$cwd" "$title" "$fixture_rows"
}

test_rename_from_an_earlier_run_still_resolves() {
  local home
  local cwd="/home/alborz"
  local output

  # The rename happened months before the current process started, which is the
  # normal state of any session restored with --resume/--continue or after a
  # reboot. It must still count.
  home="$(new_claude_home "$cwd")"
  write_transcript "$(project_dir_for "$home" "$cwd")/session-a.jsonl" "tv" "2026-06-15T11:39:37.850Z"

  output="$(run_resolver "$home" "$cwd" "✳ tv")"
  assert_eq "rename recorded before the current process still resolves" "tv" "$output"
}

test_rename_resolves_beyond_the_ten_newest_transcripts() {
  local home
  local cwd="/home/alborz"
  local project_dir
  local output
  local i

  # One transcript holds the rename record; many busier neighbours sit above it
  # in mtime order. Capping the scan at the newest few lost the name.
  home="$(new_claude_home "$cwd")"
  project_dir="$(project_dir_for "$home" "$cwd")"
  write_transcript "$project_dir/session-podcast.jsonl" "podcast" "2026-07-28T09:15:45.661Z"
  touch -d '2026-07-28T09:15:45Z' "$project_dir/session-podcast.jsonl"
  for i in $(seq 1 20); do
    write_transcript "$project_dir/decoy-$i.jsonl" "decoy-$i" "2026-08-10T10:00:00.000Z"
    touch -d "2026-08-10T10:00:00Z" "$project_dir/decoy-$i.jsonl"
  done

  output="$(run_resolver "$home" "$cwd" "✳ podcast")"
  assert_eq "rename resolves from a transcript far down the mtime order" "podcast" "$output"
}

test_unverified_pane_title_is_rejected() {
  local home
  local cwd="/home/alborz"
  local output
  local rc

  # A pane title that no transcript ever recorded a rename for is not a session
  # name, and must not claim the window.
  home="$(new_claude_home "$cwd")"
  write_transcript "$(project_dir_for "$home" "$cwd")/session-a.jsonl" "tv" "2026-06-15T11:39:37.850Z"

  if output="$(run_resolver "$home" "$cwd" "some task description")"; then
    rc=0
  else
    rc=$?
  fi

  [ "$rc" -ne 0 ] || fail "unverified pane title should not resolve: $output"
  assert_eq "pane title without a rename record is rejected" "" "$output"
}

test_generic_pane_titles_are_rejected() {
  local home
  local cwd="/home/alborz"
  local output
  local rc
  local title

  home="$(new_claude_home "$cwd")"
  write_transcript "$(project_dir_for "$home" "$cwd")/session-a.jsonl" "claude" "2026-06-15T11:39:37.850Z"

  for title in "claude" "Claude Code" "bash" ""; do
    if output="$(run_resolver "$home" "$cwd" "$title")"; then
      rc=0
    else
      rc=$?
    fi
    [ "$rc" -ne 0 ] || fail "generic title '$title' should not resolve: $output"
    [ -z "$output" ] || fail "generic title '$title' produced output: $output"
  done
  printf 'ok - %s\n' "generic pane titles are rejected"
}

test_missing_project_directory_is_rejected() {
  local home
  local cwd="/home/alborz"
  local output
  local rc

  home="$(new_claude_home "$cwd")"

  if output="$(run_resolver "$home" "/home/alborz/elsewhere" "✳ tv")"; then
    rc=0
  else
    rc=$?
  fi

  [ "$rc" -ne 0 ] || fail "unknown project directory should not resolve: $output"
  assert_eq "unknown project directory is rejected" "" "$output"
}

test_rename_from_an_earlier_run_still_resolves
test_rename_resolves_beyond_the_ten_newest_transcripts
test_unverified_pane_title_is_rejected
test_generic_pane_titles_are_rejected
test_missing_project_directory_is_rejected

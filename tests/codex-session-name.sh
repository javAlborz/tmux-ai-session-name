#!/usr/bin/env bash
set -euo pipefail

plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$plugin_dir/scripts/codex-session-name.sh"
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

new_codex_home() {
  local dir

  dir="$(mktemp -d "$tmp_root/codex.XXXXXX")"
  sqlite3 "$dir/state_5.sqlite" <<'SQL'
create table threads (
  id text primary key,
  title text,
  first_user_message text,
  updated_at integer,
  cwd text not null default '',
  created_at_ms integer not null default 0
);
SQL
  sqlite3 "$dir/logs_2.sqlite" <<'SQL'
create table logs (
  process_uuid text,
  thread_id text,
  ts integer,
  ts_nanos integer
);
SQL
  : > "$dir/session_index.jsonl"
  printf '%s\n' "$dir"
}

run_resolver() {
  local home="$1"
  local rows="$2"
  local enable_logs_db="${3:-1}"

  CODEX_HOME="$home" \
    AI_SESSION_NAME_REPORT_ID=1 \
    AI_SESSION_NAME_ENABLE_LOG_DB="$enable_logs_db" \
    "$script" 100 "" "" "$rows"
}

test_logs_db_fallback_is_disabled_by_default() {
  local home
  local output
  local rc
  local rows

  home="$(new_codex_home)"
  sqlite3 "$home/state_5.sqlite" <<'SQL'
insert into threads (id, title, first_user_message, updated_at) values ('019fe0b0-43e8-7c13-a886-10740fecb883', 'unsafe-poll', '$home generated', 1786181077);
SQL
  sqlite3 "$home/logs_2.sqlite" <<'SQL'
insert into logs values ('pid:202:live', '019fe0b0-43e8-7c13-a886-10740fecb883', 1786181076, 1);
SQL

  rows=$'100 1 bash -bash\n202 100 codex /opt/codex'
  if output="$(run_resolver "$home" "$rows" 0)"; then
    rc=0
  else
    rc=$?
  fi

  [ "$rc" -ne 0 ] || fail "default resolution should not scan logs_2.sqlite: $output"
  assert_eq "logs DB process correlation is opt-in" "" "$output"
}

test_resume_alias_uses_latest_index_match() {
  local home
  local output
  local rows

  home="$(new_codex_home)"
  sqlite3 "$home/state_5.sqlite" <<'SQL'
insert into threads (id, title, first_user_message, updated_at) values ('019faa21-7632-7ed2-ab2d-9d0142c056af', 'dark', '$home first dark', 1785330881);
insert into threads (id, title, first_user_message, updated_at) values ('019fb220-a90a-7502-afca-09529e663393', 'dark', '$home latest dark', 1785419141);
SQL
  cat > "$home/session_index.jsonl" <<'JSONL'
{"id":"019faa21-7632-7ed2-ab2d-9d0142c056af","thread_name":"dark","updated_at":"2026-07-29T12:04:38.042351033Z"}
{"id":"019fb220-a90a-7502-afca-09529e663393","thread_name":"dark","updated_at":"2026-07-30T08:25:15.162693397Z"}
JSONL

  rows=$'100 1 bash -bash\n101 100 MainThread node /home/alborz/.nvm/versions/node/v24.13.0/bin/codex resume dark\n102 101 codex /home/alborz/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/bin/codex resume dark'
  output="$(run_resolver "$home" "$rows")"

  assert_eq "resume alias resolves latest matching session index entry" \
    $'019fb220-a90a-7502-afca-09529e663393\tdark\tstrong' \
    "$output"
}

test_uuid_resume_does_not_steal_stale_process_log_name() {
  local home
  local output
  local rc
  local rows

  home="$(new_codex_home)"
  sqlite3 "$home/state_5.sqlite" <<'SQL'
insert into threads (id, title, first_user_message, updated_at) values ('019fb458-7913-77f1-aac0-05c0aa703f1c', '$home I bougth my gf a new macboook', '$home I bougth my gf a new macboook', 1785441501);
insert into threads (id, title, first_user_message, updated_at) values ('019fe0b0-43e8-7c13-a886-10740fecb883', 'mac', '$home I bougth my gf a new macboook', 1786181077);
SQL
  cat > "$home/session_index.jsonl" <<'JSONL'
{"id":"019fe0b0-43e8-7c13-a886-10740fecb883","thread_name":"mac","updated_at":"2026-08-08T11:56:55.098579381Z"}
JSONL
  sqlite3 "$home/logs_2.sqlite" <<'SQL'
insert into logs values ('pid:202:stale', '019fe0b0-43e8-7c13-a886-10740fecb883', 1786181076, 1);
SQL

  rows=$'100 1 bash -bash\n101 100 MainThread node /home/alborz/.nvm/versions/node/v24.13.0/bin/codex resume 019fb458-7913-77f1-aac0-05c0aa703f1c\n202 101 codex /home/alborz/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/bin/codex resume 019fb458-7913-77f1-aac0-05c0aa703f1c'
  if output="$(run_resolver "$home" "$rows")"; then
    rc=0
  else
    rc=$?
  fi

  [ "$rc" -ne 0 ] || fail "uuid resume should not use stale process-log title: $output"
  assert_eq "uuid resume rejects generated title instead of stealing stale name" "" "$output"
}

test_resume_alias_can_fall_back_to_state_db() {
  local home
  local output
  local rows

  home="$(new_codex_home)"
  sqlite3 "$home/state_5.sqlite" <<'SQL'
insert into threads (id, title, first_user_message, updated_at) values ('019fb220-a90a-7502-afca-09529e663393', 'dark', '$home latest dark', 1785419141);
SQL

  rows=$'100 1 bash -bash\n101 100 MainThread node /home/alborz/.nvm/versions/node/v24.13.0/bin/codex resume dark\n102 101 codex /home/alborz/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/bin/codex resume dark'
  output="$(run_resolver "$home" "$rows")"

  assert_eq "resume alias resolves from state db without session index" \
    $'019fb220-a90a-7502-afca-09529e663393\tdark\tstrong' \
    "$output"
}

test_uuid_resume_follows_thread_fork_in_same_process() {
  local home
  local output
  local rows

  # The session was launched on 019fb458 and has since forked to 019fe0b0
  # inside the same running process, which is where the user's name now lives.
  home="$(new_codex_home)"
  sqlite3 "$home/state_5.sqlite" <<'SQL'
insert into threads (id, title, first_user_message, updated_at) values ('019fb458-7913-77f1-aac0-05c0aa703f1c', '$home start the karaoke run', '$home start the karaoke run', 1785441501);
insert into threads (id, title, first_user_message, updated_at) values ('019fe0b0-43e8-7c13-a886-10740fecb883', 'karaoke', '$home start the karaoke run', 1786181077);
SQL
  cat > "$home/session_index.jsonl" <<'JSONL'
{"id":"019fe0b0-43e8-7c13-a886-10740fecb883","thread_name":"karaoke","updated_at":"2026-08-08T11:56:55.098579381Z"}
JSONL
  sqlite3 "$home/logs_2.sqlite" <<'SQL'
insert into logs values ('pid:202:5f1c8d2e-live', '019fb458-7913-77f1-aac0-05c0aa703f1c', 1786181000, 1);
insert into logs values ('pid:202:5f1c8d2e-live', '019fe0b0-43e8-7c13-a886-10740fecb883', 1786181076, 1);
SQL

  rows=$'100 1 bash -bash\n101 100 MainThread node /home/alborz/.nvm/versions/node/v24.13.0/bin/codex resume 019fb458-7913-77f1-aac0-05c0aa703f1c\n202 101 codex /home/alborz/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/bin/codex resume 019fb458-7913-77f1-aac0-05c0aa703f1c'
  output="$(run_resolver "$home" "$rows")"

  assert_eq "uuid resume follows a thread fork inside the same process" \
    $'019fe0b0-43e8-7c13-a886-10740fecb883\tkaraoke\tweak' \
    "$output"
}

test_uuid_resume_ignores_fork_from_other_process_incarnation() {
  local home
  local output
  local rc
  local rows

  # Same pid, but the named thread was written by an earlier incarnation with a
  # different process_uuid, so it is a different session and must not be used.
  home="$(new_codex_home)"
  sqlite3 "$home/state_5.sqlite" <<'SQL'
insert into threads (id, title, first_user_message, updated_at) values ('019fb458-7913-77f1-aac0-05c0aa703f1c', '$home start the karaoke run', '$home start the karaoke run', 1785441501);
insert into threads (id, title, first_user_message, updated_at) values ('019fe0b0-43e8-7c13-a886-10740fecb883', 'karaoke', '$home unrelated session', 1786181077);
SQL
  cat > "$home/session_index.jsonl" <<'JSONL'
{"id":"019fe0b0-43e8-7c13-a886-10740fecb883","thread_name":"karaoke","updated_at":"2026-08-08T11:56:55.098579381Z"}
JSONL
  sqlite3 "$home/logs_2.sqlite" <<'SQL'
insert into logs values ('pid:202:5f1c8d2e-live', '019fb458-7913-77f1-aac0-05c0aa703f1c', 1786181000, 1);
insert into logs values ('pid:202:0000aaaa-old', '019fe0b0-43e8-7c13-a886-10740fecb883', 1786181076, 1);
SQL

  rows=$'100 1 bash -bash\n101 100 MainThread node /home/alborz/.nvm/versions/node/v24.13.0/bin/codex resume 019fb458-7913-77f1-aac0-05c0aa703f1c\n202 101 codex /home/alborz/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/bin/codex resume 019fb458-7913-77f1-aac0-05c0aa703f1c'
  if output="$(run_resolver "$home" "$rows")"; then
    rc=0
  else
    rc=$?
  fi

  [ "$rc" -ne 0 ] || fail "reused pid should not adopt another incarnation's name: $output"
  assert_eq "uuid resume ignores a fork from another process incarnation" "" "$output"
}

test_uuid_resume_ignores_names_from_other_sessions_sharing_the_anchor() {
  local home
  local output
  local rc
  local rows

  # A thread outlives the run that created it, so an older unrelated session
  # (different pid) also has log rows against the anchor thread. Its own named
  # thread must not be reachable through that shared anchor.
  home="$(new_codex_home)"
  sqlite3 "$home/state_5.sqlite" <<'SQL'
insert into threads (id, title, first_user_message, updated_at) values ('019fffee-d224-79e2-91f0-b24bbb5d970b', '$work investigate the roadmap', '$work investigate the roadmap', 1786709454);
insert into threads (id, title, first_user_message, updated_at) values ('01a00013-3603-7c70-847d-1350141e33ee', '$work could our next steps be smaller', '$work could our next steps be smaller', 1786711357);
insert into threads (id, title, first_user_message, updated_at) values ('019fff56-4c5a-7c11-baf9-cebb2ade6018', 'llm2', '$work a different session entirely', 1786400000);
SQL
  cat > "$home/session_index.jsonl" <<'JSONL'
{"id":"019fff56-4c5a-7c11-baf9-cebb2ade6018","thread_name":"llm2","updated_at":"2026-08-14T08:14:33.762449172Z"}
JSONL
  sqlite3 "$home/logs_2.sqlite" <<'SQL'
insert into logs values ('pid:202:25546991-live', '019fffee-d224-79e2-91f0-b24bbb5d970b', 1786709454, 1);
insert into logs values ('pid:202:25546991-live', '01a00013-3603-7c70-847d-1350141e33ee', 1786711357, 1);
insert into logs values ('pid:999:aaaaaaaa-older', '019fffee-d224-79e2-91f0-b24bbb5d970b', 1786400000, 1);
insert into logs values ('pid:999:aaaaaaaa-older', '019fff56-4c5a-7c11-baf9-cebb2ade6018', 1786400001, 1);
SQL

  rows=$'100 1 bash -bash\n101 100 MainThread node /home/alborz/.nvm/versions/node/v24.13.0/bin/codex resume 019fffee-d224-79e2-91f0-b24bbb5d970b\n202 101 codex /home/alborz/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/bin/codex resume 019fffee-d224-79e2-91f0-b24bbb5d970b'
  if output="$(run_resolver "$home" "$rows")"; then
    rc=0
  else
    rc=$?
  fi

  [ "$rc" -ne 0 ] || fail "anchor shared with an older session leaked a name: $output"
  assert_eq "uuid resume ignores names reached through a shared anchor thread" "" "$output"
}

# A session started as a plain `codex`, with no resume argument, offers no
# handle at all: no thread id in the environment, no uuid or alias to look up, no
# shell snapshot unless a tool happens to be running, and the log database is off
# by default. Such a window could never be named, however many times the session
# was renamed inside codex. Correlating on the directory the process was started
# in and the moment it started is what is left.
#
# A real pid is used as the stand-in for codex, because the resolver reads the
# start time from /proc. $$ is the test's own shell, which is guaranteed to be
# there and to have a start time the fixture can be written around.
seed_cwd_start_home() {
  local home="$1"
  local cwd="$2"
  local start="$3"

  # Newest first, which is the order the query returns. The compaction thread is
  # the one a naive "most recent thread here" match would take.
  sqlite3 "$home/state_5.sqlite" <<SQL
insert into threads (id, title, first_user_message, updated_at, cwd, created_at_ms)
values ('01a0423f-b87d-7bc0-99c9-9b97c7d3e4e2', 'The following is the agent history', 'The following is the agent history', 2, '$cwd', $(( (start + 4) * 1000 )));
insert into threads (id, title, first_user_message, updated_at, cwd, created_at_ms)
values ('01a0423f-b610-7662-b95e-1a4bb0858c34', 'investigate the failing job', 'investigate the failing job', 1, '$cwd', $(( (start + 3) * 1000 )));
SQL
  cat > "$home/session_index.jsonl" <<'JSONL'
{"id":"01a0423f-b610-7662-b95e-1a4bb0858c34","thread_name":"llm4","updated_at":"2026-08-27T08:33:50.609366552Z"}
JSONL
}

test_bare_codex_resolves_by_cwd_and_start_time() {
  local home cwd start rows output

  home="$(new_codex_home)"
  cwd="$tmp_root/ufst"
  mkdir -p "$cwd"
  start="$(stat -c %Y "/proc/$$")"
  seed_cwd_start_home "$home" "$cwd" "$start"

  rows="$$ 1 codex /opt/codex"
  output="$(CODEX_HOME="$home" AI_SESSION_NAME_REPORT_ID=1 "$script" "$$" "$cwd" "" "$rows")"

  # The renamed thread wins over the newer compaction thread, which carries no
  # name and whose title is only its first message. Weak, so the renamer
  # debounces before claiming the window.
  assert_eq "bare codex resolves through cwd and start time" \
    "$(printf '01a0423f-b610-7662-b95e-1a4bb0858c34\tllm4\tweak')" "$output"
}

test_bare_codex_ignores_threads_from_another_directory() {
  local home cwd start rows output rc

  home="$(new_codex_home)"
  cwd="$tmp_root/elsewhere"
  mkdir -p "$cwd"
  start="$(stat -c %Y "/proc/$$")"
  seed_cwd_start_home "$home" "$tmp_root/ufst" "$start"

  rows="$$ 1 codex /opt/codex"
  if output="$(CODEX_HOME="$home" AI_SESSION_NAME_REPORT_ID=1 "$script" "$$" "$cwd" "" "$rows")"; then
    rc=0
  else
    rc=$?
  fi

  [ "$rc" -ne 0 ] || fail "adopted a name from a thread in another directory: $output"
  assert_eq "bare codex ignores threads started elsewhere" "" "$output"
}

test_bare_codex_ignores_threads_outside_the_start_window() {
  local home cwd start rows output rc

  home="$(new_codex_home)"
  cwd="$tmp_root/ufst-late"
  mkdir -p "$cwd"
  start="$(stat -c %Y "/proc/$$")"
  # Same directory, but created well outside the window: a different session
  # that happened to run here earlier.
  seed_cwd_start_home "$home" "$cwd" "$(( start - 4000 ))"

  rows="$$ 1 codex /opt/codex"
  if output="$(CODEX_HOME="$home" AI_SESSION_NAME_REPORT_ID=1 "$script" "$$" "$cwd" "" "$rows")"; then
    rc=0
  else
    rc=$?
  fi

  [ "$rc" -ne 0 ] || fail "adopted a name from a thread outside the start window: $output"
  assert_eq "bare codex ignores threads outside the start window" "" "$output"
}

test_resume_alias_uses_latest_index_match
test_logs_db_fallback_is_disabled_by_default
test_bare_codex_resolves_by_cwd_and_start_time
test_bare_codex_ignores_threads_from_another_directory
test_bare_codex_ignores_threads_outside_the_start_window
test_uuid_resume_does_not_steal_stale_process_log_name
test_uuid_resume_ignores_names_from_other_sessions_sharing_the_anchor
test_resume_alias_can_fall_back_to_state_db
test_uuid_resume_follows_thread_fork_in_same_process
test_uuid_resume_ignores_fork_from_other_process_incarnation

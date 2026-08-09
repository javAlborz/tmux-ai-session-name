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
  updated_at integer
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

  CODEX_HOME="$home" AI_SESSION_NAME_REPORT_ID=1 "$script" 100 "" "" "$rows"
}

test_resume_alias_uses_latest_index_match() {
  local home
  local output
  local rows

  home="$(new_codex_home)"
  sqlite3 "$home/state_5.sqlite" <<'SQL'
insert into threads values ('019faa21-7632-7ed2-ab2d-9d0142c056af', 'dark', '$home first dark', 1785330881);
insert into threads values ('019fb220-a90a-7502-afca-09529e663393', 'dark', '$home latest dark', 1785419141);
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
insert into threads values ('019fb458-7913-77f1-aac0-05c0aa703f1c', '$home I bougth my gf a new macboook', '$home I bougth my gf a new macboook', 1785441501);
insert into threads values ('019fe0b0-43e8-7c13-a886-10740fecb883', 'mac', '$home I bougth my gf a new macboook', 1786181077);
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
insert into threads values ('019fb220-a90a-7502-afca-09529e663393', 'dark', '$home latest dark', 1785419141);
SQL

  rows=$'100 1 bash -bash\n101 100 MainThread node /home/alborz/.nvm/versions/node/v24.13.0/bin/codex resume dark\n102 101 codex /home/alborz/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/bin/codex resume dark'
  output="$(run_resolver "$home" "$rows")"

  assert_eq "resume alias resolves from state db without session index" \
    $'019fb220-a90a-7502-afca-09529e663393\tdark\tstrong' \
    "$output"
}

test_resume_alias_uses_latest_index_match
test_uuid_resume_does_not_steal_stale_process_log_name
test_resume_alias_can_fall_back_to_state_db

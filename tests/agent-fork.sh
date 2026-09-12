#!/usr/bin/env bash
# Behavioural test for agent-fork.sh (prefix + B). Runs against a throwaway tmux
# server with stand-in processes, so it never launches a real agent or forks a
# real session. Asserts the composed command via AGENT_FORK_DRY_RUN.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/agent-fork.sh"
socket="agent-fork-test-$$"
tmp="$(mktemp -d)"
export XDG_STATE_HOME="$tmp/state"
real_tmux="$(command -v tmux)"

cleanup() {
  env -u TMUX "$real_tmux" -L "$socket" kill-server >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok()   { printf 'ok - %s\n' "$1"; }

t() { env -u TMUX "$real_tmux" -L "$socket" "$@"; }

# The helper calls bare `tmux`, so shim it onto this test's socket. The shim must
# exec tmux by ABSOLUTE path: it is itself named `tmux` and sits first on PATH.
shim="$tmp/bin"
mkdir -p "$shim"
printf '#!/usr/bin/env bash\nexec env -u TMUX %s -L %s "$@"\n' "$real_tmux" "$socket" > "$shim/tmux"
chmod +x "$shim/tmux"

run() { PATH="$shim:$PATH" AGENT_FORK_DRY_RUN=1 bash "$script" "$@" 2>&1; }

# A stand-in whose process name is the client we want detected.
make_client() {
  local name="$1"
  local fixture_env="${2:-}"
  [ -e "$tmp/$name" ] || cp /usr/bin/sleep "$tmp/$name"
  t kill-session -t probe 2>/dev/null || true
  if [ "$name" = codex ]; then
    mkdir -p "$tmp/codex-home/sessions"
    printf '{"type":"session_meta","payload":{"id":"%s","source":"cli"}}\n' "$id" > "$tmp/codex-home/sessions/rollout-fixture.jsonl"
    t -f /dev/null new-session -d -s probe -c "$tmp" "env CODEX_HOME=$tmp/codex-home $tmp/$name 120 7<$tmp/codex-home/sessions/rollout-fixture.jsonl"
  else
    t -f /dev/null new-session -d -s probe -c "$tmp" "$fixture_env $tmp/$name 120"
  fi
  # Do not load the user's plugins: a live naming daemon can take the rename
  # lock while this test expects a synchronous pass. Set the expected format
  # explicitly instead of inheriting it from the user's tmux configuration.
  t set-option -g @ai-session-name-format '#{session}'
  sleep 0.5
  t list-windows -F '#{window_id}' | head -1
}

id="0f9c1a22-1111-2222-3333-444455556666"

# --- codex: id known -> exact fork, and no name flag (it takes a prompt) ------
win="$(make_client codex)"
t set-window-option -t "$win" @ai-session-name-thread-id "$id"
out="$(run "$win" myfork)"
case "$out" in *"codex fork $id"*) ;; *) fail "codex: expected exact fork, got: $out" ;; esac
case "$out" in *"-n myfork"*|*"--name myfork"*) fail "codex: must not pass a name flag: $out" ;; esac
ok "codex forks the verified open thread, without a name flag"

# Window metadata may be stale, absent, or malformed. The live file wins.
for cached in '' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' 'bad; printf injected'; do
  t set-window-option -t "$win" @ai-session-name-thread-id "$cached"
  out="$(run "$win" myfork)"
  case "$out" in *"codex fork $id"*) ;; *) fail "cached identity overrode the open session: $out" ;; esac
done
ok "missing, stale and malformed recorded IDs cannot redirect the branch"
rm "$tmp/codex-home/sessions/rollout-fixture.jsonl"
out="$(run "$win" myfork)"
case "$out" in *"cannot verify the current Codex session"*) ;; *) fail "unverified session was branchable: $out" ;; esac
ok "an unverified current session is not branched"

# Naming and branch identity remain independent for unnamed/manual windows.
win="$(make_client codex)"
renamer="${script%/*}/rename-windows.sh"
rename_pass() { PATH="$shim:$PATH" AI_SESSION_NAME_PLUGIN_DIR="${script%/scripts/agent-fork.sh}" AI_SESSION_NAME_RUNTIME_DIR="$tmp" bash "$renamer"; }
t rename-window -t "$win" manual-base
rename_pass
[ "$(t show-options -wqv -t "$win" @ai-session-name-thread-id)" = "$id" ] || fail "unnamed session identity was lost"
[ "$(t display-message -pt "$win" '#{window_name}')" = manual-base ] || fail "unnamed session overwrote a manual name"
printf '{"id":"%s","thread_name":"Current session"}\n' "$id" > "$tmp/codex-home/session_index.jsonl"
rename_pass
[ "$(t display-message -pt "$win" '#{window_name}')" = manual-base ] || fail "a saved title overwrote an explicit window name"
t set-window-option -t "$win" automatic-rename on
rename_pass
[ "$(t display-message -pt "$win" '#{window_name}')" = 'Current session' ] || fail "named current session was not adopted"
t select-pane -t "$win" -T ''
rename_pass
[ "$(t show-options -wqv -t "$win" @ai-session-name-owned)" = 1 ] || fail "empty pane title falsely released naming ownership"
t rename-window -t "$win" pinned-name
rename_pass
[ "$(t display-message -pt "$win" '#{window_name}')" = pinned-name ] || fail "manual override was not preserved"
[ "$(t show-options -wqv -t "$win" @ai-session-name-thread-id)" = "$id" ] || fail "manual override erased branch identity"
ok "unnamed and manually named windows retain a verified branch identity"

# --- pi: id known -> fork + name in one go ----------------------------------
win="$(make_client pi)"
t set-window-option -t "$win" @ai-session-name-thread-id "$id"
out="$(run "$win" pifork)"
case "$out" in *"pi --fork $id"*) ;; *) fail "pi: expected --fork with id, got: $out" ;; esac
case "$out" in *"--name pifork"*) ;; *) fail "pi: expected --name, got: $out" ;; esac
ok "pi forks by id and names the fork at launch"

# --- pi: the generic provider's synthetic pane:<pid> is NOT a session id -----
t set-window-option -t "$win" @ai-session-name-thread-id "pane:12345"
out="$(run "$win" pifork)"
case "$out" in *"--fork"*) fail "pi: passed a synthetic pane id to --fork: $out" ;; esac
case "$out" in *"no recorded session ID"*) ;; *) fail "pi: expected missing-ID notice, got: $out" ;; esac
case "$out" in *"pi --resume"*) fail "pi must not resume the original session as a fork: $out" ;; esac
ok "pi refuses to resume the original when no forkable identity exists"

# --- claude: picker, since the plugin records no identity for Claude ---------
win="$(make_client claude)"
out="$(run "$win" cfork)"
case "$out" in *"claude --resume --fork-session"*) ;; *) fail "claude: got: $out" ;; esac
case "$out" in *"-n cfork"*) ;; *) fail "claude: expected -n, got: $out" ;; esac
ok "claude forks via its picker and names the fork"

# --- a name with shell metacharacters must be escaped, never injected --------
win="$(make_client pi)"
t set-window-option -t "$win" @ai-session-name-thread-id "$id"
out="$(run "$win" 'my fork; echo pwned')"
case "$out" in *"--name my\\ fork\\;"*) ;; *) fail "name not escaped: $out" ;; esac
ok "a name containing shell metacharacters is escaped"

# --- a window with no agent must say so, not compose a bogus command --------
win="$(make_client sleep)"
out="$(run "$win" x)"
case "$out" in *"no agent session"*) ;; *) fail "expected no-agent notice, got: $out" ;; esac
ok "a window with no agent is reported rather than forked"

# --- bad input -------------------------------------------------------------
out="$(run)"          ; case "$out" in *"no window given"*) ;; *) fail "expected no-window notice: $out" ;; esac
out="$(run @999999 x)"; case "$out" in *"cannot resolve pane"*) ;; *) fail "expected unresolvable notice: $out" ;; esac
ok "missing and unresolvable windows are handled"

# --- the name is only asked for where it can be applied ---------------------
# Codex takes no name flag, so prompting there meant typing the name twice: once
# into a prompt that could not use it, then again as /rename inside the fork.
win="$(make_client codex)"
t set-window-option -t "$win" @ai-session-name-thread-id "$id"
out="$(run "$win")"
case "$out" in *"would prompt"*) fail "codex must not prompt for a name: $out" ;; esac
case "$out" in *"codex fork $id"*) ;; *) fail "codex should fork straight away: $out" ;; esac
ok "codex forks without asking for a name it cannot use"

for client in claude pi; do
  win="$(make_client "$client")"
  t set-window-option -t "$win" @ai-session-name-thread-id "$id"
  out="$(run "$win")"
  case "$out" in *"would prompt"*) ;; *) fail "$client should ask for a name: $out" ;; esac
done
ok "claude and pi are asked for a name, which they apply at launch"

win="$(make_client pi 'env PI_SAFE_LANE=home PI_SAFE_TMUX_RUN=/tmp/fixture-run')"
out="$(run "$win" 'secure branch')"
case "$out" in *"secure branch via pi-safe-tmux"*) ;; *) fail "secure Pi did not select its restricted bridge: $out" ;; esac
case "$out" in *"pi --fork"*|*"pi --resume"*) fail "secure Pi reached an unrestricted launch: $out" ;; esac
ok "secure Pi selects its own bridge instead of the public pi alias"

win="$(make_client pi 'env PI_SAFE_LANE=home')"
out="$(run "$win" 'secure branch')"
case "$out" in *"restart this secure Pi session"*) ;; *) fail "old secure Pi should request a restart: $out" ;; esac
ok "older secure Pi processes report that the bridge requires a restart"

printf 'all agent-fork tests passed\n'

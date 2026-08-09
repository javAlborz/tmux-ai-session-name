# tmux-ai-session-name

Rename tmux windows from explicitly named coding sessions.

The plugin watches the active pane in each tmux window. It resolves explicit
session names from Claude Code, Codex, and clients that expose the generic JSONL
session-directory contract described below.

## Install

With TPM:

```tmux
set -g @plugin 'javAlborz/tmux-ai-session-name'
```

Or source it directly:

```tmux
run-shell ~/.tmux/plugins/tmux-ai-session-name/ai-session-name.tmux
```

## Options

```tmux
set -g @ai-session-name-enabled 'on'
set -g @ai-session-name-interval '5'
set -g @ai-session-name-format '#{session}'
set -g @ai-session-name-max-length '60'
set -g @ai-session-name-restore 'off'
set -g @ai-session-name-restore-unnamed 'off'
set -g @ai-session-name-release-unnamed-after '10'
set -g @ai-session-name-debounce-ticks '2'
set -g @ai-session-name-fallback ''
```

`@ai-session-name-restore` renames a window back when the active pane is no
longer a supported client. It restores both the previous name and the previous
`automatic-rename` state. By default it is off because many people manually
name tmux windows.

`@ai-session-name-restore-unnamed` can rename supported-client windows without
an explicit name to the active pane command. It defaults to off because process
trees can change while a session is active, and aggressive restore can race
explicitly named sessions.

`@ai-session-name-release-unnamed-after` controls how long, in seconds, a
plugin-owned window with a still-running AI process but no resolvable explicit
session name is kept before ownership is released and the previous window name is
restored. It defaults to `10`, so transient misses keep the last resolved agent
session name briefly before releasing stale ownership.

`@ai-session-name-debounce-ticks` controls how many consecutive daemon passes a
weak match must survive before it can rename a window. It defaults to `2`.
Strong matches from explicit process identity and Claude Code names are not
debounced.

The plugin does not change tmux's `allow-rename` option. When it claims a window,
it remembers the current name and `automatic-rename` state, then pauses automatic
naming. When it releases the window, it restores both. A manual `rename-window`
while the plugin owns a window releases ownership and wins until that detected
session goes away.

Reloading tmux configuration is safe: the plugin owns one indexed self-heal
hook per event and removes append-only hook entries left by older releases.
Its polling loop also skips tmux option writes when the resolved name and
ownership state have not changed.

## Detection

Claude Code names are read from `--name`/`-n` arguments or from `/rename`
records in Claude's project JSONL files. Auto-generated pane titles are ignored.

Codex names are resolved by mapping the live Codex process to a thread, then
reading that thread's `title` from `~/.codex/state_5.sqlite` only when it appears
user-provided. Generated titles are ignored by requiring `title` to differ from
`first_user_message`, or for `first_user_message` to be empty.

Codex thread identity is resolved in priority order: explicit environment or
resume UUID, shell snapshot UUID, `codex resume <name>` alias, then weak process
log history. The alias path uses the newest matching Codex session index/state
entry. It is intentionally lower priority than a UUID so an active fork cannot
inherit an older name from stale logs.

The generic provider detects an environment variable whose name ends in
`SESSION_DIR` on the pane process or one of its descendants. Stock Pi is also
supported through its default `~/.pi/agent/sessions/<encoded-cwd>` layout when
no session-directory variable is exported. The provider examines JSONL files
in the resolved directory and reads only:

- `id` and `cwd` from the initial `type: "session"` record
- the latest non-empty `name` from a `type: "session_info"` record

An open session-file descriptor is treated as a strong process-to-session
match. Otherwise, an explicit session name must match the pane-local terminal
title. The provider never guesses from the newest file by working directory,
because several live sessions commonly share both the directory and session
store. The generic provider requires `jq`.

## Test

```sh
tests/run.sh
```

The test uses an isolated tmux server and covers provider metadata, dispatcher
identity, automatic-name restoration, global application-rename policy, and
manual override ownership.

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

The optional `@ai-session-name-fork-key` binding opens a new window for a branch.
Claude and Pi ask for the branch name in a tmux popup; input is read literally
and an empty name cancels. Pi requires a real session ID instead of falling back
to resuming the original session. Secure Pi processes advertising
`PI_SAFE_TMUX_RUN` use the host's `~/bin/pi-safe-tmux` bridge and preserve their
security lane. Older secure Pi processes must be restarted to load that bridge.

Claude Code names are read from verified `/rename` records in Claude's project
JSONL files, then from `--name`/`-n` launch arguments. Arguments retain their
original NUL boundaries. Auto-generated pane titles are ignored.

On Linux, Codex identity comes first from the primary foreground process's open
rollout headers. Auxiliary threads are excluded. When an in-process fork retains
ancestor writers, an explicit chain with one leaf identifies the current
session; unrelated open sessions remain ambiguous. This live check runs before
cached names or launch arguments, which can become stale after a session switch.

Codex display names use the current database's `name` column. Older schemas
retain the `title` fallback only when it differs from `first_user_message` or
that message is empty. An unnamed live session still has a usable identity.
Launch UUIDs, shell snapshots, resume aliases and opt-in process log history
remain compatibility fallbacks for naming when live identity is unavailable.

The fork binding refreshes Codex identity when pressed and requires a unique
live session. It refuses an unverified source instead of using the daemon's
stored window ID. Codex is renamed inside the branch with `/rename`; Claude
uses its native session picker before branching.

Claude Code windows deliberately carry no identity, so `@ai-session-name-thread-id`
stays unset for them. Claude exposes no stable per-session id to the pane: the
`claude` process environment has none, it does not hold its transcript open, and
`CLAUDE_CODE_SESSION_ID` exists only inside the transient subprocesses it spawns
for tool calls — an idle pane has no descendant at all. An identity read from
there would appear and vanish between passes and churn the window state, and the
transcript that holds the rename record is not a substitute: two sessions sharing
a name match the same file, which would look like one window stealing another's
identity. Name resolution does not need an identity, so none is reported.

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

The suite uses isolated tmux servers and covers provider metadata, live session
identity, automatic-name restoration, global application-rename policy, manual
override ownership, fork dispatch, and popup input. It never forks a real agent
session.

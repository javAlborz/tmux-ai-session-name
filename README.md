# tmux-ai-session-name

Rename tmux windows from explicitly named Claude Code or Codex sessions.

The plugin watches the active pane in each tmux window. If it sees Claude Code or
Codex in the pane's process tree, it tries to resolve a user-provided session
name and renames the window.

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
longer Claude or Codex. By default it is off because many people manually name
tmux windows.

`@ai-session-name-restore-unnamed` can rename Claude/Codex windows without an
explicit name back to the active pane directory basename. It defaults to off
because Codex process trees can change while a session is active, and aggressive
restore can race explicitly named sessions.

`@ai-session-name-release-unnamed-after` controls how long, in seconds, a
plugin-owned window with a still-running AI process but no resolvable explicit
session name is kept before ownership is released and the previous window name is
restored. It defaults to `10`, so transient misses keep the last resolved agent
session name briefly before releasing stale ownership.

`@ai-session-name-debounce-ticks` controls how many consecutive daemon passes a
weak Codex match must survive before it can rename a window. It defaults to `2`.
Strong Codex matches from explicit process identity and Claude Code names are not
debounced.

## Detection

Claude Code names are read from `--name`/`-n` arguments or from `/rename`
records in Claude's project JSONL files. Auto-generated pane titles are ignored.

Codex names are resolved by mapping the live Codex process to a thread, then
reading that thread's `title` from `~/.codex/state_5.sqlite` only when it appears
user-provided. Generated titles are ignored by requiring `title` to differ from
`first_user_message`, or for `first_user_message` to be empty.

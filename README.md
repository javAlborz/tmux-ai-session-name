# tmux-ai-session-name

Rename tmux windows from the active Claude Code or Codex session in that window.

The plugin watches the active pane in each tmux window. If it sees Claude Code or
Codex in the pane's process tree, it tries to resolve a useful session name and
renames the window.

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
set -g @ai-session-name-fallback ''
```

`@ai-session-name-restore` renames a window back when the active pane is no
longer Claude or Codex. By default it is off because many people manually name
tmux windows.

## Detection

Claude Code names are read from the pane title first, then from `--name`/`-n`
arguments.

Codex names are read from an explicit Codex-prefixed pane title first. If that is
not available, the plugin maps the live Codex process to a thread by reading
`CODEX_THREAD_ID`, by parsing Codex shell snapshot paths from the active process
tree, or by matching a thread title to the Codex process start time. It
deliberately avoids using "latest session in this directory" because that can
rename a clean Codex session to the previous session's title.

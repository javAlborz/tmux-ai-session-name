# tmux-ai-session-name

## Shared distribution and Pi status

The `tmux-ai-session-generic` release artifact contains the same naming engine
and JSONL provider as this plugin, plus the shared status renderer and Pi
extension. Its provider dispatcher includes only generic session metadata and
Pi detection. Product-specific providers and branching remain available in the
full plugin. No downstream source rewriting is needed.

Build an artifact from a clean release commit:

```sh
python3 scripts/build-release.py --out dist
```

Publish the archive and `SHA256SUMS` together. Consumers pin the archive hash;
`manifest.json` also records the upstream commit and every installed file hash.
The archive can be mirrored without changing its bytes. Runtime requirements
are tmux 3.3+, Python 3.6+, Bash, jq, flock, and standard Linux utilities.

Extract under a shared, read-only directory such as `/opt/tmux-ai-session/0.1.1`.
All executable paths are relative to that installation. Run its controller
after user configuration loads, passing the user's socket explicitly:

```sh
python3 /opt/tmux-ai-session/0.1.1/shared/integration.py activate --socket /path/to/socket
```

The controller adds a marker to existing window formats and installs indexed
hooks. It preserves themes, local styles and key bindings. `deactivate` removes
the owned marker/hooks and stops workers without terminating sessions. Set
`@ai-session-name-format '#{session}'` for unprefixed window names. Naming options
and manual override behaviour are shared with the full plugin.

Load `pi/tmux-session-status.ts` as a Pi extension. By default it sends lifecycle
events directly to the adjacent status renderer. Set `PI_TMUX_STATUS_FILE` to
use file delivery inside a sandbox; this mode never calls tmux or host helpers.
The host adapter must validate and translate the bounded snapshot containing
`id`, `name`, `state`, and `revision`. States are `idle`, `working`, `waiting`,
`done`, and `closed`. Dialogs retain waiting status until all nested dialogs
finish. Noninteractive Pi sessions publish nothing.

Trusted host launchers can pass a helper callback as the extension's second
argument, preserving a narrower host capability without duplicating lifecycle
logic. The callback accepts `ai-unread-clear`, `ai-waiting-set`, and
`ai-unread-set`; it cannot be selected by a model or dialog answer.

Additional release checks:

```sh
npm ci --ignore-scripts
npm run test:pi
python3 tests/shared-distribution.py
```

These checks exercise both Pi transports, packaged naming/manual overrides,
reproducible archives, and shared installation under a path containing spaces.

Follow coding session titles while preserving explicit tmux window names.

The plugin watches the active pane in each tmux window. It resolves saved
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
set -g @ai-session-name-diagnostics 'on'
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
releases ownership and wins across detection failures and conversation changes.
Names set before the plugin's first pass, including `new-window -n`, are also
preserved when tmux has disabled automatic naming locally. Inherited global
`automatic-rename` settings do not imply that a particular window was named.
The current conversation ID continues to update under a manual display name.

Use the usual tmux `prefix+,` to name a window. To let it follow session titles
again, run `set-window-option automatic-rename on` from the tmux command prompt
(`prefix+:`). `/rename` inside Codex changes that conversation's saved title;
an explicit tmux window name takes precedence over it.

Diagnostics record name, ownership and conversation-ID transitions in
`${XDG_STATE_HOME:-~/.local/state}/tmux-ai-session-name/events.jsonl`. Files are
private to the user and rotate at 256 KiB, keeping one previous file (512 KiB
maximum combined). Unchanged polls produce no events. The log contains tmux
server/window/pane IDs and old/new values, without transcripts or process
environments. Set `@ai-session-name-diagnostics off` to disable recording. The
log explains the plugin's decisions; it does not capture Codex UI keystrokes.

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
that message is empty. Current Codex can generate titles automatically, and
its saved-name metadata does not distinguish those from `/rename`. The plugin
therefore treats these as display titles, not proof of a manual choice. A user
who wants a window label to survive `/new`, `/resume` or `/fork` should name the
tmux window. An unnamed live session still has a usable identity.
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
override ownership before and after claiming a window, failed detections,
conversation switches, diagnostic bounds, fork dispatch, and popup input. It
never forks a real agent session.

### Status adapters

The shared renderer exposes `Status.accept_event(row, event, payload)` to reject
stale lifecycle events and `Status.reconcile(row, event, payload)` to repair
pane state before window aggregation. Both run under the per-server state lock.
Adapters can extend `Status.fields` with their pane options; keep `pane_title`
last so embedded tabs remain part of the title. Lifecycle events receive the
JSON hook payload. The default adapter preserves hook behavior.

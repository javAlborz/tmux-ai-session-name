#!/usr/bin/env python3
"""Exercise Codex fork dispatch in isolated tmux; no real Codex is launched."""
import json
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import tempfile
import time

plugin = Path(__file__).resolve().parents[1]
tmux = shutil.which("tmux")
socket = f"codex-fork-picker-test-{os.getpid()}"
live_id = "0f9c1a22-1111-2222-3333-444455556666"
stale_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
env = dict(os.environ, TERM="xterm-256color")
for key in ("TMUX", "CODEX_HOME", "CODEX_THREAD_ID", "AGENT_FORK_DRY_RUN"):
    env.pop(key, None)


def wait_for(probe):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        result = probe()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("timed out waiting for tmux fixture")


with tempfile.TemporaryDirectory(prefix="codex-fork-picker-") as tmp:
    root = Path(tmp)
    bindir = root / "bin"
    bindir.mkdir()
    standin = root / "standin"
    standin.mkdir()
    shutil.copy("/usr/bin/sleep", standin / "codex")
    cwd = root / "project with spaces"
    cwd.mkdir()
    home = root / "profile ' $(touch INJECTED)"
    (home / "sessions").mkdir(parents=True)
    index = json.dumps({
        "id": stale_id, "thread_name": "Old session",
    }, separators=(",", ":")) + "\n"
    (home / "session_index.jsonl").write_text(index)
    # The naming compatibility fallback reads the helper's default home. Make
    # it return a plausible stale ID, while the new client must inherit the
    # source's different explicit home instead of this one.
    default_home = root / "default-home"
    default_home.mkdir()
    (default_home / "session_index.jsonl").write_text(index)
    env["CODEX_HOME"] = str(default_home)
    rollout = home / "sessions/rollout-fixture.jsonl"
    log = root / "launch.json"
    (bindir / "codex").write_text(
        "#!/usr/bin/python3\nimport json,os,sys,time\n"
        f"with open({str(log)!r}, 'w') as f:\n"
        "    json.dump({'argv': sys.argv[1:], 'cwd': os.getcwd(), "
        "'home': os.environ.get('CODEX_HOME')}, f)\n"
        "time.sleep(60)\n"
    )
    (bindir / "codex").chmod(0o755)
    (bindir / "tmux").write_text(
        f'#!/bin/sh\nexec {shlex.quote(tmux)} -L {shlex.quote(socket)} "$@"\n'
    )
    (bindir / "tmux").chmod(0o755)
    env["PATH"] = str(bindir) + ":" + env["PATH"]
    env["XDG_STATE_HOME"] = str(root / "state")

    def t(*args):
        return subprocess.run([tmux, "-L", socket, *args], env=env,
                              text=True, capture_output=True, check=True).stdout.strip()

    def stop():
        subprocess.run([tmux, "-L", socket, "kill-server"], env=env, capture_output=True)

    try:
        for mode in ("live", "stale", "duplicate"):
            verified = mode == "live"
            stop()
            socket = f"codex-fork-picker-test-{os.getpid()}-{mode}"
            (bindir / "tmux").write_text(
                f'#!/bin/sh\nexec {shlex.quote(tmux)} -L {shlex.quote(socket)} "$@"\n'
            )
            log.unlink(missing_ok=True)
            command = "exec " + shlex.join(["env", f"CODEX_HOME={home}",
                                  f"CODEX_THREAD_ID={stale_id}",
                                  str(standin / "codex"), "120"])
            if verified:
                rollout.write_text(json.dumps({
                    "type": "session_meta", "payload": {"id": live_id, "source": "cli"},
                }) + "\n")
                command += " 7<" + shlex.quote(str(rollout))
            t("-f", "/dev/null", "new-session", "-d", "-s", "source", "-c", str(cwd), command)
            t("set", "-g", "default-shell", "/bin/bash")
            source = t("list-windows", "-t", "source", "-F", "#{window_id}")
            wait_for(lambda: t("display-message", "-pt", source, "#{pane_current_command}") == "codex")
            t("set-window-option", "-t", source, "@ai-session-name-thread-id", stale_id)
            t("select-pane", "-t", source, "-T", "Old session")
            # A marked pane and another current session must not redirect the launch.
            t("new-session", "-d", "-s", "other", "sleep 120")
            t("select-pane", "-m", "-t", "other:")
            before = t("list-panes", "-t", source, "-F", "#{pane_id}:#{pane_pid}:#{pane_current_path}")
            if not verified:
                result = subprocess.run([
                    str(plugin / "scripts/session-name-for-pane.sh"),
                    t("display-message", "-pt", source, "#{pane_pid}"), str(cwd), "",
                ], env=dict(env, AI_SESSION_NAME_REPORT_ID="1", AI_SESSION_NAME_CACHE_FILE=""),
                    text=True, capture_output=True, check=True).stdout.strip()
                assert result.split("\t") == ["codex", stale_id, "Old session", "strong"], result
            if mode == "duplicate":
                # Both forks have the same saved name. The pane can display
                # it, but that must not select either ID for leader+B.
                for profile in (home, default_home):
                    with sqlite3.connect(profile / "state_5.sqlite") as db:
                        db.execute("create table threads (id text, name text, cwd text, source text, thread_source text)")
                        db.executemany("insert into threads values (?, 'Shared', ?, 'vscode', 'user')",
                                       [(ident, str(cwd)) for ident in (live_id, stale_id)])
                title = "Shared | " + cwd.name
                t("select-pane", "-t", source, "-T", title)
                result = subprocess.run([
                    str(plugin / "scripts/session-name-for-pane.sh"),
                    t("display-message", "-pt", source, "#{pane_pid}"), str(cwd), title,
                ], env=dict(env, AI_SESSION_NAME_REPORT_ID="1", AI_SESSION_NAME_CACHE_FILE=""),
                    text=True, capture_output=True, check=True).stdout.strip()
                assert result.split("\t") == ["codex", "", "Shared", "weak"], result
            subprocess.run(["bash", str(plugin / "scripts/agent-fork.sh"), source],
                           env=env, capture_output=True, text=True, check=True, timeout=10)
            wait_for(log.exists)
            launch = json.loads(log.read_text())
            assert launch == {"argv": ["fork", live_id if verified else "--all"],
                              "cwd": str(cwd), "home": str(home)}, launch
            windows = t("list-windows", "-t", "source", "-F", "#{window_id}").splitlines()
            assert len(windows) == 2 and source in windows, windows
            assert len(t("list-windows", "-t", "other", "-F", "#{window_id}").splitlines()) == 1
            assert t("list-panes", "-t", source, "-F", "#{pane_id}:#{pane_pid}:#{pane_current_path}") == before
            assert not (cwd / "INJECTED").exists(), "CODEX_HOME was evaluated as shell code"
            fork_window = next(w for w in windows if w != source)
            t("send-keys", "-t", fork_window, "C-c")
            wait_for(lambda: t("list-windows", "-t", "source", "-F", "#{window_id}") == source)
            assert t("list-panes", "-t", source, "-F", "#{pane_id}:#{pane_pid}:#{pane_current_path}") == before
            print("ok -", {"live": "verified fork", "stale": "picker despite stale strong identity",
                            "duplicate": "picker despite duplicate display names"}[mode],
                  "opens separately, preserves CODEX_HOME/cwd and leaves source alive on exit")
    finally:
        stop()

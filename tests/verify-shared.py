#!/usr/bin/env python3
"""Verify optional tmux integration on a disposable server without touching user config."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def dependencies():
    for name in ("python3", "jq", "bash", "flock", "setsid", "ps", "awk", "sed", "find",
                 "readlink", "sort", "tr", "head", "tail", "infocmp"):
        if not shutil.which(name):
            raise ValueError("Missing runtime dependency: " + name)
    subprocess.run(["infocmp", "-x", "tmux-256color"], check=True, stdout=subprocess.DEVNULL)
    print("tmux runtime dependencies verified", flush=True)


def verify(prefix):
    prefix = prefix.resolve()
    binary = Path(shutil.which("tmux"))
    integration = prefix / "shared/integration.py"
    with tempfile.TemporaryDirectory(prefix="tmux-shared-verify-") as temporary:
        socket = str(Path(temporary) / "socket")
        command = [str(binary), "-u", "-S", socket]
        def call(*args):
            return subprocess.check_output(command + list(args), universal_newlines=True).rstrip("\n")
        def plugin(action, *args):
            subprocess.run(["/usr/bin/python3", str(integration), action, "--socket", socket] + list(args),
                           check=True)
        def wait_for(format, expected):
            end = time.monotonic() + 8
            while time.monotonic() < end:
                if call("display-message", "-p", format).strip() == expected:
                    return
                time.sleep(0.1)
            raise ValueError("Status did not become " + expected)
        # Synthetic status belongs to a live process, not an empty shell prompt.
        subprocess.run(command + ["-f", "/dev/null", "new-session", "-d", "-s", "test", "sleep 300"],
                       env=dict(os.environ, AI_SESSION_NO_INTEGRATION="1"), check=True)
        try:
            pane = call("display-message", "-p", "#{pane_id}")
            normal = "#[fg=magenta] rounded #I:#W "
            current = "#[fg=green,bold] current #I:#W "
            call("set-option", "-g", "window-status-format", normal)
            call("set-option", "-g", "window-status-current-format", current)
            call("set-option", "-w", "window-status-style", "fg=yellow,bg=blue")
            call("bind-key", "w", "display-message", "custom window picker")
            binding = call("list-keys", "w")
            plugin("activate")
            plugin("activate")
            assert call("show-options", "-gqv", "window-status-format") == "#{E:@ai-session-marker}" + normal
            assert call("show-options", "-gqv", "window-status-current-format") == "#{E:@ai-session-marker}" + current
            assert call("list-keys", "w") == binding
            call("set-option", "-p", "@ai-pane-waiting", "1")
            wait_for("#{E:@ai-session-marker}", "?")
            plugin("view", "--pane", pane)
            assert call("show-options", "-pqv", "@ai-pane-waiting") == "1"
            assert call("show-options", "-wqv", "window-status-style") == "fg=yellow,bg=blue"
            call("set-option", "-p", "@ai-pane-waiting", "0")
            call("set-option", "-p", "@ai-pane-unread", "1")
            wait_for("#{E:@ai-session-marker}", "!")
            plugin("view", "--pane", pane)
            wait_for("#{E:@ai-session-marker}", "")
            # Title fallback must work without an explicit pane flag.
            call("select-pane", "-T", "Action Required")
            wait_for("#{E:@ai-session-marker}", "?")
            plugin("deactivate")
            assert call("show-options", "-gqv", "window-status-format") == normal
            assert call("show-options", "-gqv", "window-status-current-format") == current
            assert call("list-keys", "w") == binding
            assert call("show-options", "-wqv", "window-status-style") == "fg=yellow,bg=blue"
            print(json.dumps(dict(tmux=call("display-message", "-p", "#{version}"), status="passed", theme_preserved=True,
                                  bindings_preserved=True, enable_disable=True)))
        finally:
            subprocess.run(command + ["kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dependencies-only", action="store_true")
    parser.add_argument("--prefix", type=Path, required=True)
    args = parser.parse_args()
    dependencies()
    if not args.dependencies_only:
        verify(args.prefix)


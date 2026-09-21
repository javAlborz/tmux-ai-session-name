#!/usr/bin/env python3
"""Shared tmux integration, preserving user themes and key bindings."""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
PREFIX = HERE.parent
MARKER = "#{E:@ai-session-marker}"
FORMAT = "#{?#{==:#{@ai-waiting},1},? ,#{?#{==:#{@ai-working},1},#{@spin-frame} ,#{?#{==:#{@ai-unread},1},! ,}}}"
HOOKS = ("client-attached", "session-created", "after-new-window", "after-select-window",
         "after-select-pane", "session-window-changed", "client-focus-in", "client-session-changed")
INDEX = 24861
os.environ["PATH"] = str(PREFIX / "bin") + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin")


def command(socket):
    return ["tmux", "-S", socket] if socket else ["tmux", "-L", "default"]


def call(socket, *args):
    return subprocess.check_output(command(socket) + list(args), stderr=subprocess.DEVNULL,
                                   universal_newlines=True, timeout=5).rstrip("\n")


def disabled_path():
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "tmux-ai-session/tmux.disabled"


def configure(enabled):
    path = disabled_path()
    if enabled:
        if path.exists():
            path.unlink()
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch(mode=0o600)
    print("Automatic integration " + ("enabled" if enabled else "disabled"))


def spawn(args, socket):
    env = dict(os.environ, TMUX=socket + ",0,0", AI_SESSION_NAME_PLUGIN_DIR=str(PREFIX))
    subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


def compatible(socket):
    value = call(socket, "display-message", "-p", "#{version}")
    match = re.match(r"(\d+)\.(\d+)", value)
    if not match or tuple(map(int, match.groups())) < (3, 3):
        raise ValueError("This tmux server is too old; tmux 3.3 or later is required")


def activate(socket):
    compatible(socket)
    socket = call(socket, "display-message", "-p", "#{socket_path}")
    # Serialize concurrent config reloads and hooks without blocking the tmux server.
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
    key = hashlib.sha256(socket.encode()).hexdigest()[:20]
    with (runtime / ("ai-session.%s.%s.lock" % (os.getuid(), key))).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for hook in HOOKS:
            entry = hook + "[" + str(INDEX) + "]"
            value = call(socket, "show-hooks", "-g", hook)
            for line in value.splitlines():
                if line.startswith(entry + " ") and str(HERE / "integration.py") not in line:
                    raise ValueError("Integration hook slot is already in use")
        call(socket, "set-option", "-g", "@ai-session-enabled", "1")
        call(socket, "set-option", "-g", "@ai-session-marker", FORMAT)
        for option in ("window-status-format", "window-status-current-format"):
            value = call(socket, "show-options", "-gqv", option)
            if not value.startswith(MARKER):
                call(socket, "set-option", "-g", option, MARKER + value)
        for hook in HOOKS:
            action = "ensure" if hook in HOOKS[:3] else "view"
            args = [sys.executable, str(HERE / "integration.py"), action, "--socket", socket]
            if action == "view":
                args += ["--pane", "#{pane_id}"]
            script = " ".join(shlex.quote(arg) for arg in args)
            call(socket, "set-hook", "-g", hook + "[" + str(INDEX) + "]",
                 "run-shell -b " + shlex.quote(script))
        call(socket, "set-option", "-g", "@ai-session-name-enabled", "on")
        manual = "bash " + shlex.quote(str(PREFIX / "scripts/manual-name.sh")) + " '#{window_id}'"
        call(socket, "set-hook", "-g", "after-rename-window[24862]", "run-shell " + shlex.quote(manual))
        ensure(socket)


def ensure(socket):
    if call(socket, "show-options", "-gqv", "@ai-session-enabled") != "1":
        return
    spawn([sys.executable, str(PREFIX / "status/ai-status.py"), "tick", socket], socket)
    spawn(["bash", str(PREFIX / "scripts/rename-daemon.sh")], socket)


def deactivate(socket):
    call(socket, "set-option", "-g", "@ai-session-name-enabled", "off")
    call(socket, "set-hook", "-gu", "after-rename-window[24862]")
    call(socket, "set-option", "-g", "@ai-session-enabled", "0")
    for hook in HOOKS:
        entry = hook + "[" + str(INDEX) + "]"
        for line in call(socket, "show-hooks", "-g", hook).splitlines():
            if line.startswith(entry + " ") and str(HERE / "integration.py") in line:
                call(socket, "set-hook", "-gu", entry)
    for option in ("window-status-format", "window-status-current-format"):
        value = call(socket, "show-options", "-gqv", option)
        if value.startswith(MARKER):
            call(socket, "set-option", "-g", option, value[len(MARKER):])
    call(socket, "set-option", "-gu", "@ai-session-marker")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("enable", "disable", "auto", "activate", "deactivate", "ensure", "view", "status"))
    parser.add_argument("--socket", default="")
    parser.add_argument("--pane", default="")
    args = parser.parse_args()
    if args.action in ("enable", "disable"):
        configure(args.action == "enable")
        try:
            socket = call(args.socket, "display-message", "-p", "#{socket_path}")
        except subprocess.CalledProcessError:
            print("New tmux sessions use this setting automatically.")
            return
        if args.action == "enable":
            activate(socket)
        else:
            deactivate(socket)
    elif args.action == "auto":
        if not disabled_path().exists() and os.environ.get("AI_SESSION_NO_INTEGRATION") != "1":
            activate(args.socket)
    elif args.action == "activate":
        activate(args.socket)
    elif args.action == "deactivate":
        deactivate(args.socket)
    elif args.action == "ensure":
        ensure(args.socket)
    elif args.action == "view":
        if call(args.socket, "show-options", "-gqv", "@ai-session-enabled") == "1":
            subprocess.run([sys.executable, str(PREFIX / "status/ai-status.py"), "view", args.pane, args.socket], check=True)
    else:
        print("Automatic integration:", not disabled_path().exists())
        try:
            print("Server:", call(args.socket, "display-message", "-p", "#{version}"))
            print("Active:", call(args.socket, "show-option", "-gqv", "@ai-session-enabled") == "1")
        except subprocess.CalledProcessError:
            print("Managed server is not running")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("Shared tmux: " + str(error), file=sys.stderr)
        sys.exit(1)


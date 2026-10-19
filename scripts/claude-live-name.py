#!/usr/bin/env python3
"""Read a user-assigned name from Claude's live, process-owned session record.

Exit 1 allows the older transcript/argv resolver when native naming metadata is
unavailable. Exit 2 rejects ambiguous, stale or non-user metadata, without a
fallback that could resurrect a different conversation's name. No transcript
or conversation content is read here, and no session ID is exported for forks.
"""
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid


def process(proc, pid):
    path = proc / pid
    raw = (path / "stat").read_text()
    fields = raw.rsplit(")", 1)[1].split()
    return dict(parent=fields[1], group=fields[2], tty=fields[4],
                foreground=fields[5], start=fields[19], state=fields[0],
                name=raw[raw.index("(") + 1:raw.rindex(")")], uid=path.stat().st_uid)


def session_record(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as file:
        info = os.fstat(file.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 65536:
            raise ValueError("not a bounded, user-owned session record")
        raw = file.read(65537)
        if len(raw) > 65536:
            raise ValueError("session record grew beyond the limit")
        return json.loads(raw)


def resolve(pane_pid, rows, proc):
    parents, clients = {}, set()
    for row in rows.splitlines():
        parts = row.split(None, 3)
        if len(parts) >= 3 and parts[0].isdigit() and parts[1].isdigit():
            parents[parts[0]] = parts[1]
            if parts[2] == "claude":
                clients.add(parts[0])
    primary = []
    for pid in clients:
        parent, seen = pid, set()
        while parent not in seen:
            seen.add(parent)
            if parent == pane_pid:
                primary.append(pid)
                break
            parent = parents.get(parent)
            if parent is None or parent in clients:
                break  # A nested Claude worker cannot become the pane's client.
    if not primary:
        return 1, ""
    if len(primary) != 1:
        return 2, ""
    pid = primary[0]
    try:
        raw_env = (proc / pid / "environ").read_bytes().decode(errors="surrogateescape")
        env = dict(item.split("=", 1) for item in raw_env.split("\0") if "=" in item)
        home = Path(env.get("CLAUDE_CONFIG_DIR") or
                    os.environ.get("CLAUDE_HOME") or str(Path(env["HOME"]) / ".claude"))
        if not home.is_absolute():
            return 2, ""
    except (OSError, KeyError, ValueError):
        return 1, ""  # Old clients/fixtures may not expose this environment.
    try:
        record = session_record(home / "sessions" / (pid + ".json"))
    except FileNotFoundError:
        # Daemon attach clients own no interactive session record. An optional
        # platform helper can read a binding proven through the worker's PTY.
        # It verifies the current foreground client and exact socket generation;
        # launch arguments and cached display names cannot provide that proof.
        helper = Path(os.environ.get('AI_SESSION_NAME_CLAUDE_ATTACH_HELPER', str(Path.home() / '.tmux/claude-attached.py')))
        if proc == Path('/proc') and helper.is_file():
            try:
                result = subprocess.run([sys.executable, str(helper), pane_pid], capture_output=True,
                                        text=True, timeout=2)
                if result.returncode == 0 and result.stdout.strip():
                    return 0, result.stdout.strip()
                args = (proc / pid / 'cmdline').read_bytes().split(b'\0')
                if b'attach' in args or b'agents' in args:
                    return 2, ""
            except (OSError, subprocess.SubprocessError):
                return 2, ""
        return 1, ""
    except (OSError, ValueError):
        return 2, ""
    try:
        current = process(proc, pid)
        pane = process(proc, pane_pid)
        pane_id = env.get("TMUX_PANE", "")
        if (current["name"] != "claude" or current["uid"] != os.getuid() or
                current["state"] == "Z" or current["tty"] == "0" or
                current["tty"] != pane["tty"] or int(current["group"]) <= 0 or
                current["group"] != current["foreground"] or
                type(record["pid"]) is not int or record["pid"] != int(pid) or
                str(record["procStart"]) != current["start"] or record["kind"] != "interactive" or
                not re.fullmatch(r"%[0-9]+", pane_id) or
                not record["tmux"].endswith("." + pane_id)):
            return 2, ""
        uuid.UUID(record["sessionId"])
        # Recheck actual ancestry, not just the process-table snapshot.
        parent, seen = pid, set()
        while parent != pane_pid:
            if parent in seen or len(seen) >= 64:
                return 2, ""
            seen.add(parent)
            parent = process(proc, parent)["parent"]
        if "name" not in record and "nameSource" not in record:
            return 1, ""  # Earlier session-record schemas retain the legacy path.
        name = record.get("name")
        if record.get("nameSource") != "user" or not isinstance(name, str) or not name.strip():
            return 2, ""
        if len(name) > 1024 or any(ord(char) < 32 or ord(char) == 127 for char in name):
            return 2, ""
        again = process(proc, pid)
        if again["state"] == "Z" or any(again[key] != current[key] for key in
                ("parent", "group", "tty", "foreground", "start", "uid", "name")):
            return 2, ""
        return 0, name
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError):
        return 2, ""


if __name__ == "__main__":
    code, name = resolve(sys.argv[1], sys.argv[2], Path(os.environ.get("AI_SESSION_NAME_PROC_ROOT", "/proc")))
    if code == 0:
        print(name)
    sys.exit(code)

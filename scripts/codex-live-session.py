#!/usr/bin/env python3
"""Read the primary Codex process's open rollout header, never its messages.

Launch arguments and inherited environment describe where a process started.
Open rollout files describe where it is now. Ambiguity must not fall back to a
historical alias, especially when this lookup is used to branch a session.
"""
import json
import os
from pathlib import Path
import re
import sqlite3
import sys

UUID = re.compile(r"^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$")


def display_name(home, ident):
    first_message = None
    try:
        with sqlite3.connect((home / "state_5.sqlite").as_uri() + "?mode=ro", uri=True, timeout=1) as db:
            columns = {r[1] for r in db.execute("pragma table_info(threads)")}
            if "name" in columns:
                row = db.execute("select name from threads where id=?", (ident,)).fetchone()
                if row is not None:
                    return row[0] if isinstance(row[0], str) else ""
            row = db.execute("select title,first_user_message from threads where id=?", (ident,)).fetchone()
            if row:
                title, first_message = row
                if title and title != first_message:
                    return title
    except (sqlite3.Error, OSError, ValueError):
        pass
    name = ""
    try:
        with (home / "session_index.jsonl").open() as file:
            for line in file:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("id") == ident:
                    name = entry.get("thread_name") or ""
    except OSError:
        pass
    return name if name != first_message else ""


def main():
    proc = Path(os.environ.get("AI_SESSION_NAME_PROC_ROOT", "/proc"))
    default_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).resolve()
    processes = {}
    for line in sys.argv[1].splitlines():
        fields = line.split(None, 3)
        if len(fields) >= 3 and fields[0].isdigit():
            processes[fields[0]] = fields
    native = {pid for pid, row in processes.items() if row[2] == "codex"}
    primary = set()
    for pid in native:
        parent = processes[pid][1]
        visited = {pid}
        while parent in processes and parent not in visited and parent not in native:
            visited.add(parent)
            parent = processes[parent][1]
        if parent not in native:
            primary.add(pid)
    candidates = {}
    parents = {}
    saw_rollout = False
    for pid in primary:
        try:
            stat = (proc / pid / "stat").read_text().rsplit(")", 1)[1].split()
            if int(stat[5]) > 0 and stat[2] != stat[5]:
                continue # A background job is not the pane's interactive agent.
        except (OSError, ValueError, IndexError):
            pass
        home = default_home
        try:
            for item in (proc / pid / "environ").read_bytes().split(b"\0"):
                if item.startswith(b"CODEX_HOME="):
                    home = Path(os.fsdecode(item.split(b"=", 1)[1])).resolve()
        except OSError:
            pass
        try:
            descriptors = list((proc / pid / "fd").iterdir())
        except OSError:
            continue
        for fd in descriptors:
            try:
                file = fd.resolve(strict=True)
                if not file.is_relative_to(home / "sessions") or not file.name.startswith("rollout-") or file.suffix != ".jsonl":
                    continue
                saw_rollout = True
                with file.open() as stream:
                    line = stream.readline(262144)
                entry = json.loads(line)
                header = entry.get("payload", {})
                ident = header.get("id", "")
                if entry.get("type") != "session_meta" or not UUID.fullmatch(ident):
                    continue
                # Subagents/compaction workers can keep their own rollout open
                # in the same process. They are not the user's current session.
                if header.get("source", "cli") not in ("cli", "exec"):
                    continue
                candidates[ident] = home
                parent = header.get("forked_from_id")
                parents[ident] = parent if isinstance(parent, str) else None
            except (OSError, ValueError, TypeError):
                continue
    # In-process forks can retain their ancestors' open writers. An explicit
    # chain with one leaf identifies its current endpoint without guessing by
    # name, mtime, descriptor number or the newest session in the directory.
    leaves = set(candidates) - set(parents.values())
    if len(candidates) > 1 and len(leaves) == 1:
        leaf = next(iter(leaves))
        chain = set()
        current = leaf
        while current in candidates and current not in chain:
            chain.add(current)
            current = parents.get(current)
        if chain == set(candidates):
            candidates = {leaf: candidates[leaf]}
    if len(candidates) > 1:
        print("\t\tambiguous")
        return 0
    if not candidates:
        if saw_rollout:
            print("\t\tambiguous")
            return 0
        return 1
    ident, home = next(iter(candidates.items()))
    name = " ".join(display_name(home, ident).split())
    print(f"{ident}\t{name}\tlive")
    return 0


if __name__ == "__main__":
    sys.exit(main())

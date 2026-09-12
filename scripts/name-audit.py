#!/usr/bin/env python3
"""Private, bounded naming decisions; no process environments or transcripts."""
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import stat
import sys

MAX_BYTES = 256 * 1024


def private_file(path):
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        os.close(fd)
        raise OSError('unsafe diagnostic file')
    os.fchmod(fd, 0o600)
    return fd


def append(directory, record):
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise OSError('unsafe diagnostic directory')
    directory.chmod(0o700)
    data = (json.dumps(record, ensure_ascii=True) + '\n').encode()
    if len(data) > MAX_BYTES:
        return
    with os.fdopen(private_file(directory / 'events.lock'), 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = directory / 'events.jsonl'
        fd = private_file(path)
        try:
            if os.fstat(fd).st_size + len(data) > MAX_BYTES:
                os.replace(path, directory / 'events.previous.jsonl')
                os.close(fd)
                fd = -1
                fd = private_file(path)
            with os.fdopen(fd, 'ab') as file:
                fd = -1
                file.write(data)
        finally:
            if fd != -1:
                os.close(fd)


def main():
    server, window, pane, field, before, after = sys.argv[1:]
    if field not in {'thread-id', 'manual-name', 'current-name', 'owned', 'window-name'}:
        return
    directory = Path(os.environ.get('XDG_STATE_HOME', str(Path.home() / '.local/state'))) / 'tmux-ai-session-name'
    append(directory, {
        'time': datetime.now(timezone.utc).isoformat(),
        'server_pid': server, 'window': window, 'pane': pane, 'field': field,
        'before': before[:256], 'after': after[:256],
    })


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError):
        sys.exit(1)

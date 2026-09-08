#!/usr/bin/env python3
"""Exercise the real tmux popup and launch boundary with inert agent fixtures."""
import json
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import tempfile
import time

plugin = Path(__file__).resolve().parents[1]
tmux = shutil.which("tmux")
socket = f"agent-fork-prompt-test-{os.getpid()}"
env = dict(os.environ, TERM="xterm-256color")
env.pop("TMUX", None)

with tempfile.TemporaryDirectory(prefix="agent-fork-prompt-") as tmp:
    root = Path(tmp)
    bindir = root / "bin"
    bindir.mkdir()
    standin = root / "standin"
    standin.mkdir()
    shutil.copy("/usr/bin/sleep", standin / "claude")
    log = root / "argv.json"
    (bindir / "claude").write_text(
        "#!/usr/bin/python3\nimport json,sys,time\n"
        f"open({str(log)!r},'w').write(json.dumps(sys.argv[1:]))\ntime.sleep(30)\n"
    )
    (bindir / "claude").chmod(0o755)
    (bindir / "tmux").write_text(f'#!/bin/sh\nexec {tmux} -L {socket} "$@"\n')
    (bindir / "tmux").chmod(0o755)
    env["PATH"] = str(bindir) + ":" + env["PATH"]

    def t(*args):
        return subprocess.run([tmux, "-L", socket, *args], env=env,
                              text=True, capture_output=True, check=True).stdout.strip()

    client = None
    master = None
    try:
        t("-f", "/dev/null", "new-session", "-d", "-s", "probe", "-c", tmp,
          str(standin / "claude") + " 120")
        t("set", "-g", "default-shell", "/bin/bash")
        window = t("list-windows", "-F", "#{window_id}")
        master, slave = pty.openpty()
        # A real sized terminal is required for display-popup.
        import fcntl, struct, termios
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
        client = subprocess.Popen([tmux, "-L", socket, "attach", "-t", "probe"],
                                  env=env, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        time.sleep(0.2)
        for name in ["audit $(printf EXPANDED)", "Bob's \"branch\"; $USER `printf nope`", ""]:
            if log.exists():
                log.unlink()
            t("select-window", "-t", window)
            helper = subprocess.Popen(["bash", str(plugin / "scripts/agent-fork.sh"), window],
                                      env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            seen = b""
            deadline = time.monotonic() + 5
            while b"empty to cancel" not in seen and time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    seen += os.read(master, 65536)
            assert b"empty to cancel" in seen, "fork popup was not displayed"
            os.write(master, name.encode() + b"\r")
            deadline = time.monotonic() + 5
            while not log.exists() and (name or helper.poll() is None) and time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    os.read(master, 65536)
            helper.communicate(timeout=5)
            if name:
                assert log.exists(), "fork did not launch"
                actual = json.loads(log.read_text())
                assert actual == ["--resume", "--fork-session", "-n", name], actual
                print("ok - popup name reaches the agent literally:", repr(name))
            else:
                assert not log.exists(), "empty name launched an agent"
                print("ok - empty popup input cancels branching")
    finally:
        subprocess.run([tmux, "-L", socket, "kill-server"], env=env, capture_output=True)
        if client is not None:
            client.wait(timeout=5)
        if master is not None:
            os.close(master)

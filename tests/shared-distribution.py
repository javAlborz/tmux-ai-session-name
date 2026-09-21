import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release", str(ROOT / "scripts/build-release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class DistributionTests(unittest.TestCase):
    def test_reproducible_package_manifest_and_shared_install(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = release.build(root / "one")
            second = release.build(root / "two")
            self.assertEqual(first.read_bytes(), second.read_bytes())
            install = root / "shared install"
            with tarfile.open(str(first)) as archive:
                archive.extractall(str(install))
            plugin = install / "tmux-ai-session"
            manifest = json.loads((plugin / "manifest.json").read_text())
            for name, expected in manifest["files"].items():
                self.assertEqual(hashlib.sha256((plugin / name).read_bytes()).hexdigest(), expected)
            subprocess.run(["python3", str(ROOT / "tests/verify-shared.py"), "--prefix", str(plugin)], check=True)

    def test_packaged_provider_and_common_naming_engine(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with tarfile.open(str(release.build(root / "out"))) as archive:
                archive.extractall(str(root))
            plugin = root / "tmux-ai-session"
            cmd = ["tmux", "-S", str(root / "socket")]
            def call(*args):
                return subprocess.check_output(cmd + list(args)).decode().strip()
            call("-f", "/dev/null", "new-session", "-d", "-s", "0", "-c", directory)
            try:
                pid = call("display-message", "-p", "#{pane_pid}")
                proc = root / "proc" / pid
                (proc / "fd").mkdir(parents=True)
                sessions = root / "sessions"
                sessions.mkdir()
                (proc / "environ").write_bytes(("TASK_SESSION_DIR=" + str(sessions) + "\0").encode())
                metadata = sessions / "session.jsonl"
                def name(value):
                    metadata.write_text(json.dumps(dict(type="session", id="identity", cwd=directory)) + "\n" +
                                        json.dumps(dict(type="session_info", name=value)) + "\n")
                name("Release review")
                (proc / "fd/7").symlink_to(metadata)
                env = dict(os.environ, TMUX=str(root / "socket") + ",0,0", AI_SESSION_NAME_PROC_ROOT=str(root / "proc"),
                           AI_SESSION_NAME_RUNTIME_DIR=directory, XDG_STATE_HOME=str(root / "state"))
                call("set-option", "-g", "@ai-session-name-format", "#{session}")
                def rename():
                    subprocess.run([str(plugin / "scripts/rename-windows.sh")], env=env, check=True)
                rename()
                self.assertEqual(call("display-message", "-p", "#{window_name}"), "Release review")
                call("rename-window", "Manual title")
                name("Changed session")
                rename()
                self.assertEqual(call("display-message", "-p", "#{window_name}"), "Manual title")
            finally:
                call("kill-server")


if __name__ == "__main__":
    unittest.main()

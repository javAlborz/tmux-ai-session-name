#!/usr/bin/env python3
"""Regressions for process-bound Claude naming and legacy compatibility."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[1]
SESSION = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
OTHER = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"


class ClaudeNames(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "profile with spaces"
        self.proc = self.root / "proc"
        (self.home / "sessions").mkdir(parents=True)
        self.rows = "100 1 bash bash\n101 100 claude claude --name Old"
        self.make_process("100", "1", "bash", start="10")
        self.make_process("101", "100", "claude")
        self.record = dict(pid=101, procStart="1234", sessionId=SESSION,
                           kind="interactive", tmux="source:@2.%3", name="rfctr", nameSource="user")
        self.path = self.home / "sessions/101.json"
        self.write_record()
        self.env = dict(os.environ, CLAUDE_HOME=str(self.home),
                        AI_SESSION_NAME_PROC_ROOT=str(self.proc),
                        AI_SESSION_NAME_CACHE_FILE=str(self.root / "cache"))

    def make_process(self, pid, parent, name, start="1234", foreground="101", tty="34816", state="S"):
        path = self.proc / pid
        path.mkdir(exist_ok=True, parents=True)
        fields = [state, parent, pid, pid, tty, foreground] + ["0"] * 13 + [start]
        (path / "stat").write_text(f"{pid} ({name}) " + " ".join(fields))
        (path / "cmdline").write_bytes(b"claude\0--name\0Old\0")
        (path / "environ").write_bytes(
            f"HOME={self.root}\0CLAUDE_CONFIG_DIR={self.home}\0TMUX_PANE=%3\0".encode())

    def write_record(self):
        self.path.write_text(json.dumps(self.record))

    def legacy(self):
        project = self.home / "projects/-project"
        project.mkdir(parents=True, exist_ok=True)
        (project / "legacy.jsonl").write_text(json.dumps({"message": {
            "content": "<local-command-stdout>Session renamed to: Old</local-command-stdout>"
        }}) + "\n")

    def resolve(self, pane="100"):
        return subprocess.run([str(PLUGIN / "scripts/claude-session-name.sh"), pane,
                               "/project", "✳ Old", self.rows], env=self.env,
                              text=True, capture_output=True, timeout=3)

    def rejected(self):
        result = self.resolve()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_native_name_wins_over_title_legacy_confirmation_and_launch_name(self):
        self.legacy()
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "rfctr\n")

    def test_rename_and_resume_in_same_process_refresh_without_title_or_cache_change(self):
        self.assertEqual(self.resolve().stdout, "rfctr\n")
        self.record["name"] = "new name"
        self.write_record()
        self.assertEqual(self.resolve().stdout, "new name\n")
        self.record.update(sessionId=OTHER, name="resumed")
        self.write_record()
        self.assertEqual(self.resolve().stdout, "resumed\n")

    def test_alternate_profile_wins_over_helpers_default_home(self):
        self.env["CLAUDE_HOME"] = str(self.root / "wrong-profile")
        self.assertEqual(self.resolve().stdout, "rfctr\n")

    def test_process_home_used_when_no_profile_override(self):
        default = self.root / ".claude"
        self.home.rename(default)
        self.env.pop("CLAUDE_HOME")
        (self.proc / "101/environ").write_bytes(f"HOME={self.root}\0TMUX_PANE=%3\0".encode())
        self.assertEqual(self.resolve().stdout, "rfctr\n")

    def test_pane_process_itself_can_be_claude(self):
        self.rows = "101 1 claude claude"
        self.make_process("101", "1", "claude")
        self.assertEqual(self.resolve(pane="101").stdout, "rfctr\n")

    def test_nested_workers_do_not_override_parent_name(self):
        self.rows += "\n102 101 claude claude --name Worker"
        self.make_process("102", "101", "claude", foreground="102")
        worker = dict(self.record, pid=102, sessionId=OTHER, name="Worker")
        (self.home / "sessions/102.json").write_text(json.dumps(worker))
        self.assertEqual(self.resolve().stdout, "rfctr\n")

    def test_multiple_primary_clients_are_not_guessed(self):
        self.legacy()
        self.rows += "\n102 100 claude claude"
        self.make_process("102", "100", "claude")
        self.rejected()

    def test_invalid_binding_never_falls_back_to_old_name(self):
        self.legacy()
        original = self.record.copy()
        for changes in (dict(pid=999), dict(pid=True), dict(procStart="12"),
                        dict(sessionId="bad-id"), dict(sessionId=None),
                        dict(kind="worker"), dict(tmux="source:@2.%99"), dict(tmux=None)):
            with self.subTest(changes=changes):
                self.record = dict(original, **changes)
                self.write_record()
                self.rejected()

    def test_background_dead_or_different_tty_client_cannot_supply_name(self):
        self.legacy()
        for changes in (dict(foreground="999"), dict(state="Z"), dict(tty="0"), dict(tty="999")):
            with self.subTest(changes=changes):
                self.make_process("101", "100", "claude", **changes)
                self.rejected()

    def test_reparented_or_reused_process_cannot_supply_name(self):
        self.legacy()
        self.make_process("101", "1", "claude")
        self.rejected()
        self.make_process("101", "100", "claude", start="9876")
        self.rejected()

    def test_non_user_empty_and_invalid_names_suppress_old_name(self):
        self.legacy()
        original = self.record.copy()
        for changes in (dict(nameSource="generated"), dict(nameSource=None), dict(name=""),
                        dict(name=None), dict(name="two\nlines"), dict(name="x" * 1025)):
            with self.subTest(changes=changes):
                self.record = dict(original, **changes)
                self.write_record()
                self.rejected()

    def test_names_with_quotes_and_unicode_remain_literal(self):
        self.record["name"] = "Bob's λ branch; $(echo literal)"
        self.write_record()
        self.assertEqual(self.resolve().stdout, self.record["name"] + "\n")

    def test_oversized_malformed_and_non_object_metadata_are_rejected(self):
        self.legacy()
        for raw in ("{", "[]", "null", " " * 65537):
            with self.subTest(size=len(raw)):
                self.path.write_text(raw)
                self.rejected()

    def test_symlink_and_fifo_metadata_are_rejected_without_blocking(self):
        self.legacy()
        self.path.unlink()
        other = self.home / "other.json"
        other.write_text(json.dumps(self.record))
        self.path.symlink_to(other)
        self.rejected()
        self.path.unlink()
        os.mkfifo(self.path)
        self.rejected()

    def test_absent_native_record_retains_legacy_compatibility(self):
        self.legacy()
        self.path.unlink()
        self.assertEqual(self.resolve().stdout, "Old\n")

    def test_older_schema_without_name_fields_retains_legacy_compatibility(self):
        self.legacy()
        self.record.pop("name")
        self.record.pop("nameSource")
        self.write_record()
        self.assertEqual(self.resolve().stdout, "Old\n")

    def test_dispatcher_does_not_export_native_session_id_for_branching(self):
        table = self.root / "processes"
        table.write_text(self.rows)
        result = subprocess.run([str(PLUGIN / "scripts/session-name-for-pane.sh"),
                                 "100", "/project", "✳ Old"],
                                env=dict(self.env, AI_SESSION_NAME_REPORT_ID="1",
                                         AI_SESSION_NAME_PROCESS_TABLE_FILE=str(table)),
                                text=True, capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "claude\t\trfctr\n")


if __name__ == "__main__":
    unittest.main()

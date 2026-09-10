#!/usr/bin/env python3
"""Regressions for live session switches and current client metadata."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[1]
OLD = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
LIVE = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
CHILD = "cccccccc-3333-4333-8333-cccccccccccc"


class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.proc = self.root / "proc"
        self.home = self.root / "codex"
        (self.home / "sessions").mkdir(parents=True)
        (self.proc / "101/fd").mkdir(parents=True)
        (self.proc / "101/comm").write_text("codex\n")
        (self.proc / "101/cmdline").write_bytes(b"codex\0resume\0newbase\0")
        (self.proc / "101/environ").write_bytes(b"")
        self.db = sqlite3.connect(self.home / "state_5.sqlite")
        self.addCleanup(self.db.close)
        self.db.execute("create table threads(id text, title text, name text, first_user_message text, updated_at integer)")
        self.index = self.home / "session_index.jsonl"
        self.index.write_text("")
        self.rows = "100 1 bash bash\n101 100 codex codex resume newbase"
        self.env = dict(os.environ, CODEX_HOME=str(self.home), AI_SESSION_NAME_PROC_ROOT=str(self.proc), AI_SESSION_NAME_REPORT_ID="1", AI_SESSION_NAME_CACHE_FILE=str(self.root / "cache"))
        self.env.pop("CODEX_THREAD_ID", None)

    def thread(self, ident, name):
        self.db.execute("insert into threads values(?,?,?,?,?)", (ident, "Original prompt", name, "Original prompt", 1))
        self.db.commit()

    def opened(self, ident, fd=7, source="cli", parent=None):
        file = self.home / "sessions" / f"rollout-2026-09-10T00-00-00-{ident}.jsonl"
        file.write_text(json.dumps({"type": "session_meta", "payload": {"id": ident, "cwd": str(self.root), "source": source, "forked_from_id": parent}}) + "\n")
        link = self.proc / f"101/fd/{fd}"
        link.unlink(missing_ok=True)
        link.symlink_to(file)

    def resolve(self):
        return subprocess.run([str(PLUGIN / "scripts/codex-session-name.sh"), "100", str(self.root), "project", self.rows], env=self.env, capture_output=True, text=True)

    def test_current_session_wins_over_historical_alias(self):
        self.thread(OLD, "fdbck")
        self.thread(LIVE, "baseA")
        self.index.write_text(json.dumps({"id": OLD, "thread_name": "newbase", "updated_at": "2026-09-03"}, separators=(",", ":")) + "\n" + json.dumps({"id": OLD, "thread_name": "fdbck"}, separators=(",", ":")) + "\n")
        self.opened(LIVE)
        self.assertEqual(self.resolve().stdout.strip(), f"{LIVE}\tbaseA\tlive")

    def test_switch_in_same_process_invalidates_cached_identity(self):
        self.thread(OLD, "old")
        self.thread(LIVE, "new")
        self.opened(OLD)
        self.assertIn(OLD, self.resolve().stdout)
        self.opened(LIVE)
        self.assertEqual(self.resolve().stdout.strip(), f"{LIVE}\tnew\tlive")

    def test_dispatcher_ignores_old_pane_cache_after_session_switch(self):
        self.thread(LIVE, "baseA")
        self.opened(LIVE)
        table = self.root / "processes"
        table.write_text(self.rows)
        import time
        (self.root / "cache").write_text(f"pane|100|project|id:1\t{int(time.time())}\tcodex\x1f{OLD}\x1ffdbck\x1fstrong\n")
        result = subprocess.run([str(PLUGIN / "scripts/session-name-for-pane.sh"), "100", str(self.root), "project"], env=dict(self.env, AI_SESSION_NAME_PROCESS_TABLE_FILE=str(table)), capture_output=True, text=True)
        self.assertEqual(result.stdout.strip(), f"codex\t{LIVE}\tbaseA\tlive")

    def test_unnamed_current_session_keeps_identity(self):
        self.thread(LIVE, None)
        self.opened(LIVE)
        result = self.resolve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.rstrip("\n"), f"{LIVE}\t\tlive")

    def test_auxiliary_thread_is_not_the_branch_source(self):
        self.thread(LIVE, "baseA")
        self.thread(CHILD, "helper")
        self.opened(CHILD, 6, {"subagent": {"thread_spawn": {"parent_thread_id": LIVE}}})
        self.opened(LIVE, 8)
        self.assertEqual(self.resolve().stdout.strip(), f"{LIVE}\tbaseA\tlive")

    def test_ambiguous_open_sessions_do_not_fall_back_to_launch_alias(self):
        self.thread(OLD, "old")
        self.thread(LIVE, "new")
        self.opened(OLD)
        self.opened(LIVE, 8)
        self.assertEqual(self.resolve().stdout.rstrip("\n"), "\t\tambiguous")

    def test_retained_ancestor_writers_do_not_hide_current_fork(self):
        self.thread(OLD, "old")
        self.thread(LIVE, "current")
        self.thread(CHILD, "intermediate")
        self.opened(OLD, 12)
        self.opened(CHILD, 8, parent=OLD)
        self.opened(LIVE, 6, parent=CHILD)
        self.assertEqual(self.resolve().stdout.strip(), f"{LIVE}\tcurrent\tlive")

    def test_sqlite_fallback_uses_current_name_column(self):
        self.thread(LIVE, "Renamed session")
        self.rows = f"100 1 bash bash\n101 100 codex codex resume {LIVE}"
        self.assertIn(f"{LIVE}\tRenamed session\t", self.resolve().stdout)

    def test_claude_rename_wins_over_launch_name(self):
        claude = self.root / "claude"
        project = claude / "projects" / "-project"
        project.mkdir(parents=True)
        (project / "session.jsonl").write_text(json.dumps({"message": {"content": "<local-command-stdout>Session renamed to: Current name</local-command-stdout>"}}) + "\n")
        result = subprocess.run([str(PLUGIN / "scripts/claude-session-name.sh"), "100", "/project", "✳ Current name", "101 100 claude claude --name Old --model sonnet"], env=dict(self.env, CLAUDE_HOME=str(claude)), capture_output=True, text=True)
        self.assertEqual(result.stdout.strip(), "Current name")

    def test_claude_launch_options_are_not_part_of_name(self):
        (self.proc / "101/cmdline").write_bytes(b"claude\0--name\0Old name\0--model\0sonnet\0")
        result = subprocess.run([str(PLUGIN / "scripts/claude-session-name.sh"), "100", "/missing", "✳ Old name", "101 100 claude claude --name Old name --model sonnet"], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.stdout.strip(), "Old name")


if __name__ == "__main__":
    unittest.main()

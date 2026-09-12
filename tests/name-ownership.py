#!/usr/bin/env python3
"""Exercise naming policy through the real resolver and an isolated tmux server."""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[1]
OLD = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'
NEW = 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'
GENERATED = 'Audit app-platform setup and docs'


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / 'codex'
        self.proc = self.root / 'proc'
        self.bin = self.root / 'bin'
        for path in [self.home / 'sessions', self.proc / '900001/fd', self.bin]:
            path.mkdir(parents=True)
        self.real_tmux = shutil.which('tmux')
        self.socket = str(self.root / 'test.sock')
        self.env = dict(os.environ, CODEX_HOME=str(self.home),
                        AI_SESSION_NAME_PROC_ROOT=str(self.proc),
                        AI_SESSION_NAME_PLUGIN_DIR=str(PLUGIN),
                        AI_SESSION_NAME_RUNTIME_DIR=str(self.root),
                        XDG_STATE_HOME=str(self.root / 'state'),
                        AI_SESSION_NAME_CACHE_FILE=str(self.root / 'cache'),
                        PATH=str(self.bin) + ':' + os.environ['PATH'])
        for key in ['TMUX', 'CODEX_THREAD_ID']:
            self.env.pop(key, None)
        (self.bin / 'tmux').write_text(f'#!/bin/sh\nexec {self.real_tmux} -S {self.socket} "$@"\n')
        (self.bin / 'ps').write_text(f'#!/bin/sh\ncat {self.root}/processes\n')
        # Register real hooks without an asynchronous daemon racing each test.
        (self.bin / 'setsid').write_text('#!/bin/sh\nexit 0\n')
        for path in self.bin.iterdir():
            path.chmod(0o700)
        (self.proc / '900001/environ').write_bytes(f'CODEX_HOME={self.home}'.encode() + b'\0')
        (self.proc / '900001/comm').write_text('codex\n')
        (self.proc / '900001/cmdline').write_bytes(b'codex\0')
        self.db = sqlite3.connect(self.home / 'state_5.sqlite')
        self.addCleanup(self.db.close)
        self.db.execute('create table threads(id text primary key, title text, name text, first_user_message text, updated_at integer)')
        for ident, name in [(OLD, 'platfor'), (NEW, GENERATED)]:
            self.db.execute('insert into threads values(?,?,?,?,?)', (ident, 'Original request', name, 'Original request', 1))
            (self.home / 'sessions' / f'rollout-{ident}.jsonl').write_text(json.dumps({
                'type': 'session_meta', 'payload': {'id': ident, 'source': 'cli', 'cwd': str(self.root)}
            }) + '\n')
        self.db.commit()
        self.tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'audit', 'sleep 300')
        self.addCleanup(lambda: self.tmux('kill-server'))
        self.pid = self.tmux('display-message', '-pt', '@0', '#{pane_pid}')
        self.processes(True)
        self.open_thread(NEW)
        self.tmux('set-option', '-g', '@ai-session-name-format', '#{session}')
        self.tmux('set-option', '-g', '@ai-session-name-restore', 'off')
        subprocess.run(['bash', str(PLUGIN / 'ai-session-name.tmux')], env=self.env, check=True, capture_output=True)

    def tmux(self, *args):
        return subprocess.check_output([self.real_tmux, '-S', self.socket, *args], env=self.env, text=True).strip()

    def option(self, name):
        return self.tmux('show-option', '-wqv', '-t', '@0', '@ai-session-name-' + name)

    def name(self):
        return self.tmux('display-message', '-pt', '@0', '#{window_name}')

    def processes(self, present):
        (self.root / 'processes').write_text(f'{self.pid} 1 bash bash\n' + (f'900001 {self.pid} codex codex\n' if present else ''))

    def open_thread(self, ident):
        link = self.proc / '900001/fd/7'
        link.unlink(missing_ok=True)
        link.symlink_to(self.home / 'sessions' / f'rollout-{ident}.jsonl')

    def tick(self):
        subprocess.run([str(PLUGIN / 'scripts/rename-windows.sh')], env=self.env, check=True, capture_output=True, text=True)

    def manual(self):
        self.tmux('rename-window', '-t', '@0', 'platform')

    def test_automatic_window_follows_saved_title_and_explicit_codex_rename(self):
        self.tick()
        self.assertEqual(self.name(), GENERATED)
        self.db.execute('update threads set name=? where id=?', ('explicit rename', NEW))
        self.db.commit()
        self.tick()
        self.assertEqual(self.name(), 'explicit rename')

    def test_manual_name_before_first_claim_wins(self):
        self.tmux('set-hook', '-gu', 'after-rename-window[92]')
        self.manual()
        self.tick()
        self.assertEqual(self.name(), 'platform')
        self.assertEqual(self.option('thread-id'), NEW)
        self.assertEqual(self.option('owned'), '')

    def test_hook_uses_renamed_window_instead_of_active_window(self):
        self.tick()
        self.tmux('new-window', '-n', 'another', 'sleep 300')
        self.tmux('rename-window', '-t', '@0', GENERATED)
        self.assertEqual(self.option('manual-name'), GENERATED)
        self.assertEqual(self.tmux('show-option', '-wqv', '-t', '@1', '@ai-session-name-manual-name'), '')

    def test_manual_choice_of_unchanged_title_is_preserved(self):
        self.tick()
        self.tmux('rename-window', '-t', '@0', GENERATED)
        self.tick()
        self.open_thread(OLD)
        self.tick()
        self.assertEqual(self.name(), GENERATED)
        self.assertEqual(self.option('thread-id'), OLD)

    def test_reload_preserves_one_manual_hook_and_disable_removes_it(self):
        self.tmux('set-hook', '-g', 'after-rename-window[5]', 'display-message other-hook')
        subprocess.run(['bash', str(PLUGIN / 'ai-session-name.tmux')], env=self.env, check=True, capture_output=True)
        hooks = self.tmux('show-hooks', '-g', 'after-rename-window')
        self.assertEqual(hooks.count('manual-name.sh'), 1)
        self.assertIn('other-hook', hooks)
        self.tmux('set-option', '-g', '@ai-session-name-enabled', 'off')
        subprocess.run(['bash', str(PLUGIN / 'ai-session-name.tmux')], env=self.env, check=True, capture_output=True)
        hooks = self.tmux('show-hooks', '-g', 'after-rename-window')
        self.assertNotIn('manual-name.sh', hooks)
        self.assertIn('other-hook', hooks)

    def test_manual_name_survives_missing_detection(self):
        self.tick()
        self.manual()
        self.tick()
        self.processes(False)
        self.tick()
        self.assertEqual(self.option('thread-id'), '')
        self.processes(True)
        self.tick()
        self.assertEqual(self.name(), 'platform')
        self.assertEqual(self.option('thread-id'), NEW)

    def test_manual_name_detected_even_when_client_is_missing(self):
        self.tick()
        self.manual()
        self.processes(False)
        self.tick()
        self.processes(True)
        self.tick()
        self.assertEqual(self.name(), 'platform')

    def test_manual_name_survives_thread_switch_but_identity_follows(self):
        self.tick()
        self.manual()
        self.tick()
        self.open_thread(OLD)
        self.tick()
        self.assertEqual(self.name(), 'platform')
        self.assertEqual(self.option('thread-id'), OLD)

    def test_unnamed_live_thread_keeps_manual_name_and_branch_identity(self):
        self.manual()
        self.db.execute('update threads set name=null where id=?', (NEW,))
        self.db.commit()
        self.tick()
        self.assertEqual(self.name(), 'platform')
        self.assertEqual(self.option('thread-id'), NEW)

    def test_reenabling_automatic_rename_releases_manual_choice(self):
        self.manual()
        self.tick()
        self.tmux('set-option', '-w', '-t', '@0', 'automatic-rename', 'on')
        self.tick()
        self.assertEqual(self.name(), GENERATED)
        self.assertEqual(self.option('manual-name'), '')

    def test_manually_named_codex_without_client_is_preserved(self):
        self.tmux('rename-window', '-t', '@0', 'codex')
        self.processes(False)
        self.tick()
        self.assertEqual(self.name(), 'codex')

    def test_diagnostics_record_changes_without_repeated_idle_writes(self):
        self.tick()
        self.manual()
        self.tick()
        self.open_thread(OLD)
        self.tick()
        path = self.root / 'state/tmux-ai-session-name/events.jsonl'
        records = [json.loads(line) for line in path.read_text().splitlines()]
        self.assertTrue(any(r['field'] == 'thread-id' and r['after'] == OLD for r in records))
        self.assertTrue(any(r['field'] == 'manual-name' and r['after'] == 'platform' for r in records))
        self.assertTrue(any(r['field'] == 'window-name' and r['after'] == GENERATED for r in records))
        previous = path.read_bytes()
        self.tick()
        self.assertEqual(path.read_bytes(), previous)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import sys

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('audit', Path(__file__).resolve().parents[1] / 'scripts/name-audit.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class AuditTests(unittest.TestCase):
    def test_rotation_bounds_storage_and_preserves_latest_events(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'audit'
            old_limit = audit.MAX_BYTES
            self.addCleanup(setattr, audit, 'MAX_BYTES', old_limit)
            audit.MAX_BYTES = 1024
            for sequence in range(80):
                audit.append(path, {'sequence': sequence, 'after': 'x' * 80})
            self.assertLessEqual((path / 'events.jsonl').stat().st_size, 1024)
            self.assertLessEqual((path / 'events.previous.jsonl').stat().st_size, 1024)
            self.assertEqual(json.loads((path / 'events.jsonl').read_text().splitlines()[-1])['sequence'], 79)
            self.assertEqual(path.stat().st_mode & 0o777, 0o700)
            for file in path.iterdir():
                self.assertEqual(file.stat().st_mode & 0o777, 0o600)

    def test_symlink_does_not_redirect_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / 'audit'
            path.mkdir()
            other = root / 'other'
            other.write_text('untouched')
            (path / 'events.jsonl').symlink_to(other)
            with self.assertRaises(OSError):
                audit.append(path, {'after': 'replacement'})
            self.assertEqual(other.read_text(), 'untouched')

    def test_hardlink_does_not_redirect_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / 'audit'
            path.mkdir()
            other = root / 'other'
            other.write_text('untouched')
            os.link(other, path / 'events.jsonl')
            with self.assertRaises(OSError):
                audit.append(path, {'after': 'replacement'})
            self.assertEqual(other.read_text(), 'untouched')


if __name__ == '__main__':
    unittest.main()

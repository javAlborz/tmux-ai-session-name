"""Conservative process evidence for a pane returning to its shell."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('status', str(Path(__file__).resolve().parents[1] / 'status/ai-status.py'))
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)


class PaneExitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.proc = Path(self.temp.name)
        self.path = self.proc / '20'
        (self.path / 'task/20').mkdir(parents=True)
        (self.path / 'task/20/children').write_text('')
        (self.path / 'exe').symlink_to('/usr/bin/bash')
        (self.path / 'cmdline').write_bytes(b'-bash\0')
        self.row = {'pane_pid': '20', 'pane_dead': '0'}
        self.stat()

    def stat(self, state='S', foreground='20', tty='42'):
        fields = [state, '1', '20', '20', tty, foreground] + ['0'] * 13 + ['120']
        (self.path / 'stat').write_text('20 (bash) ' + ' '.join(fields))

    def exited(self):
        return core.pane_exited(self.row, self.proc)

    def test_empty_foreground_login_shell(self):
        self.assertTrue(self.exited())

    def test_foreground_job_is_not_idle(self):
        self.stat(foreground='30')
        self.assertFalse(self.exited())

    def test_background_or_suspended_child_is_not_idle(self):
        (self.path / 'task/20/children').write_text('30')
        self.assertFalse(self.exited())

    def test_child_of_another_shell_thread_is_not_idle(self):
        (self.path / 'task/21').mkdir()
        (self.path / 'task/21/children').write_text('30')
        self.assertFalse(self.exited())

    def test_shell_scripts_and_commands_are_not_prompts(self):
        for command in (b'bash\0-c\0read answer\0', b'bash\0-ci\0read answer\0',
                        b'bash\0script.sh\0', b'bash\0-i\0script.sh\0'):
            with self.subTest(command=command):
                (self.path / 'cmdline').write_bytes(command)
                self.assertFalse(self.exited())

    def test_unknown_or_unreadable_process_does_not_clear_state(self):
        (self.path / 'exe').unlink()
        self.assertFalse(self.exited())
        (self.path / 'exe').symlink_to('/usr/bin/python3')
        self.assertFalse(self.exited())

    def test_other_uid_or_running_shell_is_not_authority(self):
        with patch.object(core.os, 'getuid', return_value=os.getuid()+1):
            self.assertFalse(self.exited())
        self.stat(state='R')
        self.assertFalse(self.exited())
        self.stat(tty='0')
        self.assertFalse(self.exited())

    def test_dead_pane_requires_absent_process(self):
        self.row['pane_dead'] = '1'
        self.assertFalse(self.exited())
        self.row['pane_pid'] = '99'
        self.assertTrue(self.exited())
        self.row['pane_dead'] = '0'
        self.assertFalse(self.exited())
        self.assertFalse(core.pane_exited(dict(self.row, pane_dead='1'), self.proc / 'missing'))

    def test_identity_change_during_check_keeps_state(self):
        original = Path.read_text
        def change(path, *args, **kwargs):
            result = original(path, *args, **kwargs)
            if path.name == 'children':
                self.stat(foreground='30')
            return result
        with patch.object(Path, 'read_text', change):
            self.assertFalse(self.exited())


if __name__ == '__main__':
    unittest.main()

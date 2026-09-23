"""Exercise generic adapter callbacks against a real isolated tmux server."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('status', str(ROOT / 'status/ai-status.py'))
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)


class Adapter(core.Status):
    fields = core.FIELDS[:-1] + ['@provider-state'] + core.FIELDS[-1:]
    allowed = True
    observation = None
    def accept_event(self, row, event, payload):
        self.seen_payload = payload
        return self.allowed
    def reconcile(self, row, event, payload):
        if self.observation is not None:
            self.set(row, '@ai-pane-working', self.observation)
            self.set(row, '@provider-state', event)


class AdapterTests(unittest.TestCase):
    def test_event_rejection_and_reconciliation_before_window_aggregation(self):
        with tempfile.TemporaryDirectory() as directory:
            command = ['tmux', '-S', str(Path(directory) / 'socket')]
            def call(*args):
                return subprocess.check_output(command + list(args), text=True).strip()
            call('-f', '/dev/null', 'new-session', '-d', '-s', 'fixture', 'sleep 300')
            try:
                pane = call('display-message', '-p', '#{pane_id}')
                status = Adapter(command[2])
                status.refresh('start', pane, {'identity': 'current'})
                self.assertEqual(status.seen_payload, {'identity': 'current'})
                status.allowed = False
                status.refresh('stop', pane, {'identity': 'old'})
                self.assertEqual(call('display-message', '-p', '#{@ai-working}'), '1')
                status.observation = 0
                status.refresh()
                self.assertEqual(call('display-message', '-p', '#{@ai-working}'), '0')
                self.assertEqual(call('show-option', '-pqv', '-t', pane, '@provider-state'), 'refresh')
            finally:
                call('kill-server')


if __name__ == '__main__':
    unittest.main()

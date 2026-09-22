#!/usr/bin/env python3
"""Pane-owned agent state and the shared window renderer.

Hooks update only their originating pane. Polling observes titles and optional
provider activity. Adapters may reconcile state from verified live metadata.
"""
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time

def shell_join(args):
    return " ".join(shlex.quote(arg) for arg in args)

FIELDS = ["pane_id", "window_id", "pane_pid", "pane_active", "pane_height", "window_active", "session_name",
          "@ai-pane-working", "@ai-pane-waiting", "@ai-pane-unread", "@ai-pane-attn",
          "@ai-pane-attn-prev", "@ai-pane-waiting-id", "@ai-status-version",
          "@ai-working", "@ai-waiting", "@ai-unread", "@ai-attn", "pane_title"]




class Status:
    fields = FIELDS

    def __init__(self, socket=""):
        socket = socket or os.environ.get("TMUX", "").split(",")[0] or "default"
        self.command = ["tmux", "-S" if "/" in socket else "-L", socket]
        self.socket = self.call("display-message", "-p", "#{socket_path}").strip()
        self.pid = self.call("display-message", "-p", "#{pid}").strip()
        key = hashlib.sha256(self.socket.encode()).hexdigest()[:20]
        runtime = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
        self.lock_path = runtime / f"ai-status.{os.getuid()}.{key}.lock"
        self.tick_lock = os.environ.get("AI_SPINNER_TICK_LOCK", str(runtime / f"ai-tick.{os.getuid()}.{key}.lock"))
        self.changes = []

    def call(self, *args):
        return subprocess.run([*self.command, *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=5).stdout

    def set(self, obj, key, value, pane=True):
        value = str(value)
        if obj.get(key, "") == value:
            return
        obj[key] = value
        if self.changes:
            self.changes.append(";")
        self.changes.extend(["set-option", "-p" if pane else "-w", "-t", obj["pane_id" if pane else "window_id"], key, value])

    def question_activity(self, row):
        return None

    def accept_event(self, row, event, payload):
        """Adapters may reject events from a superseded process or session."""
        return True

    def reconcile(self, row, event, payload):
        """Adapters may repair pane state from verified live provider metadata."""
        pass

    def refresh(self, event="refresh", pane="", payload=None, frame=None):
        with self.lock_path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self._refresh(event, pane, payload or {}, frame)

    def _refresh(self, event, target, payload, frame):
        self.changes = []
        rows = self.call("list-panes", "-a", "-F", "\t".join("#{" + field + "}" for field in self.fields)).splitlines()
        panes = {}
        locations = {}
        windows = {}
        for line in rows:
            values = line.split("\t", len(self.fields) - 1)
            if len(values) != len(self.fields):
                continue
            row = dict(zip(self.fields, values))
            locations.setdefault(row["pane_id"], []).append(row)
            panes.setdefault(row["pane_id"], row)
            windows.setdefault(row["window_id"], row.copy())

        try:
            watch = int(self.call("show-option", "-gqv", "@ai-unread-watch-seconds").strip() or "120")
            if watch < 0:
                watch = 120
        except ValueError:
            watch = 120
        now = time.time()
        watched_sessions = set()
        for line in self.call("list-clients", "-F", "#{client_activity}\t#{client_session}").splitlines():
            activity, _, session = line.partition("\t")
            if activity.isdigit() and 0 <= now - int(activity) < watch:
                watched_sessions.add(session)

        def watching(pane):
            return any(r["pane_active"] == "1" and r["window_active"] == "1" and r["session_name"] in watched_sessions for r in locations[pane])

        # One-time upgrade of window flags to the active pane. Once migrated,
        # the window options below are outputs only, never shared agent state.
        for row in panes.values():
            if row["@ai-status-version"] != "2" and row["pane_active"] == "1":
                for flag in ("working", "waiting", "unread", "attn"):
                    if row[f"@ai-pane-{flag}"] == "" and row[f"@ai-{flag}"] == "1":
                        self.set(row, f"@ai-pane-{flag}", 1)
        for window in windows.values():
            self.set(window, "@ai-status-version", 2, pane=False)

        row = panes.get(target)
        applied_event = event if row and self.accept_event(row, event, payload) else "refresh"
        if row and applied_event != "refresh":
            call_id = str(payload.get("tool_use_id") or payload.get("tool_call_id") or payload.get("call_id") or "")
            if event == "start":
                for flag in ("waiting", "unread", "attn"):
                    self.set(row, f"@ai-pane-{flag}", 0)
                self.set(row, "@ai-pane-working", 1)
                self.set(row, "@ai-pane-waiting-id", "")
            elif event == "stop":
                self.set(row, "@ai-pane-working", 0)
                self.set(row, "@ai-pane-waiting", 0)
                self.set(row, "@ai-pane-waiting-id", "")
                self.set(row, "@ai-pane-unread", int(not watching(target)))
            elif event == "waiting":
                self.set(row, "@ai-pane-waiting", 1)
                self.set(row, "@ai-pane-waiting-id", call_id)
            elif event == "tool":
                waiting_id = row["@ai-pane-waiting-id"]
                if not waiting_id or call_id == waiting_id:
                    self.set(row, "@ai-pane-waiting", 0)
                    self.set(row, "@ai-pane-waiting-id", "")
                self.set(row, "@ai-pane-working", 1)
            elif event == "idle":
                for flag in ("working", "waiting", "unread", "attn"):
                    self.set(row, f"@ai-pane-{flag}", 0)
                self.set(row, "@ai-pane-waiting-id", "")
            elif event == "view":
                self.set(row, "@ai-pane-unread", 0)
                self.set(row, "@ai-pane-attn", 0)

        aggregate = {wid: dict(working=0, waiting=0, unread=0, attn=0) for wid in windows}
        for pane, row in panes.items():
            self.reconcile(row, applied_event if pane == target else "refresh", payload if pane == target else {})
            title = row["pane_title"]
            attention = "Action Required" in title
            question_working = None
            if attention and row["@ai-pane-waiting"] != "1":
                question_working = self.question_activity(row)
                if question_working is not None:
                    attention = False
                    # Also remove attention latched by an older worker which
                    # mistook this optional question for a blocking request.
                    self.set(row, "@ai-pane-attn", 0)
            if attention and row["@ai-pane-attn-prev"] != "1" and not watching(pane):
                self.set(row, "@ai-pane-attn", 1)
            self.set(row, "@ai-pane-attn-prev", int(attention))
            braille = bool(title) and 0x2800 <= ord(title[0]) <= 0x28FF
            working = braille or row["@ai-pane-working"] == "1"
            if question_working is not None:
                working = question_working
            state = aggregate[row["window_id"]]
            state["working"] |= int(working)
            state["waiting"] |= int(attention or row["@ai-pane-waiting"] == "1")
            state["unread"] |= int(row["@ai-pane-unread"] == "1")
            state["attn"] |= int(row["@ai-pane-attn"] == "1")
        for wid, state in aggregate.items():
            for flag, value in state.items():
                self.set(windows[wid], f"@ai-{flag}", value, pane=False)
        state_changed = bool(self.changes)
        if frame is not None:
            if self.changes:
                self.changes.append(";")
            self.changes.extend(["set-option", "-g", "@spin-frame", frame])
        if self.changes:
            self.call(*self.changes)
        trace = os.environ.get("AI_SPINNER_TICK_TRACE") or os.environ.get("AI_MARKER_TRACE") or os.environ.get("AI_WAITING_TRACE")
        default_trace = Path.home() / ".tmux/ai-waiting-trace.log"
        if not trace and default_trace.is_file():
            trace = str(default_trace)
        if trace and (event != "refresh" or state_changed):
            with open(trace, "a") as file:
                file.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} pane={target} event={event}\n")

    def install(self):
        script = str(Path(__file__).with_name("ai-spinner-tick.sh"))
        launch = shell_join([script, self.socket])
        spawn = "run-shell -b " + shlex.quote(f"setsid -f {launch} </dev/null >/dev/null 2>&1")
        for hook in ("client-attached", "session-created", "after-new-window"):
            for line in self.call("show-hooks", "-g", hook).splitlines():
                entry = line.split(" ", 1)[0]
                if script in line and entry != f"{hook}[93]":
                    self.call("set-hook", "-gu", entry)
            self.call("set-hook", "-g", f"{hook}[93]", spawn)
        view = "run-shell -b " + shlex.quote(shell_join([script, "--view", "#{pane_id}", self.socket]))
        for hook in ("after-select-window", "after-select-pane", "session-window-changed", "client-focus-in", "client-session-changed"):
            self.call("set-hook", "-g", f"{hook}[91]", view)
        subprocess.Popen([script, self.socket], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

    def tick(self):
        with open(self.tick_lock, "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
            self.call("set-option", "-g", "@ai-status-worker-pid", str(os.getpid()))
            i = 0
            while (self.call("display-message", "-p", "#{pid}").strip() == self.pid
                   and self.call("show-option", "-gqv", "@ai-session-enabled").strip() != "0"):
                self.refresh(frame="◐◓◑◒"[i % 4])
                i += 1
                try:
                    interval = float(self.call("show-option", "-gqv", "@ai-spinner-interval").strip() or "0.2")
                    if not math.isfinite(interval) or interval <= 0:
                        interval = 0.2
                except ValueError:
                    interval = 0.2
                time.sleep(interval)

    def restart(self):
        worker = self.call("show-option", "-gqv", "@ai-status-worker-pid").strip()
        if worker.isdigit():
            try:
                args = Path(f"/proc/{worker}/cmdline").read_bytes().decode().split("\0")
                if len(args) > 3 and Path(args[1]).resolve() == Path(__file__).resolve() and args[2] == "tick":
                    requested = args[3] or "default"
                    if requested in (self.socket, Path(self.socket).name):
                        os.kill(int(worker), signal.SIGTERM)
                        # Wait for the lock, not a guessed process shutdown delay.
                        with open(self.tick_lock, "a") as lock:
                            fcntl.flock(lock, fcntl.LOCK_EX)
            except (OSError, UnicodeError):
                pass
        self.install()


def main(status_class=Status):
    event = sys.argv[1]
    target = os.environ.get("TMUX_PANE", "")
    socket = ""
    if event in ("tick", "install", "restart"):
        socket = sys.argv[2] if len(sys.argv) > 2 else ""
    elif event == "view":
        target = sys.argv[2] if len(sys.argv) > 2 else target
        socket = sys.argv[3] if len(sys.argv) > 3 else ""
    elif event != "refresh" and not target:
        return
    payload = {}
    if event in ("start", "stop", "idle", "waiting", "tool") and not sys.stdin.isatty():
        try:
            value = json.load(sys.stdin)
            if isinstance(value, dict):
                payload = value
        except (ValueError, OSError):
            pass
    if event == "waiting" and payload.get("notification_type") == "idle_prompt":
        return
    status = status_class(socket)
    if event == "install":
        status.install()
    elif event == "restart":
        status.restart()
    elif event == "tick":
        status.tick()
    else:
        status.refresh(event, target, payload)


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.SubprocessError):
        # Closing a pane/server must not turn an agent hook into a failed tool.
        pass

import errno
import importlib.util
from pathlib import Path
import subprocess
import sys
import time
import types
import unittest
from unittest.mock import patch
path = Path(__file__).resolve().parents[2] / 'Resources/Runtime/dot_process.py'
spec = importlib.util.spec_from_file_location('dot_process_fixture', path)
observer = importlib.util.module_from_spec(spec); spec.loader.exec_module(observer)

class ProcessExitTests(unittest.TestCase):
    def test_owned_child_exit_observed_without_reaping(self):
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(0.1)'])
        try:
            deadline = time.monotonic() + 3
            while not observer.child_exited(child) and time.monotonic() < deadline: time.sleep(0.01)
            self.assertTrue(observer.child_exited(child)); self.assertIsNone(child.returncode)
        finally: child.wait(timeout=3)
        with self.assertRaises(ChildProcessError): observer.child_exited(child)
    def kqueue_result(self, events):
        self.closed = False
        owner = self
        class Queue:
            def close(self): owner.closed = True
            def control(self, changes, limit, timeout): return events
        return types.SimpleNamespace(kqueue=Queue, kevent=lambda *_args, **_kwargs: object(), KQ_FILTER_PROC=-5,
                                     KQ_EV_ADD=1, KQ_EV_ONESHOT=16, KQ_NOTE_EXIT=0x80000000, KQ_EV_ERROR=0x4000)
    def test_kqueue_path_without_os_waitid(self):
        event = types.SimpleNamespace(flags=0, fflags=0x80000000, data=0)
        with patch.object(observer.os, 'waitid', None, create=True), patch.object(observer, 'select', self.kqueue_result([event])):
            self.assertTrue(observer.child_exited(types.SimpleNamespace(pid=123, returncode=None)))
            self.assertTrue(self.closed)
    def test_kqueue_running_child_is_not_reaped(self):
        with patch.object(observer.os, 'waitid', None, create=True), patch.object(observer, 'select', self.kqueue_result([])):
            self.assertFalse(observer.child_exited(types.SimpleNamespace(pid=123, returncode=None)))
            self.assertTrue(self.closed)
    def test_kqueue_registration_error_is_not_hidden(self):
        event = types.SimpleNamespace(flags=0x4000, fflags=0, data=errno.EPERM)
        with patch.object(observer.os, 'waitid', None, create=True), patch.object(observer, 'select', self.kqueue_result([event])):
            with self.assertRaises(PermissionError): observer.child_exited(types.SimpleNamespace(pid=123, returncode=None))
            self.assertTrue(self.closed)

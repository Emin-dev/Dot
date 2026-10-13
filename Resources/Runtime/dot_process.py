"""Observe an owned child without reaping it before process-group teardown.
macOS uses kqueue NOTE_EXIT; waitid is not exposed by every CPython/macOS build.
"""
import errno
import os
import select


def child_exited(child):
    if getattr(child, 'returncode', None) is not None:
        raise ChildProcessError('owned child already reaped')
    waitid = getattr(os, 'waitid', None)
    if callable(waitid):
        return waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
    if not hasattr(select, 'kqueue'):
        raise RuntimeError('non-reaping child observation unavailable')
    queue = select.kqueue()
    try:
        event = select.kevent(child.pid, filter=select.KQ_FILTER_PROC,
                              flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)
        try: events = queue.control([event], 1, 0)
        except ProcessLookupError:
            # Our unreaped Popen child has already exited; its PID cannot be reused yet.
            return True
        for event in events:
            if event.flags & select.KQ_EV_ERROR:
                if event.data == errno.ESRCH: return True
                raise OSError(event.data, 'owned process event registration failed')
            if event.fflags & select.KQ_NOTE_EXIT: return True
        return False
    finally:
        queue.close()

"""Observe an owned child without reaping it before process-group teardown.
macOS uses kqueue NOTE_EXIT; waitid is not exposed by every CPython/macOS build.
"""
import errno
from contextlib import contextmanager
import os
import select


@contextmanager
def api_key_pipe(api_key):
    """One inherited read capability; no secret in environment/argv/files.

    Preload the bounded anonymous pipe and close its only writer before spawn.
    The caller must pass only the read descriptor to its owned child. Both ends
    start CLOEXEC, and the parent's read end closes on success or spawn failure.
    """
    if (type(api_key) is not str or len(api_key) != 64
        or any(character not in '0123456789abcdef' for character in api_key)):
        raise ValueError('invalid runtime credential')
    reader = writer = None
    transfer = bytearray(api_key, 'ascii')
    try:
        reader, writer = os.pipe()
        os.set_blocking(writer, False)
        # 64 bytes is below POSIX PIPE_BUF. A short write is a hard failure.
        if os.write(writer, transfer) != len(transfer):
            raise OSError('runtime credential transfer failed')
        os.close(writer); writer = None
        transfer[:] = b'\x00' * len(transfer)
        yield reader
    finally:
        transfer[:] = b'\x00' * len(transfer)
        if writer is not None: os.close(writer)
        if reader is not None: os.close(reader)


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

import os
import signal
import subprocess
import time


def run(cmd, cwd=None, timeout=120.0, env=None, stdin=None):
    """Run `cmd` in its own process group. Returns (returncode|None on timeout, stdout, stderr, seconds)."""
    started = time.perf_counter()
    with subprocess.Popen([str(c) for c in cmd], cwd=cwd, env=env, stdin=stdin or subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True) as proc:
        try:
            out, err = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.communicate()
            return None, b"", b"", time.perf_counter() - started
        except BaseException:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            raise
    return proc.returncode, out, err, time.perf_counter() - started


def text(b):
    return b.decode("utf-8", errors="replace")

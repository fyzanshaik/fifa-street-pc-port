#!/usr/bin/env python3
"""Follow the newest normal-play FIFA Street session log.

Watches <build>/logs/play for UTC session directories named YYYYMMDDTHHMMSSZ and
streams the newest session's fifastreet.log. Prints the last --lines lines of a
session when it attaches, then every appended line. It moves to a newer session
as soon as its directory appears (waiting for that session's log if it has not
been written yet) and keeps reading through truncation and file replacement.

Read-only by design: it never creates or modifies logs and never touches the
game process. Ctrl+C or SIGTERM stops only this watcher.
"""
from __future__ import annotations

import argparse
import os
import re
import signal
import sys
import time

LOG_NAME = "fifastreet.log"
SESSION_RE = re.compile(r"^\d{8}T\d{6}Z$")
POLL_SECONDS = 0.25
TAIL_CHUNK = 8192
READ_CHUNK = 65536

_stop = False


def _request_stop(_signum, _frame):
    global _stop
    _stop = True


def announce(message):
    print(message, flush=True)


def session_dirs(root):
    """Return sorted UTC session directory names; ignore anything else."""
    try:
        names = os.listdir(root)
    except (FileNotFoundError, NotADirectoryError):
        return []
    return sorted(
        name
        for name in names
        if SESSION_RE.match(name) and os.path.isdir(os.path.join(root, name))
    )


class LogFollower:
    """Tails one file, tolerating truncation and inode replacement."""

    def __init__(self, path, history):
        self.path = path
        self.history = history
        self.handle = None
        self.ident = None
        self.offset = 0
        self.partial = b""
        self._open()

    def _open(self):
        handle = open(self.path, "rb")
        try:
            stat = os.fstat(handle.fileno())
            self.ident = (stat.st_dev, stat.st_ino)
            self.partial = self._read_history(handle, stat.st_size)
            self.offset = stat.st_size
        except BaseException:
            handle.close()
            raise
        self.handle = handle

    def _read_history(self, handle, size):
        """Emit the last `history` complete lines and return any trailing partial.

        Reads backward in bounded chunks, so attaching to a long log never
        allocates the whole file. A final line with no terminating newline is
        held (not emitted) until an append completes it.
        """
        data = b""
        pos = size
        while pos > 0 and data.count(b"\n") < self.history + 1:
            step = min(TAIL_CHUNK, pos)
            pos -= step
            handle.seek(pos)
            data = handle.read(step) + data
        if data.endswith(b"\n"):
            lines = data[:-1].split(b"\n")
            partial = b""
        else:
            parts = data.split(b"\n")
            partial = parts.pop()
            lines = parts
        if self.history > 0:
            for raw in lines[-self.history:]:
                announce(raw.decode("utf-8", "replace"))
        return partial

    def close(self):
        if self.handle is not None:
            self.handle.close()
            self.handle = None

    def read_appended(self):
        self.handle.seek(self.offset)
        while True:
            data = self.handle.read(READ_CHUNK)
            if not data:
                return
            self.offset += len(data)
            buffer = self.partial + data
            complete = buffer.split(b"\n")
            self.partial = complete.pop()
            for raw in complete:
                announce(raw.decode("utf-8", "replace"))

    def restart(self):
        self.handle.seek(0)
        self.offset = 0
        self.partial = b""


def open_follower(path, history):
    """Open a follower, returning None if the path vanished first (rotation)."""
    try:
        return LogFollower(path, history)
    except FileNotFoundError:
        return None


def follow(root, pinned, history):
    bound_session = None
    follower = None
    waiting_root = False
    waiting_log = None

    while not _stop:
        if pinned is not None:
            target = pinned
        else:
            sessions = session_dirs(root)
            target = sessions[-1] if sessions else None

        if target is None:
            if not waiting_root:
                announce(f"== waiting for a play session under {root} ==")
                waiting_root = True
            time.sleep(POLL_SECONDS)
            continue
        waiting_root = False

        log_path = os.path.join(root, target, LOG_NAME)

        if target != bound_session:
            if follower is not None:
                follower.close()
                follower = None
            bound_session = target
            announce(f"== play session {target} ==")
            announce(f"   {log_path}")
            waiting_log = None

        if follower is None:
            follower = open_follower(log_path, history)
            if follower is None:
                if waiting_log != target:
                    announce(f"waiting for log: {log_path}")
                    waiting_log = target
                time.sleep(POLL_SECONDS)
                continue
            waiting_log = None
            continue

        try:
            stat = os.stat(log_path)
        except FileNotFoundError:
            follower.close()
            follower = None
            announce(f"log removed, waiting for it to reappear: {log_path}")
            waiting_log = target
            time.sleep(POLL_SECONDS)
            continue

        if (stat.st_dev, stat.st_ino) != follower.ident:
            follower.close()
            follower = None
            replacement = open_follower(log_path, history)
            if replacement is None:
                announce(f"log replaced and gone, waiting for it to reappear: {log_path}")
                waiting_log = target
                time.sleep(POLL_SECONDS)
                continue
            follower = replacement
            announce(f"log replaced, re-reading: {log_path}")
            continue

        if stat.st_size < follower.offset:
            follower.restart()
            announce(f"log truncated, re-reading from the start: {log_path}")

        follower.read_appended()
        time.sleep(POLL_SECONDS)

    if follower is not None:
        follower.close()


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="logs-macos.sh",
        description="Follow the newest normal-play FIFA Street session log.",
    )
    parser.add_argument("--root", required=True,
                        help="build/macos/logs/play directory to watch")
    parser.add_argument("--session", default=None,
                        help="pin a single UTC session id (YYYYMMDDTHHMMSSZ)")
    parser.add_argument("--lines", type=int, default=20,
                        help="initial history size per session (default 20)")
    args = parser.parse_args(argv)
    if args.lines < 0:
        parser.error("--lines must be zero or greater")
    if args.session is not None and not SESSION_RE.match(args.session):
        parser.error("--session must look like YYYYMMDDTHHMMSSZ")

    root = os.path.abspath(args.root)
    signal.signal(signal.SIGINT, _request_stop)
    signal.signal(signal.SIGTERM, _request_stop)
    try:
        follow(root, args.session, args.lines)
    except KeyboardInterrupt:
        pass
    announce("stopped watching.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

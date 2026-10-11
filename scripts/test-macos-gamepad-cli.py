#!/usr/bin/env python3
"""Offline wire-format fixture for scripts/gamepad-macos.py.

Runs the real CLI against a minimal in-process AF_UNIX server that speaks the
bridge protocol and checks the exact request frames the CLI emits. This covers
the client half of the contract - buttons, triggers, sticks, an explicit release
and a bounded hold - without launching the game, the SDK or a ReXGlue runtime.

The server here is a test double, not the game bridge: it proves the bytes the
CLI puts on the socket, not that the guest consumes them. Release-on-disconnect
and slot routing are the C++ behavioral test's job
(scripts/test-macos-virtual-input.sh).

Usage: python3 scripts/test-macos-gamepad-cli.py
"""

import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading

MAGIC = 0x52535450
VERSION = 1
REQUEST_BYTES = 24
RESPONSE_BYTES = 16
REQUEST_FORMAT = "<IBBBBHBBhhhhI"
RESPONSE_FORMAT = "<IBBBBHHI"

COMMAND_SET_STATE = 1
COMMAND_PRESS = 2
COMMAND_RELEASE = 3

CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gamepad-macos.py")

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)
        print(f"FAIL {message}")


def decode_request(frame):
    (magic, version, command, player, _reserved, buttons, lt, rt,
     lx, ly, rx, ry, hold_ms) = struct.unpack(REQUEST_FORMAT, frame)
    return {
        "magic": magic, "version": version, "command": command, "player": player,
        "buttons": buttons, "lt": lt, "rt": rt, "lx": lx, "ly": ly,
        "rx": rx, "ry": ry, "hold_ms": hold_ms,
    }


def encode_ok(player):
    return struct.pack(RESPONSE_FORMAT, MAGIC, VERSION, 0, player, 0, 0, 0, 0)


class FakeBridge:
    """Accepts `expected` sequential clients and records one request per client."""

    def __init__(self, path, expected):
        self._path = path
        self._expected = expected
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.bind(path)
        self._sock.listen(4)
        self._sock.settimeout(0.5)
        self._stop = False
        self.frames = []
        self.closed_clients = 0
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def start(self):
        self._thread.start()

    def _serve(self):
        while not self._stop and len(self.frames) < self._expected:
            try:
                conn, _ = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self._handle(conn)

    def _handle(self, conn):
        conn.settimeout(3.0)
        buffered = b""
        try:
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    self.closed_clients += 1
                    break
                buffered += chunk
                while len(buffered) >= REQUEST_BYTES:
                    frame, buffered = buffered[:REQUEST_BYTES], buffered[REQUEST_BYTES:]
                    request = decode_request(frame)
                    self.frames.append(request)
                    conn.sendall(encode_ok(request["player"]))
        except (socket.timeout, OSError):
            pass
        finally:
            conn.close()

    def stop(self):
        self._stop = True
        self._thread.join(timeout=5.0)
        self._sock.close()


CASES = [
    {
        "name": "state sets buttons, both triggers and all sticks",
        "args": ["state", "--player", "0", "--buttons", "A,X", "--lx", "1.0",
                 "--ly", "-1.0", "--rx", "0.5", "--ry", "-0.5",
                 "--lt", "0.4", "--rt", "0.8", "--hold", "0.05"],
        "expected": {"command": COMMAND_SET_STATE, "player": 0, "buttons": 0x5000,
                     "lt": 102, "rt": 204, "lx": 32767, "ly": -32767,
                     "rx": 16384, "ry": -16384, "hold_ms": 50},
    },
    {
        "name": "press holds one button for a bounded window",
        "args": ["press", "--player", "0", "--button", "Start", "--hold", "0.05"],
        "expected": {"command": COMMAND_PRESS, "player": 0, "buttons": 0x0010,
                     "lt": 0, "rt": 0, "lx": 0, "ly": 0,
                     "rx": 0, "ry": 0, "hold_ms": 50},
    },
    {
        "name": "release --all clears every button",
        "args": ["release", "--player", "0", "--all"],
        "expected": {"command": COMMAND_RELEASE, "player": 0, "buttons": 0,
                     "lt": 0, "rt": 0, "lx": 0, "ly": 0,
                     "rx": 0, "ry": 0, "hold_ms": 0},
    },
]


def run_case(case, socket_path):
    result = subprocess.run(
        [sys.executable, CLI, "--socket", socket_path, *case["args"]],
        capture_output=True, text=True, timeout=15,
    )
    check(result.returncode == 0,
          f"{case['name']}: CLI exit {result.returncode} ({result.stderr.strip()})")


def main():
    tmp = tempfile.mkdtemp(prefix="restreet-cli-")
    socket_path = os.path.join(tmp, "ctl.sock")
    bridge = FakeBridge(socket_path, expected=len(CASES))
    bridge.start()
    try:
        for case in CASES:
            run_case(case, socket_path)
    finally:
        bridge.stop()

    check(len(bridge.frames) == len(CASES),
          f"expected {len(CASES)} request frames, saw {len(bridge.frames)}")

    for case, frame in zip(CASES, bridge.frames):
        expected = case["expected"]
        check(frame["magic"] == MAGIC and frame["version"] == VERSION,
              f"{case['name']}: bad magic/version {frame['magic']:#x}/{frame['version']}")
        for field, value in expected.items():
            check(frame[field] == value,
                  f"{case['name']}: {field} expected {value}, got {frame[field]}")

    # The CLI closes each connection after its bounded hold, so the server sees
    # every client disconnect rather than a socket held open indefinitely.
    check(bridge.closed_clients == len(CASES),
          f"expected {len(CASES)} client disconnects, saw {bridge.closed_clients}")

    try:
        os.unlink(socket_path)
        os.rmdir(tmp)
    except OSError:
        pass

    if failures:
        print(f"{len(failures)} check(s) failed")
        return 1
    print("OK   gamepad CLI wire-format fixture passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Send human/AI input to the ReStreet macOS virtual-gamepad bridge.

This talks to the small local control protocol served by the game's opt-in
bridge (see docs/BUILDING-MACOS.md, "Virtual gamepad bridge"). It uses purpose-
built SDK input, not OS keyboard events, window automation or accessibility:
the bridge driver feeds the guest the same XInput state a real pad would.

The bridge is connection-scoped: the state a command sets lives only while the
socket connection is open (and, if a hold is given, no longer than that). The
CLI therefore keeps the connection open for the whole --hold window and closes
it afterwards, which releases the state on both sides. `--hold 0` keeps the
connection open until Ctrl-C.

Examples:
    # Start pulse on the AI player (slot 0), 0.6 s by default.
    RESTREET_CONTROL_SOCKET=/tmp/restreet-ctl.sock gamepad-macos.py press --button Start

    # Left stick full-right and A held for 1.5 s on player 1.
    gamepad-macos.py state --player 1 --buttons A --lx 1.0 --hold 1.5

    # Release the B button on player 0 (no --button / --all releases everything).
    gamepad-macos.py release --player 0 --button B

    # Hold the current state until Ctrl-C.
    gamepad-macos.py state --player 0 --buttons A --hold 0
"""

import argparse
import os
import socket
import struct
import sys
import time

MAGIC = 0x52535450
VERSION = 1
REQUEST_BYTES = 24
RESPONSE_BYTES = 16
MAX_HOLD_MS = 10 * 60 * 1000
REQUEST_FORMAT = "<IBBBBHBBhhhhI"  # magic, version, command, player, reserved, buttons, lt, rt, lx, ly, rx, ry, hold_ms
RESPONSE_FORMAT = "<IBBBBHHI"     # magic, version, status, player, reserved, buttons, reserved, packet

COMMAND_SET_STATE = 1
COMMAND_PRESS = 2
COMMAND_RELEASE = 3
COMMAND_PING = 4

STATUS_NAMES = {
    0: "ok",
    1: "bad_magic",
    2: "bad_version",
    3: "bad_length",
    4: "bad_command",
    5: "bad_player",
    6: "player_not_bridged",
}

# XInput button bit values (match rex::input::X_INPUT_GAMEPAD_BUTTON).
BUTTONS = {
    "dpadup": 0x0001,
    "dpaddown": 0x0002,
    "dpadleft": 0x0004,
    "dpadright": 0x0008,
    "start": 0x0010,
    "back": 0x0020,
    "lthumb": 0x0040,
    "rthumb": 0x0080,
    "lshoulder": 0x0100,
    "rshoulder": 0x0200,
    "guide": 0x0400,
    "a": 0x1000,
    "b": 0x2000,
    "x": 0x4000,
    "y": 0x8000,
}
BUTTON_ALIASES = {"lb": "lshoulder", "rb": "rshoulder", "l3": "lthumb", "r3": "rthumb"}


def parse_button(token):
    key = token.strip().lower()
    key = BUTTON_ALIASES.get(key, key)
    if key not in BUTTONS:
        raise argparse.ArgumentTypeError(f"unknown button: {token}")
    return BUTTONS[key]


def parse_buttons(value):
    mask = 0
    for token in value.split(","):
        if token.strip():
            mask |= parse_button(token)
    return mask


def parse_stick(value):
    try:
        f = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a number: {value}")
    if not -1.0 <= f <= 1.0:
        raise argparse.ArgumentTypeError(f"stick value must be within -1..1: {value}")
    return int(round(f * 32767.0))


def parse_trigger(value):
    try:
        f = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a number: {value}")
    if not 0.0 <= f <= 1.0:
        raise argparse.ArgumentTypeError(f"trigger value must be within 0..1: {value}")
    return int(round(f * 255.0))


def build_request(command, player, buttons=0, lt=0, rt=0, lx=0, ly=0, rx=0, ry=0, hold_ms=0):
    hold_ms = max(0, min(int(hold_ms), MAX_HOLD_MS))
    return struct.pack(
        REQUEST_FORMAT,
        MAGIC,
        VERSION,
        command,
        player,
        0,
        buttons & 0xFFFF,
        lt & 0xFF,
        rt & 0xFF,
        lx,
        ly,
        rx,
        ry,
        hold_ms,
    )


def recv_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("bridge closed the connection")
        data.extend(chunk)
    return bytes(data)


class BridgeConnection:
    """One connection-scoped control session; the socket stays open until close."""

    def __init__(self, socket_path):
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.settimeout(3.0)
        self._sock.connect(socket_path)

    def command(self, request):
        self._sock.sendall(request)
        response = recv_exact(self._sock, RESPONSE_BYTES)
        magic, version, status, player, _reserved, buttons, _reserved2, packet = struct.unpack(
            RESPONSE_FORMAT, response
        )
        if magic != MAGIC:
            raise RuntimeError("bad response magic")
        if version != VERSION:
            raise RuntimeError(f"unexpected response version {version}")
        return status, player, buttons, packet

    def close(self):
        self._sock.close()


def emit_status(status, player, buttons, packet):
    name = STATUS_NAMES.get(status, f"unknown({status})")
    if status == 0:
        print(f"ok player={player} buttons=0x{buttons:04x} packet={packet}")
    else:
        print(f"error status={name} player={player}", file=sys.stderr)


def wait_hold(hold_seconds):
    if hold_seconds == 0:
        print("holding; press Ctrl-C to release", file=sys.stderr)
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            return
    time.sleep(hold_seconds)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--socket", default=os.environ.get("RESTREET_CONTROL_SOCKET"),
                        help="absolute Unix-domain socket path (default $RESTREET_CONTROL_SOCKET)")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_player(p):
        p.add_argument("--player", type=int, choices=(0, 1), default=0,
                       help="guest player slot (default 0)")

    p_state = sub.add_parser("state", help="replace the whole gamepad state")
    add_player(p_state)
    p_state.add_argument("--buttons", type=parse_buttons, default=0)
    p_state.add_argument("--lt", type=parse_trigger, default=0)
    p_state.add_argument("--rt", type=parse_trigger, default=0)
    p_state.add_argument("--lx", type=parse_stick, default=0)
    p_state.add_argument("--ly", type=parse_stick, default=0)
    p_state.add_argument("--rx", type=parse_stick, default=0)
    p_state.add_argument("--ry", type=parse_stick, default=0)
    p_state.add_argument("--hold", type=float, default=0.6,
                         help="seconds to hold (0 = until Ctrl-C)")

    p_press = sub.add_parser("press", help="press buttons (held for --hold seconds)")
    add_player(p_press)
    p_press.add_argument("--button", action="append", type=parse_button, default=[], required=True)
    p_press.add_argument("--hold", type=float, default=0.6,
                         help="seconds to hold (0 = until Ctrl-C)")

    p_release = sub.add_parser("release", help="release buttons (no --button = release all)")
    add_player(p_release)
    p_release.add_argument("--button", action="append", type=parse_button, default=[])
    p_release.add_argument("--all", action="store_true", help="release every button")

    args = parser.parse_args(argv)
    if not args.socket:
        parser.error("no socket given; set RESTREET_CONTROL_SOCKET or pass --socket")
    if not os.path.isabs(args.socket):
        parser.error("socket path must be absolute")

    if args.command == "state":
        request = build_request(COMMAND_SET_STATE, args.player, args.buttons, args.lt, args.rt,
                                args.lx, args.ly, args.rx, args.ry,
                                int(round(args.hold * 1000)))
    elif args.command == "press":
        mask = 0
        for button in args.button:
            mask |= button
        request = build_request(COMMAND_PRESS, args.player, mask,
                                hold_ms=int(round(args.hold * 1000)))
    else:  # release
        mask = 0
        if not args.all:
            for button in args.button:
                mask |= button
        request = build_request(COMMAND_RELEASE, args.player, mask)

    connection = BridgeConnection(args.socket)
    try:
        status, player, buttons, packet = connection.command(request)
        emit_status(status, player, buttons, packet)
        if status == 0 and args.command != "release":
            wait_hold(max(0.0, args.hold))
    finally:
        connection.close()

    return 0 if status == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

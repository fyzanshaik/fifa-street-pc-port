#!/usr/bin/env python3
"""Fail-closed check that the guest startup-ordering hooks landed correctly.

The macOS fix for the sub_820509A8 worker-start race is expressed as two
[[midasm_hook]] entries in config/default_overrides.toml. Codegen emits them
into the generated entrypoint translation unit at fixed guest instruction
addresses (0x82050A00 and 0x82050A7C). If the SDK, the guest image or the
config ever drift so those addresses no longer match, the hooks are silently
dropped and the race returns. This script aborts the build in that case.

It verifies, inside the generated sub_820509A8 definition:
  * the hoist call is present exactly once and sits immediately before the
    spawn-argument setup (lis r11,-32251);
  * the hoist runs before the spawn (sub_82105948) and the "already hoisted"
    check runs after it, before the wait (sub_82050820);
  * the check jumps to the guest instruction just before the wait (0x82050ABC),
    so the redundant constructions are skipped rather than overwriting and
    leaking the hoisted wrappers.

Exit codes: 0 = verified, 1 = verification failed, 2 = inputs missing.
"""

import argparse
import glob
import os
import re
import sys

FUNC = "sub_820509A8"
HOIST_CALL = "ReStreetHoistStartEvents(ctx.r31);"
HOISTED_CHECK = "ReStreetStartEventsHoisted(ctx.r31)"
SPAWN_CALL = "sub_82105948(ctx, base);"
WAIT_CALL = "sub_82050820(ctx, base);"
SKIP_LABEL = "loc_82050ABC:"
SKIP_GOTO = "goto loc_82050ABC;"
SPAWN_ARGS_ANCHOR = "ctx.r11.s64 = -2113601536;"


def fail(message):
    print("FAIL " + message)
    sys.exit(1)


def extract_function(text, name):
    start = text.find("DEFINE_REX_FUNC(%s)" % name)
    if start < 0:
        return None
    end = text.find("DEFINE_REX_FUNC(", start + 1)
    return text[start:end] if end > 0 else text[start:]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("workspace", help="codegen workspace (contains generated/)")
    args = parser.parse_args()

    # The entrypoint partition index is not part of the contract; find the unit
    # that actually defines the function.
    pattern = os.path.join(args.workspace, "generated", "default", "fifastreet_recomp.*.cpp")
    matches = []
    for path in sorted(glob.glob(pattern)):
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            if ("DEFINE_REX_FUNC(%s)" % FUNC) in handle.read():
                matches.append(path)
    if not matches:
        print("FAIL no generated entrypoint unit defines %s (pattern: %s)" % (FUNC, pattern))
        sys.exit(2)
    if len(matches) > 1:
        fail("%s defined in more than one generated unit: %s" % (FUNC, matches))

    path = matches[0]
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    body = extract_function(text, FUNC)
    if not body:
        fail("could not extract %s body from %s" % (FUNC, path))

    if body.count(HOIST_CALL) != 1:
        fail("expected exactly one %r in %s, found %d" % (HOIST_CALL, path, body.count(HOIST_CALL)))
    if body.count(HOISTED_CHECK) != 1:
        fail(
            "expected exactly one %r in %s, found %d"
            % (HOISTED_CHECK, path, body.count(HOISTED_CHECK))
        )

    # The hoist must sit immediately before the spawn-argument setup so it runs
    # after the preceding call and before the spawn: comment line, hoist call,
    # then the lis. Allow only whitespace between them.
    hoist_before_args = re.search(
        re.escape(HOIST_CALL) + r"\s*\n\s*" + re.escape(SPAWN_ARGS_ANCHOR), body
    )
    if not hoist_before_args:
        fail(
            "hoist call is not immediately before the spawn-argument setup (%r) in %s"
            % (SPAWN_ARGS_ANCHOR, path)
        )

    # The skip must be a conditional jump to the instruction before the wait.
    skip = re.search(
        r"if\s*\(\s*" + re.escape(HOISTED_CHECK) + r"\s*\)\s*\{\s*\n\s*" + re.escape(SKIP_GOTO),
        body,
    )
    if not skip:
        fail("hoisted check does not jump to the pre-wait instruction in %s" % path)
    if SKIP_LABEL not in body:
        fail("skip target label %r is missing in %s" % (SKIP_LABEL, path))

    # Ordering: hoist < spawn < hoisted-check < wait.
    positions = {
        "hoist": body.find(HOIST_CALL),
        "spawn": body.find(SPAWN_CALL),
        "hoisted-check": body.find(HOISTED_CHECK),
        "wait": body.find(WAIT_CALL),
    }
    for name, index in positions.items():
        if index < 0:
            fail("missing %r in %s" % (name, path))
    if not (
        positions["hoist"]
        < positions["spawn"]
        < positions["hoisted-check"]
        < positions["wait"]
    ):
        fail(
            "unexpected instruction order in %s: %s"
            % (path, {k: v for k, v in sorted(positions.items(), key=lambda kv: kv[1])})
        )

    print("OK   startup-ordering hooks verified in %s" % path)
    sys.exit(0)


if __name__ == "__main__":
    main()

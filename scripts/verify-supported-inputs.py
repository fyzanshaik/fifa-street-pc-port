#!/usr/bin/env python3
"""Fail-closed check that GameData is the supported FIFA Street (2012) revision.

The macOS recompiled startup hooks are keyed to fixed guest instruction
addresses, so only the exact original revision this source tree was validated
against can be recompiled correctly. The supported set is source-controlled in
scripts/supported-macos-inputs.json and was measured from our own extracted
GameData; it is not an externally published official manifest.

An installer precompiled.json may be supplied for compatibility
(FIFA_INSTALLER_MANIFEST). When it is, it must describe the same revision: a
manifest for a different region/revision cannot silently authorize a build.

Exit codes: 0 = supported, 1 = not supported, 2 = missing or invalid inputs.
"""

import argparse
import hashlib
import json
import os
import sys

HEX_DIGITS = set("0123456789abcdefABCDEF")


def fail(message, code):
    print(message, file=sys.stderr)
    sys.exit(code)


def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as stream:
            return json.load(stream)
    except FileNotFoundError:
        fail(f"{what} not found: {path}", 2)
    except Exception as exc:  # noqa: BLE001 - report the parse failure verbatim
        fail(f"cannot read {what} {path}: {exc}", 2)


def load_supported(spec_path):
    data = load_json(spec_path, "supported-input set")
    modules = data.get("modules")
    if not isinstance(modules, dict) or not modules:
        fail(f"{spec_path} has no non-empty 'modules' map", 2)
    for rel, digest in modules.items():
        if not isinstance(digest, str) or len(digest) != 64 or not set(digest) <= HEX_DIGITS:
            fail(f"{spec_path}: {rel} has an invalid SHA-256", 2)
    return modules


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, help="supported-input JSON")
    parser.add_argument("--gamedata", required=True, help="extracted GameData root")
    parser.add_argument("--manifest", help="optional installer precompiled.json to cross-check")
    args = parser.parse_args()

    if not os.path.isdir(args.gamedata):
        fail(f"game-data root not found: {args.gamedata}", 2)

    supported = load_supported(args.spec)

    manifest_inputs = None
    if args.manifest:
        manifest = load_json(args.manifest, "installer manifest")
        manifest_inputs = manifest.get("Inputs")
        if not isinstance(manifest_inputs, dict):
            fail(
                f"{args.manifest} has no 'Inputs' map (expected the installer's precompiled.json)",
                2,
            )

    bad = False
    for rel, expected in supported.items():
        path = os.path.join(args.gamedata, rel)
        if not os.path.isfile(path):
            print(f"missing module file: {rel}", file=sys.stderr)
            bad = True
            continue
        actual = sha256_file(path)
        if actual.lower() != expected.lower():
            print(
                f"{rel}: SHA-256 mismatch (supported {expected.lower()}, got {actual})",
                file=sys.stderr,
            )
            bad = True
            continue
        if manifest_inputs is not None and manifest_inputs.get(rel, "").lower() != expected.lower():
            declared = manifest_inputs.get(rel)
            print(
                f"{rel}: installer manifest declares {declared!r}, which is not the "
                f"supported revision ({expected.lower()})",
                file=sys.stderr,
            )
            bad = True

    if bad:
        print("GameData is not the supported FIFA Street (2012) revision.", file=sys.stderr)
        print(
            "Recompiled startup hooks target fixed guest addresses, so a different "
            "region or revision cannot be compiled correctly.",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"original module SHA-256 values match the supported revision ({args.spec})")
    if args.manifest:
        print(f"installer manifest describes the same revision ({args.manifest})")
    sys.exit(0)


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
# Focused offline VFS fixture for the menu-credit profile layout.
#
# Compiles scripts/macos_credit_vfs_probe.cpp against the pinned/installed
# runtime dylib and drives the real rex::filesystem HostPathDevice on synthetic
# trees. It verifies the layout fact behind the startup regression: the pinned
# runtime classifies entries from dirent d_type, so a *symlinked directory* is
# reported as a file, is never recursed into, and a nested guest leaf
# (data/loc/locale.big) cannot be opened. Real directories resolve.
#
# Requires a prior Mac build (the runtime dylib and SDK headers). When those are
# absent it skips cleanly, so the focused credit checks stay usable anywhere.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$REPO/build/macos/out/librexruntime.dylib"
SDK_INCLUDE="$REPO/ReXGlue/include"

if [ ! -f "$RUNTIME" ] || [ ! -f "$SDK_INCLUDE/rex/filesystem.h" ]; then
    echo "skip: needs build/macos/out/librexruntime.dylib and ReXGlue/include (run a Mac build first)"
    exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/macos-credit-vfs.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

probe="$tmp/vfs_probe"
clang++ -std=c++23 \
    -I "$SDK_INCLUDE" \
    -I "$REPO/ReXGlue/thirdparty/fmt/include" \
    -I "$REPO/ReXGlue/thirdparty/spdlog/include" \
    -I "$REPO/ReXGlue/thirdparty/tomlplusplus/include" \
    -I "$REPO/ReXGlue/thirdparty/utfcpp/source" \
    "$REPO/scripts/macos_credit_vfs_probe.cpp" \
    -L "$REPO/build/macos/out" -lrexruntime \
    -Wl,-rpath,"$REPO/build/macos/out" \
    -o "$probe"

guest_path="data/loc/locale.big"

# Original assets: real nested directories, as the owner's GameData is laid out.
mkdir -p "$tmp/original/data/loc" "$tmp/original/dlc"
printf 'locale-bytes' > "$tmp/original/data/loc/locale.big"
printf 'dlc-bytes' > "$tmp/original/dlc/pack.big"

# Previous builder layout: every top-level entry, including directories, was a
# symlink. This must be rejected by the pinned runtime.
mkdir -p "$tmp/old"
ln -s "$tmp/original/data"   "$tmp/old/data"
ln -s "$tmp/original/dlc"    "$tmp/old/dlc"

# Fixed builder layout: directories are real, files stay symlinks.
mkdir -p "$tmp/new/data/loc" "$tmp/new/dlc"
ln -s "$tmp/original/data/loc/locale.big" "$tmp/new/data/loc/locale.big"
ln -s "$tmp/original/dlc/pack.big"        "$tmp/new/dlc/pack.big"

fail=0
echo "== old (symlinked directories) =="
old_out="$("$probe" "$tmp/old" "$guest_path" || true)"
echo "$old_out"
grep -q "^entry data file " <<<"$old_out" || { echo "FAIL: expected data seen as file"; fail=1; }
grep -q "^OPENFILE_LEAF NULL" <<<"$old_out" || { echo "FAIL: expected nested leaf lookup to fail"; fail=1; }
grep -q "^OPENFILE_BASE OK" <<<"$old_out" || { echo "FAIL: expected parent to resolve lazily"; fail=1; }

echo "== new (real directories) =="
new_out="$("$probe" "$tmp/new" "$guest_path" || true)"
echo "$new_out"
grep -q "^entry data dir " <<<"$new_out" || { echo "FAIL: expected data seen as dir"; fail=1; }
grep -q "^OPENFILE_LEAF OK" <<<"$new_out" || { echo "FAIL: expected nested leaf lookup to succeed"; fail=1; }

# End to end: the real profile builder's output must satisfy the same probe.
echo "== built profile (real builder) =="
profile="$(FIFA_REPO="$REPO" python3 - "$tmp" <<'PY'
import os
import sys

repo = os.environ["FIFA_REPO"]
out = sys.argv[1]
sys.path.insert(0, os.path.join(repo, "scripts"))
import macos_credit_test as fixture
import macos_credit_patch as credit

source = os.path.join(out, "source")
targets = fixture.make_source(source, fixture.DEFAULT_SPECS)
profile = os.path.join(out, "profile")
with fixture.with_targets(targets):
    credit.build_profile(source, profile)
print(profile)
PY
)"
profile_out="$("$probe" "$profile" "$guest_path" || true)"
echo "$profile_out"
grep -q "^entry data dir " <<<"$profile_out" || { echo "FAIL: built profile has a symlinked data dir"; fail=1; }
grep -q "^OPENFILE_LEAF OK" <<<"$profile_out" || { echo "FAIL: built profile nested leaf lookup failed"; fail=1; }

if [ "$fail" -ne 0 ]; then
    echo "macos-credit-vfs: FAILED"
    exit 1
fi
echo "macos-credit-vfs: ok"

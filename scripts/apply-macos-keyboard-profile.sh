#!/usr/bin/env bash
#
# apply-macos-keyboard-profile.sh - reapply the shipped keyboard profile to an
# already-built fifastreet.toml, replacing only the keyboard bindings.
#
# A normal build writes the profile for you. This is the small recovery command
# for a config whose keybinds were edited by hand, or a bundle built before the
# current profile.
#
# What it changes, and only this:
#   - removes every keybind_* = "..." assignment anywhere in the config;
#   - removes one previously applied copy of the profile block (its exact lines,
#     including the generated header comment), wherever it sits;
#   - writes the current profile once at the top of the file, before any [table]
#     header, so the binds stay in root scope.
# The root-scope placement matters: the SDK's TOML loader prefixes keys with the
# table path, so a keybind written after "[custom]" would load as
# "custom_keybind_a" and never reach the MnK driver.
# Everything else - every non-key setting, comment and section, before or after
# the profile or the bindings - is kept verbatim. Repeated runs converge on the
# same bytes, and the config's permissions are preserved. The profile is
# validated first; an empty, malformed or duplicate-binding profile fails before
# the config is touched.
#
# Usage: scripts/apply-macos-keyboard-profile.sh [--config PATH] [--profile PATH]
#        --config   target fifastreet.toml (default: <FIFA_BUILD_ROOT>/out/fifastreet.toml)
#        --profile  shipped profile      (default: config/macos/keyboard-arrows.toml)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_ROOT="${FIFA_BUILD_ROOT:-${ROOT}/build/macos}"

CONFIG="${BUILD_ROOT}/out/fifastreet.toml"
PROFILE="${ROOT}/config/macos/keyboard-arrows.toml"

usage() {
  cat <<EOF
Usage: scripts/apply-macos-keyboard-profile.sh [options]

Options:
  --config PATH    Target fifastreet.toml (default: ${CONFIG})
  --profile PATH   Profile to apply (default: ${PROFILE})
  -h, --help       Show this help

Replaces only keybind_* assignments and the previously applied profile block;
every other setting, comment and section is preserved. The profile is written at
the top of the file, before any [table] header, to keep the binds in root scope.

Environment: FIFA_BUILD_ROOT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)  [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--config requires a path" >&2; exit 2; }; CONFIG="$2"; shift 2 ;;
    --profile) [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--profile requires a path" >&2; exit 2; }; PROFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${CONFIG}" ]] || die "config not found: ${CONFIG}
Run scripts/build-macos.sh first, or pass --config <path/to/fifastreet.toml>"
[[ -f "${PROFILE}" ]] || die "profile not found: ${PROFILE}"
[[ -w "${CONFIG}" ]] || die "config is not writable: ${CONFIG}"
command -v python3 >/dev/null 2>&1 || die "python3 is required to apply a keyboard profile"

# Write the new config to a sibling temp file so the final replace is atomic and
# a validation failure leaves the original config untouched.
TMP="$(mktemp "${CONFIG}.XXXXXX")"
cleanup() { rm -f "${TMP}"; }
trap cleanup EXIT

# The parser is a safe line-based TOML-subset rewrite: it never reserialises the
# file (which would drop comments and reorder keys) and never needs tomllib, so
# plain Python 3 is sufficient.
if ! python3 - "${CONFIG}" "${PROFILE}" "${TMP}" <<'PY'
import re
import sys

config_path, profile_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

# A keybind assignment as the tool writes it, with a single well-formed TOML
# basic string value. The character set is the conservative subset the shipped
# profile and key names need (tokens, comma separators and '+' modifier chains);
# no escapes. This rejects invalid TOML such as keybind_a = "Space" "junk".
quoted_value = rb'"[A-Za-z0-9_, +-]*"'
valid_assign = re.compile(rb'^[ \t]*keybind_[A-Za-z0-9_]+[ \t]*=[ \t]*' + quoted_value + rb'[ \t\r]*$')
# Any keybind assignment, however malformed, is ours to remove.
any_assign = re.compile(rb'^[ \t]*keybind_[A-Za-z0-9_]+[ \t]*=')
key_name = re.compile(rb'^[ \t]*(keybind_[A-Za-z0-9_]+)[ \t]*=')


def fail(message):
    sys.stderr.write("ERROR: %s\n" % message)
    sys.exit(1)


def read_bytes(path):
    with open(path, 'rb') as handle:
        return handle.read()


def split_lines(data):
    lines = data.split(b'\n')
    if lines and lines[-1] == b'':
        lines = lines[:-1]
    return lines


profile_bytes = read_bytes(profile_path)
profile_lines = split_lines(profile_bytes)
if not [line for line in profile_lines if line.strip()]:
    fail("profile is empty: %s" % profile_path)

bindings = []
for line in profile_lines:
    if not line.strip():
        continue
    if line.lstrip().startswith(b'#'):
        continue
    if not valid_assign.match(line):
        fail("malformed profile line (expected a comment or keybind_* = \"...\"): %s"
             % line.decode('utf-8', 'replace'))
    bindings.append(key_name.match(line).group(1))

if not bindings:
    fail("profile defines no keybind_* assignments: %s" % profile_path)

seen = set()
duplicates = []
for name in bindings:
    if name in seen and name not in duplicates:
        duplicates.append(name)
    seen.add(name)
if duplicates:
    fail("profile has duplicate keybind keys: %s"
         % b", ".join(duplicates).decode('utf-8', 'replace'))

config_lines = split_lines(read_bytes(config_path))

# Drop one exact copy of the profile block and every stray keybind assignment;
# keep everything else in order.
kept = []
index = 0
profile_len = len(profile_lines)
total = len(config_lines)
while index < total:
    if profile_len and config_lines[index:index + profile_len] == profile_lines:
        index += profile_len
        continue
    if any_assign.match(config_lines[index]):
        index += 1
        continue
    kept.append(config_lines[index])
    index += 1

# Prepend the profile so its keybind_* keys stay in root scope, ahead of any
# [table] header in the retained config. Nothing is inserted between the block
# and the body: a second run then finds the same block at the same offset and
# converges on the same bytes.
result = b'\n'.join(profile_lines) + b'\n'
if kept:
    result += b'\n'.join(kept) + b'\n'

with open(out_path, 'wb') as handle:
    handle.write(result)
PY
then
  die "profile apply failed; ${CONFIG} left unchanged"
fi

# Post-conditions on the staged file. These run before the replace, so a failed
# check still leaves the original config byte-for-byte intact.
assign='^[[:space:]]*keybind_[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*".+"'
want="$(grep -cE "${assign}" "${PROFILE}" || true)"
got="$(grep -cE "${assign}" "${TMP}" || true)"
[[ "${got}" == "${want}" ]] || die "reapply produced ${got} keybind assignments (expected ${want}); ${CONFIG} left unchanged"
dupes="$(grep -oE 'keybind_[A-Za-z0-9_]+' "${TMP}" | sort | uniq -d || true)"
[[ -z "${dupes}" ]] || die "duplicate keybind assignments after reapply: ${dupes}; ${CONFIG} left unchanged"

# The binds must be in root scope: a keybind under a [table] header loads as
# "<table>_keybind_*" and the MnK driver never sees it.
first_table="$(grep -nE '^[[:space:]]*\[[^]]*\]' "${TMP}" | head -n1 | cut -d: -f1 || true)"
last_bind="$(grep -nE '^[[:space:]]*keybind_[A-Za-z0-9_]+[[:space:]]*=' "${TMP}" | tail -n1 | cut -d: -f1 || true)"
if [[ -n "${first_table}" && -n "${last_bind}" && "${last_bind}" -ge "${first_table}" ]]; then
  die "reapplied keybinds are not in root scope (keybind at line ${last_bind}, first [table] at line ${first_table}); ${CONFIG} left unchanged"
fi

# Preserve the target's permissions (mktemp gives a fresh 0600 inode).
MODE="$(stat -f '%Lp' "${CONFIG}" 2>/dev/null || stat -c '%a' "${CONFIG}" 2>/dev/null || true)"
[[ -z "${MODE}" ]] || chmod "${MODE}" "${TMP}"

mv "${TMP}" "${CONFIG}"
trap - EXIT
echo "OK   reapplied ${PROFILE##*/} (${want} keybind assignments) to ${CONFIG}"

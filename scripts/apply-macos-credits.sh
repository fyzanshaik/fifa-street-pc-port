#!/usr/bin/env bash
# Build a preservation profile that adds the macOS-port credit line.
#
# Draws "macOS port: fyzanshaik" below the existing upstream credit, directly in
# the press-start and main-menu textures, so it scales with them, appears only on
# those screens and never during gameplay. The branded logo and the upstream
# credit are left byte-for-byte intact; only the DXT5/BC3 blocks the new line
# touches are rewritten.
#
# Nothing is written into the original GameData. The profile is a fresh owned
# directory that symlinks every unrelated original file and holds an APFS
# copy-on-write clone of data1.big; only that clone is edited, then the complete
# profile is published atomically.
#
# Usage:
#   scripts/apply-macos-credits.sh --profile DIR [--gamedata DIR] [--dry-run]
#   scripts/apply-macos-credits.sh --check [--gamedata DIR]
#
#   --gamedata DIR   Original, unmodified GameData. Defaults to the current
#                    app's Contents/MacOS/GameData link.
#   --profile DIR    Destination profile directory to build.
#   --check          Validate the source assets only; no filesystem changes.
#   --dry-run        Report what the build would do; no filesystem changes.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

mode="build"
dry=0
gamedata=""
profile=""

usage() {
    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
}

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --gamedata) [ $# -ge 2 ] || die "--gamedata requires a value"; gamedata="$2"; shift 2 ;;
        --profile)  [ $# -ge 2 ] || die "--profile requires a value";  profile="$2";  shift 2 ;;
        --check)    mode="check"; shift ;;
        --dry-run)  dry=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

if [ "$mode" = "check" ]; then
    [ -z "$profile" ] || die "--check validates the source, not a profile; drop --profile"
    [ "$dry" -eq 0 ] || die "--check already performs no changes; drop --dry-run"
    if [ -n "$gamedata" ]; then
        exec python3 "$REPO/scripts/macos_credit_patch.py" check --gamedata "$gamedata"
    fi
    exec python3 "$REPO/scripts/macos_credit_patch.py" check
fi

[ -n "$profile" ] || die "--profile DIR is required (try --help)"

args=(build-profile --profile "$profile")
[ -n "$gamedata" ] && args+=(--gamedata "$gamedata")
[ "$dry" -eq 1 ] && args+=(--dry-run)

python3 "$REPO/scripts/macos_credit_patch.py" "${args[@]}"

if [ "$dry" -eq 0 ]; then
    cat >&2 <<EOF

Profile ready. Package or run the app against it, for example:
  scripts/package-macos-app.sh --gamedata "$profile"
The original GameData and all unrelated files are untouched; the profile holds
an APFS copy-on-write clone of data1.big plus symlinks to everything else.
EOF
fi

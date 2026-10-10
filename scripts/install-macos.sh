#!/usr/bin/env bash
#
# install-macos.sh - opt-in install of an already-built "FIFA Street.app".
#
# Copies the packaged bundle to a destination (default ~/Applications) so it can
# be launched from Finder or Launchpad, not only from the repository's
# git-ignored build tree. It never builds, never edits the source bundle, never
# uses sudo and never changes any global setting.
#
# GameData must be the absolute symlink the packager writes to the private game
# extract, so nothing but the link is copied. A real asset directory, a relative
# link or a dangling link is refused: installing either would copy the game data
# or produce a bundle that cannot find it.
#
# The destination is refused when it resolves to the source bundle itself or to
# any path inside it, so an alias (symlinked parent, ./ or ../ path) or a
# not-yet-existing descendant cannot make this command copy the bundle into its
# own tree, or move or delete the source. Rollback uses an owned staging
# directory and never touches a user-visible "<dest>.previous" backup.
#
# Usage: scripts/install-macos.sh [--app PATH] [--dest DIR] [--force]
#        --app   bundle to install   (default: <FIFA_BUILD_ROOT>/out/FIFA Street.app)
#        --dest  target directory     (default: ~/Applications)
#        --force replace an existing bundle at the destination
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_ROOT="${FIFA_BUILD_ROOT:-${ROOT}/build/macos}"

APP="${BUILD_ROOT}/out/FIFA Street.app"
DEST="${HOME}/Applications"
FORCE=0

usage() {
  cat <<EOF
Usage: scripts/install-macos.sh [options]

Options:
  --app PATH   Built bundle to install (default: ${APP})
  --dest DIR   Destination directory (default: ${DEST})
  --force      Replace an existing bundle at the destination
  -h, --help   Show this help

Environment: FIFA_BUILD_ROOT

The bundle's GameData must be an absolute symlink to the game-data tree; no
game assets are ever copied. No sudo, no global registration, no auto-launch.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)   [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--app requires a path" >&2; exit 2; }; APP="$2"; shift 2 ;;
    --dest)  [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--dest requires a path" >&2; exit 2; }; DEST="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

# Canonicalise a path that may not exist yet: resolve the deepest existing
# ancestor with pwd -P (so symlinked parents are followed) and re-append the
# missing components. This lets the destination safety check run before mkdir.
canon_path() {
  local path="$1" suffix="" base parent dir
  if [[ -d "${path}" ]]; then
    (cd "${path}" && pwd -P)
    return
  fi
  if [[ -e "${path}" ]]; then
    dir="$(dirname "${path}")"
    printf '%s/%s\n' "$(canon_path "${dir}")" "$(basename "${path}")"
    return
  fi
  parent="${path}"
  while [[ ! -e "${parent}" && "${parent}" != "/" && "${parent}" != "." ]]; do
    suffix="/$(basename "${parent}")${suffix}"
    parent="$(dirname "${parent}")"
  done
  base="$(cd "${parent}" && pwd -P)"
  printf '%s%s\n' "${base}" "${suffix}"
}

[[ "$(uname -s)" == "Darwin" ]] || die "this script only runs on macOS"
[[ -d "${APP}" ]] || die "built bundle not found: ${APP}
Build it first: scripts/build-macos.sh --gamedata <path>/GameData"
# Canonicalise the source bundle first, so a relative or symlinked --app cannot
# sneak past the destination comparison below.
APP="$(cd "${APP}" && pwd -P)"
SRC_MACOS="${APP}/Contents/MacOS"
[[ -f "${SRC_MACOS}/fifastreet" ]] || die "bundle has no executable: ${SRC_MACOS}/fifastreet"

# Game-data linkage: GameData must be an absolute symlink resolving to a tree
# holding default.xex. Anything else is a clear failure, not a silently broken
# (or asset-copying) install.
GAMEDATA="${SRC_MACOS}/GameData"
[[ -L "${GAMEDATA}" ]] || die "bundle GameData must be an absolute symlink to the game-data tree: ${GAMEDATA}
Re-create the bundle with: scripts/package-macos-app.sh --gamedata <abs>/GameData"
LINK_TARGET="$(readlink "${GAMEDATA}")"
case "${LINK_TARGET}" in
  /*) : ;;
  *) die "bundle GameData symlink is not absolute: -> ${LINK_TARGET}
Re-create the bundle with: scripts/package-macos-app.sh --gamedata <abs>/GameData" ;;
esac
[[ -d "${GAMEDATA}" && -f "${GAMEDATA}/default.xex" ]] \
  || die "bundle GameData symlink does not resolve to default.xex: -> ${LINK_TARGET}
Re-create the bundle with: scripts/package-macos-app.sh --gamedata <abs>/GameData"

# Compare canonical paths, not strings: "${DEST}/../src", a symlinked parent or
# a not-yet-existing descendant can all name the source bundle (or a path inside
# it) while reading as a different path. Reject that before mkdir/ditto so the
# bundle can never be copied into its own tree.
DEST_CANON="$(canon_path "${DEST}")"
DEST_APP="${DEST_CANON}/$(basename "${APP}")"
case "${DEST_APP}" in
  "${APP}"|"${APP}"/*)
    die "destination resolves to the source bundle or a path inside it: ${DEST_APP}" ;;
esac

mkdir -p "${DEST}"
[[ -d "${DEST}" ]] || die "destination is not a directory: ${DEST}"
[[ -w "${DEST}" ]] || die "destination is not writable: ${DEST} (try --dest \"${HOME}/Applications\")"

if [[ -e "${DEST_APP}" ]]; then
  [[ "${FORCE}" == "1" ]] || die "already installed: ${DEST_APP} (pass --force to replace it)"
fi

# ditto preserves the bundle structure (Info.plist, symlinks, modes). Stage next
# to the destination, verify, then swap, so a failed copy never destroys an
# existing install.
STAGE="$(mktemp -d "${DEST}/.install.XXXXXX")"
cleanup() { rm -rf "${STAGE}"; }
trap cleanup EXIT

echo ">>> Installing ${APP##*/} to ${DEST_APP}"
ditto "${APP}" "${STAGE}/$(basename "${APP}")"
STAGED_APP="${STAGE}/$(basename "${APP}")"
[[ -f "${STAGED_APP}/Contents/MacOS/fifastreet" ]] \
  || die "copied bundle is missing its executable"
[[ -L "${STAGED_APP}/Contents/MacOS/GameData" ]] \
  || die "copied bundle lost its GameData symlink; refusing to install"
[[ -f "${STAGED_APP}/Contents/MacOS/GameData/default.xex" ]] \
  || die "copied bundle lost its game-data linkage; refusing to install"

# Roll back inside our own staging directory, so a pre-existing
# "<dest>.previous" user backup is never removed.
ROLLBACK="${STAGE}/rollback-app"
if [[ -e "${DEST_APP}" ]]; then mv "${DEST_APP}" "${ROLLBACK}"; fi
if ! mv "${STAGED_APP}" "${DEST_APP}"; then
  if [[ -e "${ROLLBACK}" ]]; then mv "${ROLLBACK}" "${DEST_APP}"; fi
  die "failed to move the bundle into place"
fi
trap - EXIT
cleanup

echo "OK   ${DEST_APP}"
echo "     launch: open \"${DEST_APP}\""

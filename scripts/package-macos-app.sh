#!/usr/bin/env bash
#
# package-macos-app.sh - assemble a normal, double-clickable "FIFA Street.app"
# from already-built macOS outputs, without rebuilding.
#
# It consumes a staged output directory (default build/macos/out) and writes a
# launchable bundle to <out>/FIFA Street.app. Everything the runtime resolves
# relative to the executable folder lives in Contents/MacOS: the host executable
# (rpath @executable_path), the runtime/guest/GPU dylibs, fifastreet.toml and the
# bundled Vulkan loader. GameData is a symlink to the private game-data tree, so
# no game assets are copied into the repository or the bundle.
#
# The bundle is assembled in a temporary directory and moved into place, so a
# repackage always yields fresh inodes. Rewriting a signed Mach-O in place keeps
# the old vnode and macOS then kills the next launch (see
# build/macos/logs/startup-order-fix.summary.txt).
#
# Usage: scripts/package-macos-app.sh [--out DIR] [--gamedata PATH]
#        Defaults: --out  build/macos/out
#                  --gamedata private/mac-build/extract/FIFA Street/GameData
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_ROOT="${FIFA_BUILD_ROOT:-${ROOT}/build/macos}"
OUT_DIR="${BUILD_ROOT}/out"
DEFAULT_GAMEDATA="${ROOT}/private/mac-build/extract/FIFA Street/GameData"
GAMEDATA="${FIFA_GAMEDATA:-${DEFAULT_GAMEDATA}}"

# Stable, unambiguous local bundle id for the development artifact. No global
# registration, codesigning or /Applications installation is performed.
APP_NAME="FIFA Street"
BUNDLE_ID="org.restreet.fifastreet.dev"
BUNDLE_SHORT_VERSION="1.0"
BUNDLE_VERSION="1"
MIN_MACOS="13.3"
EXECUTABLE="fifastreet"

usage() {
  cat <<EOF
Usage: scripts/package-macos-app.sh [options]

Options:
  --out DIR         Staged output directory to package (default: ${OUT_DIR})
  --gamedata PATH   Game-data root for the Contents/MacOS/GameData symlink
                    (default: ${DEFAULT_GAMEDATA})
  -h, --help        Show this help

Environment: FIFA_BUILD_ROOT, FIFA_GAMEDATA

Writes <out>/${APP_NAME}.app. Does not build or modify the staged binaries.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--out requires a value" >&2; exit 2; }; OUT_DIR="$2"; shift 2 ;;
    --gamedata) [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--gamedata requires a value" >&2; exit 2; }; GAMEDATA="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -d "${OUT_DIR}" ]] || die "output directory not found: ${OUT_DIR}"
[[ -f "${OUT_DIR}/${EXECUTABLE}" ]] || die "missing executable: ${OUT_DIR}/${EXECUTABLE}"
[[ -f "${OUT_DIR}/fifastreet.toml" ]] || die "missing config: ${OUT_DIR}/fifastreet.toml"
[[ -d "${OUT_DIR}/vulkan" ]] || die "missing bundled Vulkan assets: ${OUT_DIR}/vulkan"
[[ -d "${GAMEDATA}" ]] || die "game-data root not found: ${GAMEDATA}"
[[ -f "${GAMEDATA}/default.xex" ]] || die "game-data root has no default.xex: ${GAMEDATA}"
# Absolute target: the symlink lives in Contents/MacOS, so a relative target
# would resolve against that directory and break.
GAMEDATA="$(cd "${GAMEDATA}" && pwd)"

shopt -s nullglob
dylibs=( "${OUT_DIR}"/*.dylib )
shopt -u nullglob
[[ ${#dylibs[@]} -gt 0 ]] || die "no dylibs staged in ${OUT_DIR}"

APP_PATH="${OUT_DIR}/${APP_NAME}.app"
STAGE_DIR="$(mktemp -d "${OUT_DIR}/.app-stage.XXXXXX")"
CONTENTS="${STAGE_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"

cleanup() { rm -rf "${STAGE_DIR}"; }
trap cleanup EXIT

mkdir -p "${MACOS_DIR}"
# Standard bundle permissions: the staged tree comes from mktemp (0700), but a
# shipped .app uses 0755 directories. Files keep their copied modes.
chmod 755 "${STAGE_DIR}" "${CONTENTS}" "${MACOS_DIR}"

echo ">>> Assembling ${APP_NAME}.app"
cp -f "${OUT_DIR}/${EXECUTABLE}" "${MACOS_DIR}/${EXECUTABLE}"
chmod +x "${MACOS_DIR}/${EXECUTABLE}"
for lib in "${dylibs[@]}"; do
  cp -f "${lib}" "${MACOS_DIR}/"
done
cp -f "${OUT_DIR}/fifastreet.toml" "${MACOS_DIR}/fifastreet.toml"
cp -R "${OUT_DIR}/vulkan" "${MACOS_DIR}/vulkan"

# GameData is a symlink to the private tree; never copy assets.
ln -s "${GAMEDATA}" "${MACOS_DIR}/GameData"

cat > "${CONTENTS}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleExecutable</key>
	<string>${EXECUTABLE}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${BUNDLE_SHORT_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUNDLE_VERSION}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.games</string>
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_MACOS}</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

printf 'APPL????' > "${CONTENTS}/PkgInfo"

# Swap into place with rollback: move the old bundle aside, move the fresh stage
# in (a rename within the same directory, so it is atomic and gives fresh
# inodes), then delete the old copy. If the final move fails, the previous
# bundle is restored instead of being lost.
BACKUP="${APP_PATH}.previous"
rm -rf "${BACKUP}"
if [[ -e "${APP_PATH}" ]]; then mv "${APP_PATH}" "${BACKUP}"; fi
if ! mv "${STAGE_DIR}" "${APP_PATH}"; then
  if [[ -e "${BACKUP}" ]]; then mv "${BACKUP}" "${APP_PATH}"; fi
  die "failed to move the staged bundle into place (previous bundle restored)"
fi
rm -rf "${BACKUP}"
trap - EXIT

echo "OK   ${APP_PATH}"
echo "     id:     ${BUNDLE_ID}"
echo "     launch: open \"${APP_PATH}\""
echo "     or:     \"${APP_PATH}/Contents/MacOS/${EXECUTABLE}\" --game_data_root=\"${GAMEDATA}\""

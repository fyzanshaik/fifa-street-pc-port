#!/usr/bin/env bash
#
# test-macos-install.sh - fixture test for the macOS install/controls helpers,
# no built app, game data or game build required.
#
# Covers scripts/apply-macos-keyboard-profile.sh:
#   - reapplies the shipped profile, replacing old keybind_* lines with no
#     duplicates and leaving every other setting untouched, including settings
#     and comment sections placed after the profile block or after the bindings;
#   - keeps the binds in root scope (before any [table] header) so a config with
#     [custom] or nested tables cannot turn them into custom_keybind_*; the real
#     MnK driver is driven from that section config when a runtime is available;
#   - is idempotent and preserves the config's permissions;
#   - fails clearly on a missing config and on an empty, malformed, duplicate or
#     invalid-quoted-value profile, leaving the config bytes and permissions
#     untouched.
#
# Covers scripts/install-macos.sh:
#   - installs a fake bundle (ditto, absolute GameData symlink preserved),
#     refuses to overwrite without --force and replaces with --force;
#   - requires an absolute resolving GameData symlink: refuses a real asset
#     directory (no asset copy), a relative symlink and a dangling symlink;
#   - refuses when the destination is the source bundle or any path inside it
#     (self, alias, nonexistent descendant or symlinked descendant), even with
#     --force, without creating the destination or mutating the source;
#   - never deletes a pre-existing <dest>.previous backup and never replaces an
#     existing install when the new bundle fails validation.
#
# Usage: scripts/test-macos-install.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPLY="${ROOT}/scripts/apply-macos-keyboard-profile.sh"
INSTALL="${ROOT}/scripts/install-macos.sh"
PROFILE="${ROOT}/config/macos/keyboard-arrows.toml"
RUNTIME="${ROOT}/config/macos/fifastreet-runtime.toml"
# Runtime library used for the real-SDK seam checks; overridable so a stale
# build/macos/out can be bypassed (e.g. FIFA_BUILD_ROOT points at a candidate).
LIBS="${FIFA_BUILD_ROOT:-${ROOT}/build/macos}/out"

PASSED=0
FAILED=0
ok()  { printf 'OK   %s\n' "$1"; PASSED=$((PASSED + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
mode_of()   { stat -f '%Lp' "$1"; }
inode_of()  { stat -f '%i' "$1"; }

merged_config() { cat "${RUNTIME}" "${PROFILE}"; }

# ============================================================================
# apply-macos-keyboard-profile.sh
# ============================================================================
echo "== apply keyboard profile =="
APPLY_DIR="${TMP}/apply"
mkdir -p "${APPLY_DIR}"

MACOS="${TMP}/src/FIFA Street.app/Contents/MacOS"
mkdir -p "${MACOS}/vulkan"
printf '#!/bin/sh\ntrue\n' > "${MACOS}/fifastreet"
chmod +x "${MACOS}/fifastreet"
cp "${RUNTIME}" "${MACOS}/fifastreet.toml"

if "${APPLY}" --config "${MACOS}/fifastreet.toml" >"${TMP}/apply.log" 2>&1; then
  ok "reapply exits 0"
else
  bad "reapply failed (see ${TMP}/apply.log)"
  sed 's/^/       /' "${TMP}/apply.log"
fi
tokens="$(grep -oE '^[[:space:]]*keybind_[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*".+"' "${MACOS}/fifastreet.toml" \
  | sed -E 's/^[^"]*"//; s/"[[:space:]]*$//' | tr ',' '\n' | grep -c . || true)"
[[ "${tokens}" -eq 25 ]] && ok "reapply leaves 25 key bindings" \
  || bad "reapply left ${tokens} key bindings (expected 25)"
dupes="$(grep -oE 'keybind_[A-Za-z0-9_]+' "${MACOS}/fifastreet.toml" | sort | uniq -d || true)"
[[ -z "${dupes}" ]] && ok "reapply leaves no duplicate bindings" \
  || bad "reapply left duplicate bindings: ${dupes}"
grep -q 'vulkan_macos_unpaced_present = true' "${MACOS}/fifastreet.toml" \
  && ok "reapply preserves non-keybind settings" \
  || bad "reapply dropped a non-keybind setting"

before_hash="$(hash_file "${MACOS}/fifastreet.toml")"
"${APPLY}" --config "${MACOS}/fifastreet.toml" >/dev/null 2>&1 || true
after_hash="$(hash_file "${MACOS}/fifastreet.toml")"
[[ "${before_hash}" == "${after_hash}" ]] && ok "reapply is idempotent" \
  || bad "reapply changed the file on a second run"

if "${APPLY}" --config "${TMP}/missing.toml" >"${TMP}/apply-missing.log" 2>&1; then
  bad "reapply accepted a missing config"
else
  ok "reapply fails clearly on a missing config"
fi

# --- preserving unrelated content after the profile block --------------------
KEEP="${APPLY_DIR}/keep.toml"
merged_config > "${KEEP}"
printf '\n# custom section after the profile bindings\ncustom_section_setting = true\nafter_profile_setting = 42\n' >> "${KEEP}"
if "${APPLY}" --config "${KEEP}" >"${APPLY_DIR}/keep.log" 2>&1; then
  ok "reapply exits 0 with trailing content"
else
  bad "reapply failed with trailing content (see ${APPLY_DIR}/keep.log)"
  sed 's/^/       /' "${APPLY_DIR}/keep.log"
fi
grep -qF '# custom section after the profile bindings' "${KEEP}" \
  && ok "reapply preserves a comment section after the bindings" \
  || bad "reapply deleted a comment section after the bindings"
grep -qF 'custom_section_setting = true' "${KEEP}" \
  && ok "reapply preserves a setting after the bindings" \
  || bad "reapply deleted a setting after the bindings"
grep -qF 'after_profile_setting = 42' "${KEEP}" \
  && ok "reapply preserves a setting after the profile marker" \
  || bad "reapply deleted a setting after the profile marker"
keep_before="$(hash_file "${KEEP}")"
"${APPLY}" --config "${KEEP}" >/dev/null 2>&1 || true
[[ "$(hash_file "${KEEP}")" == "${keep_before}" ]] \
  && ok "reapply with trailing content is idempotent" \
  || bad "reapply with trailing content is not idempotent"

# --- root scope: binds stay above [custom] and nested tables -----------------
# The SDK TOML loader prefixes keys with their table path, so a bind written
# after "[custom]" loads as custom_keybind_a and the MnK driver keeps its
# defaults. The shipped profile must be written in root scope.
SECTION="${APPLY_DIR}/section.toml"
{
  printf '# runtime header\n'
  printf 'some_root_setting = 1\n'
  printf '\n[custom]\n'
  printf 'my_setting = 42\n'
  printf '\n[custom.nested]\n'
  printf 'deep_setting = "keep"\n'
} > "${SECTION}"
if "${APPLY}" --config "${SECTION}" >"${APPLY_DIR}/section.log" 2>&1; then
  ok "reapply exits 0 on a config with [custom] and nested tables"
else
  bad "reapply failed on a config with [custom] and nested tables"
  sed 's/^/       /' "${APPLY_DIR}/section.log"
fi
grep -qF 'some_root_setting = 1' "${SECTION}" \
  && ok "reapply preserves a root setting above [custom]" \
  || bad "reapply dropped a root setting above [custom]"
grep -qF 'my_setting = 42' "${SECTION}" \
  && ok "reapply preserves a [custom] setting" \
  || bad "reapply dropped a [custom] setting"
grep -qF 'deep_setting = "keep"' "${SECTION}" \
  && ok "reapply preserves a nested-table setting" \
  || bad "reapply dropped a nested-table setting"
grep -qF '[custom.nested]' "${SECTION}" \
  && ok "reapply preserves the nested table header" \
  || bad "reapply dropped the nested table header"

first_table="$(grep -nE '^[[:space:]]*\[' "${SECTION}" | head -n1 | cut -d: -f1 || true)"
last_bind="$(grep -nE '^[[:space:]]*keybind_[A-Za-z0-9_]+[[:space:]]*=' "${SECTION}" | tail -n1 | cut -d: -f1 || true)"
if [[ -n "${first_table}" && -n "${last_bind}" && "${last_bind}" -lt "${first_table}" ]]; then
  ok "reapply keeps binds in root scope before the first table"
else
  bad "reapply placed a bind after the first table (bind ${last_bind:-none}, table ${first_table:-none})"
fi
section_before="$(hash_file "${SECTION}")"
"${APPLY}" --config "${SECTION}" >/dev/null 2>&1 || true
[[ "$(hash_file "${SECTION}")" == "${section_before}" ]] \
  && ok "reapply on a sectioned config is idempotent" \
  || bad "reapply on a sectioned config is not idempotent"

# The root-scope reads must reach the real MnK driver, not become custom_keybind_*.
if [[ -f "${LIBS}/librexruntime.dylib" ]]; then
  if bash "${ROOT}/scripts/test-macos-keyboard-profile.sh" "${LIBS}" "${SECTION}" \
       >"${APPLY_DIR}/section-mnk.log" 2>&1; then
    ok "sectioned config drives the real MnK driver: $(tail -n1 "${APPLY_DIR}/section-mnk.log")"
  else
    bad "sectioned config failed the real MnK driver (see ${APPLY_DIR}/section-mnk.log)"
    sed 's/^/       /' "${APPLY_DIR}/section-mnk.log"
  fi
else
  echo "SKIP sectioned MnK seam test: no ${LIBS}/librexruntime.dylib"
fi

# --- stale/duplicate old bindings are replaced, not merged -------------------
STALE="${APPLY_DIR}/stale.toml"
{ printf 'keybind_a = "Backspace"\nkeybind_a = "Backspace"\n'; merged_config; } > "${STALE}"
"${APPLY}" --config "${STALE}" >/dev/null 2>&1 || true
a_count="$(grep -cE '^[[:space:]]*keybind_a[[:space:]]*=' "${STALE}" || true)"
[[ "${a_count}" == "1" ]] && ok "reapply collapses duplicate old bindings" \
  || bad "reapply left ${a_count} keybind_a assignments (expected 1)"
grep -qE '^[[:space:]]*keybind_a[[:space:]]*=[[:space:]]*"Space"' "${STALE}" \
  && ok "reapply restores the profile value for a stale binding" \
  || bad "reapply did not restore the profile value for keybind_a"
stale_dupes="$(grep -oE 'keybind_[A-Za-z0-9_]+' "${STALE}" | sort | uniq -d || true)"
[[ -z "${stale_dupes}" ]] && ok "reapply leaves no duplicates after stale bindings" \
  || bad "reapply left duplicates after stale bindings: ${stale_dupes}"

# --- config permissions are preserved ---------------------------------------
PERM="${APPLY_DIR}/perm.toml"
merged_config > "${PERM}"
chmod 640 "${PERM}"
"${APPLY}" --config "${PERM}" >/dev/null 2>&1 || true
[[ "$(mode_of "${PERM}")" == "640" ]] && ok "reapply preserves config permissions (640)" \
  || bad "reapply changed config permissions to $(mode_of "${PERM}") (expected 640)"

# --- invalid profiles are refused with the config bytes untouched ------------
PROFDIR="${TMP}/profiles"
mkdir -p "${PROFDIR}"
: > "${PROFDIR}/empty.toml"
{
  printf '# marker\n'
  printf 'keybind_a = "Space"\n'
  printf 'not_a_keybind = "oops"\n'
} > "${PROFDIR}/nonkey.toml"
{
  printf '# marker\n'
  printf 'keybind_a = Space\n'
} > "${PROFDIR}/unquoted.toml"
{
  printf '# marker\n'
  printf 'keybind_a = "Space"\n'
  printf 'keybind_a = "X"\n'
} > "${PROFDIR}/duplicate.toml"
{
  printf '# marker\n'
  printf 'keybind_a = "Space" "junk"\n'
} > "${PROFDIR}/quoted-junk.toml"

refuse_count=0
for spec in "empty:empty" "malformed:nonkey" "unquoted:unquoted" "duplicate:duplicate" "quoted:quoted-junk"; do
  label="${spec%%:*}"
  prof="${PROFDIR}/${spec##*:}.toml"
  cfg="${APPLY_DIR}/refuse-${label}.toml"
  merged_config > "${cfg}"
  perm_before="$(mode_of "${cfg}")"
  bytes_before="$(hash_file "${cfg}")"
  if "${APPLY}" --config "${cfg}" --profile "${prof}" >"${APPLY_DIR}/refuse-${label}.log" 2>&1; then
    bad "reapply accepted a ${label} profile"
  else
    ok "reapply refuses a ${label} profile"
    refuse_count=$((refuse_count + 1))
  fi
  [[ "$(hash_file "${cfg}")" == "${bytes_before}" ]] \
    && ok "reapply leaves config bytes untouched on a ${label} profile" \
    || bad "reapply mutated config bytes on a ${label} profile"
  [[ "$(mode_of "${cfg}")" == "${perm_before}" ]] \
    && ok "reapply leaves config permissions untouched on a ${label} profile" \
    || bad "reapply mutated config permissions on a ${label} profile"
done

# ============================================================================
# install-macos.sh
# ============================================================================
echo
echo "== install bundle =="

EXTRACT="${TMP}/extract/GameData"
mkdir -p "${EXTRACT}"
printf 'XEX2fake' > "${EXTRACT}/default.xex"

# make_bundle <bundle path> <gamedata flavour: abs|rel|dangling|realdir>
make_bundle() {
  local bundle="$1" flavour="$2"
  local macos="${bundle}/Contents/MacOS"
  mkdir -p "${macos}/vulkan"
  printf '#!/bin/sh\ntrue\n' > "${macos}/fifastreet"
  chmod +x "${macos}/fifastreet"
  printf 'ORIGINAL' > "${macos}/source-sentinel"
  cp "${RUNTIME}" "${macos}/fifastreet.toml"
  case "${flavour}" in
    abs)      ln -s "${EXTRACT}" "${macos}/GameData" ;;
    rel)      ln -s "../../../../extract/GameData" "${macos}/GameData" ;;
    dangling) ln -s "${TMP}/does-not-exist/GameData" "${macos}/GameData" ;;
    realdir)  mkdir -p "${macos}/GameData"; printf 'XEX2fake' > "${macos}/GameData/default.xex" ;;
  esac
}

# A real-directory GameData would make ditto copy the assets, so it must be
# refused instead of installed.
make_bundle "${TMP}/badreal/FIFA Street.app" realdir
if "${INSTALL}" --app "${TMP}/badreal/FIFA Street.app" --dest "${TMP}/dest-realdir" >"${TMP}/realdir.log" 2>&1; then
  bad "install accepted a real-directory GameData (asset copy)"
else
  ok "install refuses a real-directory GameData"
fi
[[ ! -e "${TMP}/dest-realdir/FIFA Street.app" ]] \
  && ok "install copied no assets from a real-directory GameData" \
  || bad "install copied assets from a real-directory GameData"

# A relative symlink resolves against Contents/MacOS, so it can look valid while
# not being the absolute link the packager writes.
make_bundle "${TMP}/badrel/FIFA Street.app" rel
if "${INSTALL}" --app "${TMP}/badrel/FIFA Street.app" --dest "${TMP}/dest-rel" >"${TMP}/rel.log" 2>&1; then
  bad "install accepted a relative GameData symlink"
else
  ok "install refuses a relative GameData symlink"
fi

# A dangling symlink is a clear failure, not a silently broken install.
make_bundle "${TMP}/dangling/FIFA Street.app" dangling
if "${INSTALL}" --app "${TMP}/dangling/FIFA Street.app" --dest "${TMP}/dest-dangling" >"${TMP}/dangling.log" 2>&1; then
  bad "install accepted a bundle with a dangling GameData symlink"
else
  ok "install refuses a dangling GameData symlink"
fi

# The happy path.
make_bundle "${TMP}/src/FIFA Street.app" abs
SRC="${TMP}/src/FIFA Street.app"
DEST="${TMP}/dest"
if "${INSTALL}" --app "${SRC}" --dest "${DEST}" >"${TMP}/install.log" 2>&1; then
  ok "install exits 0"
else
  bad "install failed (see ${TMP}/install.log)"
  sed 's/^/       /' "${TMP}/install.log"
fi
[[ -x "${DEST}/FIFA Street.app/Contents/MacOS/fifastreet" ]] \
  && ok "installed bundle has its executable" || bad "installed bundle is missing the executable"
[[ -f "${DEST}/FIFA Street.app/Contents/MacOS/GameData/default.xex" ]] \
  && ok "installed bundle keeps the GameData linkage" || bad "installed bundle lost the GameData linkage"

if "${INSTALL}" --app "${SRC}" --dest "${DEST}" >"${TMP}/reinstall.log" 2>&1; then
  bad "install overwrote an existing bundle without --force"
else
  ok "install refuses to overwrite without --force"
fi
if "${INSTALL}" --app "${SRC}" --dest "${DEST}" --force >"${TMP}/force.log" 2>&1; then
  ok "install --force replaces the bundle"
else
  bad "install --force failed"
  sed 's/^/       /' "${TMP}/force.log"
fi

# A pre-existing <dest>.previous is the user's backup and must not be deleted by
# our rollback.
make_bundle "${TMP}/pvsrc/FIFA Street.app" abs
PV="${TMP}/pv"
"${INSTALL}" --app "${TMP}/pvsrc/FIFA Street.app" --dest "${PV}" >/dev/null 2>&1 || true
mkdir -p "${PV}/FIFA Street.app.previous/Contents/MacOS"
printf 'USER' > "${PV}/FIFA Street.app.previous/Contents/MacOS/user-marker"
if "${INSTALL}" --app "${TMP}/pvsrc/FIFA Street.app" --dest "${PV}" --force >"${TMP}/pv.log" 2>&1; then
  ok "install --force succeeds with a pre-existing .previous backup"
else
  bad "install --force failed with a pre-existing .previous backup"
fi
[[ -f "${PV}/FIFA Street.app.previous/Contents/MacOS/user-marker" ]] \
  && ok "install preserves a pre-existing .previous backup" \
  || bad "install deleted a pre-existing .previous backup"

# A failing install must not replace an unrelated existing bundle.
make_bundle "${TMP}/guardsrc/FIFA Street.app" abs
GUARD="${TMP}/guard"
"${INSTALL}" --app "${TMP}/guardsrc/FIFA Street.app" --dest "${GUARD}" >/dev/null 2>&1 || true
printf 'INSTALLED' > "${GUARD}/FIFA Street.app/Contents/MacOS/installed-marker"
make_bundle "${TMP}/guardbad/FIFA Street.app" realdir
if "${INSTALL}" --app "${TMP}/guardbad/FIFA Street.app" --dest "${GUARD}" --force >"${TMP}/guard.log" 2>&1; then
  bad "install replaced an install with an invalid bundle"
else
  ok "install fails before replacing an unrelated install"
fi
[[ -f "${GUARD}/FIFA Street.app/Contents/MacOS/installed-marker" ]] \
  && ok "existing install survives a failed replacement" \
  || bad "existing install was destroyed by a failed replacement"

# Destination resolving to the source (alias or self) must be refused with
# --force, and must never move/destroy the source bundle. These run last because
# a broken implementation mutates the source.
SRC_INODE="$(inode_of "${SRC}")"
ln -s "${TMP}/src" "${TMP}/alias-src"
if "${INSTALL}" --app "${SRC}" --dest "${TMP}/alias-src" --force >"${TMP}/alias.log" 2>&1; then
  bad "install accepted a destination that is an alias of the source"
else
  ok "install refuses an alias-of-source destination"
fi
[[ "$(inode_of "${SRC}")" == "${SRC_INODE}" ]] \
  && ok "source bundle inode unchanged after alias refusal" \
  || bad "source bundle was moved/replaced by an alias install"
[[ -f "${SRC}/Contents/MacOS/source-sentinel" ]] \
  && ok "source bundle still intact after alias refusal" \
  || bad "source bundle was destroyed by an alias install"

SRC_INODE="$(inode_of "${SRC}")"
if "${INSTALL}" --app "${SRC}" --dest "${TMP}/src/." --force >"${TMP}/self.log" 2>&1; then
  bad "install accepted a self destination via a ./ alias"
else
  ok "install refuses a self destination via a ./ alias"
fi
[[ "$(inode_of "${SRC}")" == "${SRC_INODE}" ]] \
  && ok "source bundle inode unchanged after ./ self refusal" \
  || bad "source bundle was moved/replaced by a ./ self install"
[[ -f "${SRC}/Contents/MacOS/source-sentinel" ]] \
  && ok "source bundle still intact after ./ self refusal" \
  || bad "source bundle was destroyed by a ./ self install"

SRC_INODE="$(inode_of "${SRC}")"
if "${INSTALL}" --app "${SRC}" --dest "${TMP}/src/../src" --force >"${TMP}/dotdot.log" 2>&1; then
  bad "install accepted a self destination via a ../ alias"
else
  ok "install refuses a self destination via a ../ alias"
fi
[[ "$(inode_of "${SRC}")" == "${SRC_INODE}" ]] \
  && ok "source bundle inode unchanged after ../ self refusal" \
  || bad "source bundle was moved/replaced by a ../ self install"

# A destination inside the source bundle must be refused before mkdir/ditto, or
# ditto would copy the bundle into its own tree.
SRC_INODE="$(inode_of "${SRC}")"
if "${INSTALL}" --app "${SRC}" --dest "${SRC}/Contents" --force >"${TMP}/inside.log" 2>&1; then
  bad "install accepted a destination inside the source bundle"
else
  ok "install refuses a destination inside the source bundle"
fi
[[ "$(inode_of "${SRC}")" == "${SRC_INODE}" ]] \
  && ok "source bundle inode unchanged after inside-source refusal" \
  || bad "source bundle was moved/replaced by an inside-source install"
[[ -f "${SRC}/Contents/MacOS/source-sentinel" ]] \
  && ok "source bundle still intact after inside-source refusal" \
  || bad "source bundle was destroyed by an inside-source install"

# Nonexistent descendant: the check must run before mkdir, so nothing is created
# inside the source.
SRC_INODE="$(inode_of "${SRC}")"
if "${INSTALL}" --app "${SRC}" --dest "${SRC}/Contents/new/deep/dest" --force >"${TMP}/inside-new.log" 2>&1; then
  bad "install accepted a nonexistent destination inside the source bundle"
else
  ok "install refuses a nonexistent destination inside the source bundle"
fi
[[ ! -e "${SRC}/Contents/new" ]] \
  && ok "install created no directory inside the source bundle" \
  || bad "install created a destination directory inside the source bundle"
[[ "$(inode_of "${SRC}")" == "${SRC_INODE}" ]] \
  && ok "source bundle inode unchanged after nonexistent inside refusal" \
  || bad "source bundle was moved/replaced by a nonexistent inside install"

# A symlinked descendant alias of the source bundle.
SRC_INODE="$(inode_of "${SRC}")"
ln -s "${SRC}/Contents" "${TMP}/alias-inside"
if "${INSTALL}" --app "${SRC}" --dest "${TMP}/alias-inside" --force >"${TMP}/inside-alias.log" 2>&1; then
  bad "install accepted a symlinked descendant of the source bundle"
else
  ok "install refuses a symlinked descendant of the source bundle"
fi
[[ "$(inode_of "${SRC}")" == "${SRC_INODE}" ]] \
  && ok "source bundle inode unchanged after descendant-symlink refusal" \
  || bad "source bundle was moved/replaced by a descendant-symlink install"
[[ -f "${SRC}/Contents/MacOS/source-sentinel" ]] \
  && ok "source bundle still intact after descendant-symlink refusal" \
  || bad "source bundle was destroyed by a descendant-symlink install"

# Source reached through a symlinked parent must canonicalise to the same bundle
# as a plain destination parent.
SRC_INODE="$(inode_of "${SRC}")"
if "${INSTALL}" --app "${TMP}/alias-src/FIFA Street.app" --dest "${TMP}/src" --force >"${TMP}/srcsym.log" 2>&1; then
  bad "install accepted a symlinked source resolving to the destination"
else
  ok "install canonicalises a symlinked source against the destination"
fi
[[ "$(inode_of "${SRC}")" == "${SRC_INODE}" ]] \
  && ok "source bundle inode unchanged after symlinked-source refusal" \
  || bad "source bundle was moved/replaced by a symlinked-source install"

echo
echo "=============================================================="
printf ' install tests: %d passed, %d failed\n' "${PASSED}" "${FAILED}"
echo "=============================================================="
[[ "${FAILED}" -eq 0 ]] || exit 1
echo "ALL INSTALL TESTS PASSED"

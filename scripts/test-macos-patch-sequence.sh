#!/usr/bin/env bash
#
# test-macos-patch-sequence.sh - real-git regression tests for
# scripts/rexglue-patches.sh, the helper scripts/build-macos.sh uses to apply the
# ordered ReXGlue patch stack to the pinned SDK checkout.
#
# The patches form a stack (project changes, then macOS portability, then the
# macOS drawable/acquire recovery). A later patch edits context an earlier one
# also matches, so the earlier patch's reverse-check fails once the later patch
# is applied. These tests build a real source tree from the pinned SDK with
# `git archive`, drive the helper with real `git apply`, and assert with real
# tree hashes - not output regexes:
#
#   fresh base        -> every patch applied, byte-identical to a plain
#                        sequential apply
#   base patches only -> only the recovery patch applied (the two present ones
#                        are left alone)
#   fully patched     -> re-run is a no-op (exit 0, tree hash unchanged)
#   conflicting tree  -> rejected (non-zero, tree hash unchanged)
#   reverted earlier  -> fully patched with an earlier patch's file reverted is
#                        rejected: the topmost reverse-check alone does not prove
#                        the whole prefix is present (tree hash unchanged)
#   missing lower     -> a valid higher patch with a missing lower patch is
#                        rejected rather than silently treated as that prefix
#   late conflict     -> a conflict in only a later patch is rejected before any
#                        patch is applied, so there is no partial mutation
#   unrelated edit    -> a valid stack carrying an unrelated edit outside the
#                        hunks is accepted and the edit preserved
#
# Requires the pinned ReXGlue checkout (ReXGlue/.git). No SDK or game build.
#
# Usage: scripts/test-macos-patch-sequence.sh
#
# Env: REXGLUE_PATCHSEQ_WORK  output directory for the temp tree and logs
#         (default build/macos/logs/recovery-build-integration/patch-sequence).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN=c94f5ebdcb3c9d1a460ca48e04f9758448f8d518
HELPER="${ROOT}/scripts/rexglue-patches.sh"
LOCAL_PATCH="${ROOT}/patches/rexglue-local-changes.patch"
PORTABILITY_PATCH="${ROOT}/patches/rexglue-macos-portability.patch"
RECOVERY_PATCH="${ROOT}/patches/rexglue-macos-drawable-recovery.patch"
WORK="${REXGLUE_PATCHSEQ_WORK:-${ROOT}/build/macos/logs/recovery-build-integration/patch-sequence}"

PASSED=0
FAILED=0
ok()  { printf 'OK   %s\n' "$1"; PASSED=$((PASSED + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${HELPER}" ]] || fail "missing ${HELPER}"
[[ -d "${ROOT}/ReXGlue/.git" ]] \
  || fail "ReXGlue checkout not found (needed to build the pinned source tree)"

rm -rf "${WORK}"
mkdir -p "${WORK}"
TREE="${WORK}/tree"

echo "== patch-sequence tests =="
echo ">>> Building pinned source tree at ${TREE}"
mkdir -p "${TREE}"
git -C "${ROOT}/ReXGlue" archive "${PIN}" | tar -x -C "${TREE}"
git -C "${TREE}" init -q
git -C "${TREE}" -c user.email=t@t -c user.name=t add -A
git -C "${TREE}" -c user.email=t@t -c user.name=t commit -qm "base ${PIN:0:12}"
BASE_COMMIT="$(git -C "${TREE}" rev-parse HEAD)"

# Return the working tree to the pinned base (tracked + untracked).
reset_tree() {
  git -C "${TREE}" reset -q --hard "${BASE_COMMIT}"
  git -C "${TREE}" clean -qfdx
}

# Content hash of the whole tree (tracked changes and untracked files included).
tree_hash() {
  git -C "${TREE}" add -A >/dev/null 2>&1
  git -C "${TREE}" write-tree
}

# Drive the helper exactly as a caller would.
run_helper() {
  bash "${HELPER}" "${TREE}" "$@"
}

# --- fresh base -> all three patches (parity with a plain sequential apply) ---
echo ""
echo "== fresh base -> all three patches =="
reset_tree
fresh_before="$(tree_hash)"
if run_helper "${LOCAL_PATCH}" "${PORTABILITY_PATCH}" "${RECOVERY_PATCH}" \
    >"${WORK}/fresh.log" 2>&1; then
  ok "fresh base: helper exits 0"
else
  bad "fresh base: helper failed (see ${WORK}/fresh.log)"
  sed 's/^/       /' "${WORK}/fresh.log"
fi
fresh_after="$(tree_hash)"
if [[ "${fresh_after}" != "${fresh_before}" ]]; then
  ok "fresh base: helper applied patches"
else
  bad "fresh base: helper changed nothing"
fi
if git -C "${TREE}" apply --reverse --check "${RECOVERY_PATCH}" >/dev/null 2>&1; then
  ok "fresh base: recovery patch is present at the top of the stack"
else
  bad "fresh base: recovery patch missing after apply"
fi

reset_tree
git -C "${TREE}" apply "${LOCAL_PATCH}"
git -C "${TREE}" apply "${PORTABILITY_PATCH}"
git -C "${TREE}" apply "${RECOVERY_PATCH}"
reference_hash="$(tree_hash)"
if [[ "${fresh_after}" == "${reference_hash}" ]]; then
  ok "fresh base: result is byte-identical to a plain sequential apply"
else
  bad "fresh base: result differs from a plain sequential apply"
fi

# --- base patches already applied -> only the recovery patch is applied -------
echo ""
echo "== base patches applied -> only recovery is applied =="
reset_tree
git -C "${TREE}" apply "${LOCAL_PATCH}"
git -C "${TREE}" apply "${PORTABILITY_PATCH}"
incremental_before="$(tree_hash)"
if run_helper "${LOCAL_PATCH}" "${PORTABILITY_PATCH}" "${RECOVERY_PATCH}" \
    >"${WORK}/incremental.log" 2>&1; then
  ok "base patches: helper exits 0"
else
  bad "base patches: helper failed (see ${WORK}/incremental.log)"
  sed 's/^/       /' "${WORK}/incremental.log"
fi
incremental_after="$(tree_hash)"
if git -C "${TREE}" apply --reverse --check "${RECOVERY_PATCH}" >/dev/null 2>&1 \
    && ! git -C "${TREE}" apply --check "${RECOVERY_PATCH}" >/dev/null 2>&1; then
  ok "base patches: recovery applied exactly once"
else
  bad "base patches: recovery not applied exactly once"
fi
# The two already-present patches must have been untouched: the result equals
# applying only the recovery patch to the base-patched tree.
reset_tree
git -C "${TREE}" apply "${LOCAL_PATCH}"
git -C "${TREE}" apply "${PORTABILITY_PATCH}"
git -C "${TREE}" apply "${RECOVERY_PATCH}"
incremental_reference="$(tree_hash)"
if [[ "${incremental_after}" == "${incremental_reference}" ]]; then
  ok "base patches: present patches left unchanged, recovery added"
else
  bad "base patches: result differs from applying only the recovery patch"
fi

# --- fully patched -> re-run is a no-op --------------------------------------
echo ""
echo "== fully patched -> re-run is a no-op =="
reset_tree
run_helper "${LOCAL_PATCH}" "${PORTABILITY_PATCH}" "${RECOVERY_PATCH}" \
  >"${WORK}/full-first.log" 2>&1 || fail "setup: helper failed on a fresh base"
noop_before="$(tree_hash)"
if run_helper "${LOCAL_PATCH}" "${PORTABILITY_PATCH}" "${RECOVERY_PATCH}" \
    >"${WORK}/full-second.log" 2>&1; then
  ok "fully patched: re-run exits 0"
else
  bad "fully patched: re-run failed (see ${WORK}/full-second.log)"
  sed 's/^/       /' "${WORK}/full-second.log"
fi
noop_after="$(tree_hash)"
if [[ "${noop_after}" == "${noop_before}" ]]; then
  ok "fully patched: re-run changed nothing"
else
  bad "fully patched: re-run modified the tree"
fi

# --- conflicting tree -> rejected, left unchanged ----------------------------
echo ""
echo "== conflicting tree -> rejected =="
reset_tree
printf 'not the pinned SDK\n' > "${TREE}/CMakeLists.txt"
conflict_before="$(tree_hash)"
if run_helper "${LOCAL_PATCH}" "${PORTABILITY_PATCH}" "${RECOVERY_PATCH}" \
    >"${WORK}/conflict.log" 2>&1; then
  bad "conflicting tree: helper accepted it (exit 0)"
else
  ok "conflicting tree: helper rejected it"
fi
conflict_after="$(tree_hash)"
if [[ "${conflict_after}" == "${conflict_before}" ]]; then
  ok "conflicting tree: no patch was applied"
else
  bad "conflicting tree: helper modified the tree before rejecting"
fi

# --- fully patched, an earlier patch's file reverted -> rejected --------------
# The recovery patch's reverse-check still passes on this tree (it touches other
# files), so the highest reverse-applicable patch alone would accept it. The
# helper must instead reverse the whole prefix and notice the reverted lower
# patch.
echo ""
echo "== fully patched with an earlier patch file reverted -> rejected =="
reset_tree
run_helper "${LOCAL_PATCH}" "${PORTABILITY_PATCH}" "${RECOVERY_PATCH}" \
  >"${WORK}/reverted-setup.log" 2>&1 || fail "setup: helper failed on a fresh base"
git -C "${TREE}" checkout "${BASE_COMMIT}" -- CMakeLists.txt
reverted_before="$(tree_hash)"
if run_helper "${LOCAL_PATCH}" "${PORTABILITY_PATCH}" "${RECOVERY_PATCH}" \
    >"${WORK}/reverted.log" 2>&1; then
  bad "reverted earlier patch: helper accepted a broken stack (exit 0)"
else
  ok "reverted earlier patch: helper rejected the broken stack"
fi
reverted_after="$(tree_hash)"
if [[ "${reverted_after}" == "${reverted_before}" ]]; then
  ok "reverted earlier patch: tree unchanged"
else
  bad "reverted earlier patch: helper modified the tree while rejecting"
fi
if git -C "${TREE}" diff --quiet "${BASE_COMMIT}" -- CMakeLists.txt; then
  ok "reverted earlier patch: reverted file left as the user had it"
else
  bad "reverted earlier patch: the reverted file was changed"
fi

# --- a lower patch missing but a higher one present -> rejected ---------------
# The recovery patch touches files the portability patch does not, so it applies
# (and reverse-checks) on its own. A missing lower patch must not be accepted
# just because the top of the stack is valid.
echo ""
echo "== lower patch missing with a higher patch present -> rejected =="
reset_tree
git -C "${TREE}" apply "${LOCAL_PATCH}"
git -C "${TREE}" apply "${RECOVERY_PATCH}"
nonprefix_before="$(tree_hash)"
if run_helper "${LOCAL_PATCH}" "${PORTABILITY_PATCH}" "${RECOVERY_PATCH}" \
    >"${WORK}/nonprefix.log" 2>&1; then
  bad "missing lower patch: helper accepted a non-prefix stack (exit 0)"
else
  ok "missing lower patch: helper rejected the non-prefix stack"
fi
nonprefix_after="$(tree_hash)"
if [[ "${nonprefix_after}" == "${nonprefix_before}" ]]; then
  ok "missing lower patch: tree unchanged"
else
  bad "missing lower patch: helper modified the tree while rejecting"
fi

# --- fresh base, a conflict only in a later patch -> rejected, nothing applied -
# Damages only the recovery patch's context, so a helper that applies as it goes
# would commit the project and portability patches before failing.
echo ""
echo "== fresh base with a conflict only in the last patch -> rejected =="
reset_tree
sed 's/present_render_pass_clear, true/present_render_pass_clear_XX, true/' \
  "${TREE}/src/ui/vulkan/vulkan_presenter.cpp" > "${WORK}/vulkan_presenter.damaged"
mv "${WORK}/vulkan_presenter.damaged" "${TREE}/src/ui/vulkan/vulkan_presenter.cpp"
late_before="$(tree_hash)"
if run_helper "${LOCAL_PATCH}" "${PORTABILITY_PATCH}" "${RECOVERY_PATCH}" \
    >"${WORK}/late-conflict.log" 2>&1; then
  bad "late conflict: helper accepted a tree the last patch cannot apply to"
else
  ok "late conflict: helper rejected the tree"
fi
late_after="$(tree_hash)"
if [[ "${late_after}" == "${late_before}" ]]; then
  ok "late conflict: no patch was applied (tree unchanged)"
else
  bad "late conflict: earlier patches were applied before the failure"
fi

# --- valid stack plus an unrelated edit outside the hunks -> accepted ---------
# An edit that does not fall in any patch hunk must not block a valid stack, and
# must survive.
echo ""
echo "== valid stack plus an unrelated edit outside the hunks -> accepted =="
reset_tree
run_helper "${LOCAL_PATCH}" "${PORTABILITY_PATCH}" "${RECOVERY_PATCH}" \
  >"${WORK}/unrelated-setup.log" 2>&1 || fail "setup: helper failed on a fresh base"
printf '\n// unrelated owner note outside any patch hunk\n' >> "${TREE}/src/core/bit_stream.cpp"
unrelated_before="$(tree_hash)"
if run_helper "${LOCAL_PATCH}" "${PORTABILITY_PATCH}" "${RECOVERY_PATCH}" \
    >"${WORK}/unrelated.log" 2>&1; then
  ok "unrelated edit: helper accepted the valid stack"
else
  bad "unrelated edit: helper rejected a valid stack (see ${WORK}/unrelated.log)"
  sed 's/^/       /' "${WORK}/unrelated.log"
fi
unrelated_after="$(tree_hash)"
if [[ "${unrelated_after}" == "${unrelated_before}" ]] \
    && grep -q "unrelated owner note outside any patch hunk" "${TREE}/src/core/bit_stream.cpp"; then
  ok "unrelated edit: no-op re-run and the edit preserved"
else
  bad "unrelated edit: the tree changed or the edit was dropped"
fi

# --- summary -----------------------------------------------------------------
echo ""
echo "=============================================================="
printf ' patch-sequence tests: %d passed, %d failed\n' "${PASSED}" "${FAILED}"
echo "=============================================================="
[[ "${FAILED}" -eq 0 ]] || exit 1
echo "ALL PATCH-SEQUENCE TESTS PASSED"

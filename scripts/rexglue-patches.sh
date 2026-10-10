#!/usr/bin/env bash
#
# rexglue-patches.sh - apply the project's ReXGlue patches to a pinned SDK
# checkout, in order, tolerating a partially or fully patched tree.
#
# Run by scripts/build-macos.sh; also driven directly by
# scripts/test-macos-patch-sequence.sh.
#
#   scripts/rexglue-patches.sh <repo> <patch> [<patch> ...]
#
# The patches form a stack: each is generated on top of the previous one, so the
# set that is applied is always a prefix of the list. A later patch edits context
# an earlier one matches, which makes the earlier patch's reverse-check fail even
# though it is applied; conversely a later patch that touches different files can
# reverse-check cleanly even when an earlier one is missing. No single patch's
# reverse-check is therefore authoritative on its own, and neither is "the
# topmost patch that reverse-applies": a fully patched tree with one earlier
# patch's file reverted still passes that check.
#
# The whole plan is validated first, against an isolated copy of only the files
# the patches touch (never the repository under test):
#   1. the topmost patch that reverse-applies names a candidate top of the stack;
#   2. the entire candidate prefix is then reverse-applied top-down, so a missing
#      or reverted lower patch is detected instead of assumed present;
#   3. the remaining patches are forward-applied in the isolated copy to prove
#      they apply on top of that prefix.
# Only when that dry run succeeds are the remaining patches applied to the real
# repository, so a failure leaves the caller's tree untouched. A tree whose
# patches are not a clean prefix is reported as conflicting/unsupported, rather
# than guessed at or silently repaired. Unrelated edits outside the patch hunks
# are preserved and do not block a valid stack.
#
# Requires: git. No other dependencies.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $(basename "$0") <repo> <patch> [<patch> ...]" >&2
  exit 2
fi

REPO="$1"
shift
PATCHES=("$@")
COUNT=${#PATCHES[@]}

# Labels for the expected positions; any extra patch falls back to its number.
patch_name() {
  case "$1" in
    0) echo "Project patch" ;;
    1) echo "macOS portability patch" ;;
    2) echo "macOS drawable-recovery patch" ;;
    *) echo "patch $(( $1 + 1 ))" ;;
  esac
}

# --- isolated dry run --------------------------------------------------------
# A throwaway tree holding only the files the patches touch, so each patch can be
# applied and reversed for real without writing to the repository under test.
# git apply rewrites whole files, so copying just the touched files (a few MB) is
# enough; no SDK tree, build output or submodule is copied, and the real index,
# HEAD and worktree are never touched.
ISO_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rexglue-patches.XXXXXX")"
cleanup() { rm -rf "${ISO_ROOT}"; }
trap cleanup EXIT

TOUCHED="${ISO_ROOT}/touched-paths"
ISO="${ISO_ROOT}/tree"
: > "${TOUCHED}"
for patch in "${PATCHES[@]}"; do
  if ! git -C "${REPO}" apply --numstat -- "${patch}" | cut -f3- >> "${TOUCHED}"; then
    echo "ERROR: cannot read patch ${patch}" >&2
    exit 1
  fi
done
sort -u -o "${TOUCHED}" "${TOUCHED}"

# Rebuild the isolated tree from the repository's current state: copy every
# touched file that exists there. A file a patch creates is absent on a clean
# base and is recreated by applying that patch.
populate_iso() {
  rm -rf "${ISO}"
  mkdir -p "${ISO}"
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    if [[ -e "${REPO}/${rel}" ]]; then
      mkdir -p "${ISO}/$(dirname "${rel}")"
      cp -p "${REPO}/${rel}" "${ISO}/${rel}"
    fi
  done < "${TOUCHED}"
  git -C "${ISO}" init -q
  git -C "${ISO}" -c user.email=iso@example.invalid -c user.name=iso add -A >/dev/null 2>&1
  git -C "${ISO}" -c user.email=iso@example.invalid -c user.name=iso commit -q --allow-empty -m isolate
}
reset_iso() {
  git -C "${ISO}" reset -q --hard
  git -C "${ISO}" clean -qfdx
}

populate_iso

# Candidate top of the applied stack: the highest patch that reverse-applies.
TOP=-1
index=$(( COUNT - 1 ))
while (( index >= 0 )); do
  if git -C "${ISO}" apply --reverse --check "${PATCHES[index]}" >/dev/null 2>&1; then
    TOP=${index}
    break
  fi
  index=$(( index - 1 ))
done

# Verify the whole candidate prefix is really present by reversing it top-down in
# the isolated tree. A missing or reverted lower patch surfaces here, even when a
# higher patch's reverse-check passed on its own.
APPLIED=0
if (( TOP >= 0 )); then
  index=${TOP}
  while (( index >= 0 )); do
    if ! git -C "${ISO}" apply --reverse "${PATCHES[index]}" >/dev/null 2>&1; then
      echo "ERROR: $(patch_name "${index}") is not applied below $(patch_name "${TOP}");" >&2
      echo "       the ReXGlue tree is partially patched or modified" >&2
      exit 1
    fi
    index=$(( index - 1 ))
  done
  APPLIED=$(( TOP + 1 ))
fi

# Prove the remaining patches apply on top of that prefix before touching the
# real tree, so a conflict in a later patch cannot leave a half-applied SDK.
reset_iso
index=${APPLIED}
while (( index < COUNT )); do
  if ! git -C "${ISO}" apply "${PATCHES[index]}" >/dev/null 2>&1; then
    if (( APPLIED == 0 && index == 0 )); then
      echo "ERROR: $(patch_name 0) neither applies nor is already applied;" >&2
      echo "       the ReXGlue tree is modified or an unsupported revision" >&2
    else
      echo "ERROR: $(patch_name "${index}") does not apply cleanly on the $(patch_name $(( index - 1 ))) tree;" >&2
      echo "       the ReXGlue tree is modified or an unsupported revision" >&2
    fi
    exit 1
  fi
  index=$(( index + 1 ))
done

# --- apply to the real repository -------------------------------------------
index=${APPLIED}
while (( index < COUNT )); do
  name="$(patch_name "${index}")"
  echo ">>> Verifying ${name} applies cleanly (git apply --check)..."
  if ! git -C "${REPO}" apply --check "${PATCHES[index]}"; then
    echo "ERROR: ${name} does not apply cleanly" >&2
    exit 1
  fi
  echo ">>> Applying ${name}..."
  if ! git -C "${REPO}" apply "${PATCHES[index]}"; then
    echo "ERROR: git apply failed for ${name}" >&2
    exit 1
  fi
  index=$(( index + 1 ))
done

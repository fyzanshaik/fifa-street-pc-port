#!/usr/bin/env bash
# Focused tests for the macOS menu-credit patcher. Uses synthetic fixtures only:
# no game data, no game launch, no compiler. Verifies the BC3 codec against
# golden vectors and an independent decoder, the Xenos endian transform, the
# tiled addressing against the SDK's formulation, XPR2 fetch-constant parsing and
# the preservation-profile lifecycle (real nested directories, directory-cycle
# refusal, refusal cases, no-mutation check/dry-run, idempotence and
# second-target failure safety).
#
# scripts/test-macos-credit-vfs.sh additionally drives the pinned runtime's VFS
# on a built profile; it needs a prior Mac build and skips otherwise.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

python3 "$REPO/scripts/macos_credit_test.py"

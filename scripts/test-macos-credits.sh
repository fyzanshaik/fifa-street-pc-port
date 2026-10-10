#!/usr/bin/env bash
# Focused tests for the macOS menu-credit patcher. Uses synthetic fixtures only:
# no game data, no game launch, no compiler. Verifies the BC3 codec against
# golden vectors and an independent decoder, the Xenos endian transform, the
# tiled addressing against the SDK's formulation, XPR2 fetch-constant parsing and
# the preservation-profile lifecycle (refusal cases, no-mutation check/dry-run,
# idempotence and second-target failure safety).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

python3 "$REPO/scripts/macos_credit_test.py"

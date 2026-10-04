#!/usr/bin/env bash
# The Tangle anti-sycophancy challenge is told not to open files, and it used to be handed only
# `head -c 3000` of the raw result files: on a real run that is the result header and the prompt
# preamble, never the change. So every high-pass run came back CHALLENGED with "the result contains
# no implementation, only the prompt" (seen on a real Develop run, 2026-10-04). The evidence must be
# the changed files and the provider's own report.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
log() { :; }
source "$PROJECT_ROOT/scripts/lib/testing.sh" 2>/dev/null || true

test_suite "anti-sycophancy challenge evidence"

REPO="$TEST_TMP_DIR/challenge-repo"
mkdir -p "$REPO/entry/pages"
git -C "$REPO" init -q
printf '# Ocean Animals Word Search\nWHALE GRID LINE\n' > "$REPO/entry/pages/page.md"
long_header="$(printf 'HEADER-PREAMBLE %.0s' $(seq 1 400))"
outputs="${long_header}
PROVIDER-REPORT: wrote entry/pages/page.md and verified it"

test_case "the evidence names the changed files and carries their content"
if declare -F tangle_challenge_evidence >/dev/null; then
    evidence="$(PROJECT_ROOT="$REPO" tangle_challenge_evidence "entry/pages/page.md" "$outputs")"
    if grep -q "entry/pages/page.md" <<<"$evidence" && grep -q "WHALE GRID LINE" <<<"$evidence"; then
        test_pass
    else
        test_fail "changed file or its content missing from the evidence"
    fi
else
    test_fail "tangle_challenge_evidence is not defined"
fi

test_case "the evidence keeps the end of the provider report, not the header"
if declare -F tangle_challenge_evidence >/dev/null; then
    evidence="$(PROJECT_ROOT="$REPO" tangle_challenge_evidence "entry/pages/page.md" "$outputs")"
    if grep -q "PROVIDER-REPORT: wrote entry/pages/page.md" <<<"$evidence"; then
        test_pass
    else
        test_fail "the provider's report was cut off"
    fi
else
    test_fail "tangle_challenge_evidence is not defined"
fi

test_case "a changed path that leaves the repository is not read"
if declare -F tangle_challenge_evidence >/dev/null; then
    printf 'OUTSIDE-SECRET\n' > "$TEST_TMP_DIR/outside.txt"
    ln -sfn "$TEST_TMP_DIR/outside.txt" "$REPO/link.txt"
    evidence="$(PROJECT_ROOT="$REPO" tangle_challenge_evidence $'../outside.txt\nlink.txt' "$outputs")"
    if ! grep -q "OUTSIDE-SECRET" <<<"$evidence"; then
        test_pass
    else
        test_fail "content outside the repository reached the challenge prompt"
    fi
else
    test_fail "tangle_challenge_evidence is not defined"
fi

test_case "the challenge prompt uses the evidence, not the head of the raw results"
block="$(sed -n '/Anti-sycophancy challenge/,/gate_status="CHALLENGED"/p' "$PROJECT_ROOT/scripts/lib/testing.sh")"
if grep -q 'tangle_challenge_evidence' <<<"$block" && ! grep -q 'head -c 3000 <<< "\$results"' <<<"$block"; then
    test_pass
else
    test_fail "the challenge still reads head -c 3000 of the raw results"
fi

test_summary

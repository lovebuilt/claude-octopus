#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Council run-state filesystem and locale safety"
test_case "status updates preserve metadata and tolerate sibling scan failures"
if python3 "$SCRIPT_DIR/test-council-run-state.py"; then
    test_pass
else
    test_fail "council run-state functional checks failed"
fi
test_summary

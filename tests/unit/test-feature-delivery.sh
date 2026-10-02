#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "portable feature delivery acceptance"
test_case "shipped package and complete offline feature lifecycle"
if python3 "$SCRIPT_DIR/test-feature-delivery.py"; then
    test_pass
else
    test_fail "feature delivery acceptance failed"
fi
test_summary

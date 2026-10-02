#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "feature workflow"
test_case "actual Python helper acceptance"
if python3 "$PROJECT_ROOT/tests/unit/test-feature-workflow.py"; then
    test_pass
else
    test_fail "Python acceptance failed"
fi
test_summary

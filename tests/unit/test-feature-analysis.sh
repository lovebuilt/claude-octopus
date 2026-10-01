#!/usr/bin/env bash
# Run the actual offline analyser and check that sourcing preserves the caller.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Deterministic feature analysis"
test_case "functional CLI fixtures without provider calls"
if PYTHONDONTWRITEBYTECODE=1 python3 "$SCRIPT_DIR/feature_analysis_fixture.py" \
    "$SCRIPT_DIR/../../scripts/helpers/feature-analysis.py"; then
    test_pass
else
    test_fail "feature analysis fixture failed"
fi
test_case "library is source safe under Bash 3.2"
if /bin/bash -c '
    set +e +u
    before_flags=$-
    before_pwd=$PWD
    before_traps=$(trap -p)
    source "$1"
    source "$1"
    [[ "$before_flags" == "$-" && "$before_pwd" == "$PWD" && "$before_traps" == "$(trap -p)" ]]
    declare -F octo_feature_analyze >/dev/null
' feature-analysis "$SCRIPT_DIR/../../scripts/lib/feature-analysis.sh"; then
    test_pass
else
    test_fail "source changed caller state or helper missing"
fi
test_summary

#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "portable task identities and validated waves"
source "$PROJECT_ROOT/scripts/lib/feature-tasks.sh"

test_case "actual Python helper covers identities, dependencies, authority and Git state"
if python3 "$PROJECT_ROOT/tests/fixtures/feature-tasks-cases.py" "$PROJECT_ROOT"; then
    test_pass
else
    test_fail "task helper behavioral fixture failed"
fi

test_case "source-safe Bash adapter returns legacy metadata without dispatch"
printf '# Tasks\nNo structured task metadata.\n' > "$TEST_TMP_DIR/tasks.md"
if octopus_feature_tasks_parse --tasks "$TEST_TMP_DIR/tasks.md" --feature-id cb796828-bdc3-4a2a-aea4-bf5f74722f61 > "$TEST_TMP_DIR/parsed.json" &&
   python3 -c 'import json,sys; value=json.load(open(sys.argv[1])); assert value["legacy"] is True and value["tasks"] == []' "$TEST_TMP_DIR/parsed.json"; then
    test_pass
else
    test_fail "legacy input did not retain safe planning fallback"
fi
test_summary

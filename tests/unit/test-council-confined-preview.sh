#!/usr/bin/env bash
# Exercise previews without starting a council or contacting providers.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../helpers/test-framework.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../scripts/lib/council.sh"
test_suite "Council confined previews"
COUNCIL_CORPUS_ROOT=$(cd -P "$TEST_TMP_DIR" && pwd)
base="$COUNCIL_CORPUS_ROOT/graphify-out"
mkdir "$base"
report="$base/GRAPH_REPORT.md"
secret="$COUNCIL_CORPUS_ROOT/secret"
printf 'external-secret-marker\n' > "$secret"
printf 'regular report\n' > "$report"
test_case "regular corpus report is previewed"
if [[ "$(council_research_preview_file "$report" Report "$base")" == *'regular report'* ]]; then
    test_pass
else test_fail "regular corpus report missing"
fi

test_case "replacement after path validation cannot disclose a secret"
# Preserve the original validation, then swap the leaf before the preview read.
eval "$(declare -f council_research_path_is_safe | sed '1s/council_research_path_is_safe/original_path_is_safe/')"
council_research_path_is_safe() {
    original_path_is_safe "$@" || return 1
    rm "$report"
    ln -s "$secret" "$report"
}
preview=$(council_research_preview_file "$report" Report "$base")
if [[ "$preview" != *'external-secret-marker'* ]]; then test_pass
else test_fail "preview reopened the replaced pathname"
fi
test_summary

#!/usr/bin/env bash
# Static integration checks for optional Graphify companion wiring.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ORCH="$PROJECT_ROOT/scripts/orchestrate.sh"
REVIEW_LIB="$PROJECT_ROOT/scripts/lib/review.sh"
DOCTOR_LIB="$PROJECT_ROOT/scripts/lib/doctor.sh"
GRAPHIFY_LIB="$PROJECT_ROOT/scripts/lib/graphify.sh"
CLAUDE_SETUP="$PROJECT_ROOT/commands/setup.md"
CODEX_SETUP="$PROJECT_ROOT/.cursor-plugin/commands/octo-setup.md"
CLAUDE_REVIEW="$PROJECT_ROOT/commands/review.md"
CODEX_REVIEW="$PROJECT_ROOT/.cursor-plugin/commands/octo-review.md"
CHANGELOG="$PROJECT_ROOT/CHANGELOG.md"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "Graphify companion integration"

assert_file_has() {
    local file="$1"
    local pattern="$2"
    local label="$3"
    test_case "$label"
    if grep -qE "$pattern" "$file"; then
        test_pass
    else
        test_fail "pattern not found in $(basename "$file"): $pattern"
    fi
}

assert_file_lacks() {
    local file="$1"
    local pattern="$2"
    local label="$3"
    test_case "$label"
    if grep -qE "$pattern" "$file"; then
        test_fail "unexpected pattern found in $(basename "$file"): $pattern"
    else
        test_pass
    fi
}

test_case "graphify.sh has valid bash syntax"
if [[ -f "$GRAPHIFY_LIB" ]] && bash -n "$GRAPHIFY_LIB" 2>/dev/null; then
    test_pass
else
    test_fail "missing or invalid $GRAPHIFY_LIB"
fi

assert_file_has "$ORCH" 'lib/graphify\.sh' \
    "orchestrate.sh sources Graphify companion module"

assert_file_has "$REVIEW_LIB" 'octo_graphify_context_for_prompt' \
    "review_run reads Graphify companion context"

assert_file_has "$REVIEW_LIB" 'Graphify companion context' \
    "review prompt labels Graphify context"

assert_file_lacks "$REVIEW_LIB" 'graphify extract' \
    "review_run does not auto-build Graphify graphs"

assert_file_has "$DOCTOR_LIB" 'doctor_check_companions' \
    "doctor has companion category"

assert_file_has "$DOCTOR_LIB" 'graphify-cli' \
    "doctor checks Graphify CLI"

assert_file_has "$DOCTOR_LIB" 'graphify-graph' \
    "doctor checks existing Graphify graph"

assert_file_has "$DOCTOR_LIB" 'graphify-freshness' \
    "doctor checks Graphify freshness"

assert_file_has "$CLAUDE_SETUP" 'graphify' \
    "Claude setup detects Graphify"

assert_file_has "$CODEX_SETUP" 'graphify' \
    "Codex setup detects Graphify"

assert_file_has "$CLAUDE_REVIEW" 'Graphify' \
    "Claude review documents Graphify companion"

assert_file_has "$CODEX_REVIEW" 'Graphify' \
    "Codex review documents Graphify companion"

assert_file_has "$CHANGELOG" 'Graphify' \
    "changelog notes Graphify companion"

graphify_fixture=$(mktemp -d "$TEST_TMP_DIR/graphify.XXXXXX")
mkdir -p "$graphify_fixture/project/graphify-out" "$graphify_fixture/external"
printf 'sensitive-value\n' > "$graphify_fixture/external/secret"
# shellcheck source=/dev/null
source "$GRAPHIFY_LIB"

assert_empty_context() {
    local label="$1" out="${2:-graphify-out}"
    test_case "$label"
    if [[ -z "$(GRAPHIFY_OUT="$out" octo_graphify_context_for_prompt "$graphify_fixture/project" 12000)" ]]; then
        test_pass
    else
        test_fail "unsafe report context was read"
    fi
}

ln -s "$graphify_fixture/external/secret" "$graphify_fixture/project/graphify-out/GRAPH_REPORT.md"
assert_empty_context "Graphify rejects symlinked reports"
rm "$graphify_fixture/project/graphify-out/GRAPH_REPORT.md"
rmdir "$graphify_fixture/project/graphify-out"
ln -s "$graphify_fixture/external" "$graphify_fixture/project/graphify-out"
assert_empty_context "Graphify rejects symlinked directories"
assert_empty_context "Graphify rejects relative directory escape" ../external
assert_empty_context "Graphify rejects absolute directory escape" "$graphify_fixture/external"

test_case "Graphify prompt context is aggregate bounded and labels untrusted input"
rm "$graphify_fixture/project/graphify-out"
mkdir "$graphify_fixture/project/graphify-out"
printf '%013000d\n%013000d\n' 0 0 > \
    "$graphify_fixture/project/graphify-out/GRAPH_REPORT.md"
graphify_context=$(octo_graphify_context_for_prompt "$graphify_fixture/project" 12000)
if [[ ${#graphify_context} -le 12000 ]] && \
        [[ "$graphify_context" == *"untrusted repository content"* ]] && \
        [[ "$graphify_context" == *$'\n''```' ]]; then
    test_pass
else
    test_fail "context exceeded aggregate limit or omitted the trust-boundary warning"
fi

test_case "Graphify keeps report fences distinct from report content"
printf '```\nembedded fence\n```\n' > "$graphify_fixture/project/graphify-out/GRAPH_REPORT.md"
graphify_context=$(octo_graphify_context_for_prompt "$graphify_fixture/project" 12000)
if [[ "$graphify_context" == *'````markdown'* && "$graphify_context" == *$'\n''````' ]]; then
    test_pass
else
    test_fail "report fence collided with content"
fi

test_case "Graphify normalizes safe directory aliases before reading context"
expected_out=$(cd -P "$graphify_fixture/project/graphify-out" && pwd -P)
alias_ok=true
for out in graphify-out/ ./graphify-out graphify-out// \
        "$expected_out/"; do
    normalized_out=$(GRAPHIFY_OUT="$out" octo_graphify_out_dir "$graphify_fixture/project")
    graphify_context=$(GRAPHIFY_OUT="$out" octo_graphify_context_for_prompt "$graphify_fixture/project" 12000)
    if [[ "$normalized_out" != "$expected_out" \
            || "$graphify_context" != *"embedded fence"* ]]; then
        alias_ok=false
        break
    fi
done
if [[ "$alias_ok" == true ]]; then
    test_pass
else
    test_fail "safe directory alias did not resolve to readable context"
fi

test_case "Graphify omits context when budget cannot hold its warning and fences"
if [[ -z "$(octo_graphify_context_for_prompt "$graphify_fixture/project" 40)" ]]; then
    test_pass
else
    test_fail "small budget emitted an incomplete packet"
fi

test_summary

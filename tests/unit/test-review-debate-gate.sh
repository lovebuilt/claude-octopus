#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "review debate gate counts needs-debate candidates"

REVIEW_SH="$PROJECT_ROOT/scripts/lib/review.sh"
REVIEW_HARNESS="$TEST_TMP_DIR/review-run-harness.sh"

cat > "$REVIEW_HARNESS" <<'HARNESS'
set -eo pipefail
source "$REVIEW_SH"
log() { printf '%s\n' "$*" >> "$HARNESS_LOG"; }
check_codex_auth_freshness() { return 0; }
parse_review_md() { REVIEW_ALWAYS_CHECK=""; REVIEW_STYLE_RULES=""; REVIEW_SKIP_PATTERNS=""; }
review_collect_diff() { printf '%s\n' 'diff --git a/src/app.ts b/src/app.ts' '+const value = input.trim();'; }
build_review_fleet() { printf '%s\n' 'claude-sonnet:implementation-logic-reviewer:correctness'; }
fleet_dispatch_begin() { :; }
fleet_dispatch_end() { :; }
spawn_agent_capture_pid() {
    printf '%s\n' '## Output' "$ROUND1_OUTPUT" '## Status: SUCCESS' > "${RESULTS_DIR}/$(octo_agent_spec_slug "$1")-$3.md"
    printf '%s\n' 424242
}
review_supervise_round1() { :; }
review_run_agent_sync_progress() {
    printf 'SYNC %s %s\n' "$1" "$3" >> "$HARNESS_LOG"
    case "$3" in
        implementation-verifier) printf '%s\n' "$VERIFIER_OUTPUT" ;;
        implementation-debater) printf '%s\n' "$2" > "$PROMPT_DUMP"; printf '%s\n' "$DEBATE_OUTPUT" ;;
        implementation-synthesizer) printf '%s\n' "$2" | sed -n 's/^Findings: //p' | jq -c '{findings: .}' ;;
        *) return 1 ;;
    esac
}
render_terminal_report() { :; }
print_provider_report() { cat "$1" > "$STATUS_DUMP"; }
gh() { return 1; }
git() { return 1; }
cd "$HOME"
review_run "$(jq -cn --arg contextFile "$HOME/contract.md" '{target:"staged",debate:"auto",publish:"never",contextFile:$contextFile}')"
HARNESS

kept_finding='{"file":"src/app.ts","line":3,"severity":"normal","category":"correctness","title":"Kept","detail":"Null dereference on empty input","confidence":0.9}'
contested_finding='{"file":"src/app.ts","line":8,"severity":"normal","category":"correctness","title":"Contested","detail":"Possibly guarded by the caller","confidence":0.6}'
debate_output='{"include":[],"exclude":["finding-1"]}'

run_review_harness() {
    local run_dir="$1" round1_output="$2" verifier_output="$3"
    mkdir -p "$run_dir/home" "$run_dir/tmp" "$run_dir/results"
    : > "$run_dir/log"
    printf '%s\n' "Caller must retain empty-input findings until proven safe" > "$run_dir/home/contract.md"
    env -i "PATH=$PATH" "HOME=$run_dir/home" "TMPDIR=$run_dir/tmp" \
        "RESULTS_DIR=$run_dir/results" "HARNESS_LOG=$run_dir/log" "REVIEW_SH=$REVIEW_SH" \
        "ROUND1_OUTPUT=$round1_output" "VERIFIER_OUTPUT=$verifier_output" "DEBATE_OUTPUT=$debate_output" "PROMPT_DUMP=$run_dir/debate-prompt" "STATUS_DUMP=$run_dir/provider-status" \
        "$BASH" "$REVIEW_HARNESS" > "$run_dir/output" 2>&1
}

review_harness_titles() {
    local findings_file
    findings_file="$(find "$1/results" -name 'review-findings-*.json' -type f | head -n 1)"
    [[ -n "$findings_file" ]] || return 1
    jq -c '[.findings[].title]' "$findings_file"
}

review_harness_diagnostics() {
    printf 'rc=%s titles=%s log=[%s] output=[%s]' "$2" \
        "$(review_harness_titles "$1" 2>/dev/null || printf 'missing')" \
        "$(grep -E '^(WARN|ERROR|SYNC)' "$1/log" 2>/dev/null | tr '\n' ';')" \
        "$(tail -n 5 "$1/output" 2>/dev/null | tr '\n' ';')"
}

contested_run="$TEST_TMP_DIR/contested"
contested_rc=0
run_review_harness "$contested_run" \
    "$(jq -cn --argjson kept "$kept_finding" --argjson contested "$contested_finding" '{findings: [$kept, $contested]}')" \
    "$(jq -cn --argjson kept "$kept_finding" --argjson contested "$contested_finding" '{findings: [$kept + {verdict: "confirmed"}, $contested + {verdict: "needs-debate"}]}')" \
    || contested_rc=$?

test_case "needs-debate findings reach the debate provider"
if [[ "$contested_rc" -eq 0 ]] &&
   grep -Eq '^SYNC [^ ]+ implementation-debater$' "$contested_run/log"; then
    test_pass
else
    test_fail "$(review_harness_diagnostics "$contested_run" "$contested_rc")"
fi

test_case "bare id exclusions retain contested findings"
if [[ "$contested_rc" -eq 0 ]] &&
   [[ "$(review_harness_titles "$contested_run" 2>/dev/null || true)" == '["Kept","Contested"]' ]]; then
    test_pass
else
    test_fail "$(review_harness_diagnostics "$contested_run" "$contested_rc")"
fi

test_case "a valid candidate list does not trigger the invalid-candidates fallback"
if [[ "$contested_rc" -eq 0 ]] &&
   ! grep -q 'invalid debate candidates' "$contested_run/log"; then
    test_pass
else
    test_fail "$(review_harness_diagnostics "$contested_run" "$contested_rc")"
fi

test_case "debate prompt supplies the diff and asks for code evidence"
if grep -q '+const value = input.trim();' "$contested_run/debate-prompt" &&
   grep -q 'Check the code and supplied diff' "$contested_run/debate-prompt" &&
   grep -q 'evidence' "$contested_run/debate-prompt" &&
   grep -q 'Caller must retain empty-input findings until proven safe' "$contested_run/debate-prompt"; then
    test_pass
else
    test_fail "debate prompt omitted context or evidence instructions"
fi

test_case "unsupported decisions are visible in the audit with the original finding"
contested_file="$(find "$contested_run/results" -name 'review-findings-*.json' -type f | head -1)"
if jq -e '.debate.decisions[0] | .decision == "retain" and .finding.title == "Contested" and .finding.line == 8' "$contested_file" >/dev/null &&
   grep -q 'debate finding-1 retained' "$contested_run/log"; then
    test_pass
else
    test_fail "missing retained decision audit"
fi

debate_output='{"decisions":[{"debate_id":"finding-1","decision":"exclude","reason":"Caller guards empty input","evidence":"src/app.ts:18 if (!input) return"}]}'
duplicate_confirmed='{"file":"src/app.ts","line":12,"severity":"normal","category":"correctness","title":"Shared title","detail":"Confirmed finding","confidence":0.9}'
duplicate_contested='{"file":"src/app.ts","line":18,"severity":"normal","category":"correctness","title":"Shared title","detail":"Contested finding","confidence":0.6}'
duplicate_run="$TEST_TMP_DIR/duplicate-title"
duplicate_rc=0
run_review_harness "$duplicate_run" \
    "$(jq -cn --argjson kept "$duplicate_confirmed" --argjson contested "$duplicate_contested" '{findings: [$kept, $contested]}')" \
    "$(jq -cn --argjson kept "$duplicate_confirmed" --argjson contested "$duplicate_contested" '{findings: [$kept + {verdict: "confirmed"}, $contested + {verdict: "needs-debate"}]}')" \
    || duplicate_rc=$?

test_case "debate exclusions preserve confirmed findings with the same title"
duplicate_findings="$(find "$duplicate_run/results" -name 'review-findings-*.json' -type f | head -n 1)"
if [[ "$duplicate_rc" -eq 0 ]] &&
   [[ "$(jq -c '[.findings[].detail]' "$duplicate_findings" 2>/dev/null || true)" == '["Confirmed finding"]' ]]; then
    test_pass
else
    test_fail "$(review_harness_diagnostics "$duplicate_run" "$duplicate_rc")"
fi

test_case "reasoned exclusion preserves identity and evidence in the final artifact"
if jq -e '.excluded[0] | .title == "Shared title" and .line == 18 and .debate_reason == "Caller guards empty input" and .debate_evidence == "src/app.ts:18 if (!input) return"' "$duplicate_findings" >/dev/null &&
   jq -e '.decisions[0].finding.detail == "Contested finding"' "$duplicate_run/results"/review-debate-*.json >/dev/null; then
    test_pass
else
    test_fail "excluded finding or original identity missing"
fi

test_case "terminal and summary reports show excluded findings with reasons"
source "$REVIEW_SH"
report="$(render_terminal_report "$duplicate_findings")"
summary="$(render_review_summary "$duplicate_findings")"
if [[ "$report" == *'Excluded by debate'* && "$report" == *'Caller guards empty input'* &&
      "$summary" == *'src/app.ts:18 if (!input) return'* ]]; then
    test_pass
else
    test_fail "exclusions not visible in reports"
fi

for bad_decision in \
    '{"decisions":[{"debate_id":"finding-1","decision":"exclude","reason":"", "evidence":"src/app.ts:8"}]}' \
    '{"decisions":[{"debate_id":"finding-1","decision":"exclude","reason":"guarded", "evidence":" "}]}' \
    '{"decisions":[{"debate_id":"finding-99","decision":"exclude","reason":"guarded", "evidence":"src/app.ts:8"}]}' \
    '{"decisions":[{"debate_id":"finding-1","decision":"exclude","reason":"guarded", "evidence":"src/app.ts:8"},{"debate_id":"finding-1","decision":"include","reason":"unsafe", "evidence":"src/app.ts:8"}]}' \
    '{"decisions":[{"debate_id":"finding-1","decision":"maybe","reason":"guarded", "evidence":"src/app.ts:8"}]}' \
    '{}'; do
    test_case "incomplete, conflicting, or unknown decision retains the candidate"
    candidate="$(jq -cn --argjson finding "$contested_finding" '[$finding + {debate_id:"finding-1"}]')"
    resolution="$(printf '%s\n%s\n' "$candidate" "$bad_decision" | review_resolve_debate_decisions)"
    if [[ "$(printf '%s' "$resolution" | jq -r '.[0].decision')" == retain ]]; then
        test_pass
    else
        test_fail "unsupported exclusion accepted: $bad_decision"
    fi
done

uncontested_run="$TEST_TMP_DIR/uncontested"
uncontested_rc=0
run_review_harness "$uncontested_run" \
    "$(jq -cn --argjson kept "$kept_finding" '{findings: [$kept]}')" \
    "$(jq -cn --argjson kept "$kept_finding" '{findings: [$kept + {verdict: "confirmed"}]}')" \
    || uncontested_rc=$?

test_case "confirmed-only findings skip the debate provider without warning"
if [[ "$uncontested_rc" -eq 0 ]] &&
   ! grep -Eq '^SYNC [^ ]+ implementation-debater$' "$uncontested_run/log" &&
   ! grep -q 'invalid debate candidates' "$uncontested_run/log" &&
   [[ "$(review_harness_titles "$uncontested_run" 2>/dev/null || true)" == '["Kept"]' ]]; then
    test_pass
else
    test_fail "$(review_harness_diagnostics "$uncontested_run" "$uncontested_rc")"
fi

parse_miss_run="$TEST_TMP_DIR/parse-miss"
parse_miss_rc=0
run_review_harness "$parse_miss_run" '{"message":"done"}' '{"findings":[]}' || parse_miss_rc=$?
parse_miss_file="$(find "$parse_miss_run/results" -name 'review-findings-*.json' -type f | head -1)"
test_case "answered seat without findings JSON reports partial coverage and fallback status"
if [[ "$parse_miss_rc" -eq 0 ]] &&
   jq -e '.warning | contains("1 provider output(s) had possible unparsed findings")' "$parse_miss_file" >/dev/null &&
   grep -q 'fallback|Round 1 answered, but no findings JSON parsed' "$parse_miss_run/provider-status"; then
    test_pass
else
    test_fail "parse miss was reported as healthy: $(review_harness_diagnostics "$parse_miss_run" "$parse_miss_rc")"
fi

test_summary

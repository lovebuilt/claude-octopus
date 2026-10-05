#!/usr/bin/env bash
# The flow skills check that orchestrate.sh produced its report before they present it. Their result gates searched
# for grasp-synthesis, tangle-synthesis and ink-validation reports, which the engine does not write (it writes
# grasp-consensus, tangle-validation and delivery), so a gate could never find its file. Nothing failed until a user
# ran the skill. A report that exists is not a pass either: the engine writes the tangle report when its quality gate
# FAILED and the delivery document when its checks fail (PARTIAL).
#
# These checks read the shell blocks of the skills and commands (both skill copies) and the engine's report writers,
# then run the result gates of both skill copies against fixture results directories.
# Exits non-zero when any check fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/octo-skill-reports.XXXXXX")"
trap 'rm -rf "$TEST_TMP_DIR"' EXIT

test_suite "skill result gates and report names"

# Every shell-fenced block in the skills, templates and commands, one logical line per output line: a line ending
# in a backslash is joined to the next, so a command split across lines is read whole. Prose and output samples
# outside bash/sh fences are not code and are not read.
caller_code() {
    find "$PROJECT_ROOT/skills" "$PROJECT_ROOT/.claude/skills" "$PROJECT_ROOT/commands" \
        -type f \( -name '*.md' -o -name '*.tmpl' \) -print 2>/dev/null | LC_ALL=C sort |
        while IFS= read -r file; do
            awk -v rel="${file#"$PROJECT_ROOT"/}" '
                /^[[:space:]]*```(bash|sh|shell|zsh)[[:space:]]*$/ { inside = 1; buf = ""; next }
                inside && /^[[:space:]]*```/ { if (buf != "") print rel ": " buf; inside = 0; buf = ""; next }
                inside {
                    line = $0
                    if (line ~ /\\$/) { sub(/\\$/, "", line); buf = buf line " "; next }
                    print rel ": " buf line
                    buf = ""
                }
            ' "$file"
        done
}
CALLER_CODE="$(caller_code)"

# ── report names ──────────────────────────────────────────────────────────────

ENGINE_FILES=("$PROJECT_ROOT/scripts/orchestrate.sh")
for f in "$PROJECT_ROOT"/scripts/lib/*.sh; do ENGINE_FILES+=("$f"); done

# A report counts as written only when an engine file writes it: a redirect straight into
# "<dir>/<prefix>$...", or a variable assigned "<dir>/<prefix>$..." that the same file then
# writes (>, >>, cp, mv, tee, install, or a *_write / *_publish helper such as atomic_write).
# A path that only appears in an echo or a log line is not a writer.
writes_report() {
    local prefix="$1" file var
    if grep -qE ">>?[[:space:]]*\"[^\"]*/${prefix}\\\$" "${ENGINE_FILES[@]}"; then
        return 0
    fi
    while IFS=: read -r file var; do
        [[ -n "$var" ]] || continue
        if grep -qE "(>>?[[:space:]]*|(^|[^A-Za-z0-9_])(cp|mv|tee|install)[[:space:]].*|[A-Za-z0-9_]*_(write|publish)[[:space:]].*)\"\\\$\\{?${var}\\}?\"" "$file"; then
            return 0
        fi
    done < <(grep -HoE "^[[:space:]]*((local|declare|export|readonly)[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=\"[^\"]*/${prefix}\\\$" "${ENGINE_FILES[@]}" |
        sed -E 's/^([^:]*):[[:space:]]*((local|declare|export|readonly)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\1:\4/')
    return 1
}

test_case "every results-directory report a skill looks for is one the engine writes"
sought="$(grep -iE 'results' <<< "$CALLER_CODE" |
    grep -oE "[a-z][a-z0-9-]*-[\"']?\*[^[:space:]\"'/]*\.md" |
    sed -E "s/[\"']?\*.*//" | sort -u || true)"
stale=""
for s in $sought; do writes_report "$s" || stale="$stale ${s}*.md"; done
if [[ -z "$sought" ]]; then
    test_fail "found no report lookups in the skills; the pattern no longer matches them"
elif [[ -n "$stale" ]]; then
    test_fail "skills look for reports the engine never writes:$stale"
elif ! grep -qx "delivery-" <<< "$sought"; then
    test_fail "found no delivery- lookup in the skills; the pattern no longer matches them"
else
    test_pass
fi

# ── result gates, run against a fixture results directory ───────────────────

ws_home="$TEST_TMP_DIR/home"
results="$ws_home/.claude-octopus/results"

epoch_stamp() { date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$1" +%Y%m%d%H%M.%S; }
now=$(date +%s)
# make_report <path> <age seconds> <body>
make_report() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$3" > "$1"; touch -t "$(epoch_stamp $((now - $2)))" "$1"; }
reset_results() { rm -rf "$results"; mkdir -p "$results"; }

# run_gate <code> [session id]: runs the block in a fresh shell, from a scratch directory, with HOME at the fixture.
run_gate() {
    local code="$1" session="${2:-}"
    (
        cd "$TEST_TMP_DIR"
        unset CLAUDE_PLUGIN_DATA CLAUDE_OCTOPUS_WORKSPACE CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
            CODEX_SESSION_ID CODEX_TASK_ID
        [[ -z "$session" ]] || export CLAUDE_CODE_SESSION_ID="$session"
        HOME="$ws_home" bash -c "$code" 2>&1
    )
}

# First shell fence under a heading, ending at the next heading of level 2 to 4.
gate_code() {
    awk -v heading="$2" '
        $0 == heading { in_section = 1; next }
        in_section && /^#{2,4} / { exit }
        in_section && /^```bash$/ { inside = 1; next }
        inside && /^```$/ { exit }
        inside { print }
    ' "$1"
}

passing_body() {
    case "$1" in
        delivery-) printf '# DELIVERY DOCUMENT\n## Task: t\n## Status: COMPLETE\n' ;;
        tangle-validation-) printf '# TANGLE Phase Validation Report\n## Task: t\n### Quality Gate: PASSED\n' ;;
        *) printf '# Report\nbody\n' ;;
    esac
}

# skill|heading|report prefix|word the gate prints on success
GATES="flow-define|### STEP 5: Verify Execution|grasp-consensus-|VALIDATION PASSED
flow-develop|### STEP 5: Verify Execution (MANDATORY - Validation Gate)|tangle-validation-|VALIDATION PASSED
flow-deliver|### STEP 5: Verify Execution (MANDATORY - Validation Gate)|delivery-|VALIDATION PASSED
skill-ship|#### Step 3: Verify Audit Completed|delivery-|AUDIT COMPLETE"

# picks <code> <session> <want path> <other path>...: the gate passes and names <want> and none of the others.
picks() {
    local code="$1" session="$2" want="$3" out other
    shift 3
    out="$(run_gate "$code" "$session")" || { echo "gate failed: $out"; return 1; }
    grep -qF "$want" <<< "$out" || { echo "did not name $want: $out"; return 1; }
    for other in "$@"; do
        if grep -qF "$other" <<< "$out"; then echo "named $other: $out"; return 1; fi
    done
}

for copy in .claude/skills skills; do
    while IFS='|' read -r skill heading prefix pass_word; do
        code="$(gate_code "$PROJECT_ROOT/$copy/$skill/SKILL.md" "$heading")"
        body="$(passing_body "$prefix")"

        test_case "$copy/$skill: the gate finds the newest fresh $prefix report"
        problem=""
        if [[ -z "$code" ]]; then
            problem="no shell block under '$heading'"
        else
            # Newest in a session directory, older at the root; then the reverse. Then two in one directory,
            # with the names in both orders. Whatever order find lists them in, only the newest is right.
            reset_results
            make_report "$results/${prefix}9.md" 300 "$body"
            make_report "$results/s1/${prefix}1.md" 30 "$body"
            make_report "$results/s2/${prefix}5.md" 600 "$body"
            problem="$(picks "$code" "" "$results/s1/${prefix}1.md" "${prefix}9.md" "${prefix}5.md")" || true
            if [[ -z "$problem" ]]; then
                reset_results
                make_report "$results/${prefix}1.md" 30 "$body"
                make_report "$results/s1/${prefix}9.md" 300 "$body"
                problem="$(picks "$code" "" "$results/${prefix}1.md" "${prefix}9.md")" || true
            fi
            if [[ -z "$problem" ]]; then
                reset_results
                make_report "$results/s1/${prefix}1.md" 300 "$body"
                make_report "$results/s1/${prefix}9.md" 30 "$body"
                problem="$(picks "$code" "" "$results/s1/${prefix}9.md" "${prefix}1.md")" || true
            fi
            if [[ -z "$problem" ]]; then
                reset_results
                make_report "$results/s1/${prefix}9.md" 300 "$body"
                make_report "$results/s1/${prefix}1.md" 30 "$body"
                problem="$(picks "$code" "" "$results/s1/${prefix}1.md" "${prefix}9.md")" || true
            fi
        fi
        if [[ -z "$problem" ]]; then test_pass; else test_fail "$problem"; fi

        # The lookup scope is the v11.10.0 one: the whole results directory, whatever the session.
        test_case "$copy/$skill: the gate searches the whole results directory, with or without a session id"
        reset_results
        make_report "$results/other-session/${prefix}2.md" 30 "$body"
        problem="$(picks "$code" "" "$results/other-session/${prefix}2.md")" || true
        if [[ -z "$problem" ]]; then
            reset_results
            make_report "$results/${prefix}3.md" 30 "$body"
            problem="$(picks "$code" "this-session" "$results/${prefix}3.md")" || true
        fi
        if [[ -z "$problem" ]]; then test_pass; else test_fail "$problem"; fi

        test_case "$copy/$skill: the gate fails on a stale, empty or missing report, and on the old name"
        problem=""
        reset_results
        make_report "$results/s1/${prefix}1.md" 1200 "$body"
        if out="$(run_gate "$code")"; then problem="accepted a report 20 minutes old: $out"; fi
        reset_results
        : > "$results/${prefix}1.md"
        if [[ -z "$problem" ]] && out="$(run_gate "$code")"; then problem="accepted an empty report: $out"; fi
        reset_results
        if [[ -z "$problem" ]] && out="$(run_gate "$code")"; then problem="passed with no report: $out"; fi
        case "$prefix" in
            grasp-consensus-) old=grasp-synthesis- ;;
            tangle-validation-) old=tangle-synthesis- ;;
            *) old=ink-validation- ;;
        esac
        make_report "$results/${old}1.md" 30 "$body"
        if [[ -z "$problem" ]] && out="$(run_gate "$code")"; then problem="accepted a ${old} report: $out"; fi
        if [[ -z "$problem" ]]; then test_pass; else test_fail "$problem"; fi
    done <<< "$GATES"

    # status_is <skill> <heading> <prefix> <status line> <pass|fail> <pass word>
    status_is() {
        local code out rc
        code="$(gate_code "$PROJECT_ROOT/$copy/$1/SKILL.md" "$2")"
        reset_results
        make_report "$results/s1/${3}1.md" 30 "$(printf '# Report\n## Task: t\n%s\n' "$4")"
        out="$(run_gate "$code")" && rc=0 || rc=$?
        if [[ "$5" == pass ]]; then
            [[ "$rc" -eq 0 ]] && grep -q "$6" <<< "$out"
        else
            [[ "$rc" -ne 0 ]] && ! grep -q "$6" <<< "$out"
        fi
    }

    develop_heading="### STEP 5: Verify Execution (MANDATORY - Validation Gate)"
    test_case "$copy/flow-develop: only PASSED, WARNING and CHALLENGED pass; FAILED, missing and unknown fail; the first gate line counts"
    if status_is flow-develop "$develop_heading" tangle-validation- '### Quality Gate: PASSED' pass "VALIDATION PASSED" &&
        status_is flow-develop "$develop_heading" tangle-validation- '### Quality Gate: WARNING' pass "VALIDATION PASSED" &&
        status_is flow-develop "$develop_heading" tangle-validation- '### Quality Gate: CHALLENGED' pass "VALIDATION PASSED" &&
        status_is flow-develop "$develop_heading" tangle-validation- '### Quality Gate: FAILED' fail "VALIDATION PASSED" &&
        status_is flow-develop "$develop_heading" tangle-validation- '- Success Rate: 100%' fail "VALIDATION PASSED" &&
        status_is flow-develop "$develop_heading" tangle-validation- '### Quality Gate: SKIPPED' fail "VALIDATION PASSED" &&
        status_is flow-develop "$develop_heading" tangle-validation- \
            "$(printf '### Quality Gate: FAILED\n---\nprovider text:\n### Quality Gate: PASSED')" fail "VALIDATION PASSED"; then
        test_pass
    else
        test_fail "the develop gate's verdict does not follow the allowed-status list"
    fi

    deliver_heading="### STEP 5: Verify Execution (MANDATORY - Validation Gate)"
    test_case "$copy/flow-deliver: only COMPLETE passes; PARTIAL, missing and unknown fail; the first status line counts"
    if status_is flow-deliver "$deliver_heading" delivery- '## Status: COMPLETE' pass "VALIDATION PASSED" &&
        status_is flow-deliver "$deliver_heading" delivery- '## Status: PARTIAL - Review Required' fail "VALIDATION PASSED" &&
        status_is flow-deliver "$deliver_heading" delivery- '## Quality Certification' fail "VALIDATION PASSED" &&
        status_is flow-deliver "$deliver_heading" delivery- '## Status: DONE' fail "VALIDATION PASSED" &&
        status_is flow-deliver "$deliver_heading" delivery- \
            "$(printf '## Status: PARTIAL - Review Required\n---\nprovider text:\n## Status: COMPLETE')" fail "VALIDATION PASSED"; then
        test_pass
    else
        test_fail "the deliver gate's verdict does not follow the allowed-status list"
    fi

    ship_heading="#### Step 3: Verify Audit Completed"
    test_case "$copy/skill-ship: only COMPLETE passes; PARTIAL, missing and unknown fail; the first status line counts"
    if status_is skill-ship "$ship_heading" delivery- '## Status: COMPLETE' pass "AUDIT COMPLETE" &&
        status_is skill-ship "$ship_heading" delivery- '## Status: PARTIAL - Review Required' fail "AUDIT COMPLETE" &&
        status_is skill-ship "$ship_heading" delivery- '## Quality Certification' fail "AUDIT COMPLETE" &&
        status_is skill-ship "$ship_heading" delivery- '## Status: DONE' fail "AUDIT COMPLETE" &&
        status_is skill-ship "$ship_heading" delivery- \
            "$(printf '## Status: PARTIAL - Review Required\n---\nprovider text:\n## Status: COMPLETE')" fail "AUDIT COMPLETE"; then
        test_pass
    else
        test_fail "the ship audit gate's verdict does not follow the allowed-status list"
    fi
done

# The verification skill (skill-verification-gate; the portable copy also ships as skill-verify) lists the newest
# phase document of any of the four names.
for file in .claude/skills/skill-verification-gate/SKILL.md skills/skill-verification-gate/SKILL.md \
    skills/skill-verify/SKILL.md; do
    test_case "$file: the check names the newest phase document"
    code="$(gate_code "$PROJECT_ROOT/$file" "## Multi-Provider Context")"
    reset_results
    make_report "$results/s1/probe-synthesis-1.md" 400 "a"
    make_report "$results/s1/grasp-consensus-1.md" 300 "b"
    make_report "$results/s1/delivery-1.md" 30 "$(printf 'c\nd\ne')"
    make_report "$results/s1/tangle-validation-1.md" 200 "f"
    if out="$(run_gate "$code")" && grep -qF "$results/s1/delivery-1.md" <<< "$out" &&
        grep -qE '^[[:space:]]*3$' <<< "$out" && ! grep -q "No such file" <<< "$out"; then
        test_pass
    else
        test_fail "$out"
    fi
done

test_summary

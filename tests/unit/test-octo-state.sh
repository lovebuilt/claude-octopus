#!/usr/bin/env bash
# Test octo-state.sh functionality
# Validates project state management for Claude Octopus v7.22.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "octo-state.sh functionality"

OCTO_STATE="$PROJECT_ROOT/scripts/octo-state.sh"


TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

# Test directory (created fresh each run)
TEST_DIR=""

echo -e "${BLUE}🧪 Testing octo-state.sh (v7.22.0 Project Lifecycle)${NC}"
echo ""

# Helper functions
pass() { test_case "$1"; test_pass; }

fail() { test_case "$1"; test_fail "${2:-$1}"; }

info() { echo "$1"; }

# Setup test directory
setup() {
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
    info "Test directory: $TEST_DIR"
}

# Cleanup test directory
cleanup() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

# Trap to cleanup on exit
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: Script exists and is executable
# ═══════════════════════════════════════════════════════════════════════════════

echo "Test 1: Checking octo-state.sh exists and is executable..."
if [[ -f "$OCTO_STATE" ]]; then
    pass "octo-state.sh exists"
else
    fail "octo-state.sh not found" "Expected: $OCTO_STATE"
    exit 1
fi

if [[ -x "$OCTO_STATE" ]]; then
    pass "octo-state.sh is executable"
else
    fail "octo-state.sh is not executable" "Run: chmod +x $OCTO_STATE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: Help command
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 2: Checking help command..."
if "$OCTO_STATE" help 2>&1 | grep -q "Octo State Manager"; then
    pass "Help command works"
else
    fail "Help command failed" "Did not find expected output"
fi

if "$OCTO_STATE" help 2>&1 | grep -q "init_project"; then
    pass "Help mentions init_project command"
else
    fail "Help missing init_project" "Should document init_project command"
fi

test_case "Help mentions update_project command"
if "$OCTO_STATE" help 2>&1 | grep -q "update_project"; then
    test_pass
else
    test_fail "Help should document bounded project-section updates"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: init_project --dry-run
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 3: Checking init_project --dry-run..."
setup

output=$("$OCTO_STATE" init_project --dry-run 2>&1)
if echo "$output" | grep -q "DRY RUN"; then
    pass "init_project --dry-run shows dry run message"
else
    fail "init_project --dry-run failed" "Did not show DRY RUN message"
fi

if [[ ! -d ".octo" ]]; then
    pass "init_project --dry-run did not create directory"
else
    fail "init_project --dry-run created directory" "Should not create files in dry-run mode"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: init_project (actual)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 4: Checking init_project..."

output=$("$OCTO_STATE" init_project 2>&1)
if echo "$output" | grep -q "SUCCESS"; then
    pass "init_project succeeds"
else
    fail "init_project failed" "$output"
fi

# Check directory structure
if [[ -d ".octo" ]]; then
    pass ".octo/ directory created"
else
    fail ".octo/ directory not created" "Expected .octo/ to exist"
fi

if [[ -d ".octo/phases" ]]; then
    pass ".octo/phases/ directory created"
else
    fail ".octo/phases/ directory not created" "Expected .octo/phases/ to exist"
fi

if [[ -d ".octo/codebase" ]]; then
    pass ".octo/codebase/ directory created"
else
    fail ".octo/codebase/ directory not created" "Expected .octo/codebase/ to exist"
fi

# Check files
for file in STATE.md PROJECT.md ROADMAP.md config.json ISSUES.md LESSONS.md; do
    if [[ -f ".octo/$file" ]]; then
        pass ".octo/$file created"
    else
        fail ".octo/$file not created" "Expected .octo/$file to exist"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: update_project with bounded file input
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 5: Checking update_project bounded file input..."

SYNTHESIS_FILE="$TEST_DIR/synthesis.md"
printf '%s\n' 'Complete discovery finding one.' 'Complete discovery finding two.' > "$SYNTHESIS_FILE"
test_case "update_project replaces one section from a content file"
if output=$("$OCTO_STATE" update_project --section vision --content-file "$SYNTHESIS_FILE" 2>&1) &&
   grep -q 'Complete discovery finding one.' .octo/PROJECT.md &&
   grep -q '^## Requirements$' .octo/PROJECT.md; then
    test_pass
else
    test_fail "${output:-update_project failed or damaged PROJECT.md}"
fi

OVERSIZED_FILE="$TEST_DIR/oversized-synthesis.md"
dd if=/dev/zero of="$OVERSIZED_FILE" bs=1048577 count=1 2>/dev/null
test_case "update_project rejects content above its one-MiB bound"
if ! "$OCTO_STATE" update_project --section vision --content-file "$OVERSIZED_FILE" >/dev/null 2>&1; then
    test_pass
else
    test_fail "Content-file input must be bounded"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: init_project (idempotent)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 5: Checking init_project idempotency..."

output=$("$OCTO_STATE" init_project 2>&1)
if echo "$output" | grep -q "already exists"; then
    pass "init_project is idempotent (warns on existing)"
else
    fail "init_project not idempotent" "Should warn when .octo/ exists"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: read_state
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 6: Checking read_state..."

output=$("$OCTO_STATE" read_state 2>&1)
if echo "$output" | grep -q "schema="; then
    pass "read_state returns schema"
else
    fail "read_state missing schema" "Should return schema=value"
fi

if echo "$output" | grep -q "current_phase=1"; then
    pass "read_state returns current_phase=1"
else
    fail "read_state wrong phase" "Should return current_phase=1"
fi

if echo "$output" | grep -q "status=ready"; then
    pass "read_state returns status=ready"
else
    fail "read_state wrong status" "Should return status=ready"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: write_state
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 7: Checking write_state..."

"$OCTO_STATE" write_state --phase 2 --status planning --position "Planning phase 2" 2>&1
output=$("$OCTO_STATE" read_state 2>&1)

if echo "$output" | grep -q "current_phase=2"; then
    pass "write_state updates phase"
else
    fail "write_state did not update phase" "Expected current_phase=2"
fi

if echo "$output" | grep -q "status=planning"; then
    pass "write_state updates status"
else
    fail "write_state did not update status" "Expected status=planning"
fi

if echo "$output" | grep -q "current_position=Planning phase 2"; then
    pass "write_state updates position"
else
    fail "write_state did not update position" "Expected position='Planning phase 2'"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: write_state with blocker
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 8: Checking write_state with blocker..."

"$OCTO_STATE" write_state --status blocked --blocker "Waiting for API access" 2>&1

if grep -q "Waiting for API access" .octo/STATE.md; then
    pass "write_state adds blocker"
else
    fail "write_state did not add blocker" "Blocker text not found in STATE.md"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: update_phase shorthand
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 9: Checking update_phase shorthand..."

"$OCTO_STATE" update_phase 3 "Building auth module" building 2>&1
output=$("$OCTO_STATE" read_state 2>&1)

if echo "$output" | grep -q "current_phase=3"; then
    pass "update_phase updates phase"
else
    fail "update_phase did not update phase" "Expected current_phase=3"
fi

if echo "$output" | grep -q "status=building"; then
    pass "update_phase updates status"
else
    fail "update_phase did not update status" "Expected status=building"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: Validation - invalid status
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 10: Checking validation (invalid status)..."

if ! "$OCTO_STATE" write_state --status invalid_status 2>&1; then
    pass "Invalid status rejected"
else
    fail "Invalid status accepted" "Should reject 'invalid_status'"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: Validation - invalid phase
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 11: Checking validation (invalid phase)..."

if ! "$OCTO_STATE" write_state --phase -1 2>&1; then
    pass "Negative phase rejected"
else
    fail "Negative phase accepted" "Should reject phase=-1"
fi

if ! "$OCTO_STATE" write_state --phase abc 2>&1; then
    pass "Non-numeric phase rejected"
else
    fail "Non-numeric phase accepted" "Should reject phase=abc"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: get_context_tier - minimal
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 12: Checking get_context_tier minimal..."

output=$("$OCTO_STATE" get_context_tier minimal 2>&1)
if echo "$output" | grep -q "Context Tier: minimal"; then
    pass "get_context_tier minimal works"
else
    fail "get_context_tier minimal failed" "Did not show tier name"
fi

if echo "$output" | grep -q "STATE.md"; then
    pass "get_context_tier minimal includes STATE.md"
else
    fail "get_context_tier minimal missing STATE.md" "Should include STATE.md"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: get_context_tier - planning
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 13: Checking get_context_tier planning..."

output=$("$OCTO_STATE" get_context_tier planning 2>&1)
if echo "$output" | grep -q "PROJECT.md"; then
    pass "get_context_tier planning includes PROJECT.md"
else
    fail "get_context_tier planning missing PROJECT.md" "Should include PROJECT.md"
fi

if echo "$output" | grep -q "ROADMAP.md"; then
    pass "get_context_tier planning includes ROADMAP.md"
else
    fail "get_context_tier planning missing ROADMAP.md" "Should include ROADMAP.md"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: get_context_tier - auto
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 14: Checking get_context_tier auto..."

# Set status to building (should auto-detect execution tier)
"$OCTO_STATE" write_state --status building 2>&1
output=$("$OCTO_STATE" get_context_tier auto 2>&1)

if echo "$output" | grep -q "Context Tier: execution"; then
    pass "get_context_tier auto detects execution tier for building status"
else
    fail "get_context_tier auto failed" "Should detect execution tier for building status"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: History tracking
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 15: Checking history tracking..."

# History should contain multiple entries from our updates
history_count=$(grep -c "^\- \[" .octo/STATE.md || echo 0)
if [[ "$history_count" -ge 3 ]]; then
    pass "History tracks multiple updates (found $history_count entries)"
else
    fail "History not tracking updates" "Found only $history_count entries, expected 3+"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: config.json structure
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 16: Checking config.json structure..."

if grep -q '"interaction_mode"' .octo/config.json; then
    pass "config.json has interaction_mode"
else
    fail "config.json missing interaction_mode" "Should have interaction_mode field"
fi

if grep -q '"model_routing"' .octo/config.json; then
    pass "config.json has model_routing"
else
    fail "config.json missing model_routing" "Should have model_routing field"
fi

if grep -q '"context_tier"' .octo/config.json; then
    pass "config.json has context_tier"
else
    fail "config.json missing context_tier" "Should have context_tier field"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: Unknown command handling
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Test 17: Checking unknown command handling..."

if ! "$OCTO_STATE" unknown_command 2>&1; then
    pass "Unknown command rejected"
else
    fail "Unknown command accepted" "Should reject unknown commands"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TEST: the commands the flow skills call (update_state, get_phase_status, update_roadmap)
# ═══════════════════════════════════════════════════════════════════════════════
# flow-define, flow-develop, flow-deliver and flow-discover call these three names; until
# they existed every call printed "Unknown command" and the skills' state steps did nothing.

echo ""
echo "Test 18: Checking the commands the flow skills call..."

FLOW_DIR=$(mktemp -d)
flow() { (cd "$FLOW_DIR" && "$OCTO_STATE" "$@"); }
phase_status() { flow get_phase_status "$1" 2>/dev/null; }
history_lines() { sed -n '/^## History/,$ p' "$FLOW_DIR/.octo/STATE.md" | grep -c '^- \[' || true; }

flow init_project >/dev/null 2>&1 || true
if flow update_state --phase 2 --position "Definition" --status in_progress >/dev/null 2>&1 &&
    grep -q "^\*\*Current Phase:\*\* 2" "$FLOW_DIR/.octo/STATE.md"; then
    pass "update_state updates STATE.md like write_state"
else
    fail "update_state rejected or did not write" "flow skills call update_state"
fi

before=$(history_lines)
if flow update_state --history "$(printf 'Define phase completed\nsecond line')" >/dev/null 2>&1 &&
    grep -q "Phase 2 (in_progress): Definition: Define phase completed second line$" "$FLOW_DIR/.octo/STATE.md" &&
    [[ "$(history_lines)" -eq $((before + 1)) ]] &&
    ! grep -q "^second line" "$FLOW_DIR/.octo/STATE.md"; then
    pass "update_state --history records the note on one history line"
else
    fail "--history rejected, not recorded, or split across lines" "$(sed -n '/^## History/,$ p' "$FLOW_DIR/.octo/STATE.md")"
fi

if [[ "$(phase_status 2)" == "in_progress" && "$(phase_status 1)" == "ready" && "$(phase_status 3)" == "pending" ]]; then
    pass "get_phase_status reads the current status and the recorded status, never the phase order"
else
    fail "get_phase_status wrong" "got 1=$(phase_status 1) 2=$(phase_status 2) 3=$(phase_status 3) (want ready in_progress pending)"
fi

# A completed phase that is reopened and left blocked is not complete; a phase that was
# never run is pending even when a later phase is current.
flow update_state --phase 2 --status complete >/dev/null 2>&1 || true
flow update_state --phase 2 --status blocked >/dev/null 2>&1 || true
flow update_state --phase 4 --position "Delivery" --status in_progress >/dev/null 2>&1 || true
if [[ "$(phase_status 2)" == "blocked" && "$(phase_status 3)" == "pending" && "$(phase_status 4)" == "in_progress" ]]; then
    pass "get_phase_status reports a reopened phase's newest record and a skipped phase as pending"
else
    fail "reopened or skipped phase misreported" "got 2=$(phase_status 2) 3=$(phase_status 3) 4=$(phase_status 4) (want blocked pending in_progress)"
fi

flow update_state --phase 3 --position "Development" --status complete_with_gaps >/dev/null 2>&1 || true
flow update_state --phase 4 --position "Delivery" --status in_progress >/dev/null 2>&1 || true
if [[ "$(phase_status 3)" == "complete_with_gaps" ]]; then
    pass "get_phase_status returns the recorded status verbatim (complete_with_gaps)"
else
    fail "complete_with_gaps misreported" "got $(phase_status 3)"
fi

# Free text in a note or a position cannot stand in for the status: the status is read
# only from its slot right after "Phase N".
flow update_state --phase 5 --position "Review" --status in_progress --history "looks done (complete)" >/dev/null 2>&1 || true
flow update_state --phase 6 --position "Review" --status blocked --history "x (complete): y" >/dev/null 2>&1 || true
flow update_state --phase 8 --position "Retry (complete) parser" --status blocked >/dev/null 2>&1 || true
flow update_state --phase 9 --position "Fix (complete): retry" --status blocked >/dev/null 2>&1 || true
flow update_state --phase 12 --position "(complete)" --status paused --history "(complete)" >/dev/null 2>&1 || true
flow update_state --phase 7 --position "Next" --status ready >/dev/null 2>&1 || true
if [[ "$(phase_status 5)" == "in_progress" && "$(phase_status 6)" == "blocked" && "$(phase_status 8)" == "blocked" &&
      "$(phase_status 9)" == "blocked" && "$(phase_status 12)" == "paused" ]] &&
    grep -q "Phase 9 (blocked): Fix (complete): retry$" "$FLOW_DIR/.octo/STATE.md"; then
    pass "(complete) inside a note or a position does not change the recorded status"
else
    fail "free text spoofed the status" "got 5=$(phase_status 5) 6=$(phase_status 6) 8=$(phase_status 8) 9=$(phase_status 9) 12=$(phase_status 12) (want in_progress blocked blocked blocked paused)"
fi

# A record in any other form is not read; the caller is told why the answer is pending.
LEGACY_DIR=$(mktemp -d)
(
    cd "$LEGACY_DIR"
    "$OCTO_STATE" init_project >/dev/null 2>&1
    printf -- '- [2026-01-01T00:00:00Z] Phase 3: Development (complete)\n' >> .octo/STATE.md
) || true
legacy_status=$(cd "$LEGACY_DIR" && "$OCTO_STATE" get_phase_status 3 2>"$LEGACY_DIR/err") || legacy_status="exit-$?"
if [[ "$legacy_status" == "pending" ]] && grep -q "Phase 3 has 1 history line" "$LEGACY_DIR/err"; then
    pass "get_phase_status does not read a record outside the status slot, and says so"
else
    fail "a record outside the status slot was read, or not reported" "status=$legacy_status err=$(cat "$LEGACY_DIR/err")"
fi
rm -rf "$LEGACY_DIR"

# Newlines in --position and --blocker are folded, so neither can add a header line or a
# history record of its own.
FOLD_DIR=$(mktemp -d)
(cd "$FOLD_DIR" && "$OCTO_STATE" init_project >/dev/null 2>&1) || true
(cd "$FOLD_DIR" && "$OCTO_STATE" update_state --phase 2 --status blocked \
    --position "$(printf 'Retry\n**Status:** complete')" >/dev/null 2>&1) || true
fold_current=$(cd "$FOLD_DIR" && "$OCTO_STATE" get_phase_status 2 2>/dev/null) || fold_current="exit-$?"
if [[ "$fold_current" == "blocked" && "$(grep -c '^\*\*Status:\*\*' "$FOLD_DIR/.octo/STATE.md")" == "1" ]] &&
    grep -q '^\*\*Current Position:\*\* Retry \*\*Status:\*\* complete$' "$FOLD_DIR/.octo/STATE.md"; then
    pass "update_state --position folds newlines onto the position line"
else
    fail "a newline in --position added a line" "status=$fold_current; $(cat "$FOLD_DIR/.octo/STATE.md")"
fi
(cd "$FOLD_DIR" && "$OCTO_STATE" update_state --phase 3 --status in_progress \
    --blocker "$(printf 'waiting\n## History\n- [2026-01-01T00:00:00Z] Phase 9 (complete): forged')" >/dev/null 2>&1) || true
fold_forged=$(cd "$FOLD_DIR" && "$OCTO_STATE" get_phase_status 9 2>/dev/null) || fold_forged="exit-$?"
if [[ "$fold_forged" == "pending" && "$(grep -c '^## History' "$FOLD_DIR/.octo/STATE.md")" == "1" ]] &&
    grep -q '^- waiting ## History - \[2026-01-01T00:00:00Z\] Phase 9 (complete): forged$' "$FOLD_DIR/.octo/STATE.md"; then
    pass "update_state --blocker folds newlines onto the blocker line"
else
    fail "a newline in --blocker added a section or a record" "phase 9=$fold_forged; $(cat "$FOLD_DIR/.octo/STATE.md")"
fi
rm -rf "$FOLD_DIR"

# Backslashes are kept as written, on one line.
(cd "$FLOW_DIR" && "$OCTO_STATE" update_state --phase 7 --position 'C:\new\table' >/dev/null 2>&1) || true
if grep -qF '**Current Position:** C:\new\table' "$FLOW_DIR/.octo/STATE.md" &&
    grep -qF 'Phase 7 (ready): C:\new\table' "$FLOW_DIR/.octo/STATE.md"; then
    pass "update_state keeps backslashes in a position"
else
    fail "a backslash in a position was changed" "$(sed -n '1,8p' "$FLOW_DIR/.octo/STATE.md")"
fi

flow update_state --phase 10 --position "Ten" --status complete >/dev/null 2>&1 || true
flow update_state --phase 11 --position "Eleven" --status ready >/dev/null 2>&1 || true
if [[ "$(phase_status 1)" == "ready" && "$(phase_status 10)" == "complete" ]]; then
    pass "get_phase_status does not confuse phase 1 with phase 10"
else
    fail "phase numbers confused" "got 1=$(phase_status 1) 10=$(phase_status 10)"
fi

if ! flow get_phase_status >/dev/null 2>&1 && ! flow get_phase_status abc >/dev/null 2>&1; then
    pass "get_phase_status refuses a missing or non-numeric phase"
else
    fail "get_phase_status accepted a bad phase" "needs a positive integer"
fi

# A recorded completion stays readable in a large STATE.md (a sed | grep -q pipeline under
# pipefail answered "pending" here once the history passed about 113 KB, on SIGPIPE). The
# current phase is 1, so nothing but the phase 2 record can make the answer "complete".
BIG_DIR=$(mktemp -d)
(
    cd "$BIG_DIR"
    "$OCTO_STATE" init_project >/dev/null 2>&1
    {
        sed -n '1,/^## History/p' .octo/STATE.md | sed 's/^\*\*Current Phase:\*\* .*/**Current Phase:** 1/'
        echo ""
        echo "- [2026-01-01T00:00:00Z] Phase 2 (complete): Definition"
        i=0
        while [[ $i -lt 4000 ]]; do
            echo "- [2026-01-01T00:00:00Z] Phase 8 (in_progress): Padding entry number $i for a large history"
            i=$((i + 1))
        done
    } > .octo/STATE.new && mv .octo/STATE.new .octo/STATE.md
) || true
big_size=$(wc -c < "$BIG_DIR/.octo/STATE.md" | tr -d ' ')
big_status=$(cd "$BIG_DIR" && "$OCTO_STATE" get_phase_status 2 2>/dev/null || echo "exit-$?")
if [[ "$big_size" -gt 200000 && "$big_status" == "complete" ]]; then
    pass "get_phase_status reads a completion in a ${big_size}-byte STATE.md"
else
    fail "large STATE.md misread" "size=$big_size status=$big_status"
fi
rm -rf "$BIG_DIR"

# Missing lines and missing values fail with a message instead of exiting silently.
BROKEN_DIR=$(mktemp -d)
(cd "$BROKEN_DIR" && "$OCTO_STATE" init_project >/dev/null 2>&1 && sed -i.bak '/^\*\*Current Phase:\*\*/d' .octo/STATE.md) || true
broken_err=$(cd "$BROKEN_DIR" && "$OCTO_STATE" get_phase_status 1 2>&1 >/dev/null) && broken_rc=0 || broken_rc=$?
noval_err=$(flow update_state --history 2>&1 >/dev/null) && noval_rc=0 || noval_rc=$?
if [[ "$broken_rc" -ne 0 && "$broken_err" == *"Current Phase"* && "$noval_rc" -ne 0 && "$noval_err" == *"--history requires a value"* ]]; then
    pass "get_phase_status and update_state explain their failures"
else
    fail "silent failure" "get_phase_status rc=$broken_rc err='$broken_err'; update_state rc=$noval_rc err='$noval_err'"
fi
rm -rf "$BROKEN_DIR"

# The writer checks the header lines it rebuilds from before it writes anything: a missing
# or repeated line is an error and STATE.md is left exactly as it was.
writer_refuses() {
    local edit="$1" want="$2" dir err rc before
    dir=$(mktemp -d)
    (cd "$dir" && "$OCTO_STATE" init_project >/dev/null 2>&1 && eval "$edit") || true
    before=$(cksum < "$dir/.octo/STATE.md")
    err=$(cd "$dir" && "$OCTO_STATE" update_state --history "note" 2>&1 >/dev/null) && rc=0 || rc=$?
    [[ "$rc" -ne 0 && "$err" == *"$want"* && "$(cksum < "$dir/.octo/STATE.md")" == "$before" ]]
    rc=$?
    rm -rf "$dir"
    return "$rc"
}
if writer_refuses "sed -i.bak '/^\*\*Status:\*\*/d' .octo/STATE.md" "no '**Status:**' line" &&
    writer_refuses "sed -i.bak '/^\*\*Current Position:\*\*/d' .octo/STATE.md" "no '**Current Position:**' line" &&
    writer_refuses "sed -i.bak '/^\*\*Current Phase:\*\*/d' .octo/STATE.md" "no '**Current Phase:**' line" &&
    writer_refuses "printf '**Status:** complete\\n' >> .octo/STATE.md" "2 '**Status:**' lines"; then
    pass "update_state refuses a STATE.md with a missing or repeated header line and leaves it unchanged"
else
    fail "update_state wrote over a damaged STATE.md" "a missing or repeated Current Phase, Current Position or Status line must stop the write"
fi

# update_roadmap writes inside "## Definitions", in order, and keeps the rest of the file.
printf '# Synthesis\n' > "$FLOW_DIR/synthesis.md"
printf '\n## Definitions\n\n- earlier entry\n\n## Notes\n\nkeep me\n' >> "$FLOW_DIR/.octo/ROADMAP.md"
if flow update_roadmap --from-synthesis synthesis.md >/dev/null 2>&1 &&
    flow update_roadmap --from-synthesis synthesis.md >/dev/null 2>&1; then
    defs=$(sed -n '/^## Definitions/,/^## Notes/p' "$FLOW_DIR/.octo/ROADMAP.md")
    first_new=$(grep -n 'synthesis: synthesis.md' "$FLOW_DIR/.octo/ROADMAP.md" | head -1 | cut -d: -f1)
    earlier=$(grep -n -- '- earlier entry' "$FLOW_DIR/.octo/ROADMAP.md" | cut -d: -f1)
    notes=$(grep -n '^## Notes' "$FLOW_DIR/.octo/ROADMAP.md" | cut -d: -f1)
    if [[ "$(grep -c 'synthesis: synthesis.md' <<< "$defs")" == "2" &&
          "$(grep -c '^## Definitions' "$FLOW_DIR/.octo/ROADMAP.md")" == "1" &&
          "$earlier" -lt "$first_new" && "$first_new" -lt "$notes" &&
          "$(tail -1 "$FLOW_DIR/.octo/ROADMAP.md")" == "keep me" &&
          "$(tail -c 1 "$FLOW_DIR/.octo/ROADMAP.md" | od -An -c | tr -d ' ')" == '\n' ]] &&
        grep -q "^## Phase 1: Initial Setup" "$FLOW_DIR/.octo/ROADMAP.md" &&
        grep -q "Phase 11 synthesis: synthesis.md" <<< "$defs"; then
        pass "update_roadmap records each synthesis inside ## Definitions and keeps the roadmap"
    else
        fail "update_roadmap wrote outside ## Definitions or changed the file" "$(cat "$FLOW_DIR/.octo/ROADMAP.md")"
    fi
else
    fail "update_roadmap rejected a valid call" "flow-define calls update_roadmap"
fi

NOSEC_DIR=$(mktemp -d)
(
    cd "$NOSEC_DIR"
    "$OCTO_STATE" init_project >/dev/null 2>&1
    printf '# Synthesis\n' > synthesis.md
    rm .octo/STATE.md
    "$OCTO_STATE" update_roadmap --from-synthesis synthesis.md >/dev/null 2>&1 &&
        "$OCTO_STATE" update_roadmap --from-synthesis synthesis.md >/dev/null 2>&1 &&
        [[ "$(grep -c '^## Definitions' .octo/ROADMAP.md)" == "1" ]] &&
        [[ "$(sed -n '/^## Definitions/,$ p' .octo/ROADMAP.md | grep -c 'Phase ? synthesis: synthesis.md')" == "2" ]]
) && pass "update_roadmap adds ## Definitions once when missing and works without STATE.md" ||
    fail "update_roadmap failed without a Definitions section or STATE.md" "$(cat "$NOSEC_DIR/.octo/ROADMAP.md" 2>/dev/null)"
rm -rf "$NOSEC_DIR"

if ! flow update_roadmap --from-synthesis missing.md >/dev/null 2>&1; then
    pass "update_roadmap refuses a missing synthesis file"
else
    fail "update_roadmap accepted a missing file" "should refuse"
fi

printf '# Synthesis\n' > "$FLOW_DIR/syn\\new.md"
roadmap_lines=$(wc -l < "$FLOW_DIR/.octo/ROADMAP.md" | tr -d ' ')
if flow update_roadmap --from-synthesis 'syn\new.md' >/dev/null 2>&1 &&
    grep -qF 'synthesis: syn\new.md' "$FLOW_DIR/.octo/ROADMAP.md" &&
    [[ "$(wc -l < "$FLOW_DIR/.octo/ROADMAP.md" | tr -d ' ')" -eq $((roadmap_lines + 1)) ]]; then
    pass "update_roadmap keeps a backslash in the path, on one line"
else
    fail "update_roadmap changed or split a path with a backslash" "$(sed -n '/^## Definitions/,$ p' "$FLOW_DIR/.octo/ROADMAP.md")"
fi
rm -rf "$FLOW_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}Test Summary${NC}"
test_summary

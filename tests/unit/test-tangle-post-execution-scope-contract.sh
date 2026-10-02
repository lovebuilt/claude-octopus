#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
source "$PROJECT_ROOT_SRC/scripts/lib/testing.sh"
source "$PROJECT_ROOT_SRC/scripts/lib/workflows.sh"

test_suite "tangle post-execution write scope contract"

TMP_ROOT="$TEST_TMP_DIR"
TMP_REPO="$TMP_ROOT/repo"
TMP_RESULTS="$TMP_ROOT/results"
mkdir -p "$TMP_REPO/src" "$TMP_RESULTS"
git -C "$TMP_REPO" init -q
git -C "$TMP_REPO" config user.email test@example.com
git -C "$TMP_REPO" config user.name Test
printf '%s\n' 'export const baseline = true;' > "$TMP_REPO/src/existing.ts"
printf '%s\n' '{"name":"fixture"}' > "$TMP_REPO/package.json"
git -C "$TMP_REPO" add src/existing.ts package.json
git -C "$TMP_REPO" commit -qm baseline

PROJECT_ROOT="$TMP_REPO"
RESULTS_DIR="$TMP_RESULTS"
export PROJECT_ROOT RESULTS_DIR
BEFORE="$RESULTS_DIR/before.txt"
snapshot_tangle_worktree_paths > "$BEFORE" || true

SUBTASKS='1. [CODING] Build UI — Reads: src/existing.ts — Files: package.json — Creates: web/ — Task: build the new UI without modifying the read-only source module.'

mkdir -p "$TMP_REPO/web/js"
printf '%s\n' 'console.log("ok")' > "$TMP_REPO/web/js/app.js"
printf '%s\n' '{"name":"fixture","scripts":{"build":"true"}}' > "$TMP_REPO/package.json"
printf '%s\n' 'export const baseline = false;' > "$TMP_REPO/src/existing.ts"

test_case "Reads paths are excluded from authorized write scopes"
write_scopes=$(tangle_authorized_write_scopes "$SUBTASKS")
read_scopes=$(tangle_authorized_read_scopes "$SUBTASKS")
if [[ "$write_scopes" == *"package.json"* ]] && [[ "$write_scopes" == *"web"* ]] && [[ "$write_scopes" != *"src/existing.ts"* ]] && [[ "$read_scopes" == "src/existing.ts" ]]; then
    test_pass
else
    test_fail "unexpected scope extraction: writes=[$write_scopes] reads=[$read_scopes]"
fi

test_case "Task prose labels do not override declared scope clauses"
SUBTASKS_WITH_LABEL_PROSE='1. [CODING] Build UI — Files: package.json — Creates: web/ — Reads: src/existing.ts — Task: explain why Files: src/decoy.ts, Creates: tmp/decoy/, and Reads: secrets.txt are not scope declarations.'
actual_files=$(tangle_raw_scope_clause "$SUBTASKS_WITH_LABEL_PROSE" "Files")
actual_creates=$(tangle_raw_scope_clause "$SUBTASKS_WITH_LABEL_PROSE" "Creates")
actual_reads=$(tangle_raw_scope_clause "$SUBTASKS_WITH_LABEL_PROSE" "Reads")
if [[ "$actual_files" == "package.json" ]] && \
   [[ "$actual_creates" == "web/" ]] && \
   [[ "$actual_reads" == "src/existing.ts" ]]; then
    test_pass
else
    test_fail "Task prose overrode declared scope: Files=[$actual_files] Creates=[$actual_creates] Reads=[$actual_reads]"
fi

test_case "Task-only scope labels do not grant write authorization"
TASK_ONLY_LABEL='1. [CODING] Explain scope — Reads: src/existing.ts — Task: document why Files: src/decoy.ts must remain untouched.'
if [[ -z "$(tangle_raw_scope_clause "$TASK_ONLY_LABEL" "Files")" ]]; then
    test_pass
else
    test_fail "Task prose was parsed as a Files declaration"
fi

test_case "post-execution scope check flags writes to Reads paths"
violations=$(tangle_changed_paths_outside_write_scopes "$SUBTASKS" "$BEFORE")
if [[ "$violations" == "src/existing.ts" ]]; then
    test_pass
else
    test_fail "expected only src/existing.ts violation; got: $violations"
fi

test_case "nested Creates and exact Files paths remain authorized"
if [[ "$violations" != *"web/js/app.js"* ]] && [[ "$violations" != *"package.json"* ]]; then
    test_pass
else
    test_fail "authorized paths were incorrectly reported: $violations"
fi

# Isolate the wrapper from the existing quality gate; this suite specifically
# verifies the deterministic scope contract and whether the base gate is invoked.
VALIDATE_CALLS=0
validate_tangle_results() {
    local task_group="$1"
    VALIDATE_CALLS=$((VALIDATE_CALLS + 1))
    printf '%s\n' '# baseline validation' > "$RESULTS_DIR/tangle-validation-${task_group}.md"
    return 0
}
log() { :; }

test_case "validation wrapper fails and records out-of-scope changed paths"
status=0
tangle_validate_results_with_scope_contract fixture 'Build UI' "$BEFORE" "$SUBTASKS" || status=$?
report="$RESULTS_DIR/tangle-validation-fixture.md"
if [[ "$status" -ne 0 ]] && [[ "$VALIDATE_CALLS" -eq 0 ]] && grep -q 'deterministic write-scope pre-gate' "$report" && grep -q 'FAILED: Out-of-Scope Worktree Changes' "$report" && grep -q -- '- src/existing.ts' "$report" && grep -q 'Reads: never grants write permission' "$report"; then
    test_pass
else
    test_fail "scope violation did not fail before base validation/retries; calls=$VALIDATE_CALLS"
fi

test_case "adaptive mode records out-of-scope changes as evidence and still runs base validation"
VALIDATE_CALLS=0
export OCTOPUS_TANGLE_WRITE_SCOPE_MODE=adaptive
adaptive_status=0
tangle_validate_results_with_scope_contract adaptive 'Build UI' "$BEFORE" "$SUBTASKS" || adaptive_status=$?
unset OCTOPUS_TANGLE_WRITE_SCOPE_MODE
adaptive_report="$RESULTS_DIR/tangle-validation-adaptive.md"
if [[ "$adaptive_status" -eq 0 ]] && [[ "$VALIDATE_CALLS" -eq 1 ]] && grep -q 'Adaptive Write Scope Expansions' "$adaptive_report" && grep -q -- '- src/existing.ts' "$adaptive_report" && [[ -z "${TANGLE_SCOPE_CONTRACT_VIOLATIONS:-}" ]]; then
    test_pass
else
    test_fail "adaptive scope expansion remained fatal or lost evidence; status=$adaptive_status calls=$VALIDATE_CALLS"
fi
VALIDATE_CALLS=0

test_case "adaptive mode rejects undeclared credential changes before quality review"
printf '%s\n' 'fixture-only' > "$TMP_REPO/.env"
printf '%s\n' '{}' > "$TMP_REPO/auth.json"
export OCTOPUS_TANGLE_WRITE_SCOPE_MODE=adaptive
credential_status=0
tangle_validate_results_with_scope_contract adaptive-credentials 'Build UI' "$BEFORE" "$SUBTASKS" || credential_status=$?
unset OCTOPUS_TANGLE_WRITE_SCOPE_MODE
credential_report="$RESULTS_DIR/tangle-validation-adaptive-credentials.md"
if [[ "$credential_status" -ne 0 ]] && [[ "$VALIDATE_CALLS" -eq 0 ]] && \
   grep -q 'Unsafe adaptive scope path: .env.' "$credential_report" && \
   grep -q 'Unsafe adaptive scope path: auth.json.' "$credential_report"; then
    test_pass
else
    test_fail "adaptive credential changes reached ordinary quality validation"
fi
rm -f "$TMP_REPO/.env" "$TMP_REPO/auth.json"
VALIDATE_CALLS=0

test_case "adaptive mode keeps protected and symlink paths fatal"
mkdir -p "$TMP_REPO/.octo" "$TMP_REPO/outside"
ln -s "$TMP_REPO/outside" "$TMP_REPO/escape"
if tangle_adaptive_scope_path_is_safe "src/existing.ts" && \
   ! tangle_adaptive_scope_path_is_safe ".octo/forged.txt" && \
   ! tangle_adaptive_scope_path_is_safe ".OCTO/forged.txt" && \
   ! tangle_adaptive_scope_path_is_safe ".CLAUDE-OCTOPUS/runtime.txt" && \
   ! tangle_adaptive_scope_path_is_safe "escape/forged.txt"; then
    test_pass
else
    test_fail "adaptive scope safety accepted a protected or symlink path"
fi

test_case "adaptive validation separates safe evidence from unsafe fatal paths"
saved_changed_paths_function="$(declare -f tangle_changed_paths_outside_write_scopes)"
tangle_changed_paths_outside_write_scopes() {
    printf '%s\n' 'src/existing.ts' 'escape/forged.txt' '.octo/forged.txt'
}
VALIDATE_CALLS=0
export OCTOPUS_TANGLE_WRITE_SCOPE_MODE=adaptive
mixed_status=0
tangle_validate_results_with_scope_contract adaptive-mixed 'Build UI' "$BEFORE" "$SUBTASKS" || mixed_status=$?
unset OCTOPUS_TANGLE_WRITE_SCOPE_MODE
mixed_report="$RESULTS_DIR/tangle-validation-adaptive-mixed.md"
if [[ "$mixed_status" -ne 0 ]] && [[ "$VALIDATE_CALLS" -eq 0 ]] && \
   grep -q -- '- src/existing.ts' "$mixed_report" && \
   grep -q 'Unsafe adaptive scope path: escape/forged.txt.' "$mixed_report" && \
   grep -q 'Unsafe adaptive scope path: .octo/forged.txt.' "$mixed_report"; then
    test_pass
else
    test_fail "adaptive validation did not separate safe evidence from unsafe fatal paths"
fi
eval "$saved_changed_paths_function"
rm -f "$TMP_REPO/escape"

test_case "adaptive validation preserves multiple integrity failures"
saved_changed_paths_function="$(declare -f tangle_changed_paths_outside_write_scopes)"
tangle_changed_paths_outside_write_scopes() {
    return 1
}
VALIDATE_CALLS=0
export TANGLE_WORKTREE_BEFORE_STATE_DIGEST=stale-state-digest
integrity_state_snapshot="$TMP_RESULTS/before-state-integrity.txt"
snapshot_tangle_worktree_state > "$integrity_state_snapshot"
integrity_status=0
tangle_validate_results_with_scope_contract adaptive-integrity 'Build UI' "$BEFORE" "$SUBTASKS" "" "" "$integrity_state_snapshot" || integrity_status=$?
unset TANGLE_WORKTREE_BEFORE_STATE_DIGEST
integrity_report="$RESULTS_DIR/tangle-validation-adaptive-integrity.md"
if [[ "$integrity_status" -ne 0 ]] && [[ "$VALIDATE_CALLS" -eq 0 ]] && \
   grep -q 'The parent-owned worktree state snapshot changed' "$integrity_report" && \
   grep -q 'Unable to verify final worktree changes against immutable start HEAD' "$integrity_report"; then
    test_pass
else
    test_fail "adaptive validation overwrote an earlier integrity failure; status=$integrity_status calls=$VALIDATE_CALLS"
fi
eval "$saved_changed_paths_function"

test_case "adaptive mode keeps a changed parent-owned state snapshot fatal"
state_snapshot="$TMP_RESULTS/before-state.txt"
snapshot_tangle_worktree_state > "$state_snapshot"
export TANGLE_WORKTREE_BEFORE_STATE_DIGEST=stale-state-digest
state_status=0
tangle_validate_results_with_scope_contract adaptive-state 'Build UI' "$BEFORE" "$SUBTASKS" "" "$(tangle_scope_manifest_digest "$SUBTASKS")" "$state_snapshot" || state_status=$?
unset TANGLE_WORKTREE_BEFORE_STATE_DIGEST
state_report="$RESULTS_DIR/tangle-validation-adaptive-state.md"
if [[ "$state_status" -ne 0 ]] && [[ "$VALIDATE_CALLS" -eq 0 ]] && grep -q 'The parent-owned worktree state snapshot changed' "$state_report" && ! grep -q 'PASS: every changed path' "$state_report"; then
    test_pass
else
    test_fail "adaptive mode cleared a parent-owned state integrity failure; status=$state_status calls=$VALIDATE_CALLS"
fi

test_case "adaptive mode keeps a changed scope manifest fatal"
manifest_status=0
tangle_validate_results_with_scope_contract adaptive-manifest 'Build UI' "$BEFORE" "$SUBTASKS" "" stale-scope-manifest "$state_snapshot" || manifest_status=$?
manifest_report="$RESULTS_DIR/tangle-validation-adaptive-manifest.md"
if [[ "$manifest_status" -ne 0 ]] && [[ "$VALIDATE_CALLS" -eq 0 ]] && grep -q 'The parent-owned scope manifest changed' "$manifest_report" && ! grep -q 'PASS: every changed path' "$manifest_report"; then
    test_pass
else
    test_fail "adaptive mode cleared a scope manifest integrity failure; status=$manifest_status calls=$VALIDATE_CALLS"
fi
unset TANGLE_WORKTREE_BEFORE_STATE_DIGEST

test_case "scope violation is surfaced as one deterministic blocking finding"
findings="$TMP_ROOT/findings.json"
printf '%s\n' '{"findings":[]}' > "$findings"
tangle_ensure_scope_contract_finding "$findings" "$violations"
tangle_ensure_scope_contract_finding "$findings" "$violations"
count=$(jq '[.findings[] | select(.category == "scope-contract" and .severity == "normal" and .verdict == "confirmed")] | length' "$findings")
file=$(jq -r '.findings[] | select(.category == "scope-contract") | .file' "$findings")
if [[ "$count" -eq 1 ]] && [[ "$file" == "src/existing.ts" ]]; then
    test_pass
else
    test_fail "expected one deterministic scope-contract finding; count=$count file=$file"
fi

test_case "validation wrapper passes after illegal write is reverted"
git -C "$TMP_REPO" checkout -- src/existing.ts
status=0
tangle_validate_results_with_scope_contract repaired 'Build UI' "$BEFORE" "$SUBTASKS" || status=$?
report="$RESULTS_DIR/tangle-validation-repaired.md"
if [[ "$status" -eq 0 ]] && [[ "$VALIDATE_CALLS" -eq 1 ]] && grep -q '# baseline validation' "$report" && grep -q 'PASS: every changed path' "$report" && [[ -z "${TANGLE_SCOPE_CONTRACT_VIOLATIONS:-}" ]]; then
    test_pass
else
    test_fail "scope contract did not clear or base validation was not restored; calls=$VALIDATE_CALLS"
fi


test_case "multiple scope violations are separated by real newlines"
violations=$'src/existing.ts\nThe parent-owned scope manifest changed before final validation.'
report="$RESULTS_DIR/newline-report.md"
: > "$report"
tangle_append_write_scope_contract_report "$report" "package.json" "src/existing.ts" "$violations" ""
if grep -Fxq -- '- src/existing.ts' "$report" && \
   grep -Fxq -- '- The parent-owned scope manifest changed before final validation.' "$report" && \
   ! grep -Fq '\n' "$report"; then
    test_pass
else
    test_fail "scope violations were not rendered as distinct lines"
fi

test_case "write authorization keeps exact case and cannot widen to an ancestor"
saved_changed_paths_function="$(declare -f check_tangle_worktree_changes)"
check_tangle_worktree_changes() {
    printf '%s\n' src/Existing.ts src package.json/child web/js/app.js Web/other.js
}
exact_violations=$(tangle_changed_paths_outside_write_scopes \
    '1. [CODING] Edit source — Files: src/existing.ts, package.json — Creates: web/ — Task: edit declared files.' "$BEFORE")
eval "$saved_changed_paths_function"
# Compare exact paths independently of the host's collation order.
exact_violations=$(printf '%s\n' "$exact_violations" | LC_ALL=C sort)
if [[ "$exact_violations" == $'Web/other.js\npackage.json/child\nsrc\nsrc/Existing.ts' ]]; then
    test_pass
else
    test_fail "scope collision comparison widened exact authority: $exact_violations"
fi

test_case "workers cannot turn authorized files into directory write authority"
printf 'fixture\n' > "$TMP_REPO/CONFIG"
replacement_before="$RESULTS_DIR/replacement-before.txt"
replacement_state="$RESULTS_DIR/replacement-before-state.txt"
snapshot_tangle_worktree_paths > "$replacement_before"
snapshot_tangle_worktree_state > "$replacement_state"
replacement_head=$(git -C "$TMP_REPO" rev-parse HEAD)
replacement_subtasks='1. [CODING] Edit config — Files: package.json, CONFIG — Task: edit only the two declared files.'
cp "$TMP_REPO/package.json" "$RESULTS_DIR/package-before.json"
rm "$TMP_REPO/package.json" "$TMP_REPO/CONFIG"
mkdir "$TMP_REPO/package.json" "$TMP_REPO/CONFIG"
printf 'unauthorized\n' > "$TMP_REPO/package.json/child"
printf 'unauthorized\n' > "$TMP_REPO/CONFIG/child"
replacement_violations=$(tangle_changed_paths_outside_write_scopes "$replacement_subtasks" \
    "$replacement_before" "$replacement_head" "$replacement_state")
VALIDATE_CALLS=0
replacement_rc=0
tangle_validate_results_with_scope_contract replacement 'Edit config' \
    "$replacement_before" "$replacement_subtasks" "$replacement_head" \
    "$(tangle_scope_manifest_digest "$replacement_subtasks")" "$replacement_state" || replacement_rc=$?
if [[ "$replacement_violations" == $'CONFIG/child\npackage.json/child' \
        && "$replacement_rc" -ne 0 && "$VALIDATE_CALLS" -eq 0 ]]; then
    test_pass
else
    test_fail "worker filesystem edits widened authority: $replacement_violations status=$replacement_rc calls=$VALIDATE_CALLS"
fi
rm "$TMP_REPO/package.json/child" "$TMP_REPO/CONFIG/child"
rmdir "$TMP_REPO/package.json" "$TMP_REPO/CONFIG"
cp "$RESULTS_DIR/package-before.json" "$TMP_REPO/package.json"

test_summary

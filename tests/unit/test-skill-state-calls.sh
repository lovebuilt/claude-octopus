#!/usr/bin/env bash
# The flow skills record their phase in .octo/ through octo-state.sh. flow-define, flow-develop, flow-deliver and
# flow-discover called `update_state`, `get_phase_status` and `update_roadmap`, which the dispatcher did not have, so
# every state step printed "Unknown command" (and flow-discover, which checks the call, stopped). Nothing failed until
# a user ran the skill.
#
# These checks read the shell blocks of the skills and commands (both skill copies) and the octo-state.sh dispatcher,
# then run the skills' lifecycle blocks against the real octo-state.sh in a scratch project.
# Exits non-zero when any check fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/octo-skill-state.XXXXXX")"
trap 'rm -rf "$TEST_TMP_DIR"' EXIT

test_suite "skill calls into octo-state.sh"

OCTO_STATE="$PROJECT_ROOT/scripts/octo-state.sh"
SKILL_COPIES=("$PROJECT_ROOT/.claude/skills" "$PROJECT_ROOT/skills")

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

test_case "every octo-state.sh command a skill or command runs is one the dispatcher accepts"
accepted="$(sed -n '/case "\$command" in/,/esac/p' "$OCTO_STATE" |
    grep -oE '^[[:space:]]+[a-z_|-]+\)' | tr -d ' )' | tr '|' '\n' | sort -u)"
# Matches "octo-state.sh cmd", "octo-state.sh" cmd, 'octo-state.sh' cmd and ./scripts/octo-state.sh cmd.
called="$(grep -oE "octo-state\.sh[\"']?[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*" <<< "$CALLER_CODE" |
    sed -E "s/^octo-state\.sh[\"']?[[:space:]]+//" | sort -u || true)"
missing=""
for c in $called; do grep -qx -- "$c" <<< "$accepted" || missing="$missing $c"; done
if [[ -z "$accepted" ]]; then
    test_fail "could not read the octo-state.sh dispatcher"
elif ! grep -qx update_state <<< "$called"; then
    test_fail "found no octo-state.sh update_state call in the skills; the pattern no longer matches them"
elif [[ -n "$missing" ]]; then
    test_fail "skills call octo-state.sh commands that do not exist:$missing"
else
    test_pass
fi

# ── lifecycle blocks, run against the real octo-state.sh ─────────────────────

# First shell fence under a "## <heading>" section of a skill.
section_code() {
    local file="$1" heading="$2"
    awk -v heading="$heading" '
        $0 == heading { in_section = 1; next }
        in_section && /^## / { exit }
        in_section && /^```bash$/ { inside = 1; next }
        inside && /^```$/ { exit }
        inside { print }
    ' "$file"
}

fake_home="$TEST_TMP_DIR/home"
mkdir -p "$fake_home/.claude-octopus/plugin/scripts"
ln -s "$OCTO_STATE" "$fake_home/.claude-octopus/plugin/scripts/octo-state.sh"

new_project() {
    local dir="$1"
    mkdir -p "$dir"
    (
        cd "$dir"
        git init -q
        printf 'one\n' > a.txt && git add a.txt && git commit -qm one
        printf 'two\n' > b.txt && git add b.txt && git commit -qm two
    ) >/dev/null 2>&1
}

# run_block <project> <persistence> <code> [synthesis file]
# Runs one lifecycle block in a fresh shell; prints its output; returns its exit status. SYNTHESIS_FILE is set
# only when given: the discover and define blocks read the path their STEP 5 verification block set.
run_block() {
    local project="$1" persistence="$2" code="$3" synthesis="${4:-}"
    (
        cd "$project"
        unset CLAUDE_PLUGIN_DATA CLAUDE_OCTOPUS_WORKSPACE SYNTHESIS_FILE
        [[ -z "$synthesis" ]] || export SYNTHESIS_FILE="$synthesis"
        HOME="$fake_home" OCTOPUS_PROJECT_PERSISTENCE="$persistence" \
            GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid \
            GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid \
            bash -c "$code" 2>&1
    )
}
SYNTHESIS="$TEST_TMP_DIR/synthesis.md"
printf '# Synthesis\nfixture\n' > "$SYNTHESIS"

# skill|heading|reads SYNTHESIS_FILE
LIFECYCLE="flow-discover|## Pre-Discovery: Optional Project Persistence|
flow-discover|## Post-Discovery: State Update|yes
flow-define|## Pre-Definition: State Check|
flow-define|## Post-Definition: State Update|yes
flow-develop|## Pre-Development: State Check|
flow-develop|## Post-Development: Checkpoint|
flow-deliver|## Pre-Delivery: State Check|
flow-deliver|## Post-Delivery: Route to Ship|"

for copy in "${SKILL_COPIES[@]}"; do
    label="${copy#"$PROJECT_ROOT"/}"
    status_of() { (cd "$project" && "$OCTO_STATE" get_phase_status "$1" 2>/dev/null); }

    test_case "$label: with OCTOPUS_PROJECT_PERSISTENCE=true the four phases record their state"
    project="$TEST_TMP_DIR/persist-${label//\//-}"
    new_project "$project"
    problem=""
    while IFS='|' read -r skill heading reads; do
        code="$(section_code "$copy/$skill/SKILL.md" "$heading")"
        if [[ -z "$code" ]]; then problem="no shell block under '$heading' in $skill"; break; fi
        synthesis=""
        [[ -z "$reads" ]] || synthesis="$SYNTHESIS"
        if ! out="$(run_block "$project" true "$code" "$synthesis")"; then
            problem="$skill '$heading' failed: $out"; break
        fi
        if grep -q "not marked complete" <<< "$out"; then
            problem="$skill '$heading' warned although the previous phase completed: $out"; break
        fi
    done <<< "$LIFECYCLE"
    state="$project/.octo/STATE.md"
    if [[ -z "$problem" ]]; then
        if [[ "$(status_of 1)" != complete || "$(status_of 2)" != complete || "$(status_of 3)" != complete ||
              "$(status_of 4)" != complete ]]; then
            problem="phase statuses 1-4: $(status_of 1) $(status_of 2) $(status_of 3) $(status_of 4)"
        elif ! grep -q '^- \[[^]]*\] Phase 3 (complete): Development: Files modified: b.txt$' "$state"; then
            problem="the files-modified note is missing or split: $(sed -n '/^## History/,$p' "$state")"
        elif ! sed -n '/^## Definitions/,$p' "$project/.octo/ROADMAP.md" | grep -qF "Phase 2 synthesis: $SYNTHESIS"; then
            problem="the consensus document is not recorded under ## Definitions"
        fi
    fi
    if [[ -z "$problem" ]]; then test_pass; else test_fail "$problem"; fi

    test_case "$label: define's roadmap step warns, and does not fail, when SYNTHESIS_FILE names no file"
    project="$TEST_TMP_DIR/nosyn-${label//\//-}"
    new_project "$project"
    (cd "$project" && "$OCTO_STATE" init_project >/dev/null 2>&1 &&
        "$OCTO_STATE" update_state --phase 2 --position Definition --status in_progress >/dev/null 2>&1) || true
    code="$(section_code "$copy/flow-define/SKILL.md" "## Post-Definition: State Update")"
    if out="$(run_block "$project" true "$code")" && grep -q "ROADMAP.md was not updated" <<< "$out" &&
        [[ "$(status_of 2)" == complete ]] && ! grep -q "synthesis:" "$project/.octo/ROADMAP.md"; then
        test_pass
    else
        test_fail "expected a warning, phase 2 complete and no roadmap entry: $out"
    fi

    test_case "$label: the previous-phase check accepts complete_with_gaps and warns on a reopened phase"
    project="$TEST_TMP_DIR/gaps-${label//\//-}"
    new_project "$project"
    (cd "$project" && "$OCTO_STATE" init_project >/dev/null 2>&1 &&
        "$OCTO_STATE" update_state --phase 2 --position Definition --status complete_with_gaps >/dev/null 2>&1) || true
    code="$(section_code "$copy/flow-develop/SKILL.md" "## Pre-Development: State Check")"
    gaps_out="$(run_block "$project" true "$code")" || gaps_out="failed: $gaps_out"
    (cd "$project" && "$OCTO_STATE" update_state --phase 2 --status blocked >/dev/null 2>&1) || true
    reopened_out="$(run_block "$project" true "$code")" || reopened_out="failed: $reopened_out"
    if ! grep -qE "not marked complete|failed:" <<< "$gaps_out" &&
        grep -q "Define phase not marked complete" <<< "$reopened_out" && [[ "$reopened_out" != failed:* ]]; then
        test_pass
    else
        test_fail "complete_with_gaps: $gaps_out | reopened: $reopened_out"
    fi

    test_case "$label: without the opt-in the lifecycle blocks write no project state"
    project="$TEST_TMP_DIR/default-${label//\//-}"
    new_project "$project"
    problem=""
    while IFS='|' read -r skill heading reads; do
        code="$(section_code "$copy/$skill/SKILL.md" "$heading")"
        synthesis=""
        [[ -z "$reads" ]] || synthesis="$SYNTHESIS"
        if ! out="$(run_block "$project" "" "$code" "$synthesis")"; then
            problem="$skill '$heading' failed with persistence off: $out"; break
        fi
    done <<< "$LIFECYCLE"
    if [[ -z "$problem" && -e "$project/.octo" ]]; then problem="a .octo/ directory was created"; fi
    if [[ -z "$problem" ]]; then test_pass; else test_fail "$problem"; fi

    test_case "$label: a failed state write stops the block"
    project="$TEST_TMP_DIR/broken-${label//\//-}"
    new_project "$project"
    (cd "$project" && "$OCTO_STATE" init_project >/dev/null 2>&1 && sed -i.bak '/^\*\*Status:\*\*/d' .octo/STATE.md) || true
    code="$(section_code "$copy/flow-deliver/SKILL.md" "## Pre-Delivery: State Check")"
    if ! out="$(run_block "$project" true "$code")" && grep -q "Deliver incomplete" <<< "$out"; then
        test_pass
    else
        test_fail "the block went on after update_state failed: $out"
    fi
done

test_summary

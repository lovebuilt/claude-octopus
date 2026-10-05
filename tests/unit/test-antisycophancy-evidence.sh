#!/usr/bin/env bash
# The Tangle anti-sycophancy challenge may not open files. It was handed `head -c 3000` of the
# raw result files, which on a real run is the result header and the prompt preamble, so every
# high-pass run came back CHALLENGED ("the result contains no implementation, only the prompt").
# These cases run validate_tangle_results end to end with a stubbed reviewer and inspect the
# challenge prompt it receives.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "anti-sycophancy challenge evidence"

# Run the gate in a UTF-8 locale, as a user's shell would, so a byte budget counted in
# characters shows up as an overrun.
UTF8_LOCALE=""
for candidate in en_US.UTF-8 C.UTF-8 C.utf8; do
    if locale -a 2>/dev/null | grep -ix "$candidate" >/dev/null; then
        UTF8_LOCALE="$candidate"
        break
    fi
done
if [[ -n "$UTF8_LOCALE" ]]; then export LC_ALL="$UTF8_LOCALE"; fi

GREEN="" RED="" YELLOW="" DIM="" NC="" _BOX_TOP="" _BOX_BOT=""
QUALITY_THRESHOLD=70
MAX_QUALITY_RETRIES=0
LOOP_UNTIL_APPROVED=false
OCTOPUS_ANTISYCOPHANCY=true

source "$PROJECT_ROOT/scripts/lib/workflows.sh"
source "$PROJECT_ROOT/scripts/lib/testing.sh"

log() { :; }
record_task_metric() { :; }
write_structured_decision() { :; }
evaluate_quality_branch() { echo "proceed"; }
run_file_validation() { :; }
get_gate_threshold() { echo 70; }
run_agent_sync() { printf '%s' "$2" > "$PROMPT_CAPTURE"; echo "Concern: stub reviewer"; }

NONCE=0123456789abcdef0123456789abcdef
write_framed_result() {
    local file="$1" output="$2"
    printf '%s\n' '# Agent: codex' '# Task ID: tangle-chal-0' '# Role: implementer' > "$file"
    write_agent_result_prompt "$file" $'PROMPT-PREAMBLE-MARKER: you are an implementer.\nDo the task.'
    printf '%s\n' '# Started: now' "<!-- BEGIN-UNTRUSTED:provider=codex:nonce=$NONCE -->" '## Output' '```' >> "$file"
    printf '%s\n' "$output" >> "$file"
    printf '%s\n' '```' "<!-- END-UNTRUSTED:provider=codex:nonce=$NONCE -->" '' '## Warnings/Errors' \
        "<!-- BEGIN-UNTRUSTED:provider=codex:stream=stderr:nonce=$NONCE -->" '```' 'STDERR-NOISE-MARKER' '```' \
        "<!-- END-UNTRUSTED:provider=codex:stream=stderr:nonce=$NONCE -->" '' '## Runtime Identity' \
        'RUNTIME-IDENTITY-MARKER' '' '## Status: SUCCESS' >> "$file"
}

new_repo() {
    git -C "$1" init -q
    git -C "$1" config user.email test@example.com
    git -C "$1" config user.name "Octopus Test"
}

# Runs the gate in $1 with results in $2 and prints the captured challenge prompt.
run_gate() {
    local repo="$1" results="$2" baseline="$3"
    PROMPT_CAPTURE="$results/challenge-prompt.txt"
    rm -f "$PROMPT_CAPTURE"
    (
        cd "$repo"
        PROJECT_ROOT="$repo" RESULTS_DIR="$results" \
            validate_tangle_results "chal" "Update the docs" "$results/before.txt" "$baseline" >/dev/null 2>&1 || true
    )
    cat "$PROMPT_CAPTURE" 2>/dev/null || true
}

section() {  # lines of $1 after a line starting with $2, up to a line starting with $3
    awk -v from="$2" -v to="$3" 'index($0, to) == 1 { on = 0 } on { print } index($0, from) == 1 { on = 1 }' <<< "$1"
}

# ── Scenario 1: a mixed change set ───────────────────────────────────────────
REPO="$TEST_TMP_DIR/challenge-repo"
RESULTS="$TEST_TMP_DIR/challenge-results"
mkdir -p "$REPO/src" "$REPO/assets" "$REPO/docs" "$RESULTS"
new_repo "$REPO"
for i in $(seq 1 200); do printf 'line %03d of a long file, padded to sit well past any head\n' "$i"; done > "$REPO/src/long.txt"
printf 'keep one\nDELETED-LINE-MARKER\nkeep two\n' > "$REPO/src/remove.txt"
printf 'WHOLE-FILE-DELETED\n' > "$REPO/src/gone.txt"
printf 'BIN\000OLD\n' > "$REPO/assets/blob.bin"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
baseline=$(git -C "$REPO" rev-parse HEAD)
(cd "$REPO" && PROJECT_ROOT="$REPO" snapshot_tangle_worktree_paths > "$RESULTS/before.txt" || true)

sed 's/^line 150 .*/DEEP-EDIT-MARKER/' "$REPO/src/long.txt" > "$REPO/src/long.tmp" && mv "$REPO/src/long.tmp" "$REPO/src/long.txt"
git -C "$REPO" commit -qam "worker commit"
printf 'keep one\nkeep two\n' > "$REPO/src/remove.txt"
rm "$REPO/src/gone.txt"
printf 'API_TOKEN=CREDENTIAL-VALUE-MARKER\n' > "$REPO/.env"  # untracked, as a worker would leave it
printf 'BIN\000BINARY-CONTENT-MARKER\n' > "$REPO/assets/blob.bin"
printf '# New page\nNEW-FILE-MARKER\n' > "$REPO/docs/new.md"
printf 'OUTSIDE-SECRET-MARKER\n' > "$TEST_TMP_DIR/outside-secret.txt"
ln -s "$TEST_TMP_DIR/outside-secret.txt" "$REPO/docs/escape.md"
write_framed_result "$RESULTS/codex-tangle-chal-0.md" "PROVIDER-REPORT-MARKER: updated the docs"

prompt=$(run_gate "$REPO" "$RESULTS" "$baseline")
diff_part=$(section "$prompt" "Diff against the start" "Provider output")

test_case "a deep edit committed by the worker reaches the reviewer as a hunk"
if grep -qx '+DEEP-EDIT-MARKER' <<< "$diff_part"; then test_pass; else test_fail "deep edit hunk missing"; fi

test_case "deleted lines and deleted files reach the reviewer"
if grep -qx -- '-DELETED-LINE-MARKER' <<< "$diff_part" && grep -qx -- '-WHOLE-FILE-DELETED' <<< "$diff_part"; then
    test_pass; else test_fail "deletions missing"; fi

test_case "a new untracked file is shown as an addition"
if grep -qx '+NEW-FILE-MARKER' <<< "$diff_part"; then test_pass; else test_fail "new file missing"; fi

test_case "a credential file is listed but its content is not read"
if grep -qx '.env' <<< "$prompt" && grep -q 'DEEP-EDIT-MARKER' <<< "$prompt" \
    && ! grep -q 'CREDENTIAL-VALUE-MARKER' <<< "$prompt"; then test_pass; else test_fail "credential file not listed, or its content reached the prompt"; fi

test_case "a binary file is listed but its content is not read"
if grep -qx 'assets/blob.bin' <<< "$prompt" && grep -q 'DEEP-EDIT-MARKER' <<< "$prompt" \
    && ! grep -q 'BINARY-CONTENT-MARKER' <<< "$prompt"; then test_pass; else test_fail "binary file not listed, or its content reached the prompt"; fi

test_case "a symlink that leaves the repository is listed but not read"
if grep -qx 'docs/escape.md' <<< "$prompt" && grep -q 'DEEP-EDIT-MARKER' <<< "$prompt" \
    && ! grep -q 'OUTSIDE-SECRET-MARKER' <<< "$prompt" && ! grep -q 'outside-secret.txt' <<< "$prompt"; then
    test_pass; else test_fail "symlink not listed, or its target was read"; fi

test_case "provider output comes from the framed Output section only"
if grep -q 'PROVIDER-REPORT-MARKER' <<< "$prompt" && ! grep -q 'STDERR-NOISE-MARKER' <<< "$prompt" \
    && ! grep -q 'RUNTIME-IDENTITY-MARKER' <<< "$prompt" && ! grep -q 'PROMPT-PREAMBLE-MARKER' <<< "$prompt"; then
    test_pass; else test_fail "provider output missing or mixed with stderr, identity or prompt"; fi

test_case "the evidence is wrapped as untrusted content"
wrapped=$(awk '/^<!-- BEGIN-UNTRUSTED:tangle-challenge-evidence:/ { on = 1 } on { print } /^<!-- END-UNTRUSTED:tangle-challenge-evidence:/ { on = 0 }' <<< "$prompt")
if grep -q 'DEEP-EDIT-MARKER' <<< "$wrapped" && grep -q 'PROVIDER-REPORT-MARKER' <<< "$wrapped" \
    && grep -q '^<!-- END-UNTRUSTED:tangle-challenge-evidence:' <<< "$wrapped"; then
    test_pass; else test_fail "evidence not inside the untrusted boundary"; fi

# ── Scenario 2: budgets, multibyte text, non-UTF-8 text, many paths ─────────
REPO2="$TEST_TMP_DIR/challenge-repo-2"
RESULTS2="$TEST_TMP_DIR/challenge-results-2"
mkdir -p "$REPO2" "$RESULTS2"
new_repo "$REPO2"
printf 'base\n' > "$REPO2/README.md"
git -C "$REPO2" add -A
git -C "$REPO2" commit -qm base
baseline2=$(git -C "$REPO2" rev-parse HEAD)
(cd "$REPO2" && PROJECT_ROOT="$REPO2" snapshot_tangle_worktree_paths > "$RESULTS2/before.txt" || true)
cjk_line='海洋动物单词搜索海洋动物单词搜索海洋动物单词搜索海洋动物|END'
for f in a1 a2 a3 a4 a5 a6; do
    for i in $(seq 1 300); do printf '%s\n' "$cjk_line"; done > "$REPO2/$f-cjk.md"
done
printf 'LATIN1-MARKER caf\351\n' > "$REPO2/0-latin1.txt"
for i in $(seq 10 69); do printf 'small %s\n' "$i" > "$REPO2/z-$i.txt"; done
long_output=$(for i in $(seq 1 400); do printf '%s\n' "$cjk_line"; done; printf 'PROVIDER-TAIL-MARKER\n')
write_framed_result "$RESULTS2/codex-tangle-chal-0.md" "$long_output"

prompt2=$(run_gate "$REPO2" "$RESULTS2" "$baseline2")
diff2=$(section "$prompt2" "Diff against the start" "Provider output" | grep -v "^(no diff shown for" | sed "/^$/d" || true)
output2=$(section "$prompt2" "Provider output" "<!-- END-UNTRUSTED:tangle-challenge-evidence")
listed2=$(section "$prompt2" "Changed files" "Diff against the start")
bytes() { printf '%s\n' "$1" | LC_ALL=C wc -c | tr -d ' '; }

test_case "diff and provider budgets hold in bytes for multibyte text"
diff_bytes=$(bytes "$diff2"); output_bytes=$(bytes "$output2")
if grep -q '海洋' <<< "$diff2" && [[ "$diff_bytes" -le 8001 ]] \
    && grep -q 'PROVIDER-TAIL-MARKER' <<< "$output2" && [[ "$output_bytes" -le 3001 ]]; then
    test_pass; else test_fail "diff ${diff_bytes} bytes (max 8000), provider ${output_bytes} bytes (max 3000)"; fi

test_case "one large file does not take the whole diff budget"
shown_files=$(grep -c '^diff --git' <<< "$diff2" || true)
if [[ "$shown_files" -ge 3 ]]; then test_pass; else test_fail "only ${shown_files} files shown"; fi

test_case "cuts fall on whole lines"
if grep -q '海洋' <<< "$prompt2" && ! grep '海' <<< "$prompt2" | grep -qv '|END$'; then
    test_pass; else test_fail "a multibyte line was cut mid-line"; fi

test_case "the challenge prompt is valid UTF-8, including a Latin-1 source file"
if grep -q 'LATIN1-MARKER' <<< "$prompt2" \
    && python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' < "$RESULTS2/challenge-prompt.txt" 2>/dev/null; then
    test_pass; else test_fail "prompt is not valid UTF-8 or the Latin-1 file was not shown"; fi

test_case "the changed-path list is capped"
if [[ "$(grep -c . <<< "$listed2")" -le 51 ]] && grep -qx '... and 17 more' <<< "$listed2"; then
    test_pass; else test_fail "path list not capped: $(grep -c . <<< "$listed2") lines"; fi

test_summary

#!/usr/bin/env bash
# Additive --supersede-key runner support: a keyed run supersedes prior runs
# carrying the SAME key in the pool and records a `latest-<slug>` pointer, while
# runs with no key or a different key are left untouched. The caller (sail-cruisey
# #2952) supplies the per-gate key; absent a key this is a complete no-op, so
# CP1/CP2 interleaved in one session pool never cross-supersede.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"

# A stray default-providers policy in the caller env makes council_run bail during
# arg validation; neutralise it (and any inherited key) for a deterministic run.
unset OCTOPUS_COUNCIL_DEFAULT_PROVIDERS OCTOPUS_COUNCIL_SUPERSEDE_KEY 2>/dev/null || true

test_suite "Council supersede-key"

_run_keyed() {
    # _run_keyed <pool> <key-or-empty>
    local pool="$1" key="$2" args=(--goal review --depth quick --output-dir "$pool")
    [[ -n "$key" ]] && args+=(--supersede-key "$key")
    OCTOPUS_COUNCIL_FIXTURE=full-success council_run "${args[@]}" "task" >/dev/null 2>&1 || true
}

_latest_run() { ls -1dt "$1"/2*/ 2>/dev/null | head -1; }

test_supersede_key_slug_is_fs_safe() {
    test_case "council_supersede_key_slug sanitizes unsafe characters"
    local slug
    slug="$(council_supersede_key_slug '2921:CP2 /weird')"
    if [[ "$slug" =~ ^[A-Za-z0-9._-]+$ ]]; then test_pass; else test_fail "unsafe slug: $slug"; fi
}

test_flag_and_env_resolution() {
    test_case "--supersede-key flag and OCTOPUS_COUNCIL_SUPERSEDE_KEY env both set the key"
    local via_flag via_env
    ( council_parse_args --supersede-key "k1" "task" >/dev/null 2>&1; printf '%s' "$COUNCIL_SUPERSEDE_KEY" ) > "$TEST_TMP_DIR/flag"
    via_flag="$(cat "$TEST_TMP_DIR/flag")"
    ( OCTOPUS_COUNCIL_SUPERSEDE_KEY="k2" council_reset_defaults; printf '%s' "$COUNCIL_SUPERSEDE_KEY" ) > "$TEST_TMP_DIR/env"
    via_env="$(cat "$TEST_TMP_DIR/env")"
    if [[ "$via_flag" == "k1" && "$via_env" == "k2" ]]; then test_pass; else test_fail "flag=$via_flag env=$via_env (want k1/k2)"; fi
}

test_same_key_supersedes_prior() {
    test_case "a keyed run supersedes the prior same-key run and updates the latest pointer"
    local pool r1 r2 slug
    pool="$(mktemp -d "$TEST_TMP_DIR/pool-same.XXXXXX")"
    _run_keyed "$pool" "2921:CP2"; sleep 1
    r1="$(_latest_run "$pool")"; r1="${r1%/}"
    _run_keyed "$pool" "2921:CP2"; sleep 1
    r2="$(_latest_run "$pool")"; r2="${r2%/}"
    slug="$(council_supersede_key_slug "2921:CP2")"
    if [[ "$r1" != "$r2" ]] \
       && [[ "$(jq -r '.superseded' "$r1/run-status.json")" == "true" ]] \
       && [[ "$(jq -r '.superseded_by' "$r1/run-status.json")" == "$(basename "$r2")" ]] \
       && [[ "$(jq -r '.superseded' "$r2/run-status.json")" == "false" ]] \
       && [[ "$(cat "$pool/latest-$slug" 2>/dev/null)" == "$(basename "$r2")" ]]; then
        COUNCIL_RUN_DIR="$r1"
        COUNCIL_RUN_ID="$(basename "$r1")"
        council_write_run_status finished completed
        if [[ "$(jq -r '.superseded' "$r1/run-status.json")" == "true" ]] &&
           [[ "$(jq -r '.superseded_by' "$r1/run-status.json")" == "$(basename "$r2")" ]]; then
            test_pass
        else
            test_fail "older run completion discarded the superseded mark"
        fi
    else
        test_fail "r1 superseded=$(jq -r '.superseded' "$r1/run-status.json") by=$(jq -r '.superseded_by' "$r1/run-status.json"); pointer=$(cat "$pool/latest-$slug" 2>/dev/null)"
    fi
}

test_different_keys_do_not_cross_supersede() {
    test_case "different keys (CP1 vs CP2) in one pool never supersede each other"
    local pool cp2 cp1
    pool="$(mktemp -d "$TEST_TMP_DIR/pool-mixed.XXXXXX")"
    _run_keyed "$pool" "2921:CP2"; sleep 1
    _run_keyed "$pool" "2921:CP1"; sleep 1
    # Find each round by its key.
    cp2=""; cp1=""
    local d k
    for d in "$pool"/2*/; do
        d="${d%/}"; k="$(jq -r '.supersede_key // empty' "$d/run-status.json" 2>/dev/null)"
        [[ "$k" == "2921:CP2" ]] && cp2="$d"
        [[ "$k" == "2921:CP1" ]] && cp1="$d"
    done
    if [[ -n "$cp2" && -n "$cp1" ]] \
       && [[ "$(jq -r '.superseded' "$cp2/run-status.json")" == "false" ]] \
       && [[ "$(jq -r '.superseded' "$cp1/run-status.json")" == "false" ]] \
       && [[ -f "$pool/latest-$(council_supersede_key_slug "2921:CP2")" ]] \
       && [[ -f "$pool/latest-$(council_supersede_key_slug "2921:CP1")" ]]; then
        test_pass
    else
        test_fail "cp2 superseded=$(jq -r '.superseded' "$cp2/run-status.json" 2>/dev/null) cp1 superseded=$(jq -r '.superseded' "$cp1/run-status.json" 2>/dev/null)"
    fi
}

test_unkeyed_run_is_a_noop() {
    test_case "an unkeyed run writes no latest pointer and no superseded flag (behavior unchanged)"
    local pool run
    pool="$(mktemp -d "$TEST_TMP_DIR/pool-none.XXXXXX")"
    _run_keyed "$pool" ""; sleep 1
    _run_keyed "$pool" ""
    run="$(_latest_run "$pool")"; run="${run%/}"
    if ! ls "$pool"/latest-* >/dev/null 2>&1 \
       && [[ "$(jq -r '.superseded' "$run/run-status.json")" == "false" ]] \
       && [[ "$(jq -r '.supersede_key' "$run/run-status.json")" == "null" ]]; then
        test_pass
    else
        test_fail "unkeyed run left a pointer or superseded flag"
    fi
}

test_summary_carries_supersede_key() {
    test_case "summary.json records the supersede_key"
    local pool run
    pool="$(mktemp -d "$TEST_TMP_DIR/pool-sum.XXXXXX")"
    _run_keyed "$pool" "2921:CP2"
    run="$(_latest_run "$pool")"; run="${run%/}"
    if [[ "$(jq -r '.supersede_key' "$run/summary.json")" == "2921:CP2" ]]; then
        test_pass
    else
        test_fail "summary supersede_key=$(jq -r '.supersede_key' "$run/summary.json" 2>/dev/null)"
    fi
}

test_delayed_older_scanner_keeps_newest() {
    test_case "a delayed older supersession scan cannot supersede the newer run"
    local pool old newer slug
    pool="$(mktemp -d "$TEST_TMP_DIR/pool-delayed.XXXXXX")"
    old="$pool/20261001-100000-000001"; newer="$pool/20261001-100000-000002"
    mkdir -p "$old" "$newer"
    COUNCIL_SUPERSEDE_KEY="gate"
    COUNCIL_RUN_DIR="$old"; COUNCIL_RUN_ID="${old##*/}"
    council_write_run_status running
    COUNCIL_RUN_DIR="$newer"; COUNCIL_RUN_ID="${newer##*/}"
    council_write_run_status running
    council_mark_prior_runs_superseded "$pool" "$newer" gate
    COUNCIL_RUN_DIR="$old"; COUNCIL_RUN_ID="${old##*/}"
    council_mark_prior_runs_superseded "$pool" "$old" gate
    slug="$(council_supersede_key_slug gate)"
    if jq -e --arg id "${newer##*/}" '.superseded == true and .superseded_by == $id' "$old/run-status.json" >/dev/null \
       && jq -e '.superseded == false' "$newer/run-status.json" >/dev/null \
       && [[ "$(cat "$pool/latest-$slug")" == "${newer##*/}" ]]; then
        test_pass
    else
        test_fail "delayed older scan superseded the newest run or regressed its pointer"
    fi
}

test_creation_order_does_not_follow_pid_sort() {
    test_case "same-second runs use creation order rather than PID lexical order"
    local pool first second slug
    pool="$(mktemp -d "$TEST_TMP_DIR/pool-order.XXXXXX")"
    first="$pool/20261001-100000-fffffe"; second="$pool/20261001-100000-000001"
    mkdir -p "$first" "$second"
    COUNCIL_SUPERSEDE_KEY="gate"
    COUNCIL_RUN_DIR="$first"; COUNCIL_RUN_ID="${first##*/}"
    council_write_run_status running
    COUNCIL_RUN_DIR="$second"; COUNCIL_RUN_ID="${second##*/}"
    council_write_run_status running
    council_mark_prior_runs_superseded "$pool" "$second" gate
    COUNCIL_RUN_DIR="$first"; COUNCIL_RUN_ID="${first##*/}"
    council_mark_prior_runs_superseded "$pool" "$first" gate
    slug="$(council_supersede_key_slug gate)"
    if jq -e '.superseded == false and .created_order > 0' "$second/run-status.json" >/dev/null \
       && [[ "$(cat "$pool/latest-$slug")" == "${second##*/}" ]] \
       && [[ "$(jq -r '.created_order' "$first/run-status.json")" -lt "$(jq -r '.created_order' "$second/run-status.json")" ]]; then
        test_pass
    else
        test_fail "newest same-second run was not selected by its creation order"
    fi
}

test_completion_waits_for_supersession_lock() {
    test_case "an older completion waits for the pool lock and preserves supersession"
    local pool older
    pool="$(mktemp -d "$TEST_TMP_DIR/pool-completion.XXXXXX")"
    older="$pool/20261001-100000-000001"
    mkdir -p "$older"
    COUNCIL_SUPERSEDE_KEY="gate"
    COUNCIL_RUN_DIR="$older"; COUNCIL_RUN_ID="${older##*/}"
    council_write_run_status running
    if python3 - "$PROJECT_ROOT" "$pool" "$older" <<'PYTEST'
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time

root, pool, older = map(Path, sys.argv[1:])
writer = None
try:
    with (pool / ".run-state.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        writer = subprocess.Popen([
            "/bin/bash", "-c",
            'source "$1/scripts/lib/council.sh"; COUNCIL_RUN_DIR="$2"; '
            'COUNCIL_RUN_ID="${2##*/}"; COUNCIL_SUPERSEDE_KEY=gate; '
            'touch "$2/writer-ready"; while [[ ! -f "$2/writer-go" ]]; do sleep 0.01; done; '
            'council_write_run_status finished completed',
            "test", str(root), str(older),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ready_deadline = time.monotonic() + 10
        while not (older / "writer-ready").exists():
            assert writer.poll() is None, "completion writer failed before readiness"
            assert time.monotonic() < ready_deadline, "completion writer did not become ready"
            time.sleep(0.01)
        (older / "writer-go").touch()
        time.sleep(0.5)
        assert writer.poll() is None, "completion ignored the pool supersession lock"
        status = older / "run-status.json"
        record = json.loads(status.read_text())
        record.update(superseded=True, superseded_by="newer-run")
        replacement = status.with_suffix(".locked-test")
        replacement.write_text(json.dumps(record))
        os.replace(replacement, status)
    assert writer.wait(timeout=10) == 0
    final = json.loads(status.read_text())
    assert final["state"] == "finished" and final["status"] == "completed"
    assert final["superseded"] is True and final["superseded_by"] == "newer-run"
finally:
    if writer is not None and writer.poll() is None:
        writer.terminate()
        writer.wait(timeout=10)
PYTEST
    then test_pass; else test_fail "concurrent completion did not preserve the locked supersession update"; fi
}

test_failed_initial_beacon_is_not_published() {
    test_case "a failed initial beacon write does not publish an empty run directory"
    local pool rc=0
    pool="$(mktemp -d "$TEST_TMP_DIR/pool-beacon-failure.XXXXXX")"
    (
        python3() { return 1; }
        COUNCIL_OUTPUT_DIR="$pool" COUNCIL_SUPERSEDE_KEY="" council_create_run_dir
    ) >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]] && [[ -z "$(find "$pool" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]]; then
        test_pass
    else
        test_fail "failed beacon persistence still published a visible run directory"
    fi
}

test_missing_python_fails_before_creating_a_run() {
    test_case "missing Python reports a prerequisite before parsing or run creation"
    local pool diagnostic rc=0
    pool="$TEST_TMP_DIR/missing-python-pool"
    diagnostic="$TEST_TMP_DIR/missing-python.err"
    (
        council_reset_defaults
        command() {
            if [[ "${1:-}" == -v && "${2:-}" == python3 ]]; then return 1; fi
            builtin command "$@"
        }
        council_parse_args() { touch "$TEST_TMP_DIR/unexpected-parse"; }
        COUNCIL_OUTPUT_DIR="$pool" council_run "task"
    ) > /dev/null 2> "$diagnostic" || rc=$?
    if [[ "$rc" == 2 && ! -e "$pool" && ! -e "$TEST_TMP_DIR/unexpected-parse" ]] \
       && grep -q 'Python 3 is required for atomic run-state updates' "$diagnostic"; then
        test_pass
    else
        test_fail "missing Python failed without an early prerequisite diagnostic (rc=$rc)"
    fi
}

source "$PROJECT_ROOT/scripts/lib/council.sh"

test_supersede_key_slug_is_fs_safe
test_flag_and_env_resolution
test_same_key_supersedes_prior
test_different_keys_do_not_cross_supersede
test_unkeyed_run_is_a_noop
test_summary_carries_supersede_key
test_delayed_older_scanner_keeps_newest
test_creation_order_does_not_follow_pid_sort
test_completion_waits_for_supersession_lock
test_failed_initial_beacon_is_not_published
test_missing_python_fails_before_creating_a_run

test_summary

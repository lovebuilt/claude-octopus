#!/usr/bin/env bash
# OpenCode 1.x takes the global --pure flag (Issue #566 workaround); 2.x rejects
# it ("Unrecognized flag: --pure"). Capability detection probes the installed
# CLI's help once per run through the bounded probe runner, and dispatch reads
# the result. A failed probe must keep --pure, the behaviour before the probe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "OpenCode --pure flag follows the installed CLI"

export WORKSPACE_DIR="$TEST_TMP_DIR/workspace"
export OCTOPUS_WORKSPACE="$WORKSPACE_DIR"
export RESULTS_DIR="$WORKSPACE_DIR/results"
mkdir -p "$RESULTS_DIR"

source "$PROJECT_ROOT/scripts/lib/run-contract.sh"
source "$PROJECT_ROOT/scripts/lib/spawn.sh"
source "$PROJECT_ROOT/scripts/lib/workflows.sh"
source "$PROJECT_ROOT/scripts/lib/validation.sh"
source "$PROJECT_ROOT/scripts/lib/model-cache-path.sh"
source "$PROJECT_ROOT/scripts/lib/model-resolver.sh"
source "$PROJECT_ROOT/scripts/lib/provider-routing.sh"
source "$PROJECT_ROOT/scripts/lib/agents.sh"
source "$PROJECT_ROOT/scripts/lib/dispatch.sh"
source "$PROJECT_ROOT/scripts/lib/utils.sh"
source "$PROJECT_ROOT/scripts/lib/providers.sh"
get_agent_model() { printf '%s\n' opencode-go/fixture-model; }

LOG_FILE="$TEST_TMP_DIR/octopus-log"
log() { local level="$1"; shift; printf '%s %s\n' "$level" "$*" >> "$LOG_FILE"; }

# One fake opencode; FAKE_OPENCODE_MODE picks its help behaviour. Every call is
# recorded so tests can count probes. It never depends on PATH.
FAKE_BIN="$TEST_TMP_DIR/fake-bin"
EMPTY_BIN="$TEST_TMP_DIR/empty-bin"
mkdir -p "$FAKE_BIN" "$EMPTY_BIN"
export PROBE_LOG="$TEST_TMP_DIR/probe-calls"
cat > "$FAKE_BIN/opencode" <<'FAKE_OPENCODE'
#!/bin/bash
printf '%s\n' "$*" >> "$PROBE_LOG"
case "${FAKE_OPENCODE_MODE:-}" in
    v1)
        # Real OpenCode 1.18.34 prints its whole help on stderr, none on stdout.
        printf '%s\n' 'opencode [project]' '' 'Options:' \
            '  -h, --help          show help                     [boolean]' \
            '      --print-logs    print logs to stderr          [boolean]' \
            '      --pure          run without external plugins  [boolean]' >&2
        ;;
    v2)
        printf '%s\n' 'USAGE' '  opencode <subcommand> [flags]' '' 'FLAGS' \
            '  --standalone            Run with a private server instead of the background service' \
            '  --print-logs            Print logs to stderr'
        ;;
    mention)
        printf '%s\n' 'FLAGS' \
            '  --pure-output           Plain output' \
            '  --standalone            Replaces --pure, which was removed in 2.0'
        ;;
    fail)
        printf '%s\n' '      --pure          run without external plugins' >&2
        exit 70
        ;;
    empty)
        ;;
    stall)
        trap '' TERM
        /bin/sleep 30
        printf '%s\n' '      --pure          run without external plugins'
        ;;
esac
exit 0
FAKE_OPENCODE
chmod +x "$FAKE_BIN/opencode"
ORIG_PATH="$PATH"
export PATH="$FAKE_BIN:$ORIG_PATH"

WITH_PURE="opencode --pure run -m opencode-go/fixture-model"
WITHOUT_PURE="opencode run -m opencode-go/fixture-model"

probe_calls() { wc -l < "$PROBE_LOG" | tr -d '[:space:]'; }
warned_override() { grep -c '^WARN .*OCTOPUS_OPENCODE_PURE' "$LOG_FILE" 2>/dev/null || true; }
dispatch_cmd() { get_agent_command opencode develop implementer; }

# Reset state, then run detection the way orchestrate.sh does at startup.
detect_with() {
    export FAKE_OPENCODE_MODE="$1"
    : > "$PROBE_LOG"
    : > "$LOG_FILE"
    unset SUPPORTS_OPENCODE_PURE_FLAG
    detect_rc=0
    OCTOPUS_OPENCODE_PURE="${2:-}" detect_opencode_capabilities || detect_rc=$?
}

test_case "OpenCode 1.x help on stderr declares --pure: supported, flag kept"
detect_with v1
out=$(dispatch_cmd)
if [[ "$detect_rc" -eq 0 && "${SUPPORTS_OPENCODE_PURE_FLAG:-}" == "true" &&
      "$out" == "$WITH_PURE" && "$(probe_calls)" == "1" && "$(warned_override)" == "0" ]]; then
    test_pass
else
    test_fail "rc=$detect_rc flag=${SUPPORTS_OPENCODE_PURE_FLAG:-unset} probes=$(probe_calls) warns=$(warned_override) got: $out"
fi

test_case "OpenCode 2.x help on stdout without --pure: unsupported, flag dropped"
detect_with v2
out=$(dispatch_cmd)
if [[ "$detect_rc" -eq 0 && "${SUPPORTS_OPENCODE_PURE_FLAG:-}" == "false" &&
      "$out" == "$WITHOUT_PURE" && "$(warned_override)" == "0" ]]; then
    test_pass
else
    test_fail "rc=$detect_rc flag=${SUPPORTS_OPENCODE_PURE_FLAG:-unset} got: $out"
fi

test_case "help that only mentions --pure (removal note, --pure-output) is not a declaration"
detect_with mention
out=$(dispatch_cmd)
if [[ "${SUPPORTS_OPENCODE_PURE_FLAG:-}" == "false" && "$out" == "$WITHOUT_PURE" ]]; then
    test_pass
else
    test_fail "flag=${SUPPORTS_OPENCODE_PURE_FLAG:-unset} got: $out"
fi

test_case "help exiting non-zero is a failed probe: --pure kept, WARN names the override"
detect_with fail
out=$(dispatch_cmd)
if [[ "$detect_rc" -eq 0 && "${SUPPORTS_OPENCODE_PURE_FLAG:-}" == "unknown" &&
      "$out" == "$WITH_PURE" && "$(warned_override)" == "1" ]]; then
    test_pass
else
    test_fail "rc=$detect_rc flag=${SUPPORTS_OPENCODE_PURE_FLAG:-unset} warns=$(warned_override) got: $out"
fi

test_case "help exiting 0 with no output is a failed probe: --pure kept"
detect_with empty
out=$(dispatch_cmd)
if [[ "${SUPPORTS_OPENCODE_PURE_FLAG:-}" == "unknown" && "$out" == "$WITH_PURE" &&
      "$(warned_override)" == "1" ]]; then
    test_pass
else
    test_fail "flag=${SUPPORTS_OPENCODE_PURE_FLAG:-unset} warns=$(warned_override) got: $out"
fi

test_case "stalled help that ignores TERM is killed within the probe budget; --pure kept"
started_at=$(date +%s)
OCTOPUS_BARE_PROBE_TIMEOUT=3 detect_with stall
elapsed=$(( $(date +%s) - started_at ))
out=$(dispatch_cmd)
# Budget is 3s total (TERM at 1s, KILL at 3s); 8s leaves CI headroom while the
# fake's 30s sleep still fails an unbounded probe.
if [[ "$detect_rc" -eq 0 && "$elapsed" -lt 8 && "${SUPPORTS_OPENCODE_PURE_FLAG:-}" == "unknown" &&
      "$out" == "$WITH_PURE" && "$(warned_override)" == "1" ]]; then
    test_pass
else
    test_fail "rc=$detect_rc elapsed=${elapsed}s flag=${SUPPORTS_OPENCODE_PURE_FLAG:-unset} warns=$(warned_override) got: $out"
fi

test_case "OCTOPUS_OPENCODE_PURE off values drop the flag on 1.x with zero probe calls"
override_failures=""
for value in 0 false FALSE no No off OFF; do
    detect_with v1 "$value"
    out=$(dispatch_cmd)
    if [[ "${SUPPORTS_OPENCODE_PURE_FLAG:-}" != "false" || "$out" != "$WITHOUT_PURE" ||
          "$(probe_calls)" != "0" ]]; then
        override_failures="$override_failures $value(flag=${SUPPORTS_OPENCODE_PURE_FLAG:-unset},probes=$(probe_calls),cmd=$out)"
    fi
done
if [[ -z "$override_failures" ]]; then test_pass; else test_fail "failed:$override_failures"; fi

test_case "OCTOPUS_OPENCODE_PURE on values force the flag on 2.x with zero probe calls"
override_failures=""
for value in 1 true TRUE yes Yes on ON; do
    detect_with v2 "$value"
    out=$(dispatch_cmd)
    if [[ "${SUPPORTS_OPENCODE_PURE_FLAG:-}" != "true" || "$out" != "$WITH_PURE" ||
          "$(probe_calls)" != "0" ]]; then
        override_failures="$override_failures $value(flag=${SUPPORTS_OPENCODE_PURE_FLAG:-unset},probes=$(probe_calls),cmd=$out)"
    fi
done
if [[ -z "$override_failures" ]]; then test_pass; else test_fail "failed:$override_failures"; fi

test_case "an unrecognised OCTOPUS_OPENCODE_PURE value warns and falls back to the probe"
detect_with v2 maybe
out=$(dispatch_cmd)
if [[ "${SUPPORTS_OPENCODE_PURE_FLAG:-}" == "false" && "$out" == "$WITHOUT_PURE" &&
      "$(probe_calls)" == "1" && "$(warned_override)" == "1" ]]; then
    test_pass
else
    test_fail "flag=${SUPPORTS_OPENCODE_PURE_FLAG:-unset} probes=$(probe_calls) warns=$(warned_override) got: $out"
fi

test_case "the probe runs once per run, not once per dispatch"
detect_with v2
dispatch_failures=""
for i in 1 2 3; do
    out=$(dispatch_cmd)
    [[ "$out" == "$WITHOUT_PURE" ]] || dispatch_failures="$dispatch_failures #$i:$out"
done
if [[ "$(probe_calls)" == "1" && -z "$dispatch_failures" ]]; then
    test_pass
else
    test_fail "probes=$(probe_calls) after 1 detection + 3 dispatches;$dispatch_failures"
fi

test_case "OpenCode absent: no probe, no warning, flag stays unknown and --pure is kept"
: > "$PROBE_LOG"; : > "$LOG_FILE"
unset SUPPORTS_OPENCODE_PURE_FLAG
absent_rc=0
PATH="$EMPTY_BIN" detect_opencode_capabilities || absent_rc=$?
out=$(dispatch_cmd)
if [[ "$absent_rc" -eq 0 && "${SUPPORTS_OPENCODE_PURE_FLAG:-}" == "unknown" &&
      "$(probe_calls)" == "0" && ! -s "$LOG_FILE" && "$out" == "$WITH_PURE" ]]; then
    test_pass
else
    test_fail "rc=$absent_rc flag=${SUPPORTS_OPENCODE_PURE_FLAG:-unset} probes=$(probe_calls) got: $out"
fi

test_case "dispatch without detection (flag unset) keeps --pure and never probes"
: > "$PROBE_LOG"
unset SUPPORTS_OPENCODE_PURE_FLAG
export FAKE_OPENCODE_MODE=v2
out=$(dispatch_cmd)
if [[ "$out" == "$WITH_PURE" && "$(probe_calls)" == "0" ]]; then
    test_pass
else
    test_fail "probes=$(probe_calls) got: $out"
fi

test_case "orchestrate.sh declares the flag and runs detection once at startup"
ORCH="$PROJECT_ROOT/scripts/orchestrate.sh"
if grep -Eq '^SUPPORTS_OPENCODE_PURE_FLAG=unknown([[:space:]]|$)' "$ORCH" &&
   [[ "$(grep -Ec '^[[:space:]]*detect_opencode_capabilities([[:space:]]|$)' "$ORCH")" == "1" ]]; then
    test_pass
else
    test_fail "orchestrate.sh must declare SUPPORTS_OPENCODE_PURE_FLAG=unknown and call detect_opencode_capabilities once"
fi

export PATH="$ORIG_PATH"
test_summary

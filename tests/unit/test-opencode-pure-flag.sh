#!/usr/bin/env bash
# OpenCode 1.x takes the global --pure flag (Issue #566 workaround); 2.x rejects
# it ("Unrecognized flag: --pure"). get_agent_command checks `opencode --help`
# only when it builds an OpenCode command, caches the verdict per binary in the
# workspace, and keeps --pure whenever the answer is not a definite "no".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "OpenCode --pure flag follows the installed CLI"

# The runner exports OCTOPUS_SKIP_PROVIDER_PROBES=true and a developer may have
# OCTOPUS_OPENCODE_PURE set; every case below sets what it needs.
unset OCTOPUS_OPENCODE_PURE OCTOPUS_SKIP_PROVIDER_PROBES OCTOPUS_BARE_PROBE_TIMEOUT

export WORKSPACE_DIR="$TEST_TMP_DIR/workspace"
export OCTOPUS_WORKSPACE="$WORKSPACE_DIR"
export RESULTS_DIR="$WORKSPACE_DIR/results"
export OCTOPUS_RUN_ID="pure-flag-run-1"
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

FAKE_BIN="$TEST_TMP_DIR/fake-bin"
EMPTY_BIN="$TEST_TMP_DIR/empty-bin"
mkdir -p "$FAKE_BIN" "$EMPTY_BIN"
export CALL_LOG="$TEST_TMP_DIR/opencode-calls"
export REAL_HELP="$SCRIPT_DIR/fixtures/opencode-1.18.34-help.txt"

# One strict fake opencode. FAKE_OPENCODE_MODE picks its help. Every call's
# argv is recorded; anything it reads on stdin is recorded as STDIN:<line>.
# Outside --help it behaves like the CLI: 2.x modes reject --pure, others run.
write_fake_opencode() {
    cat > "$FAKE_BIN/opencode" <<'FAKE_OPENCODE'
#!/bin/bash
printf '%s\n' "$*" >> "$CALL_LOG"
if [[ "${1:-}" == "--help" ]]; then
    if IFS= read -r -t 2 stdin_line; then
        printf 'STDIN:%s\n' "$stdin_line" >> "$CALL_LOG"
        exit 3
    fi
    E=$'\033'
    case "${FAKE_OPENCODE_MODE:-}" in
        real1)
            # Captured OpenCode 1.18.34 help: all of it on stderr.
            cat "$REAL_HELP" >&2
            ;;
        v1short)
            printf '%s\n' 'Options:' '  -h, --help  show help  [boolean]' \
                '  -p, --pure  run without external plugins  [boolean]' >&2
            ;;
        v2)
            printf '%s\n' 'USAGE' '  opencode <subcommand> [flags]' '' 'FLAGS' \
                '  --standalone            Run with a private server instead of the background service' \
                '' 'GLOBAL FLAGS' '  --help, -h              Show help information' \
                '  --print-logs            Print logs to stderr'
            ;;
        v2color)
            printf '%s\n' "${E}[1mUSAGE${E}[22m" "  ${E}[36mopencode <subcommand> [flags]${E}[39m" '' \
                "${E}[1mGLOBAL FLAGS${E}[22m" \
                "  ${E}[32m--help${E}[39m, ${E}[32m-h${E}[39m        Show help information" \
                "  ${E}[32m--print-logs${E}[39m      Print logs to stderr"
            ;;
        mention)
            printf '%s\n' 'FLAGS' \
                '  --pure-output           Plain output' \
                '  --standalone            Replaces --pure, which was removed in 2.0'
            ;;
        banner)
            printf '%s\n' 'Error: could not read config; pass --pure to skip plugins'
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
fi
case "${FAKE_OPENCODE_MODE:-}" in
    v2|v2color)
        for arg in "$@"; do
            if [[ "$arg" == "--pure" ]]; then
                printf '%s\n' 'ERROR  Unrecognized flag: --pure in command opencode' >&2
                exit 1
            fi
        done
        ;;
esac
cat > /dev/null
printf '%s\n' '## Findings' \
    'The fixture provider answered with a substantive paragraph of analysis.' \
    'It covers several points in enough detail to count as a contribution.' \
    '- point one' '- point two'
FAKE_OPENCODE
    chmod +x "$FAKE_BIN/opencode"
}
write_fake_opencode
ORIG_PATH="$PATH"
export PATH="$FAKE_BIN:$ORIG_PATH"

WITH_PURE="opencode --pure run -m opencode-go/fixture-model"
WITHOUT_PURE="opencode run -m opencode-go/fixture-model"
CACHE_FILE="$WORKSPACE_DIR/.opencode-capabilities"

help_calls() { grep -cx -- '--help' "$CALL_LOG" 2>/dev/null || true; }
stdin_reads() { grep -c '^STDIN:' "$CALL_LOG" 2>/dev/null || true; }
warns() { grep -c '^WARN .*OCTOPUS_OPENCODE_PURE' "$LOG_FILE" 2>/dev/null || true; }
skip_warns() { grep -c '^WARN OCTOPUS_SKIP_PROVIDER_PROBES=true.*OCTOPUS_OPENCODE_PURE=0' "$LOG_FILE" 2>/dev/null || true; }
# Dispatch builds each command in its own command-substitution subshell.
dispatch_cmd() { get_agent_command opencode develop implementer; }

reset_state() {
    export FAKE_OPENCODE_MODE="$1"
    export OCTOPUS_RUN_ID="pure-flag-run-1"
    unset OCTOPUS_OPENCODE_PURE OCTOPUS_SKIP_PROVIDER_PROBES
    rm -f "$CACHE_FILE" "$CACHE_FILE".*
    : > "$CALL_LOG"
    : > "$LOG_FILE"
}

# ── Verdicts from help text ─────────────────────────────────────────────────

test_case "real OpenCode 1.18.34 help (stderr) declares --pure: flag kept, one --help call"
reset_state real1
out=$(dispatch_cmd)
if [[ "$out" == "$WITH_PURE" && "$(help_calls)" == "1" && "$(sed -n 1p "$CALL_LOG")" == "--help" &&
      "$(warns)" == "0" ]]; then
    test_pass
else
    test_fail "help_calls=$(help_calls) warns=$(warns) calls=[$(paste -sd, "$CALL_LOG")] got: $out"
fi

test_case "the short form '-p, --pure' is a declaration"
reset_state v1short
out=$(dispatch_cmd)
if [[ "$out" == "$WITH_PURE" && "$(warns)" == "0" ]]; then test_pass; else test_fail "warns=$(warns) got: $out"; fi

test_case "OpenCode 2.x help on stdout without --pure: flag dropped, no warning"
reset_state v2
out=$(dispatch_cmd)
if [[ "$out" == "$WITHOUT_PURE" && "$(help_calls)" == "1" && "$(warns)" == "0" ]]; then
    test_pass
else
    test_fail "help_calls=$(help_calls) warns=$(warns) got: $out"
fi

test_case "coloured 2.x help (ANSI headings and flags) is still help: flag dropped"
reset_state v2color
out=$(dispatch_cmd)
if [[ "$out" == "$WITHOUT_PURE" && "$(warns)" == "0" ]]; then test_pass; else test_fail "warns=$(warns) got: $out"; fi

test_case "help that only mentions --pure (removal note, --pure-output) is not a declaration"
reset_state mention
out=$(dispatch_cmd)
if [[ "$out" == "$WITHOUT_PURE" ]]; then test_pass; else test_fail "got: $out"; fi

test_case "output that is not help (exit 0, no options section) is unknown: --pure kept, WARN"
reset_state banner
out=$(dispatch_cmd)
if [[ "$out" == "$WITH_PURE" && "$(warns)" == "1" ]]; then test_pass; else test_fail "warns=$(warns) got: $out"; fi

test_case "help exiting non-zero is a failed check: --pure kept, WARN names the override"
reset_state fail
out=$(dispatch_cmd)
if [[ "$out" == "$WITH_PURE" && "$(warns)" == "1" ]]; then test_pass; else test_fail "warns=$(warns) got: $out"; fi

test_case "help exiting 0 with no output is a failed check: --pure kept"
reset_state empty
out=$(dispatch_cmd)
if [[ "$out" == "$WITH_PURE" && "$(warns)" == "1" ]]; then test_pass; else test_fail "warns=$(warns) got: $out"; fi

test_case "stalled help that ignores TERM is killed within the probe budget; --pure kept"
reset_state stall
started_at=$(date +%s)
out=$(OCTOPUS_BARE_PROBE_TIMEOUT=3 dispatch_cmd)
elapsed=$(( $(date +%s) - started_at ))
# Budget is 3s total (TERM at 1s, KILL at 3s); 8s leaves CI headroom while the
# fake's 30s sleep still fails an unbounded probe.
if [[ "$elapsed" -lt 8 && "$out" == "$WITH_PURE" && "$(warns)" == "1" ]]; then
    test_pass
else
    test_fail "elapsed=${elapsed}s warns=$(warns) got: $out"
fi

test_case "the probe's stdin is closed: piped input never reaches opencode --help"
reset_state v2
out=$(printf 'SENTINEL-PROMPT\n' | dispatch_cmd)
if [[ "$out" == "$WITHOUT_PURE" && "$(stdin_reads)" == "0" && "$(help_calls)" == "1" ]]; then
    test_pass
else
    test_fail "stdin_reads=$(stdin_reads) calls=[$(paste -sd, "$CALL_LOG")] got: $out"
fi

# ── Cache ───────────────────────────────────────────────────────────────────

test_case "verdict is cached in the workspace: three dispatch subshells, one probe"
reset_state v2
dispatch_failures=""
for i in 1 2 3; do
    out=$(dispatch_cmd)
    [[ "$out" == "$WITHOUT_PURE" ]] || dispatch_failures="$dispatch_failures #$i:$out"
done
if [[ "$(help_calls)" == "1" && -z "$dispatch_failures" ]] &&
   grep -q "	$FAKE_BIN/opencode	" "$CACHE_FILE"; then
    test_pass
else
    test_fail "help_calls=$(help_calls) after 3 dispatches;$dispatch_failures cache=[$(cat "$CACHE_FILE" 2>/dev/null)]"
fi

test_case "a definite verdict survives into the next run (same binary, new run id)"
export OCTOPUS_RUN_ID="pure-flag-run-2"
out=$(dispatch_cmd)
if [[ "$out" == "$WITHOUT_PURE" && "$(help_calls)" == "1" ]]; then
    test_pass
else
    test_fail "help_calls=$(help_calls) got: $out"
fi

test_case "the cache is invalidated when only the binary's size changes"
reset_state v1short
out1=$(dispatch_cmd)
# Keep the mtime, so only the size can invalidate the entry.
touch -r "$FAKE_BIN/opencode" "$TEST_TMP_DIR/mtime-ref"
printf '# upgraded\n' >> "$FAKE_BIN/opencode"
touch -r "$TEST_TMP_DIR/mtime-ref" "$FAKE_BIN/opencode"
export FAKE_OPENCODE_MODE=v2
out2=$(dispatch_cmd)
if [[ "$out1" == "$WITH_PURE" && "$out2" == "$WITHOUT_PURE" && "$(help_calls)" == "2" ]]; then
    test_pass
else
    test_fail "help_calls=$(help_calls) before=[$out1] after=[$out2]"
fi
write_fake_opencode

test_case "the cache is invalidated when only the binary's mtime changes"
reset_state v1short
out1=$(dispatch_cmd)
touch -t 202001010000 "$FAKE_BIN/opencode"
export FAKE_OPENCODE_MODE=v2
out2=$(dispatch_cmd)
if [[ "$out1" == "$WITH_PURE" && "$out2" == "$WITHOUT_PURE" && "$(help_calls)" == "2" ]]; then
    test_pass
else
    test_fail "help_calls=$(help_calls) before=[$out1] after=[$out2]"
fi
write_fake_opencode

test_case "a failed check is cached for this run only: one probe and one WARN per run"
reset_state fail
out1=$(dispatch_cmd)
out2=$(dispatch_cmd)
same_run_calls=$(help_calls)
same_run_warns=$(warns)
export OCTOPUS_RUN_ID="pure-flag-run-2"
out3=$(dispatch_cmd)
if [[ "$out1" == "$WITH_PURE" && "$out2" == "$WITH_PURE" && "$out3" == "$WITH_PURE" &&
      "$same_run_calls" == "1" && "$same_run_warns" == "1" &&
      "$(help_calls)" == "2" && "$(warns)" == "2" ]]; then
    test_pass
else
    test_fail "same run: calls=$same_run_calls warns=$same_run_warns; after new run: calls=$(help_calls) warns=$(warns)"
fi

test_case "no workspace: the check still works (no cache)"
reset_state v2
out=$(unset WORKSPACE_DIR; dispatch_cmd)
if [[ "$out" == "$WITHOUT_PURE" && ! -e "$CACHE_FILE" ]]; then test_pass; else test_fail "got: $out"; fi

# ── Overrides and the skip switch ───────────────────────────────────────────

test_case "OCTOPUS_OPENCODE_PURE off values (any case) drop the flag with zero probes, no tr needed"
override_failures=""
for value in 0 false FALSE fAlSe no No off OFF oFf; do
    reset_state real1
    # PATH holds only the fake: an external case folder (tr) would be missing.
    out=$(OCTOPUS_OPENCODE_PURE="$value" PATH="$FAKE_BIN" dispatch_cmd)
    if [[ "$out" != "$WITHOUT_PURE" || "$(help_calls)" != "0" || "$(warns)" != "0" ]]; then
        override_failures="$override_failures $value(probes=$(help_calls),warns=$(warns),cmd=$out)"
    fi
done
if [[ -z "$override_failures" ]]; then test_pass; else test_fail "failed:$override_failures"; fi

test_case "OCTOPUS_OPENCODE_PURE on values (any case) force the flag on 2.x with zero probes"
override_failures=""
for value in 1 true TRUE TrUe yes Yes on ON oN; do
    reset_state v2
    out=$(OCTOPUS_OPENCODE_PURE="$value" PATH="$FAKE_BIN" dispatch_cmd)
    if [[ "$out" != "$WITH_PURE" || "$(help_calls)" != "0" || "$(warns)" != "0" ]]; then
        override_failures="$override_failures $value(probes=$(help_calls),warns=$(warns),cmd=$out)"
    fi
done
if [[ -z "$override_failures" ]]; then test_pass; else test_fail "failed:$override_failures"; fi

test_case "an unrecognised OCTOPUS_OPENCODE_PURE warns once per run and the check decides"
reset_state v2
export OCTOPUS_OPENCODE_PURE=maybe
dispatch_failures=""
for i in 1 2 3; do
    out=$(dispatch_cmd)
    [[ "$out" == "$WITHOUT_PURE" ]] || dispatch_failures="$dispatch_failures #$i:$out"
done
value_warns=$(grep -c "^WARN OCTOPUS_OPENCODE_PURE='maybe' is not recognised" "$LOG_FILE" || true)
unset OCTOPUS_OPENCODE_PURE
if [[ -z "$dispatch_failures" && "$value_warns" == "1" && "$(help_calls)" == "1" ]]; then
    test_pass
else
    test_fail "value_warns=$value_warns help_calls=$(help_calls);$dispatch_failures"
fi

test_case "OCTOPUS_SKIP_PROVIDER_PROBES=true: no probe, --pure kept, one WARN per run naming OCTOPUS_OPENCODE_PURE=0"
reset_state v2
export OCTOPUS_SKIP_PROVIDER_PROBES=true
dispatch_failures=""
for i in 1 2 3; do
    out=$(dispatch_cmd)
    [[ "$out" == "$WITH_PURE" ]] || dispatch_failures="$dispatch_failures #$i:$out"
done
first_run_warns=$(skip_warns)
export OCTOPUS_RUN_ID="pure-flag-run-2"
out=$(dispatch_cmd)
unset OCTOPUS_SKIP_PROVIDER_PROBES
if [[ -z "$dispatch_failures" && "$out" == "$WITH_PURE" && "$(help_calls)" == "0" &&
      "$first_run_warns" == "1" && "$(skip_warns)" == "2" ]]; then
    test_pass
else
    test_fail "help_calls=$(help_calls) first_run_warns=$first_run_warns total_warns=$(skip_warns);$dispatch_failures"
fi

test_case "skip switch plus OCTOPUS_OPENCODE_PURE=0: flag dropped, no probe, no WARN"
reset_state v2
out=$(OCTOPUS_SKIP_PROVIDER_PROBES=true OCTOPUS_OPENCODE_PURE=0 dispatch_cmd)
if [[ "$out" == "$WITHOUT_PURE" && "$(help_calls)" == "0" && ! -s "$LOG_FILE" ]]; then
    test_pass
else
    test_fail "help_calls=$(help_calls) log=[$(cat "$LOG_FILE")] got: $out"
fi

test_case "OpenCode absent: no probe, no warning, --pure kept"
reset_state v2
out=$(PATH="$EMPTY_BIN" dispatch_cmd)
if [[ "$out" == "$WITH_PURE" && "$(help_calls)" == "0" && ! -s "$LOG_FILE" ]]; then
    test_pass
else
    test_fail "help_calls=$(help_calls) log=[$(cat "$LOG_FILE")] got: $out"
fi

# ── orchestrate.sh, end to end ──────────────────────────────────────────────
# Every other provider command is shadowed by a stub that records the call and
# fails, so these runs never reach a real CLI even with probes enabled. The
# OpenCode seat is the only allowed provider, with a placeholder auth file.

ORCH_HOME="$TEST_TMP_DIR/orch-home"
STUB_BIN="$TEST_TMP_DIR/stub-bin"
mkdir -p "$STUB_BIN"
for stub in $(octo_provider_registry_rows | cut -d'|' -f3 | sort -u) agent cursor-agent gemini; do
    [[ "$stub" == "opencode" || "$stub" == "python3" ]] && continue
    printf '#!/bin/bash\nprintf "STUB %s %%s\\n" "$*" >> "$CALL_LOG"\nexit 1\n' "$stub" > "$STUB_BIN/$stub"
    chmod +x "$STUB_BIN/$stub"
done

run_orchestrate() {
    (
        unset CLAUDE_PLUGIN_DATA CLAUDE_OCTOPUS_WORKSPACE OCTOPUS_WORKSPACE WORKSPACE_DIR RESULTS_DIR \
            OCTOPUS_RUN_ID OCTOPUS_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION \
            OCTOPUS_WORKFLOW_STATE_DIR OCTOPUS_STATE_PROJECT_ROOT OCTOPUS_PROOF_PACKET OCTOPUS_PROOF_ROOT \
            ANTHROPIC_API_KEY GITHUB_TOKEN OPENROUTER_API_KEY Z_AI_API_KEY MINIMAX_API_KEY
        export HOME="$ORCH_HOME" OCTO_ALLOWED_PROVIDERS=opencode
        export OCTOPUS_SKIP_PROVIDER_PROBES="${ORCH_SKIP:-false}"
        export PATH="$FAKE_BIN:$STUB_BIN:$ORIG_PATH"
        cd "$TEST_TMP_DIR"
        bash "$PROJECT_ROOT/scripts/orchestrate.sh" "$@" </dev/null 2>&1
    )
}
reset_orchestrate() {
    reset_state "$1"
    rm -rf "$ORCH_HOME"
    mkdir -p "$ORCH_HOME/.local/share/opencode"
    printf '{}\n' > "$ORCH_HOME/.local/share/opencode/auth.json"
}

test_case "orchestrate.sh startup never runs opencode (lazy): 'help' makes zero calls"
reset_orchestrate v2
orch_rc=0
orch_out=$(run_orchestrate help) || orch_rc=$?
oc_calls=$(grep -vc '^STUB ' "$CALL_LOG" || true)
if [[ "$orch_rc" -eq 0 && "$oc_calls" == "0" ]]; then
    test_pass
else
    test_fail "rc=$orch_rc opencode calls=[$(grep -v '^STUB ' "$CALL_LOG" | paste -sd, -)]"
fi

test_case "orchestrate.sh probe-single on a strict 2.x fake: one --help before the run, no --pure"
reset_orchestrate v2
orch_rc=0
orch_out=$(run_orchestrate --skip-smoke-test probe-single opencode "fixture perspective" t1) || orch_rc=$?
oc_lines=$(grep -v '^STUB ' "$CALL_LOG" | paste -sd'|' -)
if [[ "$orch_rc" -eq 0 && "$oc_lines" == "--help|run -m "* ]]; then
    test_pass
else
    test_fail "rc=$orch_rc opencode calls=[$oc_lines] output tail: $(printf '%s\n' "$orch_out" | tail -5)"
fi

test_case "a second orchestrate.sh run reuses the workspace verdict (no new --help)"
: > "$CALL_LOG"
orch_rc=0
orch_out=$(run_orchestrate --skip-smoke-test probe-single opencode "fixture perspective" t2) || orch_rc=$?
oc_lines=$(grep -v '^STUB ' "$CALL_LOG" | paste -sd'|' -)
if [[ "$orch_rc" -eq 0 && "$oc_lines" == "run -m "* && "$oc_lines" != *"|"* ]]; then
    test_pass
else
    test_fail "rc=$orch_rc opencode calls=[$oc_lines]"
fi

test_case "orchestrate.sh with OCTOPUS_SKIP_PROVIDER_PROBES=true: no --help, --pure kept, one WARN"
reset_orchestrate v1short
orch_rc=0
orch_out=$(ORCH_SKIP=true run_orchestrate --skip-smoke-test probe-single opencode "fixture perspective" t1) || orch_rc=$?
oc_lines=$(grep -v '^STUB ' "$CALL_LOG" | paste -sd'|' -)
skip_warn_lines=$(grep -c 'OCTOPUS_SKIP_PROVIDER_PROBES=true.*OCTOPUS_OPENCODE_PURE=0' <<< "$orch_out" || true)
if [[ "$orch_rc" -eq 0 && "$oc_lines" == "--pure run -m "* && "$oc_lines" != *"|"* &&
      "$skip_warn_lines" == "1" ]]; then
    test_pass
else
    test_fail "rc=$orch_rc opencode calls=[$oc_lines] skip_warns=$skip_warn_lines"
fi

export PATH="$ORIG_PATH"
test_summary

#!/usr/bin/env bash
# Offline dispatch coverage for the Sonnet 5.5 host migration.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "Sonnet 5.5 routing"
log() { :; }
export PLUGIN_DIR="$PROJECT_ROOT" _BARE_OPT="" OCTOPUS_PLATFORM=Linux
source "$PROJECT_ROOT/scripts/lib/model-resolver.sh"
source "$PROJECT_ROOT/scripts/lib/agents.sh"
source "$PROJECT_ROOT/scripts/lib/dispatch.sh"
export TMPDIR="$TEST_TMP_DIR" CLAUDE_CODE_SESSION="sonnet55-$$"
export OCTOPUS_PROVIDERS_CONFIG="$TEST_TMP_DIR/providers.json"
printf '%s\n' '{"version":"3.0","providers":{}}' > "$OCTOPUS_PROVIDERS_CONFIG"
export SUPPORTS_SDK_MODEL_CAPS=true SUPPORTS_EFFORT_COMMAND=true SUPPORTS_EFFORT_CLI_FLAG=true SUPPORTS_XHIGH_EFFORT=true
unset OCTOPUS_CLAUDE_MODEL OCTOPUS_COST_MODE OCTOPUS_ROUTING_POLICY OCTOPUS_EFFORT_OVERRIDE

fake_bin="$TEST_TMP_DIR/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    printf '%s (Claude Code)\n' "${OCTOPUS_TEST_VERSION:-2.1.286}"
else
    printf '%s\n' "$@" > "$OCTOPUS_TEST_CAPTURE"
    cat > "$OCTOPUS_TEST_PROMPT"
fi
EOF
chmod +x "$fake_bin/claude"
export PATH="$fake_bin:$PATH" OCTOPUS_TEST_CAPTURE="$TEST_TMP_DIR/argv" OCTOPUS_TEST_PROMPT="$TEST_TMP_DIR/prompt"

detected_sonnet() {
    (
        set +u
        export SUPPORTS_SONNET_5_5=false SUPPORTS_SONNET_5=false OCTOPUS_HOST=claude CLAUDE_CODE_VERSION=""
        export OCTOPUS_TEST_VERSION="$1" OCTOPUS_SKIP_PROVIDER_PROBES=true
        detect_claude_code_version >/dev/null 2>&1
        sonnet_default_model
    )
}
test_case "detected Claude Code versions select Sonnet 5.5 only at its release floor"
if [[ "$(detected_sonnet 2.1.284)" == claude-sonnet-5-5 &&
      "$(detected_sonnet 2.1.283)" == claude-sonnet-5 &&
      "$(detected_sonnet 2.1.196)" == claude-sonnet-4.6 ]]; then
    test_pass
else
    test_fail "Sonnet model selection ignored the installed version"
fi

export SUPPORTS_SONNET_5_5=true SUPPORTS_SONNET_5=true SUPPORTS_OPUS_5_5=true SUPPORTS_OPUS_5=true
run_dispatch() {
    local command
    command="$(get_agent_command "$1" develop "${2:-synthesizer}")"
    local -a argv
    read -r -a argv <<< "$command"
    printf '%s' 'fixture prompt' | "${argv[@]}"
}
test_case "actual CLI dispatch receives current Sonnet and an explicit effort pin"
if OCTOPUS_CLAUDE_REASONING=medium run_dispatch claude-sonnet &&
   grep -Fxq claude-sonnet-5-5 "$OCTOPUS_TEST_CAPTURE" &&
   grep -Fxq medium "$OCTOPUS_TEST_CAPTURE" &&
   [[ "$(cat "$OCTOPUS_TEST_PROMPT")" == 'fixture prompt' ]]; then
    test_pass
else
    test_fail "Sonnet model or effort did not reach the executable"
fi

test_case "saved provider model and effort pins survive the standard-model migration"
printf '%s\n' '{"version":"3.0","providers":{"claude":{"default":"claude-sonnet-5","reasoning_effort":"low"}}}' > "$OCTOPUS_PROVIDERS_CONFIG"
if run_dispatch claude && grep -Fxq claude-sonnet-5 "$OCTOPUS_TEST_CAPTURE" &&
   grep -Fxq low "$OCTOPUS_TEST_CAPTURE"; then
    test_pass
else
    test_fail "saved Claude model or effort pin was replaced"
fi
export OCTOPUS_PROVIDERS_CONFIG="$TEST_TMP_DIR/empty-reset.json"
printf '%s\n' '{"version":"3.0","providers":{}}' > "$OCTOPUS_PROVIDERS_CONFIG"

test_case "exact older Sonnet pins and maximum effort stay exact"
if OCTOPUS_CLAUDE_REASONING=max run_dispatch claude:claude-sonnet-5 &&
   grep -Fxq claude-sonnet-5 "$OCTOPUS_TEST_CAPTURE" &&
   grep -Fxq max "$OCTOPUS_TEST_CAPTURE"; then
    test_pass
else
    test_fail "an exact model or maximum effort was changed"
fi

test_case "premium Opus remains Opus 5.5 at high effort"
if run_dispatch claude-opus architect &&
   grep -Fxq claude-opus-5-5 "$OCTOPUS_TEST_CAPTURE" &&
   grep -Fxq high "$OCTOPUS_TEST_CAPTURE"; then
    test_pass
else
    test_fail "premium default was changed by the Sonnet migration"
fi

test_summary

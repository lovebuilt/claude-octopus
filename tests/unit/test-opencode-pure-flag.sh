#!/usr/bin/env bash
# OpenCode 2.x rejects the global --pure flag ("Unrecognized flag: --pure").
# The dispatch command must carry --pure only when the installed CLI lists it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "opencode --pure flag follows the installed CLI"

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
get_agent_model() { printf '%s\n' opencode-go/fixture-model; }

make_fake_opencode() {
    local dir="$1" help_text="$2"
    mkdir -p "$dir"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$help_text" > "$dir/opencode"
    chmod +x "$dir/opencode"
}

V1="$TEST_TMP_DIR/opencode-v1"
V2="$TEST_TMP_DIR/opencode-v2"
make_fake_opencode "$V1" "  --pure      run without external plugins"
make_fake_opencode "$V2" "  --standalone  Run with a private server instead of the background service"

command_with() {
    ( unset _OCTOPUS_OPENCODE_PURE_PROBE OCTOPUS_OPENCODE_PURE
      PATH="$1:$PATH"
      [[ -n "${2:-}" ]] && export OCTOPUS_OPENCODE_PURE="$2"
      get_agent_command opencode develop implementer )
}

test_case "OpenCode 1.x (lists --pure) keeps the flag before run"
out=$(command_with "$V1")
if [[ "$out" == "opencode --pure run -m opencode-go/fixture-model" ]]; then
    test_pass
else
    test_fail "got: $out"
fi

test_case "OpenCode 2.x (no --pure) gets no flag"
out=$(command_with "$V2")
if [[ "$out" == "opencode run -m opencode-go/fixture-model" ]]; then
    test_pass
else
    test_fail "got: $out"
fi

test_case "OCTOPUS_OPENCODE_PURE=1 forces the flag on 2.x"
out=$(command_with "$V2" 1)
if [[ "$out" == "opencode --pure run -m opencode-go/fixture-model" ]]; then
    test_pass
else
    test_fail "got: $out"
fi

test_case "OCTOPUS_OPENCODE_PURE=0 drops the flag on 1.x"
out=$(command_with "$V1" 0)
if [[ "$out" == "opencode run -m opencode-go/fixture-model" ]]; then
    test_pass
else
    test_fail "got: $out"
fi

test_summary

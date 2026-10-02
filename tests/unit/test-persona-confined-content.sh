#!/usr/bin/env bash
# Persona prompt reads must keep the approved root through replacement races.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../helpers/test-framework.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../scripts/lib/personas.sh"
test_suite "Persona confined content"
fixture=$(cd -P "$TEST_TMP_DIR" && pwd)
export WORKSPACE_DIR="$fixture/workspace"
pack_dir="$fixture/pack"
outside="$fixture/external"
mkdir -p "$pack_dir" "$outside" "$WORKSPACE_DIR/.octo"
printf 'name: pack\npersonas:\n  - file: persona.md\n    replaces: debugger\n' > "$pack_dir/pack.yaml"
cp "$pack_dir/pack.yaml" "$outside/pack.yaml"
printf 'safe persona\n' > "$pack_dir/persona.md"
printf 'external-secret-marker\n' > "$outside/persona.md"
printf '{"pack":{"dir":"%s","persona_count":1}}\n' "$pack_dir" > "$WORKSPACE_DIR/.octo/active-packs.json"
export OCTOPUS_PERSONA_PACKS="$pack_dir"
test_case "approved regular persona contents reach the prompt reader"
if [[ "$(get_persona_override_content debugger)" == 'safe persona' ]]; then test_pass
else test_fail "regular persona content missing"
fi

test_case "persona replacement after resolution cannot disclose a secret"
eval "$(declare -f resolve_persona_file | sed '1s/resolve_persona_file/original_resolve_persona_file/')"
resolve_persona_file() {
    local path
    path=$(original_resolve_persona_file "$@") || return 1
    rm "$pack_dir/persona.md"
    ln -s "$outside/persona.md" "$pack_dir/persona.md"
    printf '%s\n' "$path"
}
content=$(get_persona_override_content debugger)
if [[ "$content" != *'external-secret-marker'* ]]; then test_pass
else test_fail "persona reader reopened the replaced pathname"
fi
eval "$(declare -f original_resolve_persona_file | sed '1s/original_resolve_persona_file/resolve_persona_file/')"
rm "$pack_dir/persona.md"
printf 'safe persona\n' > "$pack_dir/persona.md"

test_case "pack replacement after approval cannot change the trusted root"
eval "$(declare -f persona_pack_approved_root | sed '1s/persona_pack_approved_root/original_persona_pack_approved_root/')"
persona_pack_approved_root() {
    original_persona_pack_approved_root "$@" || return 1
    mv "$pack_dir" "$fixture/original-pack"
    ln -s "$outside" "$pack_dir"
}
content=$(get_persona_override_content debugger)
if [[ "$content" != *'external-secret-marker'* ]]; then test_pass
else test_fail "pack replacement changed the approved root"
fi
test_summary

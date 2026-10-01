#!/usr/bin/env bash
# Shared storage entry points for existing spec, plan, develop and resume flows.

[[ -n "${_OCTOPUS_FEATURE_CONTRACT_LOADED:-}" ]] && return 0
_OCTOPUS_FEATURE_CONTRACT_LOADED=1
_OCTOPUS_FEATURE_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helpers" && pwd -P)/feature-contract.py"

feature_contract() {
    command -v python3 >/dev/null 2>&1 || {
        printf '%s\n' '{"schema_version":1,"warning":"Python 3 unavailable; retain legacy artifact behavior"}'
        return 2
    }
    python3 "$_OCTOPUS_FEATURE_HELPER" "$@"
}

feature_contract_resolve() {
    local root="$1" name="${2:-feature}" explicit="${3:-${OCTOPUS_FEATURE:-}}" create="${4:-false}"
    local -a args=(resolve --root "$root" --name "$name" --layout "${OCTOPUS_FEATURE_LAYOUT:-auto}")
    [[ -z "$explicit" ]] || args+=(--explicit "$explicit")
    [[ "$create" != true ]] || args+=(--create)
    feature_contract "${args[@]}"
}

feature_contract_resume() {
    local root="$1" explicit="${2:-${OCTOPUS_FEATURE:-}}"
    local -a args=(resume --root "$root" --layout "${OCTOPUS_FEATURE_LAYOUT:-auto}")
    [[ -z "$explicit" ]] || args+=(--explicit "$explicit")
    feature_contract "${args[@]}"
}

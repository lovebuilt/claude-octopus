#!/usr/bin/env bash
# Mark framework response contracts before mixing them with repository content.
[[ "${_OCTO_JSON_CONTRACT_LOADED:-}" == true ]] && return 0

OCTOPUS_JSON_CONTRACT_NONCE="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]')"
if [[ ! "$OCTOPUS_JSON_CONTRACT_NONCE" =~ ^[[:xdigit:]]{32}$ ]]; then
    printf 'ERROR: cannot generate a JSON contract nonce\n' >&2
    return 1
fi
readonly OCTOPUS_JSON_CONTRACT_NONCE
_OCTO_JSON_CONTRACT_LOADED=true

octo_protect_json_contract() {
    local contract="${1:-}"
    printf '[[OCTOPUS_TRUSTED_JSON_CONTRACT_BEGIN:%s]]\n%s\n[[OCTOPUS_TRUSTED_JSON_CONTRACT_END:%s]]\n' \
        "$OCTOPUS_JSON_CONTRACT_NONCE" "$contract" "$OCTOPUS_JSON_CONTRACT_NONCE"
}

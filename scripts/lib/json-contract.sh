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
    # Only controller-authored raw guidance may receive a trusted envelope.
    # Flattening nested markers would turn ambiguous input into a trusted block.
    if [[ "$contract" == *'[[OCTOPUS_TRUSTED_JSON_CONTRACT_BEGIN:'* ||
          "$contract" == *'[[OCTOPUS_TRUSTED_JSON_CONTRACT_END:'* ]]; then
        printf 'ERROR: JSON contract guidance already contains transport markers\n' >&2
        return 1
    fi
    printf '[[OCTOPUS_TRUSTED_JSON_CONTRACT_BEGIN:%s]]\n%s\n[[OCTOPUS_TRUSTED_JSON_CONTRACT_END:%s]]\n' \
        "$OCTOPUS_JSON_CONTRACT_NONCE" "$contract" "$OCTOPUS_JSON_CONTRACT_NONCE"
}

octo_strip_json_contract_markers() {
    # Unknown markers in repository or provider text grant no authority either.
    # Remove transport tokens, including inline echoes, before provider input.
    printf '%s\n' "${1:-}" | sed -E 's/\[\[OCTOPUS_TRUSTED_JSON_CONTRACT_(BEGIN|END):[[:xdigit:]]{32}\]\]//g'
}

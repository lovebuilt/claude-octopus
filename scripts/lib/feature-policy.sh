#!/usr/bin/env bash
# Source-safe policy binding and evidence checks. No policy files are created.

feature_policy_bind() {
    local helper_dir
    helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helpers" && pwd -P)" || return 1
    if [[ $# -eq 1 ]]; then
        python3 "${helper_dir}/feature-policy.py" bind "--root=$1"
    elif [[ $# -eq 2 ]]; then
        python3 "${helper_dir}/feature-policy.py" bind "--root=$1" "--configured=$2"
    else
        return 2
    fi
}

feature_policy_verify() {
    [[ $# -eq 3 ]] || return 2
    local helper_dir
    helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helpers" && pwd -P)" || return 1
    python3 "${helper_dir}/feature-policy.py" verify "--policy=$1" "--plan=$2" "--findings=$3"
}

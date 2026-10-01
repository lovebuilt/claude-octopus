#!/usr/bin/env bash
# Source-safe clarification helpers. Callers publish returned artifacts.

feature_clarifications_collect() {
    [[ $# -ge 1 && $# -le 3 ]] || return 2
    local helper_dir
    local -a args
    helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helpers" && pwd -P)" || return 1
    args=(collect "--spec=$1")
    [[ $# -lt 2 || -z "$2" ]] || args+=("--challenge=$2")
    [[ $# -lt 3 || -z "$3" ]] || args+=("--previous=$3")
    python3 "${helper_dir}/feature-clarifications.py" "${args[@]}"
}

feature_clarifications_answer() {
    [[ $# -eq 2 ]] || return 2
    local helper_dir
    helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helpers" && pwd -P)" || return 1
    python3 "${helper_dir}/feature-clarifications.py" answer "--markers=$1" "--answers=$2"
}

feature_clarifications_gate() {
    [[ $# -ge 2 ]] || return 2
    local helper_dir
    local -a args
    helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helpers" && pwd -P)" || return 1
    args=(gate "--markers=$1" "--phase=$2")
    [[ $# -lt 3 || -z "$3" ]] || args+=("--task-id=$3")
    if [[ $# -gt 3 ]]; then
        shift 3
        local requirement
        for requirement in "$@"; do
            [[ "$requirement" != -* ]] || return 2
        done
        args+=(--requirements "$@")
    fi
    python3 "${helper_dir}/feature-clarifications.py" "${args[@]}"
}

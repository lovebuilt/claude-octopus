#!/usr/bin/env bash
# Source-safe bridge to the deterministic helper. It does not dispatch a seat.
if [[ "${_OCTO_FEATURE_ANALYSIS_LOADED:-}" == true ]]; then
    return 0
fi
_OCTO_FEATURE_ANALYSIS_LIB_DIR="${BASH_SOURCE[0]%/*}"
if [[ "$_OCTO_FEATURE_ANALYSIS_LIB_DIR" == "${BASH_SOURCE[0]}" ]]; then
    _OCTO_FEATURE_ANALYSIS_LIB_DIR=.
fi
if ! _OCTO_FEATURE_ANALYSIS_LIB_DIR="$(cd "$_OCTO_FEATURE_ANALYSIS_LIB_DIR" && pwd -P)"; then
    return 1
fi
_OCTO_FEATURE_ANALYSIS_LOADED=true

octo_feature_analyze() {
    PYTHONDONTWRITEBYTECODE=1 python3 "$_OCTO_FEATURE_ANALYSIS_LIB_DIR/../helpers/feature-analysis.py" analyze "$@"
}

#!/usr/bin/env bash
# Internal host adapter. Existing commands own activation and user decisions.
set -euo pipefail
helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$helper_dir/../lib/feature-workflow.sh"
PROJECT_ROOT="${OCTOPUS_PROJECT_DIR:-$PWD}"
operation="${1:-}"
shift || true

# These values describe one binding, not input configuration for a new host call.
case "$operation" in
    prepare|boundary)
        unset FEATURE_SELECTION FEATURE_RUNTIME_DIR FEATURE_SOURCE_ROOT FEATURE_POLICY_SNAPSHOT \
            FEATURE_ACTIVE FEATURE_AMBIGUOUS FEATURE_SELECTED FEATURE_SPEC_PATH FEATURE_ID FEATURE_TASK_CONTRACT
        ;;
esac

case "$operation" in
    prepare)
        phase="${1:-spec}"
        name="${2:-feature}"
        OCTOPUS_FEATURE="${3:-${OCTOPUS_FEATURE:-}}"
        create=false
        [[ "$phase" != spec ]] || create=true
        feature_workflow_begin "$phase" "$name" "$create"
        if [[ -z "${FEATURE_SELECTION:-}" || ! -f "$FEATURE_SELECTION" || -z "${FEATURE_RUNTIME_DIR:-}" ]]; then
            feature_workflow_warning 'feature context unavailable; continuing legacy workflow'
            printf '{"schema_version":1,"feature":null,"feature_context":false}\n'
            exit 0
        fi
        jq -c --arg runtime_dir "$FEATURE_RUNTIME_DIR" --arg policy_snapshot "${FEATURE_POLICY_SNAPSHOT:-}" \
            '. + {runtime_dir:$runtime_dir,policy_snapshot:$policy_snapshot}' "$FEATURE_SELECTION"
        ;;
    boundary)
        phase="${1:-develop}"
        OCTOPUS_FEATURE="${2:-${OCTOPUS_FEATURE:-}}"
        feature_workflow_begin "$phase" feature false
        [[ "${FEATURE_AMBIGUOUS:-false}" != true ]] || exit 1
        feature_workflow_refresh_clarifications || true
        rc=0
        if [[ "$phase" == develop ]]; then
            feature_workflow_preimplement || rc=$?
        else
            feature_workflow_gate "$phase" || rc=$?
        fi
        if [[ -n "${FEATURE_RUNTIME_DIR:-}" && -f "${FEATURE_RUNTIME_DIR}/clarifications.json" ]]; then
            jq -c '{feature_context:true,batch:.batch,score:.score,markers:.markers,umbrella:.umbrella}' "${FEATURE_RUNTIME_DIR}/clarifications.json"
        else
            printf '{"feature_context":false,"batch":[]}\n'
        fi
        exit "$rc"
        ;;
    save)
        [[ $# -ge 6 ]] || exit 64
        kind="$1" draft="$2" provider="$3" model="$4" run_id="$5"
        OCTOPUS_FEATURE="$6"
        feature_workflow_begin "$kind" feature false
        local_target=""
        [[ "$kind" != spec ]] || local_target="${FEATURE_SPEC_PATH:-spec.md}"
        args=(publish --root "$FEATURE_SOURCE_ROOT" --feature "$FEATURE_SELECTED" --kind "$kind" --input "$draft" --provider "$provider" --model "$model" --run-id "$run_id")
        [[ -z "$local_target" ]] || args+=(--target "$local_target")
        feature_contract "${args[@]}"
        if [[ "$kind" == spec ]]; then
            feature_workflow_refresh_clarifications "${7:-}" || true
        elif [[ "$kind" == plan ]]; then
            feature_workflow_plan_completed "$draft" "$provider" "$run_id" "$model" || true
        fi
        ;;
    answer)
        [[ $# -ge 2 ]] || exit 64
        answers="$1"
        OCTOPUS_FEATURE="$2"
        feature_workflow_begin plan feature false
        feature_workflow_refresh_clarifications || true
        previous="${FEATURE_RUNTIME_DIR}/clarifications.json"
        answered="$(mktemp "${FEATURE_RUNTIME_DIR}/answers.XXXXXX")"
        python3 "$helper_dir/feature-clarifications.py" answer --markers "$previous" --answers "$answers" > "$answered"
        mv "$answered" "$previous"
        feature_workflow_refresh_clarifications
        jq -c '{batch:.batch,score:.score,markers:.markers}' "$previous"
        ;;
    *)
        printf 'Internal feature adapter: prepare, boundary, save or answer\n' >&2
        exit 64
        ;;
esac

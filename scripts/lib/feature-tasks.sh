#!/usr/bin/env bash
# Source-safe internal task metadata adapter. No providers are invoked here.

octopus_feature_tasks() {
    local helper
    helper="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helpers" && pwd)/feature-tasks.py" || return 2
    command -v python3 >/dev/null 2>&1 || return 2
    python3 "$helper" "$@"
}

octopus_feature_tasks_parse() { octopus_feature_tasks parse "$@"; }
octopus_feature_tasks_reconcile() { octopus_feature_tasks reconcile "$@"; }
octopus_feature_tasks_wave() { octopus_feature_tasks wave "$@"; }

#!/usr/bin/env bash
# Stdin-preserving entry point for the text-only Messages adapter.
set -euo pipefail
adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I "$adapter_dir/anthropic-api.py" "$@"

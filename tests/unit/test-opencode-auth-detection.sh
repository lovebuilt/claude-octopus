#!/usr/bin/env bash
# OpenCode 2.x (@opencode/cli) keeps logins in opencode.db, not auth.json, and its
# `auth list` prints one row per login with no "N credentials" summary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../helpers/test-framework.sh"
test_suite "OpenCode login detection, 1.x and 2.x"

log() { :; }
source "$PROJECT_ROOT/scripts/lib/providers.sh"

FAKE="$TEST_TMP_DIR/bin"; mkdir -p "$FAKE"
fake_opencode() {  # $1 = auth list output (printf format), $2 = exit code
    printf '#!/usr/bin/env bash\n[[ "$1 $2" == "auth list" ]] || exit 9\nprintf "%s"\nexit %s\n' "$1" "${2:-0}" > "$FAKE/opencode"
    chmod +x "$FAKE/opencode"
}
detect_opencode() {  # $1 = store file to create (auth.json | opencode.db | none)
    local home="$TEST_TMP_DIR/home-$RANDOM"; mkdir -p "$home/.local/share/opencode"
    [[ "$1" != none ]] && : > "$home/.local/share/opencode/$1"
    ( HOME="$home" PATH="$FAKE:$PATH"; unset -f octo_provider_allowed 2>/dev/null || true
      detect_providers 2>/dev/null | grep -o 'opencode:[a-z]*' || true )
}

test_case "2.x: login in opencode.db and listed is detected"
fake_opencode 'OpenCode Go  OpenCode Go                 stored\\n'
out=$(detect_opencode opencode.db)
[[ "$out" == "opencode:multi" ]] && test_pass || test_fail "got: $out"

test_case "2.x: opencode.db but auth list fails is expired"
fake_opencode '' 1
out=$(detect_opencode opencode.db)
[[ "$out" == "opencode:expired" ]] && test_pass || test_fail "got: $out"

test_case "2.x: opencode.db but nothing listed is expired"
fake_opencode '\\n  \\n'
out=$(detect_opencode opencode.db)
[[ "$out" == "opencode:expired" ]] && test_pass || test_fail "got: $out"

test_case "1.x: auth.json with 2 credentials is detected (with colour codes)"
fake_opencode '\\033[0m\\nCredentials ~/.local/share/opencode/auth.json\\n  2 credentials\\n'
out=$(detect_opencode auth.json)
[[ "$out" == "opencode:multi" ]] && test_pass || test_fail "got: $out"

test_case "1.x: auth.json with 0 credentials is expired"
fake_opencode 'Credentials ~/.local/share/opencode/auth.json\\n  \\033[90m0 credentials\\033[0m\\n'
out=$(detect_opencode auth.json)
[[ "$out" == "opencode:expired" ]] && test_pass || test_fail "got: $out"

test_case "no login store at all is none, and auth list is not run"
printf '#!/usr/bin/env bash\ntouch "%s/ran"\n' "$TEST_TMP_DIR" > "$FAKE/opencode"; chmod +x "$FAKE/opencode"
out=$(detect_opencode none)
[[ "$out" == "opencode:none" && ! -e "$TEST_TMP_DIR/ran" ]] && test_pass || test_fail "got: $out"

test_case "preflight static readiness accepts the 2.x store"
grep -q 'opencode/auth.json" || -f "${HOME}/.local/share/opencode/opencode.db"' "$PROJECT_ROOT/scripts/lib/preflight.sh" \
    && test_pass || test_fail "preflight still requires auth.json"

test_summary

#!/usr/bin/env bash
# tests/unit/test-perplexity-agent-api.sh
# perplexity_execute talks to the Perplexity Agent API (POST /v1/agent).
# These tests stub curl, so they never reach the network and need no key.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "Perplexity Agent API request and response handling"

WORK_DIR="$TEST_TMP_DIR/perplexity-agent-api"
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$WORK_DIR"
REAL_JQ="$(command -v jq)"
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/jq" <<'BASH'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "$PPX_TEST_JQ_ARGV"
exec "$PPX_TEST_REAL_JQ" "$@"
BASH
chmod +x "$WORK_DIR/bin/jq"

# Runs perplexity_execute in a clean subshell with curl replaced by a stub that
# records the URL and the -d payload, then prints the fixture file as the body.
# Usage: run_ppx <model> <fixture-file> [output-file]
# Records the request, stdout, logs, quota marker, and exit status in WORK_DIR.
run_ppx() {
    local model="$1" fixture="$2" output_file="${3:-}"
    rm -f "$WORK_DIR"/{url.txt,payload.json,out.txt,rc.txt,curl-called,log.txt,quota-dead,jq-argv}
    (
        export PERPLEXITY_API_KEY="test-key-not-real"
        export PPX_TEST_REAL_JQ="$REAL_JQ" PPX_TEST_JQ_ARGV="$WORK_DIR/jq-argv"
        export PATH="$WORK_DIR/bin:$PATH"
        VERBOSE=false
        log() { printf '%s %s\n' "$1" "$2" >> "$WORK_DIR/log.txt"; }
        octo_quota_mark_dead() { printf '%s' "$1" > "$WORK_DIR/quota-dead"; }
        source "$PROJECT_ROOT/scripts/lib/utils.sh" >/dev/null 2>&1
        source "$PROJECT_ROOT/scripts/lib/perplexity.sh" >/dev/null 2>&1
        curl() {
            : > "$WORK_DIR/curl-called"
            local prev=""
            for arg in "$@"; do
                case "$prev" in
                    -d) printf '%s' "$arg" > "$WORK_DIR/payload.json" ;;
                    -X) : ;;
                esac
                case "$arg" in https://*) printf '%s' "$arg" > "$WORK_DIR/url.txt" ;; esac
                prev="$arg"
            done
            cat "$fixture"
        }
        local rc=0
        perplexity_execute "$model" "What changed in AI agents this week?" "$output_file" > "$WORK_DIR/out.txt" 2>/dev/null || rc=$?
        echo "$rc" > "$WORK_DIR/rc.txt"
    ) </dev/null
}

cat > "$WORK_DIR/reply-annotated.json" <<'JSON'
{"id":"resp_1","object":"response","status":"completed","error":null,
 "output":[
  {"type":"search_results","queries":["ai agents"],"results":[
    {"id":1,"url":"https://example.com/search-a","title":"A","snippet":"a"},
    {"id":2,"url":"https://example.com/search-b","title":"B","snippet":"b"}]},
  {"type":"message","role":"assistant","status":"completed","content":[
    {"type":"output_text","text":"B supports this claim.[2] A supports the next claim.[1]","annotations":[
      {"type":"url_citation","url":"https://example.com/search-b","title":"B","start_index":22,"end_index":25},
      {"type":"url_citation","url":"https://example.com/search-a","title":"A","start_index":52,"end_index":55}]}]}],
 "usage":{"input_tokens":120,"output_tokens":9,"cost":{"total_cost":0.00141,"currency":"USD"}}}
JSON

cat > "$WORK_DIR/reply-search-only.json" <<'JSON'
{"status":"completed","error":null,
 "output":[
  {"type":"search_results","queries":["q"],"results":[
    {"id":1,"url":"https://example.com/search-a"},
    {"id":2,"url":"https://example.com/search-b"},
    {"id":3,"url":"https://example.com/search-a"}]},
  {"type":"message","role":"assistant","content":[{"type":"output_text","text":"A.[3] B.[2] A again.[1]","annotations":[]}]}]}
JSON

cat > "$WORK_DIR/reply-error.json" <<'JSON'
{"error":{"message":"Invalid API key","type":"authentication_error","code":"401"}}
JSON

cat > "$WORK_DIR/reply-legacy-chat.json" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"legacy shape"}}],"citations":["https://example.com/legacy"]}
JSON

test_posts_to_agent_endpoint() {
    test_case "requests go to POST https://api.perplexity.ai/v1/agent"
    run_ppx sonar-pro "$WORK_DIR/reply-annotated.json"
    assert_equals "https://api.perplexity.ai/v1/agent" "$(cat "$WORK_DIR/url.txt" 2>/dev/null)" "request URL" && test_pass
}

test_sonar_pro_maps_to_fast_preset() {
    test_case "sonar-pro is sent as preset fast with input, instructions and max_output_tokens"
    run_ppx sonar-pro "$WORK_DIR/reply-annotated.json"
    local summary
    summary=$(jq -c '{preset, model, has_input: (.input|type), has_instr: (.instructions|type), mot: .max_output_tokens, messages, max_tokens, tools}' "$WORK_DIR/payload.json" 2>/dev/null)
    assert_equals '{"preset":"fast","model":null,"has_input":"string","has_instr":"string","mot":4096,"messages":null,"max_tokens":null,"tools":null}' "$summary" "payload fields" && test_pass
}

test_legacy_ids_follow_migration_guide() {
    test_case "sonar, sonar-reasoning-pro and sonar-deep-research map to fast, low and high"
    local got=""
    for m in sonar sonar-reasoning-pro sonar-deep-research; do
        run_ppx "$m" "$WORK_DIR/reply-annotated.json"
        got+="$m=$(jq -r .preset "$WORK_DIR/payload.json" 2>/dev/null) "
    done
    assert_equals "sonar=fast sonar-reasoning-pro=low sonar-deep-research=high " "$got" "preset mapping" && test_pass
}

test_explicit_model_adds_web_search_tool() {
    test_case "a provider/model id is sent as model plus the web_search tool"
    run_ppx perplexity/sonar "$WORK_DIR/reply-annotated.json"
    local summary
    summary=$(jq -c '{model, preset, tools}' "$WORK_DIR/payload.json" 2>/dev/null)
    assert_equals '{"model":"perplexity/sonar","preset":null,"tools":[{"type":"web_search"}]}' "$summary" "payload fields" && test_pass
}

test_prompt_is_json_escaped() {
    test_case "a prompt with quotes and newlines still produces valid JSON"
    rm -f "$WORK_DIR/payload.json"
    (
        export PERPLEXITY_API_KEY="test-key-not-real"; VERBOSE=false
        log() { :; }
        source "$PROJECT_ROOT/scripts/lib/utils.sh" >/dev/null 2>&1
        source "$PROJECT_ROOT/scripts/lib/perplexity.sh" >/dev/null 2>&1
        curl() { local p=""; for a in "$@"; do [[ "$p" == "-d" ]] && printf '%s' "$a" > "$WORK_DIR/payload.json"; p="$a"; done; cat "$WORK_DIR/reply-annotated.json"; }
        perplexity_execute fast $'He said "hi"\nthen left' >/dev/null 2>&1 || true
    ) </dev/null
    assert_equals $'He said "hi"\nthen left' "$(jq -r .input "$WORK_DIR/payload.json" 2>/dev/null)" "round-tripped input" && test_pass
}

test_reads_text_and_cited_sources() {
    test_case "answer text comes from output[].content[] and sources from url_citation annotations"
    run_ppx sonar-pro "$WORK_DIR/reply-annotated.json"
    local out; out=$(cat "$WORK_DIR/out.txt")
    assert_equals "0" "$(cat "$WORK_DIR/rc.txt")" "exit status" &&
    assert_contains "$out" "B supports this claim.[2] A supports the next claim.[1]" "answer text" &&
    assert_contains "$out" "[1] https://example.com/search-a" "A keeps its result ID" &&
    assert_contains "$out" "[2] https://example.com/search-b" "B keeps its result ID" &&
    assert_not_contains "$out" "[1] https://example.com/search-b" "B is not renumbered" && test_pass
}

test_falls_back_to_search_results() {
    test_case "with no annotations, sources retain result IDs even when URLs repeat"
    run_ppx fast "$WORK_DIR/reply-search-only.json"
    local out; out=$(cat "$WORK_DIR/out.txt")
    assert_contains "$out" "A.[3] B.[2] A again.[1]" "answer markers preserved" &&
    assert_contains "$out" "[1] https://example.com/search-a" "first source" &&
    assert_contains "$out" "[2] https://example.com/search-b" "second source" &&
    assert_contains "$out" "[3] https://example.com/search-a" "same URL keeps its other result ID" && test_pass
}

test_error_body_fails() {
    test_case "an Agent API error body returns non-zero"
    run_ppx sonar-pro "$WORK_DIR/reply-error.json"
    assert_not_equals "0" "$(cat "$WORK_DIR/rc.txt")" "exit status" && test_pass
}

test_legacy_chat_shape_is_not_success() {
    test_case "a Sonar-shaped reply is not mistaken for an Agent API answer"
    run_ppx sonar-pro "$WORK_DIR/reply-legacy-chat.json"
    assert_not_equals "0" "$(cat "$WORK_DIR/rc.txt")" "exit status" && test_pass
}

test_unknown_model_refused_before_request() {
    test_case "a model with no Agent API mapping is refused without an HTTP call"
    run_ppx 'sonar"; rm -rf /' "$WORK_DIR/reply-annotated.json"
    assert_not_equals "0" "$(cat "$WORK_DIR/rc.txt")" "exit status" || return 0
    if [[ -e "$WORK_DIR/curl-called" ]]; then
        test_fail "curl was called for an unmapped model"
    else
        test_pass
    fi
}

test_quota_probe_uses_agent_endpoint() {
    test_case "the quota probe posts to /v1/agent with tools disabled"
    rm -f "$WORK_DIR"/probe-{url,method,payload,rc}.txt
    (
        export PERPLEXITY_API_KEY="test-key-not-real"
        source "$PROJECT_ROOT/scripts/lib/quota-watcher.sh"
        octo_quota_is_dead() { return 1; }
        octo_quota_mark_dead() { return 99; }
        curl() {
            local prev="" arg
            for arg in "$@"; do
                case "$prev" in
                    -X) printf '%s' "$arg" > "$WORK_DIR/probe-method.txt" ;;
                    -d) printf '%s' "$arg" > "$WORK_DIR/probe-payload.txt" ;;
                esac
                case "$arg" in
                    https://*) printf '%s' "$arg" > "$WORK_DIR/probe-url.txt" ;;
                esac
                prev="$arg"
            done
            printf '200'
        }
        set +e
        octo_provider_probe perplexity
        printf '%s' "$?" > "$WORK_DIR/probe-rc.txt"
    )
    assert_equals "0" "$(cat "$WORK_DIR/probe-rc.txt")" "probe exit" || return 0
    assert_equals "https://api.perplexity.ai/v1/agent" "$(cat "$WORK_DIR/probe-url.txt")" "probe URL" || return 0
    assert_equals "POST" "$(cat "$WORK_DIR/probe-method.txt")" "probe method" || return 0
    assert_equals '{"preset":"fast","input":"hi","max_output_tokens":1,"max_tool_calls":0}' \
        "$(jq -c . "$WORK_DIR/probe-payload.txt")" "probe payload" || return 0
    test_pass
}

test_presets_keep_their_tools() {
    test_case "bare presets retain the configured preset and its provider-managed tools"
    local preset
    for preset in fast low medium high xhigh; do
        run_ppx "$preset" "$WORK_DIR/reply-annotated.json"
        assert_equals "$preset" "$(jq -r .preset "$WORK_DIR/payload.json")" "preset mapping" || return 0
        assert_equals "null" "$(jq -c .tools "$WORK_DIR/payload.json")" "preset tools are inherited" || return 0
    done
    test_pass
}

test_rejects_unfinished_and_invalid_responses_before_write() {
    local variant
    for variant in failed incomplete cancelled in_progress queued failed-error completed-error missing-status malformed missing-output empty-output nonarray-output nonstring-text empty-text; do
        test_case "$variant response cannot overwrite a saved result"
        case "$variant" in
            failed|incomplete|cancelled|in_progress|queued)
                jq --arg status "$variant" '.status = $status' "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-invalid.json" ;;
            failed-error) jq '.status = "failed" | .error = {message: "Generation stopped", type: "server_error"}' "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-invalid.json" ;;
            completed-error) jq '.error = {message: "Generation stopped", type: "server_error"}' "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-invalid.json" ;;
            missing-status) jq 'del(.status)' "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-invalid.json" ;;
            malformed) printf '{"status":"completed",' > "$WORK_DIR/reply-invalid.json" ;;
            missing-output) jq 'del(.output)' "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-invalid.json" ;;
            empty-output) jq '.output = []' "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-invalid.json" ;;
            nonarray-output) jq '.output = {message: "bad shape"}' "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-invalid.json" ;;
            nonstring-text) jq '.output[1].content[0].text = 42' "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-invalid.json" ;;
            empty-text) jq '.output[1].content[0].text = ""' "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-invalid.json" ;;
        esac
        printf 'saved sentinel\n' > "$WORK_DIR/saved.txt"
        run_ppx fast "$WORK_DIR/reply-invalid.json" "$WORK_DIR/saved.txt"
        assert_not_equals "0" "$(cat "$WORK_DIR/rc.txt")" "exit status" &&
        assert_equals "saved sentinel" "$(cat "$WORK_DIR/saved.txt")" "saved output survives" && test_pass
    done
}

test_completed_response_saves_output() {
    test_case "a completed response with null error writes its typed text"
    printf 'saved sentinel\n' > "$WORK_DIR/saved.txt"
    run_ppx fast "$WORK_DIR/reply-annotated.json" "$WORK_DIR/saved.txt"
    assert_equals "0" "$(cat "$WORK_DIR/rc.txt")" "exit status" &&
    assert_contains "$(cat "$WORK_DIR/saved.txt")" "B supports this claim.[2]" "answer saved" &&
    assert_contains "$(cat "$WORK_DIR/saved.txt")" "**Sources:**" "sources saved" && test_pass
}

test_partial_quota_failure_marks_provider_dead() {
    test_case "partial text cannot hide a terminal quota error"
    jq -c '.status = "failed" | .error = {message: "No quota left", type: "insufficient_quota", code: 401}' "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-quota.json"
    printf 'saved sentinel\n' > "$WORK_DIR/saved.txt"
    run_ppx fast "$WORK_DIR/reply-quota.json" "$WORK_DIR/saved.txt"
    assert_not_equals "0" "$(cat "$WORK_DIR/rc.txt")" "exit status" &&
    assert_equals "saved sentinel" "$(cat "$WORK_DIR/saved.txt")" "saved output survives" &&
    assert_equals "perplexity" "$(cat "$WORK_DIR/quota-dead" 2>/dev/null)" "provider marked dead" &&
    assert_contains "$(cat "$WORK_DIR/log.txt")" "TerminalQuotaError" "quota error logged" && test_pass
}

test_source_typed_and_noncontiguous_ids() {
    test_case "source-typed markers keep noncontiguous search-result IDs"
    jq '.output[0].results[0].id = 4 | .output[0].results[1].id = 9 | .output[1].content[0].text = "B.[web:9] A.[web:4]"' "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-typed.json"
    run_ppx high "$WORK_DIR/reply-typed.json"
    local out; out=$(cat "$WORK_DIR/out.txt")
    assert_contains "$out" "B.[web:9] A.[web:4]" "answer markers preserved" &&
    assert_contains "$out" "[web:4] https://example.com/search-a" "A source label" &&
    assert_contains "$out" "[web:9] https://example.com/search-b" "B source label" &&
    assert_not_contains "$out" "[1]" "no invented consecutive ID" && test_pass
}

test_annotation_urls_without_result_ids_are_unnumbered() {
    local variant
    for variant in absent invalid; do
        test_case "annotation URLs with $variant result IDs stay unnumbered"
        if [[ "$variant" == absent ]]; then
            jq 'del(.output[0])' "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-urls.json"
        else
            jq '.output[0].results[0].id = "source_a" | .output[0].results[1].id = null' "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-urls.json"
        fi
        run_ppx fast "$WORK_DIR/reply-urls.json"
        local out; out=$(cat "$WORK_DIR/out.txt")
        assert_contains "$out" "**Sources:**" "Sources header" &&
        assert_contains "$out" "- https://example.com/search-a" "A URL" &&
        assert_contains "$out" "- https://example.com/search-b" "B URL" &&
        assert_not_contains "$out" "[1] https://" "no invented numbered source" && test_pass
    done
}

test_answer_text_stays_off_jq_argv() {
    test_case "generated answer text reaches jq through stdin rather than process arguments"
    jq '.output[1].content[0].text = "INERT_PRIVATE_ANSWER_MARKER.[2]"' "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-private.json"
    run_ppx fast "$WORK_DIR/reply-private.json"
    assert_equals "0" "$(cat "$WORK_DIR/rc.txt")" "exit status" || return 0
    assert_contains "$(cat "$WORK_DIR/out.txt")" "INERT_PRIVATE_ANSWER_MARKER.[2]" "answer consumed" || return 0
    if [[ ! -s "$WORK_DIR/jq-argv" ]]; then
        test_fail "the executable jq wrapper did not record any arguments"
    elif grep -Fq 'INERT_PRIVATE_ANSWER_MARKER' "$WORK_DIR/jq-argv"; then
        test_fail "generated answer text appeared in jq process arguments"
    else
        test_pass
    fi
}

test_large_completed_answer_keeps_sources() {
    test_case "a completed answer above the platform argument limit retains Sources"
    local answer_bytes
    if [[ "$(uname -s)" == Darwin ]]; then
        answer_bytes=$(( $(getconf ARG_MAX) + 8192 ))
    else
        answer_bytes=$(( 32 * $(getconf PAGESIZE) + 8192 ))
    fi
    jq ".output[1].content[0].text = ((\"x\" * $answer_bytes) + \".[web:2]\")" "$WORK_DIR/reply-annotated.json" > "$WORK_DIR/reply-large.json"
    run_ppx high "$WORK_DIR/reply-large.json" "$WORK_DIR/saved-large.txt"
    assert_equals "0" "$(cat "$WORK_DIR/rc.txt")" "exit status" || return 0
    if [[ "$(wc -c < "$WORK_DIR/saved-large.txt")" -le "$answer_bytes" ]]; then
        test_fail "the large completed answer was truncated"
    elif ! grep -Fq '**Sources:**' "$WORK_DIR/saved-large.txt" \
        || ! grep -Fqx '[web:2] https://example.com/search-b' "$WORK_DIR/saved-large.txt"; then
        test_fail "the large answer lost its Sources footer or source ID"
    else
        test_pass
    fi
}

test_posts_to_agent_endpoint || true
test_sonar_pro_maps_to_fast_preset || true
test_legacy_ids_follow_migration_guide || true
test_explicit_model_adds_web_search_tool || true
test_prompt_is_json_escaped || true
test_presets_keep_their_tools || true
test_rejects_unfinished_and_invalid_responses_before_write || true
test_completed_response_saves_output || true
test_partial_quota_failure_marks_provider_dead || true
test_source_typed_and_noncontiguous_ids || true
test_annotation_urls_without_result_ids_are_unnumbered || true
test_answer_text_stays_off_jq_argv || true
test_large_completed_answer_keeps_sources || true
test_reads_text_and_cited_sources || true
test_falls_back_to_search_results || true
test_error_body_fails || true
test_legacy_chat_shape_is_not_success || true
test_unknown_model_refused_before_request || true
test_quota_probe_uses_agent_endpoint || true

rm -rf "$WORK_DIR"
test_summary || true

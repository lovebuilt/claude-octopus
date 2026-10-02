#!/usr/bin/env bash
# tests/unit/test-perplexity-agent-api.sh
# perplexity_execute talks to the Perplexity Agent API (POST /v1/agent).
# Perplexity ended Sonar chat completions support on 2026-09-27; the old
# /chat/completions path answers HTTP 403. These tests stub curl, so they never
# reach the network and need no key.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers/test-framework.sh"

test_suite "Perplexity Agent API request and response handling"

WORK_DIR="$(mktemp -d)"

# Runs perplexity_execute in a clean subshell with curl replaced by a stub that
# records the URL and the -d payload, then prints the fixture file as the body.
# Usage: run_ppx <model> <fixture-file>; leaves url.txt, payload.json, out.txt, rc.txt
run_ppx() {
    local model="$1" fixture="$2"
    rm -f "$WORK_DIR"/{url.txt,payload.json,out.txt,rc.txt,curl-called}
    (
        export PERPLEXITY_API_KEY="test-key-not-real"
        VERBOSE=false
        log() { :; }
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
        perplexity_execute "$model" "What changed in AI agents this week?" > "$WORK_DIR/out.txt" 2>/dev/null || rc=$?
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
    {"type":"output_text","text":"Agents gained long-running tools.","annotations":[
      {"type":"url_citation","url":"https://example.com/cited-1","title":"One","start_index":0,"end_index":6},
      {"type":"url_citation","url":"https://example.com/cited-2","title":"Two","start_index":7,"end_index":12},
      {"type":"url_citation","url":"https://example.com/cited-1","title":"One again","start_index":13,"end_index":20}]}]}],
 "usage":{"input_tokens":120,"output_tokens":9,"cost":{"total_cost":0.00141,"currency":"USD"}}}
JSON

cat > "$WORK_DIR/reply-search-only.json" <<'JSON'
{"status":"completed","error":null,
 "output":[
  {"type":"search_results","queries":["q"],"results":[
    {"id":1,"url":"https://example.com/search-a"},
    {"id":2,"url":"https://example.com/search-b"},
    {"id":3,"url":"https://example.com/search-a"}]},
  {"type":"message","role":"assistant","content":[{"type":"output_text","text":"PONG","annotations":[]}]}]}
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
    assert_contains "$out" "Agents gained long-running tools." "answer text" &&
    assert_contains "$out" "[1] https://example.com/cited-1" "first citation" &&
    assert_contains "$out" "[2] https://example.com/cited-2" "second citation" &&
    assert_not_contains "$out" "[3]" "duplicate citation removed" &&
    assert_not_contains "$out" "search-a" "search results not listed when the text cites sources" && test_pass
}

test_falls_back_to_search_results() {
    test_case "with no annotations, sources are the de-duplicated search_results URLs"
    run_ppx fast "$WORK_DIR/reply-search-only.json"
    local out; out=$(cat "$WORK_DIR/out.txt")
    assert_contains "$out" "PONG" "answer text" &&
    assert_contains "$out" "[1] https://example.com/search-a" "first source" &&
    assert_contains "$out" "[2] https://example.com/search-b" "second source" &&
    assert_not_contains "$out" "[3]" "duplicate source removed" && test_pass
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
    local qw="$PROJECT_ROOT/scripts/lib/quota-watcher.sh"
    if grep -q 'https://api.perplexity.ai/v1/agent' "$qw" \
        && grep -q '"max_tool_calls":0' "$qw" \
        && ! grep -q 'api.perplexity.ai/chat/completions' "$qw"; then
        test_pass
    else
        test_fail "quota-watcher.sh perplexity probe is not on the Agent API"
    fi
}

test_posts_to_agent_endpoint || true
test_sonar_pro_maps_to_fast_preset || true
test_legacy_ids_follow_migration_guide || true
test_explicit_model_adds_web_search_tool || true
test_prompt_is_json_escaped || true
test_reads_text_and_cited_sources || true
test_falls_back_to_search_results || true
test_error_body_fails || true
test_legacy_chat_shape_is_not_success || true
test_unknown_model_refused_before_request || true
test_quota_probe_uses_agent_endpoint || true

rm -rf "$WORK_DIR"
test_summary || true

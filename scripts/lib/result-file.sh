#!/usr/bin/env bash
# Shared result-file framing helpers.

# Length-prefix the exact dispatched prompt so prompt content can contain any
# Markdown heading, including the legacy `# Started:` delimiter.
write_agent_result_prompt() {
    local result_file="$1"
    local prompt="$2"
    local prompt_bytes
    local LC_ALL=C
    prompt_bytes=${#prompt}
    [[ "$prompt_bytes" =~ ^[0-9]+$ ]] || return 1
    printf '# Prompt-Format: octopus-length-v1\n' >> "$result_file" || return 1
    printf '# Prompt-Bytes: %s\n' "$prompt_bytes" >> "$result_file" || return 1
    printf '%s\n' "$prompt" >> "$result_file"
}

# Read launcher-owned sections after the exact dispatched-prompt byte frame.
# Return 2 for legacy files so callers can keep their compatibility parser.
# In failure mode, preserve prompt lines for echoed-text filtering and quote
# provider headings so they cannot become section delimiters in the selector.
# Status mode accepts the first outer terminal status after complete Output.
octo_result_framed_sections() {
    local result_file="$1" mode="${2:-output}"
    LC_ALL=C awk -v mode="$mode" '
        BEGIN { status_mode=(mode == "status" || mode == "launcher-status") }
        function append(value, line) { return value (value == "" ? "" : "\n") line }
        function own_header(line) {
            return line ~ /^## (Status|Contract Status):/ ||
                   line ~ /^## (Errors|Warnings\/Errors|Native Metrics|Runtime Identity|Error Log)$/ ||
                   line ~ /^## Raw Output/
        }
        !framed && /^# Prompt: / { exit }
        !framed && /^# Started:/ { exit }
        !framed && /^## Output$/ { exit }
        !framed && /^# Prompt-Format:/ {
            if ($0 != "# Prompt-Format: octopus-length-v1") { invalid=1; exit }
            framed=1
            if (getline <= 0 || $0 !~ /^# Prompt-Bytes: [0-9]+$/) { invalid=1; exit }
            remaining=$3+1
            next
        }
        !framed && /^# Agent: / { agent=$0; sub(/^# Agent: /, "", agent); next }
        !framed { next }
        remaining > 0 {
            if (mode == "failure") prompt=append(prompt, "# Dispatched-Prompt-Line: " $0)
            remaining -= length($0)+1
            if (remaining < 0) { invalid=1; exit }
            next
        }
        !started {
            if ($0 ~ /^# Started:/) started=1
            else if ($0 !~ /^[[:space:]]*$/) { invalid=1; exit }
            next
        }
        expect_output && $0 != "## Output" { invalid=1; exit }
        !seen_output && /^<!-- BEGIN-UNTRUSTED:/ {
            if (end_marker != "" || $0 !~ /^<!-- BEGIN-UNTRUSTED:provider=.+:nonce=[0-9a-f]+ -->$/) { invalid=1; exit }
            nonce=$0
            sub(/^.*:nonce=/, "", nonce)
            sub(/ -->$/, "", nonce)
            if (length(nonce) != 16 && length(nonce) != 32) { invalid=1; exit }
            if (agent != "" && index($0, "<!-- BEGIN-UNTRUSTED:provider=" agent ":nonce=") != 1) { invalid=1; exit }
            expect_output=1
            stderr_begin=$0
            sub(/:nonce=/, ":stream=stderr:nonce=", stderr_begin)
            end_marker=$0
            sub(/BEGIN-UNTRUSTED/, "END-UNTRUSTED", end_marker)
            next
        }
        !seen_output && /^## Output$/ { expect_output=0; seen_output=1; section="output"; next }
        section == "output" && end_marker != "" {
            if ($0 == end_marker) { nonce_closed=1; output_done=1; section=""; next }
            if (!status_mode) output=append(output, $0)
            next
        }
        status_mode && section == "output" && end_marker == "" {
            if (!output_fence && !output_done && $0 == "```") { output_fence=1; next }
            if (output_fence) {
                if ($0 == "```") { output_fence=0; output_done=1; section="" }
                next
            }
            if (own_header($0)) { output_done=1; section="" }
            else next
        }
        stderr_end != "" {
            if ($0 == stderr_end) { stderr_end=""; section=""; next }
            if (!status_mode && section == "error") errors=append(errors, $0)
            next
        }
        section != "output" && /^<!-- BEGIN-UNTRUSTED:.*:stream=/ {
            stream=$0
            sub(/^.*:stream=/, "", stream)
            sub(/:nonce=.*$/, "", stream)
            expected_begin=stderr_begin
            sub(/:stream=stderr:/, ":stream=" stream ":", expected_begin)
            if (!nonce_closed || $0 != expected_begin || stream !~ /^(stderr|metrics|raw)$/) { invalid=1; exit }
            stderr_pending=0
            metrics_pending=0
            raw_pending=0
            stderr_end=$0
            sub(/BEGIN-UNTRUSTED/, "END-UNTRUSTED", stderr_end)
            next
        }
        status_mode && seen_output && section != "output" {
            if (stderr_fence) {
                if ($0 == "```") { stderr_fence=0; section="" }
                next
            }
            if (stderr_pending) {
                if ($0 == "```") { stderr_fence=1; stderr_pending=0 }
                next
            }
            if (metrics_open) {
                if ($0 ~ /<\/usage>/) metrics_open=0
                next
            }
            if (metrics_pending) {
                if ($0 ~ /<usage>/) { metrics_open=($0 !~ /<\/usage>/); metrics_pending=0 }
                next
            }
            if (raw_pending) {
                if ($0 == "```") { stderr_fence=1; raw_pending=0 }
                next
            }
            if ($0 == "## Native Metrics") { metrics_pending=1; next }
            if ($0 ~ /^## Raw Output/) { raw_pending=1; next }
            if ($0 ~ /^## (Error Log|Warnings\/Errors|Errors)$/) { stderr_pending=1; next }
            if (status == "" && output_done &&
                ($0 ~ /^## Status: (SUCCESS|FAILED|TIMEOUT)([[:space:](]|$)/ ||
                 (mode == "launcher-status" && $0 ~ /^## Status: (STALLED|CANCELLED|ERROR)([[:space:](]|$)/))) status=$0
            next
        }
        section == "output" && own_header($0) { section="" }
        /^## Error Log$/ && section != "error" { section="error"; next }
        section == "error" && own_header($0) && $0 !~ /^## Error Log$/ { section=""; next }
        section == "output" { output=append(output, $0); next }
        section == "error" { errors=append(errors, $0) }
        END {
            if (invalid) exit 1
            if (!framed) exit 2
            if (invalid || remaining != 0 || !started || !seen_output || (end_marker != "" && !nonce_closed)) exit 1
            if (status_mode) {
                if (!output_done || output_fence || stderr_fence || stderr_pending || metrics_pending || metrics_open || raw_pending || stderr_end != "" || status == "") exit 1
                print status
            } else if (mode == "failure") {
                if (prompt != "") print prompt
                print "## Output"
                n=split(output, lines, "\n")
                for (i=1; i<=n; i++) print (lines[i] ~ /^## / ? " " : "") lines[i]
                print "## Error Log"
                n=split(errors, lines, "\n")
                for (i=1; i<=n; i++) print (lines[i] ~ /^## / ? " " : "") lines[i]
            } else {
                n=split(output, lines, "\n")
                for (i=1; i<=n; i++) if (lines[i] !~ /^```(json|JSON)?$/) print lines[i]
            }
        }
    ' "$result_file" 2>/dev/null
}

# Current artifacts use launcher boundaries. Legacy artifacts retain last-status
# selection so appended retries and historical result files keep their behavior.
octo_result_launcher_status() {
    local result_file="$1" framed_rc=0
    [[ -f "$result_file" ]] || return 1
    octo_result_framed_sections "$result_file" launcher-status && return 0 || framed_rc=$?
    [[ "$framed_rc" -eq 2 ]] || return 1
    awk '
        /^## Status: / { status=$0 }
        END { if (status != "") print status; else exit 1 }
    ' "$result_file" 2>/dev/null
}

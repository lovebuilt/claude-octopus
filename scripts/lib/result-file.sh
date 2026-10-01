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
octo_result_framed_sections() {
    local result_file="$1" mode="${2:-output}"
    LC_ALL=C awk -v mode="$mode" '
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
        !framed { next }
        remaining > 0 {
            prompt=append(prompt, "# Dispatched-Prompt-Line: " $0)
            remaining -= length($0)+1
            if (remaining < 0) { invalid=1; exit }
            next
        }
        !started {
            if ($0 ~ /^# Started:/) started=1
            else if ($0 !~ /^[[:space:]]*$/) { invalid=1; exit }
            next
        }
        !seen_output && /^<!-- BEGIN-UNTRUSTED:/ {
            end_marker=$0
            sub(/BEGIN-UNTRUSTED/, "END-UNTRUSTED", end_marker)
            next
        }
        !seen_output && /^## Output$/ { seen_output=1; section="output"; next }
        section == "output" && end_marker != "" {
            if ($0 == end_marker) { nonce_closed=1; section=""; next }
            output=append(output, $0)
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
            if (mode == "failure") {
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

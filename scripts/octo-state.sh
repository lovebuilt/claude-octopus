#!/usr/bin/env bash
# Project-level state management for Claude Octopus
# Manages .octo/ directory with STATE.md, PROJECT.md, ROADMAP.md, etc.

set -eo pipefail

# Configuration
OCTO_DIR=".octo"
STATE_FILE="$OCTO_DIR/STATE.md"
PROJECT_FILE="$OCTO_DIR/PROJECT.md"
ROADMAP_FILE="$OCTO_DIR/ROADMAP.md"
CONFIG_FILE="$OCTO_DIR/config.json"
ISSUES_FILE="$OCTO_DIR/ISSUES.md"
LESSONS_FILE="$OCTO_DIR/LESSONS.md"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Valid status values
VALID_STATUSES="ready planned planning building in_progress complete complete_with_gaps shipped blocked paused"

# Valid context tiers
VALID_TIERS="minimal planning execution brownfield full auto"

# Keep project-section updates well below platform command and memory limits.
MAX_PROJECT_SECTION_BYTES=1048576

# ═══════════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
    exit 1
}

warning() {
    echo -e "${YELLOW}WARNING:${NC} $1" >&2
}

success() {
    echo -e "${GREEN}SUCCESS:${NC} $1"
}

info() {
    echo -e "${BLUE}INFO:${NC} $1"
}

# Validate phase is an integer >= 1
validate_phase() {
    local phase="$1"
    if ! [[ "$phase" =~ ^[0-9]+$ ]] || [[ "$phase" -lt 1 ]]; then
        error "Phase must be a positive integer (got: '$phase')"
    fi
}

# Validate status is in enum
validate_status() {
    local status="$1"
    local found=false
    for valid in $VALID_STATUSES; do
        if [[ "$status" == "$valid" ]]; then
            found=true
            break
        fi
    done
    if [[ "$found" != "true" ]]; then
        error "Invalid status '$status'. Valid values: $VALID_STATUSES"
    fi
}

# Validate tier is in enum
validate_tier() {
    local tier="$1"
    local found=false
    for valid in $VALID_TIERS; do
        if [[ "$tier" == "$valid" ]]; then
            found=true
            break
        fi
    done
    if [[ "$found" != "true" ]]; then
        error "Invalid tier '$tier'. Valid values: $VALID_TIERS"
    fi
}

# Get current timestamp in ISO 8601 format
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Fold a free-text value onto one line. STATE.md keeps one record per line, so a
# newline in a position, blocker or history note would split a record and could
# forge another one.
single_line() {
    local value="$1"
    value="${value//$'\r'/ }"
    printf '%s' "${value//$'\n'/ }"
}

# Print the value of the first "**<label>:** value" line in STATE.md, or nothing.
# awk reads the whole file itself: a grep | sed | head pipeline under pipefail
# exits silently when the line is missing, and can fail on SIGPIPE when it is not.
state_field() {
    [[ -f "$STATE_FILE" ]] || return 0
    awk -v label="**$1:** " 'index($0, label) == 1 { print substr($0, length(label) + 1); exit }' "$STATE_FILE"
}

# write_state rewrites STATE.md from its header lines. Refuse to write when one is
# missing or repeated: filling in a default would overwrite the recorded phase or
# status with a guess, and a repeated line means the file was damaged or edited.
require_state_fields() {
    local label count
    for label in "Current Phase" "Current Position" "Status"; do
        count=$(awk -v label="**$label:** " 'index($0, label) == 1 { n++ } END { print n + 0 }' "$STATE_FILE")
        if [[ "$count" -eq 0 ]]; then
            error "STATE.md has no '**$label:**' line; nothing was written: $STATE_FILE"
        elif [[ "$count" -gt 1 ]]; then
            error "STATE.md has $count '**$label:**' lines; nothing was written: $STATE_FILE"
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# ATOMIC WRITE
# ═══════════════════════════════════════════════════════════════════════════════

atomic_write() {
    local target_file="$1"
    local content="$2"
    local temp_file="${target_file}.tmp.$$"
    
    # Ensure directory exists
    mkdir -p "$(dirname "$target_file")"
    
    # Write to temp file
    echo "$content" > "$temp_file"
    
    # Verify temp file was written
    if [[ ! -f "$temp_file" ]]; then
        error "Failed to write temporary file"
    fi
    
    # Atomic move
    mv "$temp_file" "$target_file"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEMPLATE FILES
# ═══════════════════════════════════════════════════════════════════════════════

generate_state_template() {
    local timestamp
    timestamp=$(get_timestamp)
    cat <<EOF
# Octo State

**Schema:** 2.0
**Last Updated:** $timestamp
**Current Phase:** 1
**Current Position:** Project initialized
**Status:** ready

## Blockers

(none)

## History

- [$timestamp] Phase 1 (ready): Project initialized
EOF
}

generate_project_template() {
    cat <<EOF
# Project

## Vision

(Describe the project's purpose and goals)

## Requirements

### Functional Requirements

- [ ] Requirement 1
- [ ] Requirement 2

### Non-Functional Requirements

- [ ] Performance targets
- [ ] Security requirements

## Constraints

- Timeline: (specify)
- Resources: (specify)
- Technical: (specify)

## Decisions

| Date | Decision | Rationale | Impact |
|------|----------|-----------|--------|
| | | | |
EOF
}

generate_roadmap_template() {
    cat <<EOF
# Roadmap

## Overview

Total Phases: 1
Current Phase: 1

## Phase 1: Initial Setup

**Status:** ready
**Success Criteria:**
- [ ] Criterion 1
- [ ] Criterion 2

**Dependencies:** None

**Plans:**
(To be defined)

## Milestone Deliverables

- [ ] Deliverable 1
- [ ] Deliverable 2
EOF
}

generate_config_template() {
    local timestamp
    timestamp=$(get_timestamp)
    cat <<EOF
{
  "interaction_mode": "interactive",
  "git_strategy": "per_task",
  "review_depth": "detailed",
  "security_audit": true,
  "simplification_review": true,
  "iac_validation": "auto",
  "documentation_generation": true,
  "codebase_docs_path": ".octo/codebase",
  "model_routing": {
    "validation": "haiku",
    "building": "sonnet",
    "planning": "sonnet",
    "architecture": "opus",
    "debugging": "opus",
    "review": "sonnet",
    "security_audit": "sonnet"
  },
  "context_tier": "auto",
  "created_at": "$timestamp",
  "version": "1.0"
}
EOF
}

generate_issues_template() {
    cat <<EOF
# Issues

## Active

(none)

## Resolved

(none)
EOF
}

generate_lessons_template() {
    cat <<EOF
# Lessons Learned

## Technical

(none yet)

## Process

(none yet)

## Architecture

(none yet)
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# INIT_PROJECT
# ═══════════════════════════════════════════════════════════════════════════════

init_project() {
    local dry_run=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=true
                shift
                ;;
            *)
                error "Unknown argument: $1"
                ;;
        esac
    done
    
    if [[ "$dry_run" == "true" ]]; then
        echo "DRY RUN: Would create the following structure:"
        echo ""
        echo "$OCTO_DIR/"
        echo "├── STATE.md        # Current session position, status, history"
        echo "├── PROJECT.md      # Project vision, requirements, constraints"
        echo "├── ROADMAP.md      # Phase structure, success criteria, dependencies"
        echo "├── config.json     # Configuration (interaction mode, git strategy, etc.)"
        echo "├── ISSUES.md       # Active and resolved issues"
        echo "├── LESSONS.md      # Lessons learned"
        echo "├── phases/         # Phase-specific plans and summaries"
        echo "└── codebase/       # Codebase analysis (brownfield projects)"
        echo ""
        echo "To create: ./octo-state.sh init_project"
        return 0
    fi
    
    # Check if already initialized
    if [[ -d "$OCTO_DIR" ]]; then
        if [[ -f "$STATE_FILE" ]]; then
            warning ".octo/ directory already exists. Use 'read_state' to view current state."
            return 0
        fi
    fi
    
    # Create directory structure
    mkdir -p "$OCTO_DIR"
    mkdir -p "$OCTO_DIR/phases"
    mkdir -p "$OCTO_DIR/codebase"
    
    # Generate template files
    atomic_write "$STATE_FILE" "$(generate_state_template)"
    atomic_write "$PROJECT_FILE" "$(generate_project_template)"
    atomic_write "$ROADMAP_FILE" "$(generate_roadmap_template)"
    atomic_write "$CONFIG_FILE" "$(generate_config_template)"
    atomic_write "$ISSUES_FILE" "$(generate_issues_template)"
    atomic_write "$LESSONS_FILE" "$(generate_lessons_template)"
    
    success "Initialized .octo/ directory with template files"
    echo ""
    echo "Next steps:"
    echo "  1. Edit $PROJECT_FILE with your project vision and requirements"
    echo "  2. Edit $ROADMAP_FILE with your phase breakdown"
    echo "  3. Run 'octo-state.sh read_state' to view current state"
}

# Replace one top-level PROJECT.md section from a bounded file input.
# File input avoids ARG_MAX failures and preserves multiline synthesis content.
update_project() {
    local section=""
    local content_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --section)
                [[ $# -ge 2 ]] || error "--section requires a value"
                section="$2"
                shift 2
                ;;
            --content-file)
                [[ $# -ge 2 ]] || error "--content-file requires a path"
                content_file="$2"
                shift 2
                ;;
            *)
                error "Unknown update_project option: $1"
                ;;
        esac
    done

    local heading
    case "$section" in
        vision)       heading="## Vision" ;;
        requirements) heading="## Requirements" ;;
        constraints)  heading="## Constraints" ;;
        decisions)    heading="## Decisions" ;;
        *) error "Unsupported project section '$section'. Valid sections: vision requirements constraints decisions" ;;
    esac

    [[ -f "$PROJECT_FILE" ]] || error "Project file not found. Run 'init_project' first."
    [[ -f "$content_file" && -r "$content_file" ]] || error "Content file is missing or unreadable: $content_file"
    [[ -s "$content_file" ]] || error "Content file is empty: $content_file"

    local content_bytes
    content_bytes=$(LC_ALL=C wc -c < "$content_file")
    content_bytes=${content_bytes//[[:space:]]/}
    if [[ "$content_bytes" -gt "$MAX_PROJECT_SECTION_BYTES" ]]; then
        error "Content file exceeds ${MAX_PROJECT_SECTION_BYTES} bytes: $content_file"
    fi

    local temp_file
    if ! temp_file=$(mktemp "${PROJECT_FILE}.tmp.XXXXXX"); then
        error "Failed to allocate temporary project file"
    fi
    if ! awk -v heading="$heading" -v content_file="$content_file" '
        BEGIN {
            while ((getline content_line < content_file) > 0) {
                content = content content_line "\n"
            }
            close(content_file)
        }
        $0 == heading {
            print
            printf "%s\n", content
            replacing = 1
            found = 1
            next
        }
        replacing && /^## / { replacing = 0 }
        !replacing { print }
        END { if (!found) exit 42 }
    ' "$PROJECT_FILE" > "$temp_file"; then
        rm -f "$temp_file"
        error "Project section not found: $heading"
    fi

    if [[ ! -s "$temp_file" ]]; then
        rm -f "$temp_file"
        error "Failed to write updated project file"
    fi
    if ! mv "$temp_file" "$PROJECT_FILE"; then
        rm -f "$temp_file"
        error "Failed to publish updated project file"
    fi
    success "Updated PROJECT.md section: $section"
}

# ═══════════════════════════════════════════════════════════════════════════════
# READ_STATE
# ═══════════════════════════════════════════════════════════════════════════════

read_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        error "State file not found. Run 'init_project' first."
    fi
    
    # Parse STATE.md fields
    local schema last_updated current_phase current_position status
    
    schema=$(grep -E "^\*\*Schema:\*\*" "$STATE_FILE" | sed 's/\*\*Schema:\*\* //' || echo "unknown")
    last_updated=$(grep -E "^\*\*Last Updated:\*\*" "$STATE_FILE" | sed 's/\*\*Last Updated:\*\* //' || echo "unknown")
    current_phase=$(grep -E "^\*\*Current Phase:\*\*" "$STATE_FILE" | sed 's/\*\*Current Phase:\*\* //' || echo "0")
    current_position=$(grep -E "^\*\*Current Position:\*\*" "$STATE_FILE" | sed 's/\*\*Current Position:\*\* //' || echo "unknown")
    status=$(grep -E "^\*\*Status:\*\*" "$STATE_FILE" | sed 's/\*\*Status:\*\* //' || echo "unknown")
    
    # Output as simple key=value pairs for easy parsing
    echo "schema=$schema"
    echo "last_updated=$last_updated"
    echo "current_phase=$current_phase"
    echo "current_position=$current_position"
    echo "status=$status"
}

# ═══════════════════════════════════════════════════════════════════════════════
# WRITE_STATE
# ═══════════════════════════════════════════════════════════════════════════════

write_state() {
    local phase=""
    local position=""
    local status=""
    local blocker=""
    local history_note=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --phase|--position|--status|--blocker|--history)
                [[ $# -ge 2 ]] || error "$1 requires a value"
                ;;
        esac
        case "$1" in
            --phase)
                phase="$2"
                shift 2
                ;;
            --position)
                position="$(single_line "$2")"
                shift 2
                ;;
            --status)
                status="$2"
                shift 2
                ;;
            --blocker)
                blocker="$(single_line "$2")"
                shift 2
                ;;
            --history)
                history_note="$(single_line "$2")"
                shift 2
                ;;
            *)
                error "Unknown argument: $1"
                ;;
        esac
    done
    
    if [[ ! -f "$STATE_FILE" ]]; then
        error "State file not found. Run 'init_project' first."
    fi
    
    # Read current state; a missing or repeated header line stops here, before any write.
    require_state_fields
    local current_schema current_phase_val current_position_val current_status
    current_schema=$(state_field "Schema")
    current_schema="${current_schema:-2.0}"
    current_phase_val=$(state_field "Current Phase")
    current_position_val=$(state_field "Current Position")
    current_status=$(state_field "Status")
    
    # Extract existing history (everything after "## History")
    local history
    history=$(sed -n '/^## History/,$ p' "$STATE_FILE" | tail -n +2 || echo "")
    
    # Use provided values or keep current
    local new_phase="${phase:-$current_phase_val}"
    local new_position="${position:-$current_position_val}"
    local new_status="${status:-$current_status}"
    
    # Validate inputs
    validate_phase "$new_phase"
    validate_status "$new_status"
    
    local timestamp
    timestamp=$(get_timestamp)
    
    # Build blocker section
    local blocker_section="(none)"
    if [[ -n "$blocker" ]]; then
        blocker_section="- $blocker"
    fi
    
    # Build new history entry. The status sits in a fixed slot right after the phase
    # number, before any free text, so get_phase_status reads it from there only and
    # neither the position nor a note can stand in for it.
    local new_history_entry="- [$timestamp] Phase $new_phase ($new_status): $new_position"
    if [[ -n "$history_note" ]]; then
        new_history_entry="$new_history_entry: $history_note"
    fi
    
    # Generate new STATE.md content
    local new_content
    new_content=$(cat <<EOF
# Octo State

**Schema:** $current_schema
**Last Updated:** $timestamp
**Current Phase:** $new_phase
**Current Position:** $new_position
**Status:** $new_status

## Blockers

$blocker_section

## History

$new_history_entry
$history
EOF
)
    
    atomic_write "$STATE_FILE" "$new_content"
    success "Updated STATE.md (phase=$new_phase, status=$new_status)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# GET_PHASE_STATUS
# ═══════════════════════════════════════════════════════════════════════════════

# Prints the status recorded for phase N: the current status when N is the current
# phase, otherwise the status of the newest history record for N, otherwise
# "pending". Nothing is inferred from phase order: a phase that was skipped, or
# reopened and left blocked, reports what was recorded for it. The flow skills
# gate on this ("Discover phase not marked complete"). Read-only.
get_phase_status() {
    local phase="${1:-}"
    [[ -n "$phase" ]] || error "Phase number required. Usage: get_phase_status <phase>"
    validate_phase "$phase"
    if [[ ! -f "$STATE_FILE" ]]; then
        error "State file not found. Run 'init_project' first."
    fi
    local current current_status recorded
    current=$(state_field "Current Phase")
    [[ "$current" =~ ^[0-9]+$ ]] || error "STATE.md has no valid '**Current Phase:**' line: $STATE_FILE"
    if [[ $((10#$phase)) -eq $((10#$current)) ]]; then
        current_status=$(state_field "Status")
        [[ -n "$current_status" ]] || error "STATE.md has no '**Status:**' line: $STATE_FILE"
        echo "$current_status"
        return 0
    fi
    # History lines read "- [time] Phase N (status): position", optionally followed
    # by ": note", newest first (write_state prepends). The status is read only from
    # the slot right after "Phase N", so free text can never stand in for it. Lines
    # for phase N in any other form (records written before this format) are not
    # read; they are counted so the caller is told why the answer is "pending".
    local result unread
    result=$(awk -v want="$((10#$phase))" -v statuses="$VALID_STATUSES" '
        BEGIN { n = split(statuses, list, " "); for (i = 1; i <= n; i++) valid[list[i]] = 1 }
        /^## History/ { in_history = 1; next }
        in_history && /^## / { exit }
        !in_history || index($0, "- [") != 1 { next }
        {
            b = index($0, "]")
            if (b == 0 || substr($0, b, 8) != "] Phase ") next
            rest = substr($0, b + 8)
            d = 0
            while (d < length(rest) && substr(rest, d + 1, 1) ~ /[0-9]/) d++
            if (d == 0 || substr(rest, 1, d) + 0 != want + 0) next
            rest = substr(rest, d + 1)
            cl = index(rest, ")")
            if (substr(rest, 1, 2) == " (" && cl > 3) {
                status = substr(rest, 3, cl - 3)
                after = substr(rest, cl + 1)
                if ((status in valid) && (after == "" || substr(after, 1, 2) == ": ")) {
                    recorded = status
                    exit
                }
            }
            unread++
        }
        END {
            print (recorded == "" ? "pending" : recorded)
            print unread + 0
        }
    ' "$STATE_FILE")
    recorded="${result%%$'\n'*}"
    unread="${result#*$'\n'}"
    if [[ "$recorded" == "pending" && "$unread" != "0" ]]; then
        warning "Phase $phase has $unread history line(s) not in the 'Phase N (status): position' form; they were not read. Record the phase again to update its status."
    fi
    echo "$recorded"
}

# ═══════════════════════════════════════════════════════════════════════════════
# UPDATE_ROADMAP
# ═══════════════════════════════════════════════════════════════════════════════

# Records a phase's synthesis in ROADMAP.md: one dated line at the end of the
# "## Definitions" section (created at the end of the file when missing) naming
# the synthesis file, so the roadmap points at what was decided. It does not
# rewrite the roadmap's phases or success criteria.
update_roadmap() {
    local synthesis=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from-synthesis)
                [[ $# -ge 2 ]] || error "--from-synthesis requires a file"
                synthesis="$2"
                shift 2
                ;;
            *)
                error "Unknown argument: $1"
                ;;
        esac
    done
    [[ -n "$synthesis" ]] || error "Usage: update_roadmap --from-synthesis <file>"
    [[ -f "$synthesis" ]] || error "Synthesis file not found: $synthesis"
    if [[ ! -f "$ROADMAP_FILE" ]]; then
        error "Roadmap not found. Run 'init_project' first."
    fi
    local current entry temp_file
    current=$(state_field "Current Phase")
    [[ "$current" =~ ^[0-9]+$ ]] || current="?"
    entry="- [$(get_timestamp)] Phase $current synthesis: $(single_line "$synthesis")"
    if ! temp_file=$(mktemp "${ROADMAP_FILE}.tmp.XXXXXX"); then
        error "Failed to allocate temporary roadmap file"
    fi
    # The entry goes through the environment, not awk -v, which would expand
    # backslash escapes in the path and could split the line.
    if ! OCTO_ROADMAP_ENTRY="$entry" awk '
        { line[NR] = $0 }
        END {
            entry = ENVIRON["OCTO_ROADMAP_ENTRY"]
            for (i = 1; i <= NR; i++) if (line[i] ~ /^## Definitions[ \t]*$/) { start = i; break }
            if (!start) {
                for (i = 1; i <= NR; i++) print line[i]
                if (NR > 0 && line[NR] != "") print ""
                print "## Definitions"
                print ""
                print entry
                exit
            }
            stop = NR
            for (i = start + 1; i <= NR; i++) if (line[i] ~ /^## /) { stop = i - 1; break }
            last = stop
            while (last > start && line[last] ~ /^[ \t]*$/) last--
            for (i = 1; i <= last; i++) print line[i]
            if (last == start) print ""
            print entry
            for (i = last + 1; i <= NR; i++) print line[i]
        }
    ' "$ROADMAP_FILE" > "$temp_file" || ! mv "$temp_file" "$ROADMAP_FILE"; then
        rm -f "$temp_file"
        error "Failed to update $ROADMAP_FILE"
    fi
    success "Updated ROADMAP.md (synthesis recorded)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# UPDATE_PHASE
# ═══════════════════════════════════════════════════════════════════════════════

update_phase() {
    local phase="$1"
    local position="${2:-Phase $phase started}"
    local status="${3:-in_progress}"
    
    if [[ -z "$phase" ]]; then
        error "Phase number required. Usage: update_phase <phase> [position] [status]"
    fi
    
    validate_phase "$phase"
    validate_status "$status"
    
    write_state --phase "$phase" --position "$position" --status "$status"
}

# ═══════════════════════════════════════════════════════════════════════════════
# GET_CONTEXT_TIER
# ═══════════════════════════════════════════════════════════════════════════════

get_context_tier() {
    local tier="${1:-auto}"
    
    validate_tier "$tier"
    
    # If auto, determine tier from status
    if [[ "$tier" == "auto" ]]; then
        if [[ ! -f "$STATE_FILE" ]]; then
            tier="minimal"
        else
            local status
            status=$(grep -E "^\*\*Status:\*\*" "$STATE_FILE" | sed 's/\*\*Status:\*\* //' || echo "ready")
            
            case "$status" in
                ready|planned|planning|complete|shipped)
                    tier="planning"
                    ;;
                building|in_progress)
                    tier="execution"
                    ;;
                blocked|paused)
                    tier="execution"
                    ;;
                *)
                    tier="planning"
                    ;;
            esac
        fi
    fi
    
    echo "=== Context Tier: $tier ==="
    echo ""
    
    case "$tier" in
        minimal)
            # ~300 tokens: STATE.md only
            if [[ -f "$STATE_FILE" ]]; then
                echo "### STATE.md"
                cat "$STATE_FILE"
            else
                echo "(STATE.md not found)"
            fi
            ;;
        planning)
            # ~1200 tokens: STATE.md + PROJECT.md + ROADMAP.md (first 80 lines)
            if [[ -f "$STATE_FILE" ]]; then
                echo "### STATE.md"
                cat "$STATE_FILE"
                echo ""
            fi
            if [[ -f "$PROJECT_FILE" ]]; then
                echo "### PROJECT.md"
                cat "$PROJECT_FILE"
                echo ""
            fi
            if [[ -f "$ROADMAP_FILE" ]]; then
                echo "### ROADMAP.md (first 80 lines)"
                head -n 80 "$ROADMAP_FILE"
                echo ""
            fi
            ;;
        execution)
            # ~2000 tokens: planning + phase plans + recent summaries
            if [[ -f "$STATE_FILE" ]]; then
                echo "### STATE.md"
                cat "$STATE_FILE"
                echo ""
            fi
            if [[ -f "$PROJECT_FILE" ]]; then
                echo "### PROJECT.md"
                cat "$PROJECT_FILE"
                echo ""
            fi
            if [[ -f "$ROADMAP_FILE" ]]; then
                echo "### ROADMAP.md (first 80 lines)"
                head -n 80 "$ROADMAP_FILE"
                echo ""
            fi
            # Phase plans (first 50 lines each, max 3)
            local plan_count=0
            for plan in "$OCTO_DIR"/phases/phase-*-plan.md; do
                if [[ -f "$plan" ]] && [[ $plan_count -lt 3 ]]; then
                    echo "### $(basename "$plan") (first 50 lines)"
                    head -n 50 "$plan"
                    echo ""
                    ((plan_count++)) || true
                fi
            done
            # Recent summaries (first 30 lines each, max 3)
            local summary_count=0
            for summary in "$OCTO_DIR"/phases/phase-*-summary.md; do
                if [[ -f "$summary" ]] && [[ $summary_count -lt 3 ]]; then
                    echo "### $(basename "$summary") (first 30 lines)"
                    head -n 30 "$summary"
                    echo ""
                    ((summary_count++)) || true
                fi
            done
            ;;
        brownfield)
            # ~3500 tokens: execution + codebase analysis
            # First output execution tier
            get_context_tier "execution" 2>/dev/null | tail -n +3  # Skip header
            
            # Add codebase analysis
            for doc in STACK.md ARCHITECTURE.md CONVENTIONS.md CONCERNS.md; do
                if [[ -f "$OCTO_DIR/codebase/$doc" ]]; then
                    echo "### codebase/$doc (first 40 lines)"
                    head -n 40 "$OCTO_DIR/codebase/$doc"
                    echo ""
                fi
            done
            ;;
        full)
            # ~6000+ tokens: everything in .octo/
            echo "### Full Context (all .octo/ files)"
            echo ""
            for file in "$OCTO_DIR"/*.md "$OCTO_DIR"/*.json; do
                if [[ -f "$file" ]]; then
                    echo "#### $(basename "$file")"
                    cat "$file"
                    echo ""
                fi
            done
            # All phase plans and summaries
            for file in "$OCTO_DIR"/phases/*.md; do
                if [[ -f "$file" ]]; then
                    echo "#### phases/$(basename "$file")"
                    cat "$file"
                    echo ""
                fi
            done
            # All codebase docs
            for file in "$OCTO_DIR"/codebase/*.md; do
                if [[ -f "$file" ]]; then
                    echo "#### codebase/$(basename "$file")"
                    cat "$file"
                    echo ""
                fi
            done
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELP
# ═══════════════════════════════════════════════════════════════════════════════

show_help() {
    cat <<EOF
Octo State Manager - Project-level state management for Claude Octopus

Usage: octo-state.sh <command> [options]

Commands:
  init_project [--dry-run]           Initialize .octo/ directory with template files
                                     --dry-run: Show what would be created without making changes

  read_state                         Read and parse .octo/STATE.md
                                     Returns key=value pairs for easy scripting

  write_state [options]              Update .octo/STATE.md with atomic write
                                     --phase <N>        Set current phase (positive integer)
                                     --position <text>  Set current position description
                                     --status <status>  Set status (see valid values below)
                                     --blocker <text>   Set blocker description
                                     --history <text>   Add a note to this update's history line
                                     (update_state is the same command; the flow skills use that name)

  get_phase_status <N>               Print phase N's status: the current status for the current
                                     phase, else its newest history record, else "pending"

  update_roadmap --from-synthesis <file>
                                     Record a phase's synthesis file under "## Definitions"
                                     in ROADMAP.md

  update_project [options]           Replace one PROJECT.md section atomically
                                     --section <name>   vision, requirements, constraints, decisions
                                     --content-file <path>
                                                        Read at most 1 MiB from a file

  update_phase <phase> [position] [status]
                                     Shorthand for updating phase with position and status
                                     Defaults: position="Phase N started", status="in_progress"

  get_context_tier [tier]            Return context based on tier
                                     Tiers: minimal, planning, execution, brownfield, full, auto
                                     Default: auto (detects from status)

  help                               Show this help message

Valid Status Values:
  ready              - Phase initialized, ready to plan
  planned            - Phase decomposed into plans
  planning           - Planning in progress
  building           - Build in progress
  in_progress        - Execution in progress
  complete           - Phase complete, all gates passed
  complete_with_gaps - Phase complete but with known gaps
  shipped            - Milestone delivered
  blocked            - Workflow blocked by external issue
  paused             - Workflow paused by user

Context Tiers:
  minimal   (~300 tokens)   - STATE.md only
  planning  (~1200 tokens)  - + PROJECT.md + ROADMAP.md (first 80 lines)
  execution (~2000 tokens)  - + phase plans + recent summaries
  brownfield (~3500 tokens) - + codebase analysis
  full      (~6000+ tokens) - everything in .octo/
  auto      (default)       - detect from status field

Examples:
  octo-state.sh init_project --dry-run
  octo-state.sh init_project
  octo-state.sh read_state
  octo-state.sh write_state --phase 2 --status planning --position "Planning phase 2"
  octo-state.sh update_project --section vision --content-file /path/to/synthesis.md
  octo-state.sh update_phase 3 "Building authentication module" building
  octo-state.sh get_context_tier planning
  octo-state.sh get_context_tier auto
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        init_project)
            init_project "$@"
            ;;
        read_state)
            read_state
            ;;
        write_state|update_state)
            write_state "$@"
            ;;
        get_phase_status)
            get_phase_status "$@"
            ;;
        update_roadmap)
            update_roadmap "$@"
            ;;
        update_project)
            update_project "$@"
            ;;
        update_phase)
            update_phase "$@"
            ;;
        get_context_tier)
            get_context_tier "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $command. Run 'octo-state.sh help' for usage."
            ;;
    esac
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

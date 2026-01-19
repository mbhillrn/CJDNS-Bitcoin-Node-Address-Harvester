#!/usr/bin/env bash
# CJDNS Harvester v5 - UI and Color Definitions

# ============================================================================
# ANSI Color Palette - Consistent Theming
# ============================================================================
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'

# Semantic colors
C_SUCCESS='\033[38;5;120m'      # Bright green (connected, success)
C_WARNING='\033[38;5;214m'      # Orange (warnings)
C_ERROR='\033[38;5;203m'        # Bright red (errors, failures)
C_INFO='\033[38;5;111m'         # Light blue (info)
C_MUTED='\033[38;5;245m'        # Gray (already-seen, low priority)

# Section headers
C_HEADER='\033[1;36m'           # Bold cyan (section headers)
C_SUBHEADER='\033[38;5;147m'    # Purple-ish (subsections)

# Status indicators
C_NEW='\033[1;38;5;226m'        # Bright yellow (NEW addresses)
C_EXISTING='\033[38;5;250m'     # Light gray (existing addresses)
C_CONNECTED='\033[38;5;108m'    # Calm green (connected peer)
C_PENDING='\033[38;5;179m'      # Calm yellow (pending)

# Direction indicators
C_IN='\033[38;5;75m'            # Light blue (inbound)
C_OUT='\033[38;5;205m'          # Pink (outbound)

# Bandwidth indicators
C_DOWNLOAD='\033[38;5;117m'     # Light blue (download)
C_UPLOAD='\033[38;5;218m'       # Light pink (upload)

# ============================================================================
# Box Drawing Functions
# ============================================================================
print_box() {
    local title="$1"
    local width=72
    local title_len=${#title}
    local padding=$(( width - title_len - 2 ))  # -2 for spaces on both sides

    printf "\n${C_HEADER}"
    printf '╔'
    printf '═%.0s' $(seq 1 $width)
    printf '╗\n'
    printf '║ %s' "$title"
    printf '%*s' "$padding" ""
    printf ' ║\n'
    printf '╚'
    printf '═%.0s' $(seq 1 $width)
    printf '╝\n'
    printf "${C_RESET}\n"
}

print_section() {
    local title="$1"
    printf "\n${C_BOLD}${C_HEADER}▶ %s${C_RESET}\n" "$title"
}

print_subsection() {
    local title="$1"
    printf "\n${C_SUBHEADER}  ◆ %s${C_RESET}\n" "$title"
}

print_divider() {
    printf "${C_MUTED}%s${C_RESET}\n" "$(printf '─%.0s' $(seq 1 72))"
}

# Alias for compatibility
print_separator() {
    print_divider
}

# ============================================================================
# Status Display Functions
# ============================================================================
status_ok() {
    printf "${C_SUCCESS}✓${C_RESET} %s\n" "$1"
}

status_warn() {
    printf "${C_WARNING}⚠${C_RESET} %s\n" "$1"
}

status_error() {
    printf "${C_ERROR}✗${C_RESET} %s\n" "$1"
}

status_info() {
    printf "${C_INFO}ℹ${C_RESET} %s\n" "$1"
}

# ============================================================================
# Progress Indicators
# ============================================================================
show_progress() {
    printf "${C_DIM}%s...${C_RESET}" "$1"
}

show_progress_done() {
    printf "${C_SUCCESS} done${C_RESET}\n"
}

show_progress_fail() {
    printf "${C_ERROR} failed${C_RESET}\n"
}

# ============================================================================
# Peer Status Indicators
# ============================================================================
peer_in() {
    printf "${C_IN}IN ${C_RESET}"
}

peer_out() {
    printf "${C_OUT}OUT${C_RESET}"
}

peer_connected() {
    printf "${C_SUCCESS}CONNECTED${C_RESET}"
}

peer_not_seen() {
    printf "${C_MUTED}NOT-SEEN${C_RESET}"
}

# ============================================================================
# Database Stats Display
# ============================================================================
print_db_stats() {
    local master_count="$1"
    local confirmed_count="$2"
    local title="${3:-DATABASE STATUS}"

    print_box "$title"
    printf "  ${C_BOLD}Master List:${C_RESET}    %s addresses\n" "$master_count"
    printf "  ${C_BOLD}Confirmed:${C_RESET}      %s addresses (known Bitcoin nodes)\n" "$confirmed_count"
    echo
}

# ============================================================================
# Harvest Summary Display
# ============================================================================
print_harvest_summary() {
    local source_name="$1"
    local pages="$2"
    local seen="$3"
    local new="$4"
    local existing="$5"

    echo
    print_divider
    printf "${C_BOLD}%s Summary:${C_RESET}\n" "$source_name"
    printf "  Pages scanned:    %s\n" "$pages"
    printf "  Addresses seen:   %s\n" "$seen"
    if (( new > 0 )); then
        printf "  ${C_NEW}${C_BOLD}NEW addresses:    %s${C_RESET}\n" "$new"
    else
        printf "  ${C_MUTED}NEW addresses:    %s${C_RESET}\n" "$new"
    fi
    printf "  Already known:    %s\n" "$existing"
    print_divider
}

# ============================================================================
# Frontier Progress Display
# ============================================================================
print_frontier_progress() {
    local stage="$1"
    local current="$2"
    local total="$3"

    printf "${C_INFO}  [Frontier]${C_RESET} %s: %s/%s\n" "$stage" "$current" "$total"
}

# ============================================================================
# Address Display Functions
# ============================================================================
print_address_new() {
    local addr="$1"
    printf "    ${C_NEW}${C_BOLD}●${C_RESET} %s ${C_NEW}(NEW!)${C_RESET}\n" "$addr"
}

print_address_existing() {
    local addr="$1"
    printf "    ${C_EXISTING}•${C_RESET} ${C_MUTED}%s${C_RESET}\n" "$addr"
}

print_no_new_addresses() {
    printf "\n  ${C_MUTED}No new addresses found this scan${C_RESET}\n"
}

# ============================================================================
# Graceful Shutdown Handling
# ============================================================================
HARVEST_STOP_REQUESTED=0
HARVEST_SIGINT_COUNT=0

request_stop() {
    local sig="${1:-INT}"
    HARVEST_STOP_REQUESTED=1

    if [[ "$sig" == "INT" ]]; then
        HARVEST_SIGINT_COUNT=$(( ${HARVEST_SIGINT_COUNT:-0} + 1 ))
        if (( HARVEST_SIGINT_COUNT >= 2 )); then
            echo
            status_warn "Second Ctrl+C: exiting immediately"
            exit 130
        fi
        echo
        status_warn "Stop requested (Ctrl+C). Finishing current step..."
        status_info "Press Ctrl+C again to exit immediately"
    fi
}

trap 'request_stop INT' INT
trap 'request_stop TERM' TERM

# ============================================================================
# Logging Functions
# ============================================================================
log_info() {
    printf "[$(date '+%Y-%m-%d %H:%M:%S')] ${C_INFO}INFO${C_RESET}  %s\n" "$*"
}

log_warn() {
    printf "[$(date '+%Y-%m-%d %H:%M:%S')] ${C_WARNING}WARN${C_RESET}  %s\n" "$*"
}

log_error() {
    printf "[$(date '+%Y-%m-%d %H:%M:%S')] ${C_ERROR}ERROR${C_RESET} %s\n" "$*"
}

log_success() {
    printf "[$(date '+%Y-%m-%d %H:%M:%S')] ${C_SUCCESS}OK${C_RESET}    %s\n" "$*"
}

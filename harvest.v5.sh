#!/usr/bin/env bash
# CJDNS Address Harvester v5
# Simplified, cleaner, prettier

set -euo pipefail

# ============================================================================
# Environment Setup
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${SCRIPT_DIR}"
DB_PATH="${BASE_DIR}/state.db"

# Load all v5 modules
source "${SCRIPT_DIR}/lib/v5/utils.sh"      # canon_host function
source "${SCRIPT_DIR}/lib/v5/ui.sh"         # UI functions and colors
source "${SCRIPT_DIR}/lib/v5/db.sh"         # Database functions
source "${SCRIPT_DIR}/lib/v5/detect.sh"     # Detection and verification
source "${SCRIPT_DIR}/lib/v5/frontier.sh"   # Frontier expansion (unchanged)
source "${SCRIPT_DIR}/lib/v5/harvest.sh"    # Harvesting modules
source "${SCRIPT_DIR}/lib/v5/onetry.sh"     # Onetry execution
source "${SCRIPT_DIR}/lib/v5/display.sh"    # Status display

# Export variables for submodules
export BASE_DIR DB_PATH

# ============================================================================
# Main Menu
# ============================================================================
show_main_menu() {
    clear
    print_box "CJDNS ADDRESS HARVESTER v5"

    echo
    printf "${C_BOLD}Choose operation:${C_RESET}\n\n"
    printf "  ${C_SUCCESS}1)${C_RESET} Run harvester (continuous discovery)\n"
    printf "     └─ Harvest nodestore → frontier → onetry new addresses → repeat\n\n"
    printf "  ${C_INFO}2)${C_RESET} Onetry master list\n"
    printf "     └─ Try connecting to all discovered addresses\n\n"
    printf "  ${C_WARNING}3)${C_RESET} Onetry confirmed list\n"
    printf "     └─ Retry addresses with known Bitcoin nodes\n\n"
    printf "  ${C_ERROR}0)${C_RESET} Exit\n\n"
}

# ============================================================================
# Harvester Mode (Option 1)
# ============================================================================
run_harvester_mode() {
    print_box "HARVESTER MODE"

    # Ask for run mode
    echo
    echo "Run mode:"
    echo "  1) Once (single pass, then exit)"
    echo "  2) Continuous (loop)"
    echo
    local run_mode
    read -r -p "Choice [1/2]: " run_mode

    local scan_interval=60
    local harvest_remote="no"

    if [[ "$run_mode" == "2" ]]; then
        # Ask for scan interval
        echo
        read -r -p "Seconds between scans [default: 60]: " scan_interval
        [[ -z "$scan_interval" || ! "$scan_interval" =~ ^[0-9]+$ ]] && scan_interval=60
    fi

    # Ask about remote nodestore
    echo
    echo "Almost all set..."
    echo
    if prompt_yn "Do you have other machines on your local network with CJDNS that you would like to scan simultaneously (UNCOMMON)?"; then
        harvest_remote="yes"
        echo
        status_info "Remote harvesting will scan NodeStore + Frontier on other CJDNS nodes"
        status_info "Setting up automatic login (SSH keys) for each remote host"
        status_warn "EXPERIMENTAL FUNCTION: Disable this if experiencing errors"
        echo

        # Configure remote hosts
        source "${SCRIPT_DIR}/lib/v5/remote.sh"
        configure_remote_hosts

        if [[ "${#REMOTE_HOSTS[@]}" -eq 0 ]]; then
            status_warn "No remote hosts configured, skipping remote harvest"
            harvest_remote="no"
        else
            export HARVEST_REMOTE=yes
        fi
    fi

    echo
    status_ok "Configuration complete"
    echo

    # Main harvester loop
    local loop_count=0
    while true; do
        loop_count=$((loop_count + 1))

        log_info "Harvest loop $loop_count starting"
        echo

        # Show current database status
        local master_count confirmed_count
        master_count="$(db_count_master)"
        confirmed_count="$(db_count_confirmed)"
        print_db_stats "$master_count" "$confirmed_count"

        # Display current status
        display_cjdns_router
        display_bitcoin_peers

        # Harvest addresses (connected peers first to avoid re-testing)
        harvest_connected_peers
        harvest_nodestore
        harvest_remote_nodestore
        harvest_frontier
        harvest_remote_frontier
        harvest_addrman

        # Show updated database counts
        echo
        master_count="$(db_count_master)"
        confirmed_count="$(db_count_confirmed)"
        print_db_stats "$master_count" "$confirmed_count" "DATABASE STATUS (AFTER HARVEST)"

        # Onetry new addresses
        onetry_new_addresses

        # Show final database counts
        echo
        master_count="$(db_count_master)"
        confirmed_count="$(db_count_confirmed)"
        print_db_stats "$master_count" "$confirmed_count" "FINAL DATABASE STATUS"

        # Check if stop requested
        if (( HARVEST_STOP_REQUESTED == 1 )); then
            log_warn "Stop requested, exiting"
            break
        fi

        # Exit if run-once mode
        if [[ "$run_mode" == "1" ]]; then
            echo
            log_success "Single pass complete"
            echo
            read -r -p "Press Enter to return to main menu..."
            break
        fi

        # Sleep with countdown
        log_info "Sleeping ${scan_interval}s until next scan"
        local remaining=$scan_interval
        while (( remaining > 0 )); do
            printf "  ${C_MUTED}%ss remaining...${C_RESET}\r" "$remaining"
            sleep 1
            remaining=$((remaining - 1))

            # Check for stop request during sleep
            if (( HARVEST_STOP_REQUESTED == 1 )); then
                echo
                log_warn "Stop requested during sleep, exiting"
                exit 0
            fi
        done
        echo
    done
}

# ============================================================================
# Main Entry Point
# ============================================================================
main() {
    # Initialize database
    db_init

    # Detect and confirm Bitcoin Core
    detect_and_confirm_bitcoin

    # Detect and confirm CJDNS
    detect_and_confirm_cjdns

    # Run preflight checks
    run_preflight_checks

    # Main menu loop
    while true; do
        show_main_menu

        local choice
        read -r -p "Choice [1-3, 0=exit]: " choice

        case "$choice" in
            1)
                run_harvester_mode
                ;;
            2)
                onetry_all_master
                echo
                read -r -p "Press Enter to continue..."
                ;;
            3)
                onetry_all_confirmed
                echo
                read -r -p "Press Enter to continue..."
                ;;
            0)
                echo
                log_success "Goodbye!"
                exit 0
                ;;
            *)
                status_error "Invalid choice: $choice"
                sleep 2
                ;;
        esac
    done
}

# Run main
main "$@"

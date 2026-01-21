#!/usr/bin/env bash
# CJDNS Peer Manager - PeerYeeter
# Interactive tool for managing CJDNS peers with quality tracking

set -euo pipefail

# Check for sudo/root access - Required for /etc/ operations
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges to:"
    echo "  - Access and modify cjdns config files in /etc/"
    echo "  - Create backups in /etc/cjdns_backups/"
    echo "  - Restart cjdns service"
    echo
    echo "Re-running with sudo..."
    exec sudo "$0" "$@"
fi

# Get script directory (for portable relative paths)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source modules
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/detect.sh"
source "$SCRIPT_DIR/lib/peers.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/database.sh"
source "$SCRIPT_DIR/lib/master_list.sh"

# Global variables (will be set during initialization)
CJDNS_CONFIG=""
CJDNS_SERVICE=""
ADMIN_IP=""
ADMIN_PORT=""
ADMIN_PASSWORD=""
WORK_DIR=""

# Cleanup on exit
cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

# Initialize - detect cjdns installation and config
initialize() {
    clear
    print_ascii_header
    print_header "PeerYeeter - Initialization"

    # Check for required tools
    print_subheader "Checking Requirements"

    local missing_tools=()

    if ! command -v jq &>/dev/null; then
        missing_tools+=("jq")
    fi

    if ! command -v git &>/dev/null; then
        missing_tools+=("git")
    fi

    if ! command -v wget &>/dev/null; then
        missing_tools+=("wget")
    fi

    if ! command -v sqlite3 &>/dev/null; then
        missing_tools+=("sqlite3")
    fi

    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        echo
        echo "Please install them:"
        echo "  sudo apt-get install ${missing_tools[*]}"
        exit 1
    fi

    print_success "All required tools found (jq, git, wget, sqlite3)"

    # Check cjdnstool
    print_subheader "Checking cjdnstool"

    local cjdnstool_version
    if cjdnstool_version=$(check_cjdnstool); then
        print_success "cjdnstool found: $cjdnstool_version"
    else
        print_error "cjdnstool not found"
        echo
        echo "cjdnstool is required to communicate with cjdns."
        echo "Please install it from: https://github.com/furetosan/cjdnstool"
        exit 1
    fi

    # Detect cjdns config and service
    print_subheader "Detecting CJDNS Configuration"

    local detection_result
    if detection_result=$(detect_cjdns_service); then
        CJDNS_SERVICE=$(echo "$detection_result" | cut -d'|' -f1)
        CJDNS_CONFIG=$(echo "$detection_result" | cut -d'|' -f2)

        print_success "Detected cjdns service: $CJDNS_SERVICE"
        print_success "Detected config file: $CJDNS_CONFIG"

        if ! ask_yes_no "Is this the correct config file?"; then
            CJDNS_CONFIG=""
            CJDNS_SERVICE=""
        fi
    fi

    # Fallback: list available configs
    if [ -z "$CJDNS_CONFIG" ]; then
        print_warning "Auto-detection failed or was rejected"
        print_subheader "Available cjdns config files"

        local configs
        mapfile -t configs < <(list_cjdns_configs)

        if [ ${#configs[@]} -eq 0 ]; then
            print_error "No cjdns config files found in /etc/"
            echo
            if ask_yes_no "Would you like to specify a custom config path?"; then
                CJDNS_CONFIG=$(ask_input "Enter full path to cjdns config file")
                if [ ! -f "$CJDNS_CONFIG" ]; then
                    print_error "File not found: $CJDNS_CONFIG"
                    exit 1
                fi
            else
                exit 1
            fi
        else
            if [ ${#configs[@]} -eq 1 ]; then
                CJDNS_CONFIG="${configs[0]}"
                print_info "Found one config file: $CJDNS_CONFIG"
                if ! ask_yes_no "Use this config file?"; then
                    exit 1
                fi
            else
                print_info "Found multiple config files:"
                CJDNS_CONFIG=$(ask_selection "Select your config file:" "${configs[@]}")
            fi
        fi
    fi

    # Validate config file
    print_subheader "Validating Configuration"

    if ! validate_config "$CJDNS_CONFIG"; then
        print_error "Invalid or corrupted config file: $CJDNS_CONFIG"
        exit 1
    fi

    print_success "Config file is valid JSON"

    # Extract admin connection info
    local admin_info
    if admin_info=$(get_admin_info "$CJDNS_CONFIG"); then
        local bind=$(echo "$admin_info" | cut -d'|' -f1)
        ADMIN_IP=$(echo "$bind" | cut -d':' -f1)
        ADMIN_PORT=$(echo "$bind" | cut -d':' -f2)
        ADMIN_PASSWORD=$(echo "$admin_info" | cut -d'|' -f2)

        print_success "Admin interface: $ADMIN_IP:$ADMIN_PORT"

        # Test connection
        if test_cjdnstool_connection "$ADMIN_IP" "$ADMIN_PORT" "$ADMIN_PASSWORD"; then
            print_success "Successfully connected to cjdns"
        else
            print_error "Cannot connect to cjdns admin interface"
            echo
            echo "Make sure cjdns is running:"
            if [ -n "$CJDNS_SERVICE" ]; then
                echo "  sudo systemctl start $CJDNS_SERVICE"
            else
                echo "  sudo systemctl start cjdroute"
            fi
            exit 1
        fi
    else
        print_error "Could not extract admin connection info from config"
        exit 1
    fi

    # Initialize database and master list
    print_subheader "Initializing Database & Master List"

    # Create backup directory with proper permissions
    if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        print_error "Cannot create backup directory: $BACKUP_DIR"
        exit 1
    fi

    # Ensure backup directory has proper permissions
    chmod 755 "$BACKUP_DIR" 2>/dev/null

    if init_database; then
        print_success "Peer tracking database ready"
    else
        print_error "Failed to initialize database"
        exit 1
    fi

    if init_master_list; then
        print_success "Locally stored address list downloaded and initialized"
    else
        print_error "Failed to initialize locally stored address list"
        exit 1
    fi

    # Show current stats from locally stored address list
    local counts=$(get_master_counts)
    local local_ipv4=$(echo "$counts" | cut -d'|' -f1)
    local local_ipv6=$(echo "$counts" | cut -d'|' -f2)

    if [ "$local_ipv4" -gt 0 ] || [ "$local_ipv6" -gt 0 ]; then
        print_success "Locally stored address list contains: $local_ipv4 IPv4 addresses, and $local_ipv6 IPv6 addresses"
    else
        print_error "Locally stored address list contains: $local_ipv4 IPv4 addresses, and $local_ipv6 IPv6 addresses"
    fi

    # Show current config file peer counts
    local config_ipv4=$(get_peer_count "$CJDNS_CONFIG" 0)
    local config_ipv6=$(get_peer_count "$CJDNS_CONFIG" 1)

    if [ "$config_ipv4" -gt 0 ] || [ "$config_ipv6" -gt 0 ]; then
        print_success "CJDNS config file currently contains: $config_ipv4 IPv4 peers, and $config_ipv6 IPv6 peers"
    else
        print_error "CJDNS config file currently contains: $config_ipv4 IPv4 peers, and $config_ipv6 IPv6 peers"
    fi

    # Create working directory
    WORK_DIR=$(mktemp -d -t cjdns-manager.XXXXXX)
    print_success "Working directory: $WORK_DIR"

    echo
    print_success "Initialization complete!"
    echo
    read -p "Press Enter to continue..."
}

# Main menu
show_menu() {
    clear
    print_ascii_header
    print_header "PeerYeeter - Main Menu"
    echo "Config: $CJDNS_CONFIG"
    echo "Backup: $BACKUP_DIR"
    echo
    echo "1) Peer Adding Wizard (Recommended)"
    echo "2) Discover & Preview Peers"
    echo "3) Add Single Peer"
    echo "4) Remove Peers"
    echo "5) View Peer Status"
    echo "6) Maintenance"
    echo "0) Exit"
    echo
}

# Peer Adding Wizard - Main automated workflow
peer_adding_wizard() {
    clear
    print_ascii_header
    print_header "Peer Adding Wizard"

    print_info "This wizard will guide you through discovering, testing, and adding peers."
    echo

    # Step 1: Ask protocol selection
    print_subheader "Step 1: Protocol Selection"
    echo "What protocol would you like to discover peers for?"
    echo "  4) IPv4 only"
    echo "  6) IPv6 only"
    echo "  B) Both IPv4 and IPv6"
    echo

    local protocol
    while true; do
        read -p "Enter selection (4/6/B): " -r protocol
        case "$protocol" in
            4|[Ii][Pp][Vv]4)
                protocol="ipv4"
                print_success "IPv4 only selected"
                break
                ;;
            6|[Ii][Pp][Vv]6)
                protocol="ipv6"
                print_success "IPv6 only selected"
                break
                ;;
            [Bb]|[Bb][Oo][Tt][Hh])
                protocol="both"
                print_success "Both IPv4 and IPv6 selected"
                break
                ;;
            *)
                print_error "Please enter 4, 6, or B"
                ;;
        esac
    done
    echo

    # Step 2: Update master list
    print_subheader "Step 2: Updating Master Peer List"
    print_info "Fetching latest peers from online sources..."

    local result=$(update_master_list)
    local master_ipv4=$(echo "$result" | cut -d'|' -f1)
    local master_ipv6=$(echo "$result" | cut -d'|' -f2)

    print_success "Master list updated: $master_ipv4 IPv4, $master_ipv6 IPv6 peers"
    echo

    # Step 3: Filter for new peers
    print_subheader "Step 3: Finding New Peers"

    local discovered_ipv4="$WORK_DIR/discovered_ipv4.json"
    local discovered_ipv6="$WORK_DIR/discovered_ipv6.json"
    local new_ipv4="$WORK_DIR/new_ipv4.json"
    local new_ipv6="$WORK_DIR/new_ipv6.json"
    local updates_ipv4="$WORK_DIR/updates_ipv4.json"
    local updates_ipv6="$WORK_DIR/updates_ipv6.json"

    # Get peers from master list
    if [ "$protocol" = "ipv4" ] || [ "$protocol" = "both" ]; then
        get_master_peers "ipv4" > "$discovered_ipv4"
    else
        echo "{}" > "$discovered_ipv4"
    fi

    if [ "$protocol" = "ipv6" ] || [ "$protocol" = "both" ]; then
        get_master_peers "ipv6" > "$discovered_ipv6"
    else
        echo "{}" > "$discovered_ipv6"
    fi

    # Smart duplicate detection
    local new_counts_ipv4="0|0"
    local new_counts_ipv6="0|0"

    if [ "$protocol" = "ipv4" ] || [ "$protocol" = "both" ]; then
        new_counts_ipv4=$(smart_duplicate_check "$discovered_ipv4" "$CJDNS_CONFIG" 0 "$new_ipv4" "$updates_ipv4")
    else
        echo "{}" > "$new_ipv4"
        echo "{}" > "$updates_ipv4"
    fi

    if [ "$protocol" = "ipv6" ] || [ "$protocol" = "both" ]; then
        new_counts_ipv6=$(smart_duplicate_check "$discovered_ipv6" "$CJDNS_CONFIG" 1 "$new_ipv6" "$updates_ipv6")
    else
        echo "{}" > "$new_ipv6"
        echo "{}" > "$updates_ipv6"
    fi

    local new_ipv4_count=$(echo "$new_counts_ipv4" | cut -d'|' -f1)
    local update_ipv4_count=$(echo "$new_counts_ipv4" | cut -d'|' -f2)
    local new_ipv6_count=$(echo "$new_counts_ipv6" | cut -d'|' -f1)
    local update_ipv6_count=$(echo "$new_counts_ipv6" | cut -d'|' -f2)

    print_success "New peers: $new_ipv4_count IPv4, $new_ipv6_count IPv6"
    print_info "Updates: $update_ipv4_count IPv4, $update_ipv6_count IPv6"
    echo

    if [ "$new_ipv4_count" -eq 0 ] && [ "$new_ipv6_count" -eq 0 ]; then
        print_warning "No new peers to add"
        if [ "$update_ipv4_count" -gt 0 ] || [ "$update_ipv6_count" -gt 0 ]; then
            print_info "But there are updated peer credentials available"
            if ask_yes_no "Apply updates now?"; then
                wizard_apply_updates "$updates_ipv4" "$updates_ipv6" "$update_ipv4_count" "$update_ipv6_count"
            fi
        fi
        echo
        read -p "Press Enter to continue..."
        return
    fi

    # Step 4: Test connectivity
    print_subheader "Step 4: Testing Connectivity"

    if ! ask_yes_no "Test connectivity to discovered peers? (May take several minutes)"; then
        print_info "Skipping connectivity tests"
        echo
        read -p "Press Enter to continue..."
        return
    fi

    local active_ipv4="$WORK_DIR/active_ipv4.json"
    local active_ipv6="$WORK_DIR/active_ipv6.json"
    local inactive_ipv4="$WORK_DIR/inactive_ipv4.json"
    local inactive_ipv6="$WORK_DIR/inactive_ipv6.json"

    wizard_test_peers "$new_ipv4" "$new_ipv6" "$active_ipv4" "$active_ipv6" "$inactive_ipv4" "$inactive_ipv6"

    local active_ipv4_count=$(jq 'length' "$active_ipv4")
    local active_ipv6_count=$(jq 'length' "$active_ipv6")
    local inactive_ipv4_count=$(jq 'length' "$inactive_ipv4")
    local inactive_ipv6_count=$(jq 'length' "$inactive_ipv6")

    echo
    print_success "Active: $active_ipv4_count IPv4, $active_ipv6_count IPv6"
    print_warning "Inactive: $inactive_ipv4_count IPv4, $inactive_ipv6_count IPv6"
    echo

    # Step 5: Selection options
    print_subheader "Step 5: Select Peers to Add"

    wizard_select_and_add "$active_ipv4" "$active_ipv6" "$inactive_ipv4" "$inactive_ipv6" \
                          "$updates_ipv4" "$updates_ipv6" \
                          "$active_ipv4_count" "$active_ipv6_count" \
                          "$update_ipv4_count" "$update_ipv6_count"

    echo
    read -p "Press Enter to continue..."
}

# Wizard helper: test peers
wizard_test_peers() {
    local new_ipv4="$1"
    local new_ipv6="$2"
    local active_ipv4="$3"
    local active_ipv6="$4"
    local inactive_ipv4="$5"
    local inactive_ipv6="$6"

    echo "{}" > "$active_ipv4"
    echo "{}" > "$active_ipv6"
    echo "{}" > "$inactive_ipv4"
    echo "{}" > "$inactive_ipv6"

    local total_ipv4=$(jq 'length' "$new_ipv4")
    local total_ipv6=$(jq 'length' "$new_ipv6")

    # Test IPv4
    if [ "$total_ipv4" -gt 0 ]; then
        print_info "Testing $total_ipv4 IPv4 peers..."
        local tested=0
        local active=0

        while IFS= read -r addr; do
            tested=$((tested + 1))
            echo -n "[$tested/$total_ipv4] Testing $addr... "

            local peer_data=$(jq --arg addr "$addr" '.[$addr]' "$new_ipv4")

            if test_peer_connectivity "$addr" 2; then
                echo -e "${GREEN}✓${NC}"
                active=$((active + 1))
                jq -s --arg addr "$addr" --argjson peer "$peer_data" \
                    '.[0] + {($addr): $peer}' "$active_ipv4" > "$active_ipv4.tmp"
                mv "$active_ipv4.tmp" "$active_ipv4"
            else
                echo -e "${RED}✗${NC}"
                jq -s --arg addr "$addr" --argjson peer "$peer_data" \
                    '.[0] + {($addr): $peer}' "$inactive_ipv4" > "$inactive_ipv4.tmp"
                mv "$inactive_ipv4.tmp" "$inactive_ipv4"
            fi
        done < <(jq -r 'keys[]' "$new_ipv4")

        print_success "IPv4: $active active out of $tested"
    fi

    # Test IPv6
    if [ "$total_ipv6" -gt 0 ]; then
        print_info "Testing $total_ipv6 IPv6 peers..."
        local tested=0
        local active=0

        while IFS= read -r addr; do
            tested=$((tested + 1))
            echo -n "[$tested/$total_ipv6] Testing $addr... "

            local peer_data=$(jq --arg addr "$addr" '.[$addr]' "$new_ipv6")

            if test_peer_connectivity "$addr" 2; then
                echo -e "${GREEN}✓${NC}"
                active=$((active + 1))
                jq -s --arg addr "$addr" --argjson peer "$peer_data" \
                    '.[0] + {($addr): $peer}' "$active_ipv6" > "$active_ipv6.tmp"
                mv "$active_ipv6.tmp" "$active_ipv6"
            else
                echo -e "${RED}✗${NC}"
                jq -s --arg addr "$addr" --argjson peer "$peer_data" \
                    '.[0] + {($addr): $peer}' "$inactive_ipv6" > "$inactive_ipv6.tmp"
                mv "$inactive_ipv6.tmp" "$inactive_ipv6"
            fi
        done < <(jq -r 'keys[]' "$new_ipv6")

        print_success "IPv6: $active active out of $tested"
    fi
}

# Wizard helper: select and add peers
wizard_select_and_add() {
    local active_ipv4="$1"
    local active_ipv6="$2"
    local inactive_ipv4="$3"
    local inactive_ipv6="$4"
    local updates_ipv4="$5"
    local updates_ipv6="$6"
    local active_ipv4_count="$7"
    local active_ipv6_count="$8"
    local update_ipv4_count="$9"
    local update_ipv6_count="${10}"

    if [ "$active_ipv4_count" -eq 0 ] && [ "$active_ipv6_count" -eq 0 ]; then
        print_warning "No active peers found"
        return
    fi

    echo "What would you like to add?"
    echo "  A) All active peers (${active_ipv4_count} IPv4, ${active_ipv6_count} IPv6)"
    echo "  4) IPv4 active only ($active_ipv4_count peers)"
    echo "  6) IPv6 active only ($active_ipv6_count peers)"
    echo "  E) Experimental - Add ALL (including non-pingable)"
    echo "  C) Cancel"
    echo

    local selection
    while true; do
        read -p "Enter selection: " -r selection
        case "$selection" in
            [Aa])
                wizard_add_peers "$active_ipv4" "$active_ipv6" "$updates_ipv4" "$updates_ipv6" \
                                 "$active_ipv4_count" "$active_ipv6_count" "$update_ipv4_count" "$update_ipv6_count"
                return
                ;;
            4)
                wizard_add_peers "$active_ipv4" "$WORK_DIR/empty.json" "$updates_ipv4" "$WORK_DIR/empty.json" \
                                 "$active_ipv4_count" 0 "$update_ipv4_count" 0
                return
                ;;
            6)
                wizard_add_peers "$WORK_DIR/empty.json" "$active_ipv6" "$WORK_DIR/empty.json" "$updates_ipv6" \
                                 0 "$active_ipv6_count" 0 "$update_ipv6_count"
                return
                ;;
            [Ee])
                print_warning "EXPERIMENTAL: This will add peers that didn't respond to ping"
                if ask_yes_no "Are you sure?"; then
                    # Merge active + inactive
                    local all_ipv4="$WORK_DIR/all_ipv4.json"
                    local all_ipv6="$WORK_DIR/all_ipv6.json"
                    jq -s '.[0] * .[1]' "$active_ipv4" "$inactive_ipv4" > "$all_ipv4"
                    jq -s '.[0] * .[1]' "$active_ipv6" "$inactive_ipv6" > "$all_ipv6"
                    local all_ipv4_count=$(jq 'length' "$all_ipv4")
                    local all_ipv6_count=$(jq 'length' "$all_ipv6")
                    wizard_add_peers "$all_ipv4" "$all_ipv6" "$updates_ipv4" "$updates_ipv6" \
                                     "$all_ipv4_count" "$all_ipv6_count" "$update_ipv4_count" "$update_ipv6_count"
                fi
                return
                ;;
            [Cc])
                print_info "Cancelled"
                return
                ;;
            *)
                print_error "Invalid selection"
                ;;
        esac
    done
}

# Wizard helper: add peers to config
wizard_add_peers() {
    local peers_ipv4="$1"
    local peers_ipv6="$2"
    local updates_ipv4="$3"
    local updates_ipv6="$4"
    local count_ipv4="$5"
    local count_ipv6="$6"
    local update_ipv4_count="$7"
    local update_ipv6_count="$8"

    echo "{}" > "$WORK_DIR/empty.json"

    # Ask about removing unresponsive peers first
    print_subheader "Remove Unresponsive Peers"

    local peer_states="$WORK_DIR/peer_states.txt"
    get_current_peer_states "$ADMIN_IP" "$ADMIN_PORT" "$ADMIN_PASSWORD" "$peer_states"

    local unresponsive_count=$(grep -c "^UNRESPONSIVE|" "$peer_states" 2>/dev/null || echo 0)

    if [ "$unresponsive_count" -gt 0 ]; then
        print_warning "You have $unresponsive_count unresponsive peers in your config"
        if ask_yes_no "Remove unresponsive peers before adding new ones?"; then
            wizard_remove_unresponsive "$peer_states"
        fi
    fi

    # Backup config
    print_subheader "Creating Backup"
    local backup
    if backup=$(backup_config "$CJDNS_CONFIG"); then
        print_success "Backup created: $backup"
    else
        print_error "Failed to create backup"
        return
    fi

    # Add peers
    print_subheader "Adding Peers"

    local temp_config="$WORK_DIR/config.tmp"
    cp "$CJDNS_CONFIG" "$temp_config"

    local total_added=0

    if [ "$count_ipv4" -gt 0 ]; then
        if add_peers_to_config "$temp_config" "$peers_ipv4" 0 "$temp_config.new"; then
            mv "$temp_config.new" "$temp_config"
            print_success "Added $count_ipv4 IPv4 peers"
            total_added=$((total_added + count_ipv4))
        else
            print_error "Failed to add IPv4 peers"
            return
        fi
    fi

    if [ "$count_ipv6" -gt 0 ]; then
        if add_peers_to_config "$temp_config" "$peers_ipv6" 1 "$temp_config.new"; then
            mv "$temp_config.new" "$temp_config"
            print_success "Added $count_ipv6 IPv6 peers"
            total_added=$((total_added + count_ipv6))
        else
            print_error "Failed to add IPv6 peers"
            return
        fi
    fi

    # Apply updates
    if [ "$update_ipv4_count" -gt 0 ]; then
        if apply_peer_updates "$temp_config" "$updates_ipv4" 0 "$temp_config.new"; then
            mv "$temp_config.new" "$temp_config"
            print_success "Updated $update_ipv4_count IPv4 peer credentials"
        fi
    fi

    if [ "$update_ipv6_count" -gt 0 ]; then
        if apply_peer_updates "$temp_config" "$updates_ipv6" 1 "$temp_config.new"; then
            mv "$temp_config.new" "$temp_config"
            print_success "Updated $update_ipv6_count IPv6 peer credentials"
        fi
    fi

    # Validate and save
    if validate_config "$temp_config"; then
        cp "$temp_config" "$CJDNS_CONFIG"
        print_success "Config updated successfully! Added $total_added peers."

        if ask_yes_no "Restart cjdns service now to apply changes?"; then
            restart_service
        fi
    else
        print_error "Config validation failed - changes NOT applied"
        echo "Backup is safe at: $backup"
    fi
}

# Wizard helper: apply credential updates
wizard_apply_updates() {
    local updates_ipv4="$1"
    local updates_ipv6="$2"
    local update_ipv4_count="$3"
    local update_ipv6_count="$4"

    # Backup config
    print_subheader "Creating Backup"
    local backup
    if backup=$(backup_config "$CJDNS_CONFIG"); then
        print_success "Backup created: $backup"
    else
        print_error "Failed to create backup"
        return
    fi

    local temp_config="$WORK_DIR/config.tmp"
    cp "$CJDNS_CONFIG" "$temp_config"

    if [ "$update_ipv4_count" -gt 0 ]; then
        if apply_peer_updates "$temp_config" "$updates_ipv4" 0 "$temp_config.new"; then
            mv "$temp_config.new" "$temp_config"
            print_success "Updated $update_ipv4_count IPv4 peers"
        fi
    fi

    if [ "$update_ipv6_count" -gt 0 ]; then
        if apply_peer_updates "$temp_config" "$updates_ipv6" 1 "$temp_config.new"; then
            mv "$temp_config.new" "$temp_config"
            print_success "Updated $update_ipv6_count IPv6 peers"
        fi
    fi

    if validate_config "$temp_config"; then
        cp "$temp_config" "$CJDNS_CONFIG"
        print_success "Config updated successfully!"

        if ask_yes_no "Restart cjdns now?"; then
            restart_service
        fi
    else
        print_error "Config validation failed"
    fi
}

# Wizard helper: remove unresponsive peers
wizard_remove_unresponsive() {
    local peer_states="$1"

    local unresponsive_ipv4="$WORK_DIR/unresponsive_ipv4.txt"
    local unresponsive_ipv6="$WORK_DIR/unresponsive_ipv6.txt"

    grep "^UNRESPONSIVE|" "$peer_states" | cut -d'|' -f2 | grep -v '^\[' > "$unresponsive_ipv4" 2>/dev/null || touch "$unresponsive_ipv4"
    grep "^UNRESPONSIVE|" "$peer_states" | cut -d'|' -f2 | grep '^\[' > "$unresponsive_ipv6" 2>/dev/null || touch "$unresponsive_ipv6"

    local count_ipv4=$(wc -l < "$unresponsive_ipv4")
    local count_ipv6=$(wc -l < "$unresponsive_ipv6")

    local temp_config="$WORK_DIR/config_remove.tmp"
    cp "$CJDNS_CONFIG" "$temp_config"

    if [ "$count_ipv4" -gt 0 ]; then
        mapfile -t dead_addrs < "$unresponsive_ipv4"
        remove_peers_from_config "$temp_config" 0 "$temp_config.new" "${dead_addrs[@]}"
        mv "$temp_config.new" "$temp_config"
    fi

    if [ "$count_ipv6" -gt 0 ]; then
        mapfile -t dead_addrs < "$unresponsive_ipv6"
        remove_peers_from_config "$temp_config" 1 "$temp_config.new" "${dead_addrs[@]}"
        mv "$temp_config.new" "$temp_config"
    fi

    if validate_config "$temp_config"; then
        cp "$temp_config" "$CJDNS_CONFIG"
        print_success "Removed $count_ipv4 IPv4 and $count_ipv6 IPv6 unresponsive peers"
    fi
}

# Discover & Preview Peers (read-only)
discover_preview() {
    clear
    print_ascii_header
    print_header "Discover & Preview Peers"

    print_info "This will show you what peers are available (read-only preview)"
    echo

    print_subheader "Updating Master List"
    local result=$(update_master_list)
    local master_ipv4=$(echo "$result" | cut -d'|' -f1)
    local master_ipv6=$(echo "$result" | cut -d'|' -f2)

    print_success "Master list: $master_ipv4 IPv4, $master_ipv6 IPv6 peers"
    echo

    print_subheader "Sample IPv4 Peers"
    local preview_ipv4="$WORK_DIR/preview_ipv4.json"
    get_master_peers "ipv4" > "$preview_ipv4"
    show_peer_details "$preview_ipv4" 5

    echo
    print_subheader "Sample IPv6 Peers"
    local preview_ipv6="$WORK_DIR/preview_ipv6.json"
    get_master_peers "ipv6" > "$preview_ipv6"
    show_peer_details "$preview_ipv6" 5

    echo
    print_info "Use the Wizard to test and add these peers"
    echo
    read -p "Press Enter to continue..."
}

# Add Single Peer
add_single_peer() {
    clear
    print_ascii_header
    print_header "Add Single Peer"

    print_info "Enter peer details (all fields are optional except address, password, and publicKey)"
    echo

    local address=$(ask_input "Peer address (IP:PORT or [IPv6]:PORT)")
    local password=$(ask_input "Password")
    local publicKey=$(ask_input "Public key")

    echo
    print_info "Optional fields (press Enter to skip):"
    local peerName=$(ask_input "Peer name" "")
    local login=$(ask_input "Login" "")
    local contact=$(ask_input "Contact" "")
    local location=$(ask_input "Location" "")
    local gpg=$(ask_input "GPG" "")

    # Build JSON
    local peer_json=$(jq -n \
        --arg pw "$password" \
        --arg pk "$publicKey" \
        '{password: $pw, publicKey: $pk}')

    if [ -n "$peerName" ]; then
        peer_json=$(echo "$peer_json" | jq --arg pn "$peerName" '. + {peerName: $pn}')
    fi
    if [ -n "$login" ]; then
        peer_json=$(echo "$peer_json" | jq --arg l "$login" '. + {login: $l}')
    fi
    if [ -n "$contact" ]; then
        peer_json=$(echo "$peer_json" | jq --arg c "$contact" '. + {contact: $c}')
    fi
    if [ -n "$location" ]; then
        peer_json=$(echo "$peer_json" | jq --arg loc "$location" '. + {location: $loc}')
    fi
    if [ -n "$gpg" ]; then
        peer_json=$(echo "$peer_json" | jq --arg g "$gpg" '. + {gpg: $g}')
    fi

    # Show review
    echo
    print_subheader "Review Peer"
    echo "Address: $address"
    echo "$peer_json" | jq -r 'to_entries[] | "  \(.key): \(.value)"'
    echo

    if ! ask_yes_no "Add this peer to your config?"; then
        print_info "Cancelled"
        echo
        read -p "Press Enter to continue..."
        return
    fi

    # Determine interface (IPv4 or IPv6)
    local interface_index=0
    if [[ "$address" =~ ^\[ ]]; then
        interface_index=1
    fi

    # Create temp peer file
    local temp_peer="$WORK_DIR/single_peer.json"
    jq -n --arg addr "$address" --argjson peer "$peer_json" \
        '{($addr): $peer}' > "$temp_peer"

    # Backup and add
    local backup
    if backup=$(backup_config "$CJDNS_CONFIG"); then
        print_success "Backup created: $backup"
    else
        print_error "Failed to create backup"
        return
    fi

    local temp_config="$WORK_DIR/config.tmp"
    if add_peers_to_config "$CJDNS_CONFIG" "$temp_peer" "$interface_index" "$temp_config"; then
        if validate_config "$temp_config"; then
            cp "$temp_config" "$CJDNS_CONFIG"
            print_success "Peer added successfully!"

            if ask_yes_no "Restart cjdns now?"; then
                restart_service
            fi
        else
            print_error "Config validation failed"
        fi
    else
        print_error "Failed to add peer"
    fi

    echo
    read -p "Press Enter to continue..."
}

# Remove Peers Menu
remove_peers_menu() {
    clear
    print_ascii_header
    print_header "Remove Peers"

    # Get current peer states
    local peer_states="$WORK_DIR/peer_states.txt"
    get_current_peer_states "$ADMIN_IP" "$ADMIN_PORT" "$ADMIN_PASSWORD" "$peer_states"

    # Update database with current states
    while IFS='|' read -r state address; do
        update_peer_state "$address" "$state"
    done < "$peer_states"

    # Get all peers sorted by quality
    print_info "Loading peer quality data..."
    echo

    local all_peers=$(get_all_peers_by_quality)

    if [ -z "$all_peers" ]; then
        print_warning "No peers found in database"
        echo
        read -p "Press Enter to continue..."
        return
    fi

    print_subheader "All Peers (sorted by quality)"
    printf "%-30s %-15s %-10s %-5s %-5s\n" "Address" "State" "Quality" "Est." "Unr."
    printf "%-30s %-15s %-10s %-5s %-5s\n" "-------" "-----" "-------" "----" "----"

    while IFS='|' read -r address state quality established unresponsive first_seen; do
        printf "%-30s %-15s %-9.1f%% %-5d %-5d\n" "$address" "$state" "$quality" "$established" "$unresponsive"
    done <<< "$all_peers"

    echo
    print_info "To remove specific peers, enter their addresses (comma-separated)"
    print_info "Or press Enter to cancel"
    echo

    local selection
    read -p "Addresses to remove: " -r selection

    if [ -z "$selection" ]; then
        return
    fi

    # Parse addresses
    IFS=',' read -ra addresses <<< "$selection"

    if [ ${#addresses[@]} -eq 0 ]; then
        return
    fi

    # Confirm
    echo
    print_warning "About to remove ${#addresses[@]} peer(s)"
    if ! ask_yes_no "Are you sure?"; then
        return
    fi

    # Backup and remove
    local backup
    if backup=$(backup_config "$CJDNS_CONFIG"); then
        print_success "Backup created: $backup"
    else
        print_error "Failed to create backup"
        return
    fi

    local temp_config="$WORK_DIR/config.tmp"

    # Try removing from both interfaces
    remove_peers_from_config "$CJDNS_CONFIG" 0 "$temp_config" "${addresses[@]}"
    remove_peers_from_config "$temp_config" 1 "$temp_config.new" "${addresses[@]}"
    mv "$temp_config.new" "$temp_config"

    if validate_config "$temp_config"; then
        cp "$temp_config" "$CJDNS_CONFIG"
        print_success "Peers removed successfully!"

        if ask_yes_no "Restart cjdns now?"; then
            restart_service
        fi
    else
        print_error "Config validation failed"
    fi

    echo
    read -p "Press Enter to continue..."
}

# View Peer Status
view_peer_status() {
    clear
    print_ascii_header
    print_header "Current Peer Status"

    local peer_states="$WORK_DIR/peer_states.txt"
    get_current_peer_states "$ADMIN_IP" "$ADMIN_PORT" "$ADMIN_PASSWORD" "$peer_states"

    # Update database
    while IFS='|' read -r state address; do
        update_peer_state "$address" "$state"
    done < "$peer_states"

    local total=$(wc -l < "$peer_states")
    local established=$(grep -c "^ESTABLISHED|" "$peer_states" || echo 0)
    local unresponsive=$(grep -c "^UNRESPONSIVE|" "$peer_states" || echo 0)

    echo "Total peers: $total"
    echo "  ${GREEN}✓${NC} ESTABLISHED: $established"
    echo "  ${RED}✗${NC} UNRESPONSIVE: $unresponsive"
    echo

    if ask_yes_no "Show detailed list with quality scores?"; then
        print_subheader "Peer Details"
        while IFS='|' read -r state address; do
            local quality=$(get_peer_quality "$address")
            local quality_display=$(printf "%.0f%%" "$quality")

            if [ "$state" = "ESTABLISHED" ]; then
                echo -e "${GREEN}✓${NC} $state: $address (Quality: $quality_display)"
            else
                echo -e "${RED}✗${NC} $state: $address (Quality: $quality_display)"
            fi
        done < "$peer_states"
    fi

    echo
    read -p "Press Enter to continue..."
}

# Maintenance Menu
maintenance_menu() {
    while true; do
        clear
        print_ascii_header
        print_header "Maintenance"

        echo "1) Show Directories & Config Info"
        echo "2) Reset Master Peer List"
        echo "3) Manage Peer Sources"
        echo "4) Reset Database"
        echo "5) Import Peers from File"
        echo "6) Export Peers to File"
        echo "7) Backup Config"
        echo "8) Restore Config"
        echo "9) Restart cjdns Service"
        echo "0) Back to Main Menu"
        echo

        local choice
        read -p "Enter choice: " choice

        case "$choice" in
            1) show_directories ;;
            2) reset_master_list_menu ;;
            3) manage_sources_menu ;;
            4) reset_database_menu ;;
            5) import_peers_menu ;;
            6) export_peers_menu ;;
            7) backup_config_menu ;;
            8) restore_config_menu ;;
            9) restart_service ;;
            0) return ;;
            *) print_error "Invalid choice"; sleep 1 ;;
        esac
    done
}

# Show directories and config info
show_directories() {
    clear
    print_ascii_header
    print_header "Directories & Config Info"

    echo "Config file:"
    echo "  $CJDNS_CONFIG"
    echo

    echo "Backup directory:"
    echo "  $BACKUP_DIR"
    echo

    echo "Database:"
    echo "  $DB_FILE"
    echo

    echo "Master peer list:"
    echo "  $MASTER_LIST"
    echo

    echo "Peer sources:"
    echo "  $PEER_SOURCES"
    echo

    local backup_count=$(ls -1 "$BACKUP_DIR"/cjdroute_backup_*.conf 2>/dev/null | wc -l)
    echo "Number of backups: $backup_count"

    local counts=$(get_master_counts)
    local ipv4_count=$(echo "$counts" | cut -d'|' -f1)
    local ipv6_count=$(echo "$counts" | cut -d'|' -f2)
    echo "Master list: $ipv4_count IPv4, $ipv6_count IPv6"

    echo
    read -p "Press Enter to continue..."
}

# Reset master peer list
reset_master_list_menu() {
    clear
    print_ascii_header
    print_header "Reset Master Peer List"

    print_warning "This will delete the current master list and re-download from all sources"
    echo

    if ! ask_yes_no "Are you sure you want to reset the master list?"; then
        return
    fi

    print_info "Resetting master peer list..."
    reset_master_list

    local counts=$(get_master_counts)
    local ipv4_count=$(echo "$counts" | cut -d'|' -f1)
    local ipv6_count=$(echo "$counts" | cut -d'|' -f2)

    print_success "Master list reset complete!"
    print_info "New master list: $ipv4_count IPv4, $ipv6_count IPv6"

    echo
    read -p "Press Enter to continue..."
}

# Manage peer sources
manage_sources_menu() {
    clear
    print_ascii_header
    print_header "Manage Peer Sources"

    print_info "Current peer sources:"
    echo

    local sources=$(jq -r '.sources[] | "\(.name)|\(.type)|\(.url)|\(.enabled)"' "$PEER_SOURCES")

    local i=1
    while IFS='|' read -r name type url enabled; do
        local status="ENABLED"
        if [ "$enabled" = "false" ]; then
            status="DISABLED"
        fi
        printf "%d) [%s] %s (%s)\n" "$i" "$status" "$name" "$type"
        printf "   %s\n" "$url"
        echo
        i=$((i + 1))
    done <<< "$sources"

    print_info "Source management features:"
    echo "  - Toggle sources on/off"
    echo "  - Add custom sources"
    echo
    print_warning "Feature coming soon - sources are currently read-only"

    echo
    read -p "Press Enter to continue..."
}

# Reset database
reset_database_menu() {
    clear
    print_ascii_header
    print_header "Reset Database"

    print_warning "This will delete all peer quality tracking data"
    echo

    if ! ask_yes_no "Are you sure you want to reset the database?"; then
        return
    fi

    if reset_database; then
        print_success "Database reset complete!"
    else
        print_error "Failed to reset database"
    fi

    echo
    read -p "Press Enter to continue..."
}

# Import peers from file
import_peers_menu() {
    clear
    print_ascii_header
    print_header "Import Peers from File"

    print_info "Import peers from a JSON file"
    echo

    local file_path=$(ask_input "Enter path to JSON file")

    if [ ! -f "$file_path" ]; then
        print_error "File not found: $file_path"
        echo
        read -p "Press Enter to continue..."
        return
    fi

    if ! jq empty "$file_path" 2>/dev/null; then
        print_error "Invalid JSON file"
        echo
        read -p "Press Enter to continue..."
        return
    fi

    local peer_count=$(jq 'length' "$file_path")
    print_info "Found $peer_count peers in file"

    # Detect IPv4/IPv6
    local has_ipv4=$(jq -r 'keys[] | select(startswith("[") | not)' "$file_path" | head -1)
    local has_ipv6=$(jq -r 'keys[] | select(startswith("["))' "$file_path" | head -1)

    local interface_index=0
    if [ -n "$has_ipv6" ] && [ -z "$has_ipv4" ]; then
        interface_index=1
        print_info "Detected IPv6 peers"
    else
        print_info "Detected IPv4 peers"
    fi

    echo
    if ! ask_yes_no "Import these peers?"; then
        return
    fi

    # Smart duplicate check
    local new_peers="$WORK_DIR/import_new.json"
    local updates="$WORK_DIR/import_updates.json"

    local counts=$(smart_duplicate_check "$file_path" "$CJDNS_CONFIG" "$interface_index" "$new_peers" "$updates")
    local new_count=$(echo "$counts" | cut -d'|' -f1)
    local update_count=$(echo "$counts" | cut -d'|' -f2)

    echo
    print_info "Import summary: $new_count new, $update_count updates"

    if [ "$new_count" -eq 0 ] && [ "$update_count" -eq 0 ]; then
        print_warning "No peers to import"
        echo
        read -p "Press Enter to continue..."
        return
    fi

    # Backup and add
    local backup
    if backup=$(backup_config "$CJDNS_CONFIG"); then
        print_success "Backup created: $backup"
    else
        print_error "Failed to create backup"
        return
    fi

    local temp_config="$WORK_DIR/config.tmp"
    cp "$CJDNS_CONFIG" "$temp_config"

    if [ "$new_count" -gt 0 ]; then
        if add_peers_to_config "$temp_config" "$new_peers" "$interface_index" "$temp_config.new"; then
            mv "$temp_config.new" "$temp_config"
            print_success "Added $new_count new peers"
        fi
    fi

    if [ "$update_count" -gt 0 ]; then
        if apply_peer_updates "$temp_config" "$updates" "$interface_index" "$temp_config.new"; then
            mv "$temp_config.new" "$temp_config"
            print_success "Updated $update_count peers"
        fi
    fi

    if validate_config "$temp_config"; then
        cp "$temp_config" "$CJDNS_CONFIG"
        print_success "Import complete!"

        if ask_yes_no "Restart cjdns now?"; then
            restart_service
        fi
    else
        print_error "Config validation failed"
    fi

    echo
    read -p "Press Enter to continue..."
}

# Export peers to file
export_peers_menu() {
    clear
    print_ascii_header
    print_header "Export Peers to File"

    print_info "Export all peers from your config to a JSON file"
    echo

    echo "Select interface to export:"
    echo "  4) IPv4 peers"
    echo "  6) IPv6 peers"
    echo "  B) Both (separate files)"
    echo

    local selection
    read -p "Enter selection: " -r selection

    local export_dir="$BACKUP_DIR/exported_peers"
    mkdir -p "$export_dir"

    local timestamp=$(date +%Y%m%d_%H%M%S)

    case "$selection" in
        4)
            local output="$export_dir/ipv4_peers_$timestamp.json"
            jq '.interfaces.UDPInterface[0].connectTo // {}' "$CJDNS_CONFIG" > "$output"
            local count=$(jq 'length' "$output")
            print_success "Exported $count IPv4 peers to: $output"
            ;;
        6)
            local output="$export_dir/ipv6_peers_$timestamp.json"
            jq '.interfaces.UDPInterface[1].connectTo // {}' "$CJDNS_CONFIG" > "$output"
            local count=$(jq 'length' "$output")
            print_success "Exported $count IPv6 peers to: $output"
            ;;
        [Bb])
            local output_ipv4="$export_dir/ipv4_peers_$timestamp.json"
            local output_ipv6="$export_dir/ipv6_peers_$timestamp.json"
            jq '.interfaces.UDPInterface[0].connectTo // {}' "$CJDNS_CONFIG" > "$output_ipv4"
            jq '.interfaces.UDPInterface[1].connectTo // {}' "$CJDNS_CONFIG" > "$output_ipv6"
            local count_ipv4=$(jq 'length' "$output_ipv4")
            local count_ipv6=$(jq 'length' "$output_ipv6")
            print_success "Exported $count_ipv4 IPv4 peers to: $output_ipv4"
            print_success "Exported $count_ipv6 IPv6 peers to: $output_ipv6"
            ;;
        *)
            print_error "Invalid selection"
            ;;
    esac

    echo
    read -p "Press Enter to continue..."
}

# Backup config manually
backup_config_menu() {
    clear
    print_ascii_header
    print_header "Backup Config File"

    echo "Current config: $CJDNS_CONFIG"
    echo "Backup directory: $BACKUP_DIR"
    echo

    if ! ask_yes_no "Create a backup of your current config?"; then
        return
    fi

    local backup
    if backup=$(backup_config "$CJDNS_CONFIG"); then
        print_success "Backup created successfully"
        echo
        echo "Backup location: $backup"
        echo "Backup size: $(ls -lh "$backup" | awk '{print $5}')"
    else
        print_error "Failed to create backup"
    fi

    echo
    read -p "Press Enter to continue..."
}

# Restore config from backup
restore_config_menu() {
    clear
    print_ascii_header
    print_header "Restore Config from Backup"

    echo "Available backups in $BACKUP_DIR:"
    echo

    local backups
    mapfile -t backups < <(list_backups)

    if [ ${#backups[@]} -eq 0 ]; then
        print_warning "No backups found in $BACKUP_DIR"
        echo
        read -p "Press Enter to continue..."
        return
    fi

    # Show backups with numbers
    for i in "${!backups[@]}"; do
        local backup="${backups[$i]}"
        local timestamp=$(basename "$backup" | sed 's/cjdroute_backup_\(.*\)\.conf/\1/')
        local size=$(ls -lh "$backup" | awk '{print $5}')
        local date_formatted=$(format_timestamp $(stat -c %Y "$backup"))
        echo "  $((i+1))) $timestamp - $date_formatted ($size)"
    done

    echo
    echo "  0) Cancel"
    echo

    local choice
    while true; do
        read -p "Select backup to restore (0-${#backups[@]}): " choice

        if [ "$choice" = "0" ]; then
            return
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#backups[@]} ]; then
            break
        else
            print_error "Invalid selection"
        fi
    done

    local selected_backup="${backups[$((choice-1))]}"

    echo
    print_warning "This will replace your current config with:"
    echo "  $selected_backup"
    echo
    echo "Your current config will be backed up first as a safety measure."
    echo

    if ! ask_yes_no "Are you sure you want to restore this backup?"; then
        return
    fi

    if restore_config "$selected_backup" "$CJDNS_CONFIG"; then
        print_success "Config restored successfully"
        echo
        print_info "You should restart cjdns for changes to take effect"

        if ask_yes_no "Restart cjdns now?"; then
            restart_service
        fi
    else
        print_error "Failed to restore config"
    fi

    echo
    read -p "Press Enter to continue..."
}

# Restart cjdns service
restart_service() {
    print_subheader "Restarting cjdns Service"

    if [ -z "$CJDNS_SERVICE" ]; then
        print_warning "Service name not detected"
        CJDNS_SERVICE=$(ask_input "Enter cjdns service name" "cjdroute")
    fi

    echo "Restarting $CJDNS_SERVICE..."

    if systemctl restart "$CJDNS_SERVICE"; then
        print_success "Service restarted"

        # Poll for connection with 2s intervals, max 10s
        local attempts=0
        local max_attempts=5

        while [ $attempts -lt $max_attempts ]; do
            sleep 2
            if test_cjdnstool_connection "$ADMIN_IP" "$ADMIN_PORT" "$ADMIN_PASSWORD"; then
                print_success "cjdns is running and responding"
                echo
                read -p "Press Enter to continue..."
                return
            fi
            attempts=$((attempts + 1))
        done

        print_warning "Service restarted but not responding yet"
    else
        print_error "Failed to restart service"
    fi

    echo
    read -p "Press Enter to continue..."
}

# Main program
main() {
    # Initialize
    initialize

    # Main loop
    while true; do
        show_menu

        local choice
        read -p "Enter choice: " choice

        case "$choice" in
            1) peer_adding_wizard ;;
            2) discover_preview ;;
            3) add_single_peer ;;
            4) remove_peers_menu ;;
            5) view_peer_status ;;
            6) maintenance_menu ;;
            0)
                clear
                print_ascii_header
                print_success "Goodbye!"
                exit 0
                ;;
            *)
                print_error "Invalid choice"
                sleep 1
                ;;
        esac
    done
}

# Run main program
main

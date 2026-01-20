#!/usr/bin/env bash
# CJDNS Peer Manager - Interactive tool for managing CJDNS peers
# Portable and auto-detecting for use on any system

set -euo pipefail

# Get script directory (for portable relative paths)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source modules
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/detect.sh"
source "$SCRIPT_DIR/lib/peers.sh"
source "$SCRIPT_DIR/lib/config.sh"

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
    print_header "CJDNS Peer Manager - Initialization"

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

    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        echo
        echo "Please install them:"
        echo "  sudo apt-get install ${missing_tools[*]}"
        exit 1
    fi

    print_success "All required tools found (jq, git, wget)"

    # Check cjdnstool
    print_subheader "Checking cjdnstool"

    local cjdnstool_version
    if cjdnstool_version=$(check_cjdnstool); then
        print_success "cjdnstool found: $cjdnstool_version"
        print_warning "This tool has been tested with cjdnstool. Your version may work differently."
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

    # Create working directory
    WORK_DIR=$(mktemp -d -t cjdns-manager.XXXXXX)
    print_success "Working directory: $WORK_DIR"

    echo
    print_success "Initialization complete!"
    echo
}

# Main menu
show_menu() {
    print_header "CJDNS Peer Manager - Main Menu"
    echo "Config: $CJDNS_CONFIG"
    echo
    echo "1) View current peer status"
    echo "2) Discover new peers from online sources"
    echo "3) Test peer connectivity"
    echo "4) Add new peers to config"
    echo "5) Remove unresponsive peers"
    echo "6) Restart cjdns service"
    echo "0) Exit"
    echo
}

# View current peer status
view_peer_status() {
    print_header "Current Peer Status"

    local peer_states="$WORK_DIR/peer_states.txt"
    get_current_peer_states "$ADMIN_IP" "$ADMIN_PORT" "$ADMIN_PASSWORD" "$peer_states"

    local total=$(wc -l < "$peer_states")
    local established=$(grep -c "^ESTABLISHED|" "$peer_states" || echo 0)
    local unresponsive=$(grep -c "^UNRESPONSIVE|" "$peer_states" || echo 0)

    echo "Total peers: $total"
    echo "  ESTABLISHED: $established"
    echo "  UNRESPONSIVE: $unresponsive"
    echo

    if ask_yes_no "Show detailed list?"; then
        print_subheader "Peer Details"
        while IFS='|' read -r state address; do
            if [ "$state" = "ESTABLISHED" ]; then
                echo -e "${GREEN}✓${NC} $state: $address"
            else
                echo -e "${RED}✗${NC} $state: $address"
            fi
        done < "$peer_states"
    fi

    echo
    read -p "Press Enter to continue..."
}

# Discover new peers
discover_new_peers() {
    print_header "Discovering New Peers"

    local ipv4_peers="$WORK_DIR/discovered_ipv4.json"
    local ipv6_peers="$WORK_DIR/discovered_ipv6.json"

    # Discover from GitHub
    print_subheader "Fetching from GitHub repositories"
    local result
    result=$(discover_peers_from_github "$WORK_DIR" "$ipv4_peers" "$ipv6_peers")
    local github_ipv4=$(echo "$result" | cut -d'|' -f1)
    local github_ipv6=$(echo "$result" | cut -d'|' -f2)

    echo
    print_success "GitHub: $github_ipv4 IPv4 peers, $github_ipv6 IPv6 peers"

    # Try kaotisk-hund source
    if discover_peers_from_kaotisk "$ipv4_peers" "$ipv6_peers"; then
        local total_ipv4=$(jq 'length' "$ipv4_peers")
        local total_ipv6=$(jq 'length' "$ipv6_peers")
        print_success "Total discovered: $total_ipv4 IPv4 peers, $total_ipv6 IPv6 peers"
    fi

    # Filter out peers already in config
    print_subheader "Filtering new peers"

    local new_ipv4="$WORK_DIR/new_ipv4.json"
    local new_ipv6="$WORK_DIR/new_ipv6.json"

    local new_ipv4_count=$(filter_new_peers "$ipv4_peers" "$CJDNS_CONFIG" 0 "$new_ipv4")
    local new_ipv6_count=$(filter_new_peers "$ipv6_peers" "$CJDNS_CONFIG" 1 "$new_ipv6")

    print_success "New IPv4 peers: $new_ipv4_count"
    print_success "New IPv6 peers: $new_ipv6_count"

    if [ "$new_ipv4_count" -gt 0 ]; then
        echo
        print_subheader "Sample New IPv4 Peers"
        show_peer_details "$new_ipv4" 5
    fi

    if [ "$new_ipv6_count" -gt 0 ]; then
        echo
        print_subheader "Sample New IPv6 Peers"
        show_peer_details "$new_ipv6" 5
    fi

    echo
    print_success "Peer discovery complete"
    echo "New peers saved for testing/adding"
    echo
    read -p "Press Enter to continue..."
}

# Test peer connectivity
test_peer_connectivity_menu() {
    print_header "Test Peer Connectivity"

    local new_ipv4="$WORK_DIR/new_ipv4.json"
    local new_ipv6="$WORK_DIR/new_ipv6.json"

    if [ ! -f "$new_ipv4" ] || [ ! -f "$new_ipv6" ]; then
        print_error "No discovered peers found. Please run 'Discover new peers' first."
        echo
        read -p "Press Enter to continue..."
        return
    fi

    local total_ipv4=$(jq 'length' "$new_ipv4")
    local total_ipv6=$(jq 'length' "$new_ipv6")

    echo "Discovered peers available for testing:"
    echo "  IPv4: $total_ipv4"
    echo "  IPv6: $total_ipv6"
    echo

    if ! ask_yes_no "Test connectivity to discovered peers? (This may take several minutes)"; then
        return
    fi

    local active_ipv4="$WORK_DIR/active_ipv4.json"
    local active_ipv6="$WORK_DIR/active_ipv6.json"

    echo "{" > "$active_ipv4"
    echo "{" > "$active_ipv6"

    # Test IPv4 peers
    if [ "$total_ipv4" -gt 0 ]; then
        print_subheader "Testing IPv4 Peers"

        local tested=0
        local active=0
        local first=true

        while IFS= read -r addr; do
            tested=$((tested + 1))
            echo -n "[$tested/$total_ipv4] Testing $addr... "

            if test_peer_connectivity "$addr" 2; then
                echo -e "${GREEN}✓ ACTIVE${NC}"
                active=$((active + 1))

                # Add to active list
                if [ "$first" = true ]; then
                    first=false
                else
                    echo "," >> "$active_ipv4"
                fi

                local peer_data=$(jq -r --arg addr "$addr" '{($addr): .[$addr]}' "$new_ipv4")
                echo -n "$peer_data" | jq -r 'to_entries[] | "  \"\(.key)\": \(.value)"' >> "$active_ipv4"
            else
                echo -e "${RED}✗ No response${NC}"
            fi
        done < <(jq -r 'keys[]' "$new_ipv4")

        echo "" >> "$active_ipv4"
        echo "}" >> "$active_ipv4"

        echo
        print_success "IPv4: $active active out of $tested tested"
    fi

    # Test IPv6 peers
    if [ "$total_ipv6" -gt 0 ]; then
        print_subheader "Testing IPv6 Peers"

        local tested=0
        local active=0
        local first=true

        while IFS= read -r addr; do
            tested=$((tested + 1))
            echo -n "[$tested/$total_ipv6] Testing $addr... "

            if test_peer_connectivity "$addr" 2; then
                echo -e "${GREEN}✓ ACTIVE${NC}"
                active=$((active + 1))

                # Add to active list
                if [ "$first" = true ]; then
                    first=false
                else
                    echo "," >> "$active_ipv6"
                fi

                local peer_data=$(jq -r --arg addr "$addr" '{($addr): .[$addr]}' "$new_ipv6")
                echo -n "$peer_data" | jq -r 'to_entries[] | "  \"\(.key)\": \(.value)"' >> "$active_ipv6"
            else
                echo -e "${RED}✗ No response${NC}"
            fi
        done < <(jq -r 'keys[]' "$new_ipv6")

        echo "" >> "$active_ipv6"
        echo "}" >> "$active_ipv6"

        echo
        print_success "IPv6: $active active out of $tested tested"
    fi

    echo
    print_success "Connectivity testing complete"
    echo
    read -p "Press Enter to continue..."
}

# Add new peers to config
add_peers_menu() {
    print_header "Add New Peers to Config"

    local active_ipv4="$WORK_DIR/active_ipv4.json"
    local active_ipv6="$WORK_DIR/active_ipv6.json"

    if [ ! -f "$active_ipv4" ] || [ ! -f "$active_ipv6" ]; then
        print_error "No tested peers found. Please run 'Test peer connectivity' first."
        echo
        read -p "Press Enter to continue..."
        return
    fi

    local count_ipv4=$(jq 'length' "$active_ipv4")
    local count_ipv6=$(jq 'length' "$active_ipv6")

    echo "Active peers available to add:"
    echo "  IPv4: $count_ipv4"
    echo "  IPv6: $count_ipv6"
    echo

    if [ "$count_ipv4" -eq 0 ] && [ "$count_ipv6" -eq 0 ]; then
        print_warning "No active peers to add"
        echo
        read -p "Press Enter to continue..."
        return
    fi

    # Show samples
    if [ "$count_ipv4" -gt 0 ]; then
        print_subheader "Sample Active IPv4 Peers"
        show_peer_details "$active_ipv4" 3
    fi

    if [ "$count_ipv6" -gt 0 ]; then
        print_subheader "Sample Active IPv6 Peers"
        show_peer_details "$active_ipv6" 3
    fi

    if ! ask_yes_no "Add these peers to your config?"; then
        return
    fi

    # Backup config
    print_subheader "Creating Backup"
    local backup
    if backup=$(backup_config "$CJDNS_CONFIG" "$WORK_DIR"); then
        print_success "Backup created: $backup"
    else
        print_error "Failed to create backup"
        return
    fi

    # Add peers
    print_subheader "Adding Peers"

    local temp_config="$WORK_DIR/config.tmp"
    cp "$CJDNS_CONFIG" "$temp_config"

    if [ "$count_ipv4" -gt 0 ]; then
        if add_peers_to_config "$temp_config" "$active_ipv4" 0 "$temp_config.new"; then
            mv "$temp_config.new" "$temp_config"
            print_success "Added $count_ipv4 IPv4 peers"
        else
            print_error "Failed to add IPv4 peers"
            return
        fi
    fi

    if [ "$count_ipv6" -gt 0 ]; then
        if add_peers_to_config "$temp_config" "$active_ipv6" 1 "$temp_config.new"; then
            mv "$temp_config.new" "$temp_config"
            print_success "Added $count_ipv6 IPv6 peers"
        else
            print_error "Failed to add IPv6 peers"
            return
        fi
    fi

    # Validate
    if validate_config "$temp_config"; then
        sudo cp "$temp_config" "$CJDNS_CONFIG"
        print_success "Config updated successfully"

        echo
        print_info "Backup saved at: $backup"

        if ask_yes_no "Restart cjdns service now to apply changes?"; then
            restart_service
        fi
    else
        print_error "Config validation failed - changes NOT applied"
        echo "Backup is safe at: $backup"
    fi

    echo
    read -p "Press Enter to continue..."
}

# Remove unresponsive peers
remove_unresponsive_peers() {
    print_header "Remove Unresponsive Peers"

    local peer_states="$WORK_DIR/peer_states.txt"
    get_current_peer_states "$ADMIN_IP" "$ADMIN_PORT" "$ADMIN_PASSWORD" "$peer_states"

    local unresponsive_ipv4="$WORK_DIR/unresponsive_ipv4.txt"
    grep "^UNRESPONSIVE|" "$peer_states" | cut -d'|' -f2 | grep -v '^\[' > "$unresponsive_ipv4" || touch "$unresponsive_ipv4"

    local count=$(wc -l < "$unresponsive_ipv4")

    if [ "$count" -eq 0 ]; then
        print_success "No unresponsive IPv4 peers found"
        echo
        read -p "Press Enter to continue..."
        return
    fi

    echo "Found $count unresponsive IPv4 peers:"
    echo
    cat "$unresponsive_ipv4" | nl
    echo

    if ! ask_yes_no "Remove these peers from config?"; then
        return
    fi

    # Backup
    local backup
    if backup=$(backup_config "$CJDNS_CONFIG" "$WORK_DIR"); then
        print_success "Backup created: $backup"
    else
        print_error "Failed to create backup"
        return
    fi

    # Remove peers
    local temp_config="$WORK_DIR/config.tmp"
    mapfile -t dead_addrs < "$unresponsive_ipv4"

    remove_peers_from_config "$CJDNS_CONFIG" 0 "$temp_config" "${dead_addrs[@]}"

    if validate_config "$temp_config"; then
        sudo cp "$temp_config" "$CJDNS_CONFIG"
        print_success "Removed $count unresponsive peers"

        if ask_yes_no "Restart cjdns service now?"; then
            restart_service
        fi
    else
        print_error "Config validation failed - changes NOT applied"
    fi

    echo
    read -p "Press Enter to continue..."
}

# Restart cjdns service
restart_service() {
    print_header "Restart CJDNS Service"

    if [ -z "$CJDNS_SERVICE" ]; then
        print_warning "Service name not detected"
        CJDNS_SERVICE=$(ask_input "Enter cjdns service name" "cjdroute")
    fi

    echo "Restarting $CJDNS_SERVICE..."

    if sudo systemctl restart "$CJDNS_SERVICE"; then
        print_success "Service restarted successfully"
        sleep 2

        if test_cjdnstool_connection "$ADMIN_IP" "$ADMIN_PORT" "$ADMIN_PASSWORD"; then
            print_success "cjdns is running and responding"
        else
            print_warning "Service restarted but not responding yet (may take a moment)"
        fi
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
            1)
                view_peer_status
                ;;
            2)
                discover_new_peers
                ;;
            3)
                test_peer_connectivity_menu
                ;;
            4)
                add_peers_menu
                ;;
            5)
                remove_unresponsive_peers
                ;;
            6)
                restart_service
                ;;
            0)
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

#!/usr/bin/env bash
# Editor Module - Interactive config editing

# Detect available editor
get_editor() {
    if command -v micro &>/dev/null; then
        echo "micro"
    elif command -v nano &>/dev/null; then
        echo "nano"
    elif command -v vim &>/dev/null; then
        echo "vim"
    else
        echo "vi"
    fi
}

# Edit admin section
edit_admin_section() {
    local config="$1"
    local temp_section="$WORK_DIR/edit_admin.json"
    local temp_config="$WORK_DIR/config_new.json"

    # Extract admin section
    jq '.admin' "$config" > "$temp_section"

    print_info "Editing admin section..."
    echo "Current values:"
    cat "$temp_section"
    echo
    print_info "Press Enter to open editor..."
    read -r

    # Open in editor
    local editor=$(get_editor)
    $editor "$temp_section"

    # Validate JSON
    if ! jq empty "$temp_section" 2>/dev/null; then
        print_error "Invalid JSON in edited section"
        return 1
    fi

    # Merge back
    jq --slurpfile admin "$temp_section" '.admin = $admin[0]' "$config" > "$temp_config"

    if validate_config "$temp_config"; then
        print_success "Admin section updated"
        return 0
    else
        print_error "Config validation failed"
        return 1
    fi
}

# Edit authorized passwords
edit_authorized_passwords() {
    local config="$1"
    local temp_section="$WORK_DIR/edit_authpw.json"
    local temp_config="$WORK_DIR/config_new.json"

    # Extract authorizedPasswords
    jq '.authorizedPasswords' "$config" > "$temp_section"

    print_info "Editing authorized passwords..."
    echo "Current values:"
    cat "$temp_section"
    echo
    print_info "Press Enter to open editor..."
    read -r

    local editor=$(get_editor)
    $editor "$temp_section"

    if ! jq empty "$temp_section" 2>/dev/null; then
        print_error "Invalid JSON in edited section"
        return 1
    fi

    jq --slurpfile authpw "$temp_section" '.authorizedPasswords = $authpw[0]' "$config" > "$temp_config"

    if validate_config "$temp_config"; then
        print_success "Authorized passwords updated"
        return 0
    else
        print_error "Config validation failed"
        return 1
    fi
}

# Edit IPv4 peers (UDPInterface[0].connectTo)
edit_ipv4_peers() {
    local config="$1"
    local temp_section="$WORK_DIR/edit_ipv4.json"
    local temp_config="$WORK_DIR/config_new.json"

    # Extract IPv4 peers
    jq '.interfaces.UDPInterface[0].connectTo // {}' "$config" > "$temp_section"

    print_info "Editing IPv4 peers..."
    echo "Found $(jq 'length' "$temp_section") IPv4 peers"
    echo
    print_info "Press Enter to open editor..."
    read -r

    local editor=$(get_editor)
    $editor "$temp_section"

    if ! jq empty "$temp_section" 2>/dev/null; then
        print_error "Invalid JSON in edited section"
        return 1
    fi

    # Merge back
    jq --slurpfile peers "$temp_section" '
        if .interfaces.UDPInterface[0] then
            .interfaces.UDPInterface[0].connectTo = $peers[0]
        else
            .interfaces.UDPInterface[0] = {"connectTo": $peers[0]}
        end
    ' "$config" > "$temp_config"

    if validate_config "$temp_config"; then
        print_success "IPv4 peers updated"
        return 0
    else
        print_error "Config validation failed"
        return 1
    fi
}

# Edit IPv6 peers (UDPInterface[1].connectTo)
edit_ipv6_peers() {
    local config="$1"
    local temp_section="$WORK_DIR/edit_ipv6.json"
    local temp_config="$WORK_DIR/config_new.json"

    # Check if IPv6 interface exists
    local has_ipv6=$(jq '.interfaces.UDPInterface[1] // null' "$config")

    if [ "$has_ipv6" = "null" ]; then
        print_warning "No IPv6 interface found in config"
        if ! ask_yes_no "Create IPv6 interface?"; then
            return 1
        fi
        echo '{}' > "$temp_section"
    else
        jq '.interfaces.UDPInterface[1].connectTo // {}' "$config" > "$temp_section"
    fi

    print_info "Editing IPv6 peers..."
    echo "Found $(jq 'length' "$temp_section") IPv6 peers"
    echo
    print_info "Press Enter to open editor..."
    read -r

    local editor=$(get_editor)
    $editor "$temp_section"

    if ! jq empty "$temp_section" 2>/dev/null; then
        print_error "Invalid JSON in edited section"
        return 1
    fi

    # Merge back
    if [ "$has_ipv6" = "null" ]; then
        # Create new IPv6 interface with IPv6 bind address prompt
        print_info "Creating new IPv6 interface"
        local ipv6_bind=$(ask_input "Enter IPv6 bind address (e.g., [::]:PORT or [2001:db8::1]:PORT)")

        jq --slurpfile peers "$temp_section" --arg bind "$ipv6_bind" '
            .interfaces.UDPInterface[1] = {
                "bind": $bind,
                "connectTo": $peers[0]
            }
        ' "$config" > "$temp_config"
    else
        jq --slurpfile peers "$temp_section" '
            .interfaces.UDPInterface[1].connectTo = $peers[0]
        ' "$config" > "$temp_config"
    fi

    if validate_config "$temp_config"; then
        print_success "IPv6 peers updated"
        return 0
    else
        print_error "Config validation failed"
        return 1
    fi
}

# Edit IPv4 interface settings (bind, beacon, etc)
edit_ipv4_interface() {
    local config="$1"
    local temp_section="$WORK_DIR/edit_ipv4_iface.json"
    local temp_config="$WORK_DIR/config_new.json"

    # Extract IPv4 interface (without connectTo)
    jq '.interfaces.UDPInterface[0] | del(.connectTo)' "$config" > "$temp_section"

    print_info "Editing IPv4 interface settings (bind, beacon, etc)..."
    echo "Current values:"
    cat "$temp_section"
    echo
    print_warning "Do NOT edit 'connectTo' here - use 'Edit IPv4 Peers' instead"
    print_info "Press Enter to open editor..."
    read -r

    local editor=$(get_editor)
    $editor "$temp_section"

    if ! jq empty "$temp_section" 2>/dev/null; then
        print_error "Invalid JSON in edited section"
        return 1
    fi

    # Merge back (preserve connectTo)
    jq --slurpfile iface "$temp_section" '
        .interfaces.UDPInterface[0] = ($iface[0] + {"connectTo": .interfaces.UDPInterface[0].connectTo})
    ' "$config" > "$temp_config"

    if validate_config "$temp_config"; then
        print_success "IPv4 interface settings updated"
        return 0
    else
        print_error "Config validation failed"
        return 1
    fi
}

# Edit IPv6 interface settings
edit_ipv6_interface() {
    local config="$1"
    local temp_section="$WORK_DIR/edit_ipv6_iface.json"
    local temp_config="$WORK_DIR/config_new.json"

    local has_ipv6=$(jq '.interfaces.UDPInterface[1] // null' "$config")

    if [ "$has_ipv6" = "null" ]; then
        print_error "No IPv6 interface found. Create one via 'Edit IPv6 Peers' first."
        return 1
    fi

    # Extract IPv6 interface (without connectTo)
    jq '.interfaces.UDPInterface[1] | del(.connectTo)' "$config" > "$temp_section"

    print_info "Editing IPv6 interface settings..."
    echo "Current values:"
    cat "$temp_section"
    echo
    print_warning "Do NOT edit 'connectTo' here - use 'Edit IPv6 Peers' instead"
    print_info "Press Enter to open editor..."
    read -r

    local editor=$(get_editor)
    $editor "$temp_section"

    if ! jq empty "$temp_section" 2>/dev/null; then
        print_error "Invalid JSON in edited section"
        return 1
    fi

    # Merge back (preserve connectTo)
    jq --slurpfile iface "$temp_section" '
        .interfaces.UDPInterface[1] = ($iface[0] + {"connectTo": .interfaces.UDPInterface[1].connectTo})
    ' "$config" > "$temp_config"

    if validate_config "$temp_config"; then
        print_success "IPv6 interface settings updated"
        return 0
    else
        print_error "Config validation failed"
        return 1
    fi
}

# Edit router section (seeds, tunnels, etc)
edit_router_section() {
    local config="$1"
    local temp_section="$WORK_DIR/edit_router.json"
    local temp_config="$WORK_DIR/config_new.json"

    jq '.router // {}' "$config" > "$temp_section"

    print_info "Editing router section (DNS seeds, tunnels, etc)..."
    echo "Current values:"
    cat "$temp_section"
    echo
    print_info "Press Enter to open editor..."
    read -r

    local editor=$(get_editor)
    $editor "$temp_section"

    if ! jq empty "$temp_section" 2>/dev/null; then
        print_error "Invalid JSON in edited section"
        return 1
    fi

    jq --slurpfile router "$temp_section" '.router = $router[0]' "$config" > "$temp_config"

    if validate_config "$temp_config"; then
        print_success "Router section updated"
        return 0
    else
        print_error "Config validation failed"
        return 1
    fi
}

# Main config editor menu
config_editor_menu() {
    while true; do
        clear
        print_ascii_header
        print_header "Config File Editor"

        echo "Config: $CJDNS_CONFIG"
        echo "Editor: $(get_editor)"
        echo
        echo "What would you like to edit?"
        echo
        echo "1) Admin Section (bind IP, password)"
        echo "2) Authorized Passwords"
        echo "3) IPv4 Peers (connectTo)"
        echo "4) IPv6 Peers (connectTo)"
        echo "5) IPv4 Interface Settings (bind, beacon, beaconDevices)"
        echo "6) IPv6 Interface Settings (bind, beacon)"
        echo "7) Router Section (DNS seeds, tunnels, publicPeer)"
        echo "8) Full Config (edit entire file - ADVANCED)"
        echo "0) Back to Main Menu"
        echo

        local choice
        read -p "Enter choice: " choice

        case "$choice" in
            1|2|3|4|5|6|7)
                # Create backup first
                local backup
                if backup=$(backup_config "$CJDNS_CONFIG"); then
                    print_success "Backup created: $backup"
                else
                    print_error "Failed to create backup"
                    sleep 2
                    continue
                fi

                local temp_config="$WORK_DIR/config_new.json"

                case "$choice" in
                    1) edit_admin_section "$CJDNS_CONFIG" ;;
                    2) edit_authorized_passwords "$CJDNS_CONFIG" ;;
                    3) edit_ipv4_peers "$CJDNS_CONFIG" ;;
                    4) edit_ipv6_peers "$CJDNS_CONFIG" ;;
                    5) edit_ipv4_interface "$CJDNS_CONFIG" ;;
                    6) edit_ipv6_interface "$CJDNS_CONFIG" ;;
                    7) edit_router_section "$CJDNS_CONFIG" ;;
                esac

                if [ $? -eq 0 ]; then
                    if [ -f "$temp_config" ]; then
                        cp "$temp_config" "$CJDNS_CONFIG"
                        print_success "Config file updated!"

                        if ask_yes_no "Restart cjdns service now?"; then
                            restart_service
                        fi
                    fi
                fi

                echo
                read -p "Press Enter to continue..."
                ;;
            8)
                print_warning "ADVANCED: Editing entire config file"
                print_warning "Make sure you know what you're doing!"
                echo
                if ! ask_yes_no "Continue?"; then
                    continue
                fi

                local backup
                if backup=$(backup_config "$CJDNS_CONFIG"); then
                    print_success "Backup created: $backup"
                else
                    print_error "Failed to create backup"
                    sleep 2
                    continue
                fi

                local editor=$(get_editor)
                $editor "$CJDNS_CONFIG"

                if validate_config "$CJDNS_CONFIG"; then
                    print_success "Config file is valid"
                    if ask_yes_no "Restart cjdns service now?"; then
                        restart_service
                    fi
                else
                    print_error "Config file is INVALID!"
                    if ask_yes_no "Restore from backup?"; then
                        cp "$backup" "$CJDNS_CONFIG"
                        print_success "Config restored from backup"
                    fi
                fi

                echo
                read -p "Press Enter to continue..."
                ;;
            0)
                return
                ;;
            *)
                print_error "Invalid choice"
                sleep 1
                ;;
        esac
    done
}

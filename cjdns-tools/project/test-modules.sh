#!/usr/bin/env bash
# Test each module independently

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/detect.sh"
source "$SCRIPT_DIR/lib/peers.sh"
source "$SCRIPT_DIR/lib/config.sh"

print_header "CJDNS Manager - Module Testing"

echo "This script will test each module individually"
echo

# Test 1: Detection
print_subheader "Test 1: Auto-Detection"
echo "Testing service detection..."

if result=$(detect_cjdns_service); then
    SERVICE=$(echo "$result" | cut -d'|' -f1)
    CONFIG=$(echo "$result" | cut -d'|' -f2)
    print_success "Detected service: $SERVICE"
    print_success "Detected config: $CONFIG"
else
    print_warning "Auto-detection failed - will list configs"
    echo "Available configs:"
    list_cjdns_configs
fi

echo
read -p "Press Enter to continue..."

# Test 2: Config validation
print_subheader "Test 2: Config Validation"

if [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
    echo "Validating: $CONFIG"
    if validate_config "$CONFIG"; then
        print_success "Config is valid JSON"

        echo
        echo "Admin info:"
        admin_info=$(get_admin_info "$CONFIG")
        echo "  $admin_info"

        ADMIN_IP=$(echo "$admin_info" | cut -d'|' -f1 | cut -d':' -f1)
        ADMIN_PORT=$(echo "$admin_info" | cut -d'|' -f1 | cut -d':' -f2)
        ADMIN_PASSWORD=$(echo "$admin_info" | cut -d'|' -f2)

        echo
        echo "IPv4 interface peers: $(get_peer_count "$CONFIG" 0)"
        echo "IPv6 interface peers: $(get_peer_count "$CONFIG" 1)"
    else
        print_error "Config validation failed"
    fi
fi

echo
read -p "Press Enter to continue..."

# Test 3: cjdnstool connection
print_subheader "Test 3: cjdnstool Connection"

if [ -n "$ADMIN_IP" ]; then
    echo "Testing connection to $ADMIN_IP:$ADMIN_PORT..."
    if test_cjdnstool_connection "$ADMIN_IP" "$ADMIN_PORT" "$ADMIN_PASSWORD"; then
        print_success "Successfully connected to cjdns"

        echo
        echo "Getting peer states..."
        TEMP=$(mktemp)
        get_current_peer_states "$ADMIN_IP" "$ADMIN_PORT" "$ADMIN_PASSWORD" "$TEMP"

        echo "Total peers: $(wc -l < "$TEMP")"
        echo "First 5 peers:"
        head -5 "$TEMP"

        rm -f "$TEMP"
    else
        print_error "Cannot connect to cjdns"
    fi
fi

echo
read -p "Press Enter to continue..."

# Test 4: Backup functionality
print_subheader "Test 4: Backup Functionality"

if [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
    echo "Creating test backup..."
    BACKUP=$(backup_config "$CONFIG" "/tmp")
    if [ -f "$BACKUP" ]; then
        print_success "Backup created: $BACKUP"
        echo "Backup size: $(ls -lh "$BACKUP" | awk '{print $5}')"
    else
        print_error "Backup failed"
    fi
fi

echo
print_header "Testing Complete"
echo "All modules tested individually"

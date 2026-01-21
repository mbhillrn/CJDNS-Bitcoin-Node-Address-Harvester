#!/usr/bin/env bash
# Config Module - Safe manipulation of cjdns config files

# Default backup directory (persistent, not /tmp)
BACKUP_DIR="/etc/cjdns_backups"

# Create backup of config file
backup_config() {
    local config_file="$1"
    local backup_dir="${2:-$BACKUP_DIR}"

    # Validate config before backing it up
    if ! validate_config "$config_file"; then
        print_warning "Config file has validation issues - backup may not be restorable"
        if ! ask_yes_no "Create backup anyway?"; then
            return 1
        fi
    fi

    # Create backup directory if it doesn't exist
    if ! mkdir -p "$backup_dir" 2>/dev/null; then
        print_error "Cannot create backup directory: $backup_dir"
        return 1
    fi

    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/cjdroute_backup_$timestamp.conf"

    if cp "$config_file" "$backup_file"; then
        echo "$backup_file"
        return 0
    else
        return 1
    fi
}

# List all backups in backup directory
list_backups() {
    local backup_dir="${1:-$BACKUP_DIR}"

    if [ ! -d "$backup_dir" ]; then
        return 1
    fi

    find "$backup_dir" -name "cjdroute_backup_*.conf" -type f 2>/dev/null | sort -r
}

# Restore config from backup
restore_config() {
    local backup_file="$1"
    local config_file="$2"

    if [ ! -f "$backup_file" ]; then
        print_error "Backup file not found: $backup_file"
        return 1
    fi

    # Validate backup before restoring
    if ! validate_config "$backup_file"; then
        print_error "Backup file is not a valid config"
        return 1
    fi

    # Create a backup of current config before restoring
    local safety_backup
    if safety_backup=$(backup_config "$config_file" "$BACKUP_DIR/safety"); then
        print_info "Created safety backup: $safety_backup"
    fi

    if cp "$backup_file" "$config_file"; then
        return 0
    else
        return 1
    fi
}

# Validate JSON config file
validate_config() {
    local config_file="$1"

    if ! jq empty "$config_file" 2>/dev/null; then
        return 1
    fi

    # Check for required fields
    if ! jq -e '.interfaces.UDPInterface' "$config_file" &>/dev/null; then
        return 1
    fi

    return 0
}

# Add peers to config file (preserves all fields exactly as they appear)
add_peers_to_config() {
    local config_file="$1"
    local peers_json="$2"
    local interface_index="$3"
    local temp_config="$4"

    # First, ensure the interface has a connectTo field
    # If it doesn't exist, create it as an empty object
    jq --argjson idx "$interface_index" '
        if .interfaces.UDPInterface[$idx].connectTo == null then
            .interfaces.UDPInterface[$idx].connectTo = {}
        else
            .
        end
    ' "$config_file" > "$temp_config.tmp"

    # Now merge peers into the interface
    # This preserves ALL fields from the peers_json without modification
    jq --slurpfile new_peers "$peers_json" --argjson idx "$interface_index" \
        '.interfaces.UDPInterface[$idx].connectTo += $new_peers[0]' \
        "$temp_config.tmp" > "$temp_config"

    rm -f "$temp_config.tmp"

    return $?
}

# Get peer count from config
get_peer_count() {
    local config_file="$1"
    local interface_index="$2"

    # Return 0 if connectTo doesn't exist or is null
    jq --argjson idx "$interface_index" \
        '.interfaces.UDPInterface[$idx].connectTo // {} | length' \
        "$config_file" 2>/dev/null || echo 0
}

# Remove peers from config by address
remove_peers_from_config() {
    local config_file="$1"
    local interface_index="$2"
    local temp_config="$3"
    shift 3
    local addresses=("$@")

    cp "$config_file" "$temp_config"

    for addr in "${addresses[@]}"; do
        jq --arg addr "$addr" \
            "del(.interfaces.UDPInterface[$interface_index].connectTo[\$addr])" \
            "$temp_config" > "$temp_config.tmp"
        mv "$temp_config.tmp" "$temp_config"
    done

    return 0
}

# Extract peers from config by state (requires cjdnstool connection)
get_peers_by_state() {
    local peer_states_file="$1"
    local state="$2"
    local output_file="$3"

    grep "^$state|" "$peer_states_file" | cut -d'|' -f2 > "$output_file"

    return 0
}

# Show peer details from JSON file
show_peer_details() {
    local peers_json="$1"
    local max_count="${2:-5}"

    local total=$(jq 'length' "$peers_json")

    if [ "$total" -eq 0 ]; then
        echo "No peers found"
        return
    fi

    echo "Showing first $max_count of $total peers:"
    echo

    jq -r --argjson max "$max_count" '
        to_entries[:$max][] |
        "Address:    \(.key)",
        "PublicKey:  \(.value.publicKey)",
        "Password:   \(.value.password)",
        (if .value.peerName then "PeerName:   \(.value.peerName)" else empty end),
        (if .value.contact then "Contact:    \(.value.contact)" else empty end),
        (if .value.login then "Login:      \(.value.login)" else empty end),
        (if .value.location then "Location:   \(.value.location)" else empty end),
        (if .value.gpg then "GPG:        \(.value.gpg)" else empty end),
        ""
    ' "$peers_json"

    if [ "$total" -gt "$max_count" ]; then
        echo "... and $((total - max_count)) more peers"
    fi
}

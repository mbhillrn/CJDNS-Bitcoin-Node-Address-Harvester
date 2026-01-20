#!/usr/bin/env bash
# CJDNS Detection Module
# Auto-detects cjdns config file, service, and admin credentials

# Find the active cjdns service
detect_cjdns_service() {
    local services

    # Find all services with 'cjd' in the name
    services=$(systemctl list-units --type=service --all --no-pager 2>/dev/null | grep -i 'cjd' | awk '{print $1}' || echo "")

    if [ -z "$services" ]; then
        return 1
    fi

    # Check each service to find one with a valid cjdroute config
    while IFS= read -r service; do
        [ -z "$service" ] && continue

        # Get service status to check if it references a config file
        local service_info
        service_info=$(systemctl status "$service" 2>/dev/null || echo "")

        # Look for /etc/cjdroute_*.conf pattern in service output
        local config_file
        config_file=$(echo "$service_info" | grep -oP '/etc/cjdroute_[0-9]+\.conf' | head -1 || echo "")

        if [ -n "$config_file" ] && [ -f "$config_file" ]; then
            echo "$service|$config_file"
            return 0
        fi

        # Alternative: check if service file itself references a config
        local service_file="/etc/systemd/system/$service"
        if [ -f "$service_file" ]; then
            config_file=$(grep -oP '/etc/cjdroute_[0-9]+\.conf' "$service_file" | head -1 || echo "")
            if [ -n "$config_file" ] && [ -f "$config_file" ]; then
                echo "$service|$config_file"
                return 0
            fi
        fi
    done <<< "$services"

    return 1
}

# Find cjdns config files manually (fallback)
list_cjdns_configs() {
    # Only match files like cjdroute_NNNN.conf (not backups)
    find /etc -maxdepth 1 -name 'cjdroute_*.conf' -type f ! -name '*.backup*' ! -name '*.bak*' ! -name '*.old*' 2>/dev/null | sort
}

# Extract admin connection info from config
get_admin_info() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    local bind password
    bind=$(jq -r '.admin.bind // empty' "$config_file" 2>/dev/null)
    password=$(jq -r '.admin.password // empty' "$config_file" 2>/dev/null)

    if [ -z "$bind" ]; then
        return 1
    fi

    echo "$bind|$password"
    return 0
}

# Check cjdnstool version and availability
check_cjdnstool() {
    if ! command -v cjdnstool &>/dev/null; then
        return 1
    fi

    local version
    version=$(cjdnstool --version 2>/dev/null | head -1 || echo "unknown")
    echo "$version"
    return 0
}

# Validate that cjdnstool can connect to cjdns
test_cjdnstool_connection() {
    local admin_ip="$1"
    local admin_port="$2"
    local admin_password="$3"

    # Try to get peer stats (page 0)
    if cjdnstool -a "$admin_ip" -p "$admin_port" -P "$admin_password" cexec InterfaceController_peerStats --page=0 2>/dev/null | jq empty 2>/dev/null; then
        return 0
    fi

    return 1
}

#!/usr/bin/env bash
# CJDNS Harvester v5 - Remote Host Configuration

# Global arrays for remote host configuration
declare -g -a REMOTE_HOSTS=()
declare -g -a REMOTE_USERS=()

# ============================================================================
# SSH Connection Testing (Key-based only)
# ============================================================================
test_ssh_keys() {
    local host="$1"
    local user="$2"

    # Test basic SSH connection with keys only
    if ! ssh -o ConnectTimeout=5 \
             -o BatchMode=yes \
             -o PasswordAuthentication=no \
             -o StrictHostKeyChecking=accept-new \
             "${user}@${host}" 'echo test' >/dev/null 2>&1; then
        return 1
    fi

    # Test cjdnstool availability
    if ! ssh -o ConnectTimeout=5 \
             -o BatchMode=yes \
             -o PasswordAuthentication=no \
             -o StrictHostKeyChecking=accept-new \
             "${user}@${host}" 'command -v cjdnstool' >/dev/null 2>&1; then
        status_error "cjdnstool not found on remote host"
        echo "Install with: npm install -g cjdnstool"
        return 1
    fi

    # Test CJDNS admin connection
    if ! ssh -o ConnectTimeout=5 \
             -o BatchMode=yes \
             -o PasswordAuthentication=no \
             -o StrictHostKeyChecking=accept-new \
             "${user}@${host}" \
             'cjdnstool -a 127.0.0.1 -p 11234 -P NONE cexec Core_nodeInfo' >/dev/null 2>&1; then
        status_error "CJDNS not responding on remote host (or wrong port)"
        echo "Make sure CJDNS is running on ${host} and admin port is 11234"
        return 1
    fi

    return 0
}

# ============================================================================
# Remote Host Configuration
# ============================================================================
configure_remote_hosts() {
    local host_num=1

    while true; do
        echo
        printf "${C_HEADER}Remote Host #%d${C_RESET}\n" "$host_num"
        echo

        # Get host address
        local host
        while true; do
            read -r -p "Remote host address (IP or hostname) [empty to finish]: " host
            host="${host// /}"  # trim spaces

            if [[ -z "$host" ]]; then
                if [[ "$host_num" -eq 1 ]]; then
                    status_info "No remote hosts configured"
                fi
                return 0
            fi

            # Basic validation
            if [[ "$host" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                break
            else
                printf "${C_ERROR}Invalid hostname/IP. Try again.${C_RESET}\n"
            fi
        done

        # Get username
        local user
        while true; do
            read -r -p "SSH username for $host: " user
            user="${user// /}"
            if [[ -n "$user" ]]; then
                break
            else
                printf "${C_ERROR}Username required. Try again.${C_RESET}\n"
            fi
        done

        # Test if SSH keys already work
        echo
        printf "  "
        show_progress "Testing connection"

        if test_ssh_keys "$host" "$user"; then
            show_progress_done
            status_ok "Already configured"

            # Add to arrays
            REMOTE_HOSTS+=("$host")
            REMOTE_USERS+=("$user")

            host_num=$((host_num + 1))
        else
            printf "${C_WARNING}login required${C_RESET}\n"
            echo

            # Ensure SSH key exists (silently)
            if [[ ! -f ~/.ssh/id_rsa ]]; then
                ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa -q >/dev/null 2>&1
            fi

            # Run ssh-copy-id - let it prompt for password
            echo "  Setting up automatic login..."
            echo
            if ssh-copy-id -o ConnectTimeout=10 "${user}@${host}" 2>&1 | \
               sed '/^\/usr\/bin\/ssh-copy-id: INFO:/d; /^Number of key(s) added:/d'; then
                echo
                status_ok "Automatic login configured"

                # Verify it works
                if test_ssh_keys "$host" "$user" 2>/dev/null; then
                    # Add to arrays
                    REMOTE_HOSTS+=("$host")
                    REMOTE_USERS+=("$user")
                    host_num=$((host_num + 1))
                else
                    status_error "Verification failed - host not added"
                fi
            else
                echo
                status_error "Setup failed"
            fi
        fi

        echo

        # Ask about adding another host
        local add_another
        while true; do
            read -r -p "Add another remote host? [y/N]: " add_another
            add_another="${add_another,,}"

            if [[ "$add_another" == "y" || "$add_another" == "yes" ]]; then
                break  # Continue outer loop
            elif [[ "$add_another" == "n" || "$add_another" == "no" || -z "$add_another" ]]; then
                # Summary
                if [[ "${#REMOTE_HOSTS[@]}" -gt 0 ]]; then
                    echo
                    printf "${C_SUCCESS}${C_BOLD}Configured %d remote host(s):${C_RESET}\n" "${#REMOTE_HOSTS[@]}"
                    for i in "${!REMOTE_HOSTS[@]}"; do
                        printf "  %d. ${C_INFO}%s@%s${C_RESET} ${C_DIM}(SSH keys)${C_RESET}\n" \
                            "$((i + 1))" "${REMOTE_USERS[$i]}" "${REMOTE_HOSTS[$i]}"
                    done
                fi
                return 0
            else
                printf "${C_ERROR}Invalid response. Please answer 'y' or 'n'.${C_RESET}\n"
            fi
        done
    done
}

# ============================================================================
# SSH Command Execution (Keys only)
# ============================================================================
exec_ssh_command() {
    local idx="$1"
    local remote_command="$2"

    local host="${REMOTE_HOSTS[$idx]}"
    local user="${REMOTE_USERS[$idx]}"

    ssh -o ConnectTimeout=10 \
        -o BatchMode=yes \
        -o PasswordAuthentication=no \
        -o StrictHostKeyChecking=accept-new \
        -o LogLevel=ERROR \
        "${user}@${host}" \
        "$remote_command"
}

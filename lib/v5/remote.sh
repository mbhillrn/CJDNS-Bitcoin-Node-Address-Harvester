#!/usr/bin/env bash
# CJDNS Harvester v5 - Remote Host Configuration

# Global arrays for remote host configuration
declare -g -a REMOTE_HOSTS=()
declare -g -a REMOTE_USERS=()
declare -g -a REMOTE_PASSWORDS=()
declare -g -a REMOTE_USE_SSHPASS=()

# ============================================================================
# SSH Connection Testing
# ============================================================================
test_ssh_connection() {
    local host="$1"
    local user="$2"
    local password="$3"
    local use_sshpass="$4"

    local ssh_cmd="ssh"
    local ssh_opts="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o PasswordAuthentication=no"

    if [[ "$use_sshpass" == "yes" && -n "$password" ]]; then
        ssh_opts="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
        if ! command -v sshpass >/dev/null 2>&1; then
            status_error "sshpass not installed (required for password auth)"
            echo "Install with: sudo apt-get install sshpass"
            return 1
        fi
        ssh_cmd="sshpass -p '$password' ssh"
    fi

    # Test basic SSH connection
    if ! eval "$ssh_cmd $ssh_opts ${user}@${host} 'echo test'" >/dev/null 2>&1; then
        return 1
    fi

    # Test cjdnstool availability
    if ! eval "$ssh_cmd $ssh_opts ${user}@${host} 'command -v cjdnstool'" >/dev/null 2>&1; then
        status_error "cjdnstool not found on remote host"
        return 1
    fi

    # Test CJDNS admin connection
    if ! eval "$ssh_cmd $ssh_opts ${user}@${host} 'cjdnstool -a 127.0.0.1 -p 11234 -P NONE cexec Core_nodeInfo'" >/dev/null 2>&1; then
        status_error "CJDNS not responding on remote host"
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
        read -r -p "Remote host address (IP or hostname) [empty to finish]: " host
        host="${host// /}"  # trim spaces

        if [[ -z "$host" ]]; then
            if [[ "$host_num" -eq 1 ]]; then
                status_info "No remote hosts configured"
            fi
            break
        fi

        # Get username
        local user
        read -r -p "SSH username for $host: " user
        user="${user// /}"
        if [[ -z "$user" ]]; then
            status_warn "Username required, skipping this host"
            continue
        fi

        # Ask about authentication method
        echo
        echo "Authentication method:"
        echo "  1) SSH key (passwordless)"
        echo "  2) Password"
        echo
        local auth_choice
        read -r -p "Choice [1/2]: " auth_choice

        local password=""
        local use_sshpass="no"

        if [[ "$auth_choice" == "2" ]]; then
            # Password authentication
            read -r -s -p "Password for ${user}@${host}: " password
            echo
            use_sshpass="yes"
        fi

        # Test connection
        printf "\n  "
        show_progress "Testing connection to ${user}@${host}"

        if test_ssh_connection "$host" "$user" "$password" "$use_sshpass"; then
            show_progress_done
            status_ok "Connection successful"

            # Add to arrays
            REMOTE_HOSTS+=("$host")
            REMOTE_USERS+=("$user")
            REMOTE_PASSWORDS+=("$password")
            REMOTE_USE_SSHPASS+=("$use_sshpass")

            host_num=$((host_num + 1))
        else
            show_progress_fail
            status_error "Connection failed - host not added"
            echo

            # Offer to set up SSH keys
            if [[ "$auth_choice" == "2" || -z "$auth_choice" ]]; then
                echo "Would you like to set up SSH key authentication?"
                echo "This is more secure and won't require passwords in the future."
                echo
                if prompt_yn "Run ssh-copy-id now?"; then
                    echo
                    echo "Running: ssh-copy-id ${user}@${host}"
                    echo "You'll need to enter your password one more time:"
                    echo
                    if ssh-copy-id -o ConnectTimeout=5 "${user}@${host}"; then
                        echo
                        status_ok "SSH keys configured successfully"
                        echo
                        # Retry with keys
                        printf "  "
                        show_progress "Re-testing connection with SSH keys"
                        if test_ssh_connection "$host" "$user" "" "no"; then
                            show_progress_done
                            status_ok "Connection successful with SSH keys"

                            # Add to arrays (without password)
                            REMOTE_HOSTS+=("$host")
                            REMOTE_USERS+=("$user")
                            REMOTE_PASSWORDS+=("")
                            REMOTE_USE_SSHPASS+=("no")

                            host_num=$((host_num + 1))
                        else
                            show_progress_fail
                            status_error "Still unable to connect"
                        fi
                    else
                        echo
                        status_error "ssh-copy-id failed"
                    fi
                fi
            fi
        fi

        echo
        if ! prompt_yn "Add another remote host?"; then
            break
        fi
    done

    # Summary
    if [[ "${#REMOTE_HOSTS[@]}" -gt 0 ]]; then
        echo
        printf "${C_SUCCESS}${C_BOLD}Configured %d remote host(s):${C_RESET}\n" "${#REMOTE_HOSTS[@]}"
        for i in "${!REMOTE_HOSTS[@]}"; do
            local auth_method="SSH key"
            [[ "${REMOTE_USE_SSHPASS[$i]}" == "yes" ]] && auth_method="password"
            printf "  %d. ${C_INFO}%s@%s${C_RESET} (${C_DIM}%s${C_RESET})\n" \
                "$((i + 1))" "${REMOTE_USERS[$i]}" "${REMOTE_HOSTS[$i]}" "$auth_method"
        done
    fi
}

# ============================================================================
# SSH Command Builder
# ============================================================================
build_ssh_command() {
    local idx="$1"
    local remote_command="$2"

    local host="${REMOTE_HOSTS[$idx]}"
    local user="${REMOTE_USERS[$idx]}"
    local password="${REMOTE_PASSWORDS[$idx]}"
    local use_sshpass="${REMOTE_USE_SSHPASS[$idx]}"

    local ssh_opts="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"

    if [[ "$use_sshpass" == "yes" && -n "$password" ]]; then
        printf "sshpass -p %q ssh %s %s@%s %q" "$password" "$ssh_opts" "$user" "$host" "$remote_command"
    else
        printf "ssh %s -o BatchMode=yes -o PasswordAuthentication=no %s@%s %q" "$ssh_opts" "$user" "$host" "$remote_command"
    fi
}

# ============================================================================
# Execute SSH Command
# ============================================================================
exec_ssh_command() {
    local idx="$1"
    local remote_command="$2"
    local cmd
    cmd="$(build_ssh_command "$idx" "$remote_command")"
    eval "$cmd"
}

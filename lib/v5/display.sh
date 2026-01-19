#!/usr/bin/env bash
# CJDNS Harvester v5 - Status Display Functions

# Requires: ui.sh, canon_host

# ============================================================================
# CJDNS Router Status Display
# ============================================================================
display_cjdns_router() {
    print_section "CJDNS Router Status"

    # Get node info (my address)
    local nodeinfo myip
    nodeinfo="$(cjdnstool -a "$CJDNS_ADMIN_ADDR" -p "$CJDNS_ADMIN_PORT" -P NONE cexec Core_nodeInfo 2>/dev/null)" || {
        status_error "Failed to get CJDNS node info"
        return 1
    }
    myip="$(echo "$nodeinfo" | jq -r '.myIp6 // "unknown"')"

    printf "  ${C_BOLD}My CJDNS Address:${C_RESET} ${C_SUCCESS}%s${C_RESET}\n\n" "$myip"

    # Get peer stats (paginated)
    local page=0 more=1 all_peers='[]'
    while [[ "$more" == "1" ]]; do
        local pstats
        pstats="$(cjdnstool -a "$CJDNS_ADMIN_ADDR" -p "$CJDNS_ADMIN_PORT" -P NONE cexec InterfaceController_peerStats --page="$page" 2>/dev/null)" || break

        # Merge peers
        all_peers="$(jq -cs '.[0] + (.[1].peers // [])' <(echo "$all_peers") <(echo "$pstats") 2>/dev/null)"

        # Check if more pages
        more="$(echo "$pstats" | jq -r '.more // 0' 2>/dev/null)"
        [[ "$more" == "1" ]] || break
        page=$((page + 1))
    done

    # Count peers by state
    local established unresponsive total
    established="$(echo "$all_peers" | jq '[.[] | select(.state=="ESTABLISHED")] | length' 2>/dev/null || echo 0)"
    unresponsive="$(echo "$all_peers" | jq '[.[] | select(.state=="UNRESPONSIVE")] | length' 2>/dev/null || echo 0)"
    total="$(echo "$all_peers" | jq 'length' 2>/dev/null || echo 0)"

    printf "  ${C_SUCCESS}Established:${C_RESET}   %s\n" "$established"
    printf "  ${C_MUTED}Unresponsive:${C_RESET}  %s\n" "$unresponsive"
    printf "  ${C_BOLD}Total Peers:${C_RESET}    %s\n\n" "$total"

    # Display established peers only
    if (( established > 0 )); then
        printf "  ${C_BOLD}${C_SUBHEADER}Established Peers:${C_RESET}\n\n"

        echo "$all_peers" | jq -r '.[] | select(.state=="ESTABLISHED") |
            [.lladdr, .isIncoming, .recvKbps, .sendKbps, .lostPackets, .receivedOutOfRange] |
            @tsv' 2>/dev/null | while IFS=$'\t' read -r lladdr is_incoming recv send los oor; do

            # Determine direction
            local direction
            if [[ "$is_incoming" == "1" ]]; then
                direction="$(peer_in) "
            else
                direction="$(peer_out)"
            fi

            # Format lladdr (trim if IPv6 is too long)
            local display_addr="$lladdr"
            if [[ "${#lladdr}" -gt 45 ]]; then
                display_addr="${lladdr:0:42}..."
            fi

            # Format bandwidth
            local bw_in="${recv}kb/s"
            local bw_out="${send}kb/s"

            printf "    %-46s %s  ${C_DOWNLOAD}↓%-8s${C_RESET} ${C_UPLOAD}↑%-8s${C_RESET}  ${C_MUTED}LOS:%-6s OOR:%-4s${C_RESET}\n" \
                "$display_addr" "$direction" "$bw_in" "$bw_out" "$los" "$oor"
        done
    fi

    echo
}

# ============================================================================
# Bitcoin Core Peers Display
# ============================================================================
display_bitcoin_peers() {
    print_section "Bitcoin Core CJDNS Peers"

    local peers_json
    peers_json="$(bash -c "$CLI getpeerinfo" 2>/dev/null)" || {
        status_error "Failed to get Bitcoin peer info"
        return 1
    }

    # Extract CJDNS peers
    local cjdns_peers
    cjdns_peers="$(echo "$peers_json" | jq -r '.[] | select(.network=="cjdns") |
        [.addr, .inbound] | @tsv' 2>/dev/null)"

    # Count inbound vs outbound
    local total=0 inbound=0 outbound=0
    local unique_addrs=()

    while IFS=$'\t' read -r raw is_in; do
        [[ -n "$raw" ]] || continue

        local host
        host="$(canon_host "$(cjdns_host_from_maybe_bracketed "$raw")")"
        [[ -n "$host" ]] || continue

        # Track unique addresses (Bitcoin can have same address as IN and OUT)
        if [[ ! " ${unique_addrs[*]} " =~ " ${host} " ]]; then
            unique_addrs+=("$host")
        fi

        total=$((total + 1))
        if [[ "$is_in" == "true" ]]; then
            inbound=$((inbound + 1))
        else
            outbound=$((outbound + 1))
        fi
    done <<< "$cjdns_peers"

    local unique_count=${#unique_addrs[@]}

    printf "  ${C_BOLD}Total Connections:${C_RESET}  %s (${C_INFO}%s unique${C_RESET})\n" "$total" "$unique_count"
    printf "  ${C_IN}Inbound:${C_RESET}            %s\n" "$inbound"
    printf "  ${C_OUT}Outbound:${C_RESET}           %s\n\n" "$outbound"

    if (( total > 0 )); then
        printf "  ${C_BOLD}${C_SUBHEADER}Connected Peers:${C_RESET}\n\n"

        echo "$peers_json" | jq -r '.[] | select(.network=="cjdns") |
            [.addr, .inbound] | @tsv' 2>/dev/null | while IFS=$'\t' read -r raw is_in; do
            [[ -n "$raw" ]] || continue

            local host
            host="$(canon_host "$(cjdns_host_from_maybe_bracketed "$raw")")"
            [[ -n "$host" ]] || continue

            local direction
            if [[ "$is_in" == "true" ]]; then
                direction="$(peer_in) "
            else
                direction="$(peer_out)"
            fi

            printf "    %s  %s\n" "$direction" "$host"
        done
    fi

    echo
}

# ============================================================================
# Helper to extract host from bracketed addresses
# ============================================================================
cjdns_host_from_maybe_bracketed() {
    # Extracts fc00::/8 address from "[fc..:..]:port" or "fc..:.."
    local raw="$1"
    raw="${raw#\[}"
    raw="${raw%%\]*}"
    echo "$raw"
}

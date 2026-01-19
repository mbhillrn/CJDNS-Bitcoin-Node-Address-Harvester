#!/usr/bin/env bash
# CJDNS Harvester v5 - Address Harvesting Module

# Requires: ui.sh, db.sh, frontier.sh, canon_host

# ============================================================================
# Helper Functions
# ============================================================================
cjdns_host_from_maybe_bracketed() {
    # Extracts fc00::/8 address from "[fc..:..]:port" or "fc..:.."
    local raw="$1"
    raw="${raw#\[}"
    raw="${raw%%\]*}"
    echo "$raw"
}

# ============================================================================
# NodeStore Harvesting
# ============================================================================
harvest_nodestore() {
    print_section "NodeStore Harvest"

    local page=0
    local total_seen=0 total_new=0 total_existing=0
    local all_new=()
    local all_existing=()

    printf "  ${C_DIM}Scanning pages"
    local dots=0

    while true; do
        local tmpjson="/tmp/cjdh_nodestore_p${page}.json"

        # Animate dots
        dots=$(( (dots + 1) % 4 ))
        local dot_str=""
        for ((i=0; i<dots; i++)); do dot_str="${dot_str}."; done
        printf "\r  ${C_DIM}Scanning pages%-3s${C_RESET} ${C_INFO}Page: %s${C_RESET}" "$dot_str" "$page"

        # Fetch page
        if ! cjdnstool -a "$CJDNS_ADMIN_ADDR" -p "$CJDNS_ADMIN_PORT" -P NONE cexec NodeStore_dumpTable --page="$page" >"$tmpjson" 2>/dev/null; then
            rm -f "$tmpjson"
            break
        fi

        # Check if page is empty
        local rt_len
        rt_len="$(jq '.routingTable | length' "$tmpjson" 2>/dev/null || echo 0)"
        if [[ ! "$rt_len" =~ ^[0-9]+$ ]] || (( rt_len == 0 )); then
            rm -f "$tmpjson"
            break
        fi

        # Extract addresses
        jq -r '.routingTable[]? | .ip // empty' "$tmpjson" 2>/dev/null | while IFS= read -r ip; do
            [[ -n "$ip" ]] || continue
            local host
            host="$(canon_host "$(cjdns_host_from_maybe_bracketed "$ip")")"
            [[ -n "$host" ]] || continue

            # Check if new
            if db_check_new "$host"; then
                echo "$host" >> "/tmp/cjdh_harvest_new.$$"
                echo "$host" >> "/tmp/cjdh_all_new.$$"  # Track for onetry
            else
                echo "$host" >> "/tmp/cjdh_harvest_existing.$$"
            fi

            # Add to database
            db_upsert_master "$host" "nodestore"
        done

        rm -f "$tmpjson"
        page=$((page + 1))
    done

    printf "\r  ${C_DIM}Scanning pages... ${C_SUCCESS}done${C_RESET} (scanned %s pages)\n" "$page"
    echo

    # Read accumulated results
    if [[ -f "/tmp/cjdh_harvest_new.$$" ]]; then
        mapfile -t all_new < "/tmp/cjdh_harvest_new.$$"
        total_new=${#all_new[@]}
        rm -f "/tmp/cjdh_harvest_new.$$"
    fi
    if [[ -f "/tmp/cjdh_harvest_existing.$$" ]]; then
        mapfile -t all_existing < "/tmp/cjdh_harvest_existing.$$"
        total_existing=${#all_existing[@]}
        rm -f "/tmp/cjdh_harvest_existing.$$"
    fi
    total_seen=$((total_new + total_existing))

    # Display results
    if (( total_new > 0 )); then
        echo
        printf "${C_NEW}${C_BOLD}NEW ADDRESSES FOUND (%s):${C_RESET}\n" "$total_new"
        for addr in "${all_new[@]}"; do
            print_address_new "$addr"
        done
    else
        print_no_new_addresses
    fi

    if (( total_existing > 0 )); then
        echo
        printf "${C_MUTED}Already harvested (%s addresses):${C_RESET}\n" "$total_existing"
        for addr in "${all_existing[@]}"; do
            print_address_existing "$addr"
        done
    fi

    print_harvest_summary "NodeStore" "$page" "$total_seen" "$total_new" "$total_existing"
}

# ============================================================================
# Remote NodeStore Harvesting (SSH)
# ============================================================================
harvest_remote_nodestore() {
    [[ "${HARVEST_REMOTE:-no}" == "yes" ]] || return 0

    local remote_user="$REMOTE_USER"
    local remote_hosts_raw="$REMOTE_HOSTS"

    # Parse comma-separated hosts
    IFS=',' read -ra hosts <<< "$remote_hosts_raw"

    for rhost in "${hosts[@]}"; do
        rhost="${rhost// /}"  # trim spaces
        [[ -n "$rhost" ]] || continue

        print_subsection "Remote NodeStore: ${remote_user}@${rhost}"

        local page=0
        local total_seen=0 total_new=0 total_existing=0
        local all_new=()
        local all_existing=()

        while true; do
            local tmpjson="/tmp/cjdh_remote_${rhost}_p${page}.json"

            # Fetch remote page via SSH
            if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${remote_user}@${rhost}" \
                "cjdnstool -a 127.0.0.1 -p 11234 -P NONE cexec NodeStore_dumpTable --page=$page" >"$tmpjson" 2>/dev/null; then
                rm -f "$tmpjson"
                break
            fi

            local rt_len
            rt_len="$(jq '.routingTable | length' "$tmpjson" 2>/dev/null || echo 0)"
            if [[ ! "$rt_len" =~ ^[0-9]+$ ]] || (( rt_len == 0 )); then
                rm -f "$tmpjson"
                break
            fi

            # Extract addresses
            jq -r '.routingTable[]? | .ip // empty' "$tmpjson" 2>/dev/null | while IFS= read -r ip; do
                [[ -n "$ip" ]] || continue
                local host
                host="$(canon_host "$(cjdns_host_from_maybe_bracketed "$ip")")"
                [[ -n "$host" ]] || continue

                if db_check_new "$host"; then
                    echo "$host" >> "/tmp/cjdh_remote_new.$$"
                else
                    echo "$host" >> "/tmp/cjdh_remote_existing.$$"
                fi

                db_upsert_master "$host" "remote_nodestore"
            done

            rm -f "$tmpjson"
            page=$((page + 1))
        done

        # Read results
        if [[ -f "/tmp/cjdh_remote_new.$$" ]]; then
            mapfile -t all_new < "/tmp/cjdh_remote_new.$$"
            total_new=${#all_new[@]}
            rm -f "/tmp/cjdh_remote_new.$$"
        fi
        if [[ -f "/tmp/cjdh_remote_existing.$$" ]]; then
            mapfile -t all_existing < "/tmp/cjdh_remote_existing.$$"
            total_existing=${#all_existing[@]}
            rm -f "/tmp/cjdh_remote_existing.$$"
        fi
        total_seen=$((total_new + total_existing))

        # Display
        if (( total_new > 0 )); then
            echo
            printf "${C_NEW}${C_BOLD}NEW from %s (%s):${C_RESET}\n" "$rhost" "$total_new"
            for addr in "${all_new[@]}"; do
                print_address_new "$addr"
            done
        fi

        print_harvest_summary "Remote ($rhost)" "$page" "$total_seen" "$total_new" "$total_existing"
    done
}

# ============================================================================
# Frontier Expansion
# ============================================================================
harvest_frontier() {
    [[ "$FRONTIER_AVAILABLE" == "1" ]] || {
        status_warn "Frontier expansion not available (skipping)"
        return 0
    }

    print_section "Frontier Expansion"

    show_progress "Running frontier expansion"

    local frontier_out="/tmp/cjdh_frontier.$$.txt"
    local frontier_log="/tmp/cjdh_frontier.$$.log"

    # Run frontier expansion (outputs addresses to stdout, progress to stderr)
    if cjdh_frontier_expand "$CJDNS_ADMIN_ADDR" "$CJDNS_ADMIN_PORT" 2000 \
        >"$frontier_out" 2>"$frontier_log"; then
        show_progress_done
    else
        show_progress_fail
        rm -f "$frontier_out" "$frontier_log"
        return 0
    fi

    # Show progress from log
    if [[ -s "$frontier_log" ]]; then
        while IFS= read -r line; do
            # Colorize frontier log lines
            if [[ "$line" == *"paths="* ]]; then
                printf "${C_INFO}  %s${C_RESET}\n" "$line"
            elif [[ "$line" == *"getPeers"* ]]; then
                printf "${C_MUTED}  %s${C_RESET}\n" "$line"
            elif [[ "$line" == *"key2ip6"* ]]; then
                printf "${C_MUTED}  %s${C_RESET}\n" "$line"
            else
                echo "  $line"
            fi
        done < "$frontier_log"
    fi

    # Process results
    local total=0 new=0 existing=0
    while IFS= read -r addr; do
        [[ -n "$addr" ]] || continue
        addr="$(canon_host "$addr")"
        [[ -n "$addr" ]] || continue

        total=$((total + 1))
        if db_check_new "$addr"; then
            new=$((new + 1))
            db_upsert_master "$addr" "frontier"
            echo "$addr" >> "/tmp/cjdh_frontier_new.$$"
            echo "$addr" >> "/tmp/cjdh_all_new.$$"  # Track for onetry
        else
            existing=$((existing + 1))
        fi
    done < "$frontier_out"

    # Display new addresses
    if (( new > 0 )); then
        echo
        printf "${C_NEW}${C_BOLD}NEW from frontier (%s):${C_RESET}\n" "$new"
        while IFS= read -r addr; do
            print_address_new "$addr"
        done < "/tmp/cjdh_frontier_new.$$"
    fi

    echo
    print_divider
    printf "${C_BOLD}Frontier Summary:${C_RESET}\n"
    local keys_count
    keys_count="$(grep 'keys=' "$frontier_log" 2>/dev/null | sed -n 's/.*keys=\([0-9]\+\).*/\1/p' | head -n1)"
    [[ -z "$keys_count" ]] && keys_count="?"
    printf "  Peer keys found:  %s\n" "$keys_count"
    printf "  Valid addresses:  %s\n" "$total"
    if (( new > 0 )); then
        printf "  ${C_NEW}NEW addresses:    %s${C_RESET}\n" "$new"
    else
        printf "  ${C_MUTED}NEW addresses:    %s${C_RESET}\n" "$new"
    fi
    printf "  Already known:    %s\n" "$existing"
    printf "\n  ${C_DIM}Note: Some peer keys don't convert to valid fc00:: addresses${C_RESET}\n"
    print_divider

    rm -f "$frontier_out" "$frontier_log" "/tmp/cjdh_frontier_new.$$"
}

# ============================================================================
# Addrman Harvesting (Bitcoin Core's address manager)
# ============================================================================
harvest_addrman() {
    print_subsection "Bitcoin Addrman Harvest"

    local addrs_json
    addrs_json="$(bash -c "$CLI getnodeaddresses 0 cjdns" 2>/dev/null)" || addrs_json="[]"

    local total new=0 existing=0
    total="$(echo "$addrs_json" | jq 'length' 2>/dev/null || echo 0)"

    if (( total > 0 )); then
        local new_file="/tmp/cjdh_addrman_new.$$"
        local existing_file="/tmp/cjdh_addrman_existing.$$"
        : >"$new_file"
        : >"$existing_file"

        echo "$addrs_json" | jq -r '.[]? | .address' | while IFS= read -r addr; do
            addr="$(canon_host "$addr")"
            [[ -n "$addr" ]] || continue

            if db_check_new "$addr"; then
                db_upsert_master "$addr" "addrman"
                echo "$addr" >> "$new_file"
                echo "$addr" >> "/tmp/cjdh_all_new.$$"  # Track for onetry
            else
                db_upsert_master "$addr" "addrman"
                echo "$addr" >> "$existing_file"
            fi
        done

        new="$(wc -l < "$new_file" 2>/dev/null || echo 0)"
        existing="$(wc -l < "$existing_file" 2>/dev/null || echo 0)"

        printf "  Found %s addresses in Bitcoin addrman\n" "$total"

        if (( new > 0 )); then
            echo
            printf "  ${C_NEW}${C_BOLD}NEW from addrman (%s):${C_RESET}\n" "$new"
            while IFS= read -r addr; do
                printf "    ${C_NEW}●${C_RESET} %s ${C_NEW}(NEW!)${C_RESET}\n" "$addr"
            done < "$new_file"
        fi

        if (( existing > 0 )); then
            echo
            printf "  ${C_MUTED}Already known (%s):${C_RESET}\n" "$existing"
            while IFS= read -r addr; do
                printf "    ${C_MUTED}•${C_RESET} %s\n" "$addr"
            done < "$existing_file"
        fi

        rm -f "$new_file" "$existing_file"
    else
        printf "  ${C_MUTED}No CJDNS addresses in addrman${C_RESET}\n"
    fi
}

# ============================================================================
# Connected Peers Harvesting (auto-add to confirmed)
# ============================================================================
harvest_connected_peers() {
    print_subsection "Connected Bitcoin Core Peers"

    local peers_json
    peers_json="$(bash -c "$CLI getpeerinfo" 2>/dev/null)" || peers_json="[]"

    local cjdns_peers
    cjdns_peers="$(echo "$peers_json" | jq -r '.[] | select(.network=="cjdns") | [.addr, .inbound] | @tsv' 2>/dev/null)"

    local count=0 inbound=0 outbound=0
    local unique_addrs=()

    echo
    while IFS=$'\t' read -r raw is_in; do
        [[ -n "$raw" ]] || continue
        local host
        host="$(canon_host "$(cjdns_host_from_maybe_bracketed "$raw")")"
        [[ -n "$host" ]] || continue

        # Determine direction
        local direction
        if [[ "$is_in" == "true" ]]; then
            direction="IN "
            inbound=$((inbound + 1))
        else
            direction="OUT"
            outbound=$((outbound + 1))
        fi

        # Track unique addresses
        if [[ ! " ${unique_addrs[*]} " =~ " ${host} " ]]; then
            unique_addrs+=("$host")
        fi

        # Print with proper color codes
        if [[ "$direction" == "IN " ]]; then
            printf "    ${C_IN}%s${C_RESET}  %s\n" "$direction" "$host"
        else
            printf "    ${C_OUT}%s${C_RESET}  %s\n" "$direction" "$host"
        fi

        db_upsert_master "$host" "connected_now"
        db_upsert_confirmed "$host"  # Auto-confirm connected peers
        count=$((count + 1))
    done <<< "$cjdns_peers"

    local unique_count=${#unique_addrs[@]}

    echo
    printf "  ${C_BOLD}Total:${C_RESET} %s connections (%s unique addresses)\n" "$count" "$unique_count"
    printf "  ${C_IN}Inbound:${C_RESET} %s  ${C_OUT}Outbound:${C_RESET} %s\n" "$inbound" "$outbound"
    printf "  ${C_SUCCESS}All connected peers auto-confirmed${C_RESET}\n"
}

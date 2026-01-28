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
                echo "$host" >> "/tmp/cjdh_run_new_master.$$"  # Track for run summary
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
    [[ "${#REMOTE_HOSTS[@]}" -gt 0 ]] || return 0

    for idx in "${!REMOTE_HOSTS[@]}"; do
        local rhost="${REMOTE_HOSTS[$idx]}"
        local ruser="${REMOTE_USERS[$idx]}"

        print_subsection "Remote NodeStore: ${ruser}@${rhost}"

        local page=0
        local total_seen=0 total_new=0 total_existing=0
        local all_new=()
        local all_existing=()
        local error_msg=""

        # Animated progress indicator
        printf "  ${C_DIM}Scanning pages"
        local dots=0

        while true; do
            # Update progress animation
            dots=$(( (dots + 1) % 4 ))
            local dot_str=""
            for ((i=0; i<dots; i++)); do dot_str="${dot_str}."; done
            printf "\r  ${C_DIM}Scanning pages%-3s${C_RESET} ${C_INFO}Page: %s${C_RESET}" "$dot_str" "$page"

            local tmpjson="/tmp/cjdh_remote_${rhost}_p${page}.json"
            local tmperr="/tmp/cjdh_remote_${rhost}_err.txt"

            # Fetch remote page via SSH
            local ssh_output
            if ! ssh_output="$(exec_ssh_command "$idx" "cjdnstool -a 127.0.0.1 -p 11234 -P NONE cexec NodeStore_dumpTable --page=$page" 2>"$tmperr")"; then
                error_msg="$(cat "$tmperr" 2>/dev/null || echo "SSH connection failed")"
                rm -f "$tmpjson" "$tmperr"
                break
            fi

            echo "$ssh_output" > "$tmpjson"

            # Check if we got valid JSON
            local rt_len
            rt_len="$(jq '.routingTable | length' "$tmpjson" 2>/dev/null || echo 0)"
            if [[ ! "$rt_len" =~ ^[0-9]+$ ]] || (( rt_len == 0 )); then
                rm -f "$tmpjson" "$tmperr"
                break
            fi

            # Extract addresses
            jq -r '.routingTable[]? | .ip // empty' "$tmpjson" 2>/dev/null | while IFS= read -r ip; do
                [[ -n "$ip" ]] || continue
                local host
                host="$(canon_host "$(cjdns_host_from_maybe_bracketed "$ip")")"
                [[ -n "$host" ]] || continue

                if db_check_new "$host"; then
                    echo "$host" >> "/tmp/cjdh_remote_new_${idx}.$$"
                    echo "$host" >> "/tmp/cjdh_all_new.$$"  # Track for onetry
                echo "$host" >> "/tmp/cjdh_run_new_master.$$"  # Track for run summary
                else
                    echo "$host" >> "/tmp/cjdh_remote_existing_${idx}.$$"
                fi

                db_upsert_master "$host" "remote_nodestore:$rhost"
            done

            rm -f "$tmpjson" "$tmperr"
            page=$((page + 1))
        done

        printf "\r  ${C_DIM}Scanning pages... ${C_SUCCESS}done${C_RESET} (scanned %s pages)\n" "$page"

        # Display errors if any
        if [[ -n "$error_msg" && "$page" -eq 0 ]]; then
            echo
            printf "  ${C_ERROR}${C_BOLD}ERROR:${C_RESET} ${C_ERROR}%s${C_RESET}\n" "$error_msg"
            echo
        fi

        # Read results
        if [[ -f "/tmp/cjdh_remote_new_${idx}.$$" ]]; then
            mapfile -t all_new < "/tmp/cjdh_remote_new_${idx}.$$"
            total_new=${#all_new[@]}
            rm -f "/tmp/cjdh_remote_new_${idx}.$$"
        fi
        if [[ -f "/tmp/cjdh_remote_existing_${idx}.$$" ]]; then
            mapfile -t all_existing < "/tmp/cjdh_remote_existing_${idx}.$$"
            total_existing=${#all_existing[@]}
            rm -f "/tmp/cjdh_remote_existing_${idx}.$$"
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
# Remote Frontier Expansion (SSH)
# ============================================================================
harvest_remote_frontier() {
    [[ "${HARVEST_REMOTE:-no}" == "yes" ]] || return 0
    [[ "${#REMOTE_HOSTS[@]}" -gt 0 ]] || return 0

    for idx in "${!REMOTE_HOSTS[@]}"; do
        local rhost="${REMOTE_HOSTS[$idx]}"
        local ruser="${REMOTE_USERS[$idx]}"

        print_subsection "Remote Frontier: ${ruser}@${rhost}"

        # Check if frontier expansion is available on remote
        printf "  ${C_DIM}Testing frontier capability...${C_RESET} "
        local test_output
        if ! test_output="$(exec_ssh_command "$idx" "cjdnstool -a 127.0.0.1 -p 11234 -P NONE cexec ReachabilityCollector_getPeerInfo --page=0" 2>&1)"; then
            printf "${C_WARN}not available${C_RESET}\n"
            echo
            printf "  ${C_DIM}Note: ReachabilityCollector not available on %s${C_RESET}\n" "$rhost"
            echo
            continue
        fi
        printf "${C_SUCCESS}available${C_RESET}\n"

        # Run frontier expansion on remote host
        printf "  ${C_DIM}Running remote frontier expansion...${C_RESET} "

        local frontier_out="/tmp/cjdh_remote_frontier_${idx}.$$.txt"
        local frontier_log="/tmp/cjdh_remote_frontier_${idx}.$$.log"
        local error_msg=""

        # Upload frontier script to remote host
        local remote_script="/tmp/cjdh_frontier_expand.sh"
        if ! upload_file_to_remote "$idx" "${SCRIPT_DIR}/lib/v5/frontier.sh" "$remote_script"; then
            printf "${C_ERROR}failed${C_RESET} (upload error)\n"
            echo
            continue
        fi

        # Execute frontier expansion remotely
        local frontier_cmd="bash -c 'source $remote_script && cjdh_frontier_expand 127.0.0.1 11234 2000' 2>&1"
        local frontier_result
        if ! frontier_result="$(exec_ssh_command "$idx" "$frontier_cmd" 2>&1)"; then
            printf "${C_ERROR}failed${C_RESET}\n"
            error_msg="Remote frontier execution failed"
            echo
            printf "  ${C_ERROR}${C_BOLD}ERROR:${C_RESET} ${C_ERROR}%s${C_RESET}\n" "$error_msg"
            echo
            continue
        fi

        printf "${C_SUCCESS}done${C_RESET}\n"
        echo

        # Parse frontier results (addresses on stdout, progress on stderr)
        echo "$frontier_result" > "$frontier_out"

        # Extract addresses and progress info
        local total_new=0 total_existing=0 keys_count=0
        local all_new=()

        # Show progress from output
        while IFS= read -r line; do
            if [[ "$line" == fc[0-9a-f][0-9a-f]:* ]]; then
                # It's an address
                local host
                host="$(canon_host "$line")"
                [[ -n "$host" ]] || continue

                if db_check_new "$host"; then
                    all_new+=("$host")
                    echo "$host" >> "/tmp/cjdh_all_new.$$"  # Track for onetry
                echo "$host" >> "/tmp/cjdh_run_new_master.$$"  # Track for run summary
                    total_new=$((total_new + 1))
                else
                    total_existing=$((total_existing + 1))
                fi

                db_upsert_master "$host" "remote_frontier:$rhost"
            elif [[ "$line" == *"paths="* ]]; then
                printf "  ${C_INFO}%s${C_RESET}\n" "$line"
            elif [[ "$line" == *"keys="* ]]; then
                keys_count="$(echo "$line" | sed -n 's/.*keys=\([0-9]\+\).*/\1/p')"
                printf "  ${C_BOLD}${C_SUCCESS}Keys found: %s${C_RESET}\n" "$keys_count"
            elif [[ "$line" == *"getPeers"* ]] || [[ "$line" == *"key2ip6"* ]]; then
                printf "  ${C_MUTED}%s${C_RESET}\n" "$line"
            fi
        done < "$frontier_out"

        # Display NEW addresses
        if (( total_new > 0 )); then
            echo
            printf "${C_NEW}${C_BOLD}NEW from remote frontier (%s):${C_RESET}\n" "$total_new"
            for addr in "${all_new[@]}"; do
                print_address_new "$addr"
            done
        fi

        # Summary
        local total_seen=$((total_new + total_existing))
        echo
        print_separator
        printf "Remote Frontier ($rhost) Summary:\n"
        printf "  Peer keys found:  %s\n" "${keys_count:-0}"
        printf "  Valid addresses:  %s\n" "$total_seen"
        printf "  NEW addresses:    %s\n" "$total_new"
        printf "  Already known:    %s\n" "$total_existing"
        [[ "$total_seen" -lt "${keys_count:-0}" ]] && printf "\n  ${C_DIM}Note: Some peer keys don't convert to valid fc00:: addresses${C_RESET}\n"
        print_separator

        # Cleanup
        rm -f "$frontier_out" "$frontier_log"
        # Remote cleanup with retry - non-critical, don't let it kill the loop
        if ! exec_ssh_command "$idx" "rm -f $remote_script" >/dev/null 2>&1; then
            sleep 5
            exec_ssh_command "$idx" "rm -f $remote_script" >/dev/null 2>&1 || true
        fi
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

    printf "  ${C_DIM}Running frontier expansion...${C_RESET} "

    local frontier_out="/tmp/cjdh_frontier.$$.txt"
    local frontier_log="/tmp/cjdh_frontier.$$.log"

    # Run frontier expansion (outputs addresses to stdout, progress to stderr)
    if cjdh_frontier_expand "$CJDNS_ADMIN_ADDR" "$CJDNS_ADMIN_PORT" 2000 \
        >"$frontier_out" 2>"$frontier_log"; then
        printf "${C_SUCCESS}done${C_RESET}\n"
    else
        printf "${C_ERROR}failed${C_RESET}\n"
        rm -f "$frontier_out" "$frontier_log"
        return 0
    fi

    # Show progress from log
    echo
    if [[ -s "$frontier_log" ]]; then
        local keys_line=""
        while IFS= read -r line; do
            # Colorize frontier log lines
            if [[ "$line" == *"paths="* ]]; then
                printf "  ${C_INFO}%s${C_RESET}\n" "$line"
            elif [[ "$line" == *"keys="* ]]; then
                keys_line="$line"
                local keys_count
                keys_count="$(echo "$line" | sed -n 's/.*keys=\([0-9]\+\).*/\1/p')"
                printf "  ${C_BOLD}${C_SUCCESS}Keys found: %s${C_RESET}\n" "$keys_count"
            elif [[ "$line" == *"getPeers"* ]] || [[ "$line" == *"key2ip6"* ]]; then
                printf "  ${C_MUTED}%s${C_RESET}\n" "$line"
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
    keys_count="$(grep 'keys=' "$frontier_log" 2>/dev/null | sed -n 's/.*keys=\([0-9]\+\).*/\1/p' | head -n1 || true)"
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

        # Track if this is NEW to confirmed, then confirm it
        if ! db_is_in_confirmed "$host"; then
            echo "$host" >> "/tmp/cjdh_run_new_confirmed.$$" 2>/dev/null
        fi
        db_upsert_confirmed "$host"  # Auto-confirm connected peers

        count=$((count + 1))
    done <<< "$cjdns_peers"

    local unique_count=${#unique_addrs[@]}

    echo
    printf "  ${C_BOLD}Total:${C_RESET} %s connections (%s unique addresses)\n" "$count" "$unique_count"
    printf "  ${C_IN}Inbound:${C_RESET} %s  ${C_OUT}Outbound:${C_RESET} %s\n" "$inbound" "$outbound"
    printf "  ${C_SUCCESS}All connected peers auto-confirmed${C_RESET}\n"
}

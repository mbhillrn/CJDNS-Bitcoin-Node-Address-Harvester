#!/usr/bin/env bash
# CJDNS Harvester v5 - Onetry Execution Module

# Requires: ui.sh, db.sh, canon_host

# ============================================================================
# Onetry Execution
# ============================================================================
onetry_addresses() {
    # Usage: onetry_addresses address1 address2 address3 ...
    # Dispatches addnode onetry for all provided addresses

    local addresses=("$@")
    local count=${#addresses[@]}

    (( count > 0 )) || {
        status_info "No addresses to try"
        return 0
    }

    print_section "Attempting Connection to $count Addresses"

    # Get snapshot of currently connected peers BEFORE onetry
    local pre_peers="/tmp/cjdh_pre_peers.$$"
    bash -c "$CLI getpeerinfo" 2>/dev/null \
        | jq -r '.[] | select(.network=="cjdns") | .addr' 2>/dev/null \
        | while IFS= read -r raw; do
            canon_host "$(cjdns_host_from_maybe_bracketed "$raw")"
        done | sort -u > "$pre_peers"

    # Dispatch onetry for each address
    local dispatched=0 failed=0 current=0
    local show_every=10  # Show progress every N addresses
    local dots_cycle=0
    local dots_pattern=("." ".." "..." ".." ".")

    printf "  ${C_DIM}Dispatching onetry commands${C_RESET}\n\n"

    for addr in "${addresses[@]}"; do
        addr="$(canon_host "$addr")"
        [[ -n "$addr" ]] || continue

        current=$((current + 1))

        if bash -c "$CLI addnode \"[$addr]\" onetry" >/dev/null 2>&1; then
            dispatched=$((dispatched + 1))
        else
            failed=$((failed + 1))
        fi

        # Show progress periodically with animated dots
        if (( current % show_every == 0 )) || (( current == count )); then
            dots_cycle=$(( (dots_cycle + 1) % ${#dots_pattern[@]} ))
            printf "  ${C_INFO}Progress:${C_RESET} %s/%s dispatched${C_DIM}%s${C_RESET}  " "$current" "$count" "${dots_pattern[$dots_cycle]}"
            if (( failed > 0 )); then
                printf " (${C_ERROR}%s failed${C_RESET})" "$failed"
            fi
            printf "\r"
        fi
    done

    echo  # Newline after progress
    echo
    printf "  ${C_SUCCESS}✓ Dispatched %s addresses${C_RESET}" "$dispatched"
    if (( failed > 0 )); then
        printf " (${C_ERROR}%s failed${C_RESET})" "$failed"
    fi
    printf "\n"

    # Wait for connections to settle
    if (( dispatched > 0 )); then
        echo
        show_progress "Waiting 10 seconds for connections to settle"
        sleep 10
        show_progress_done
    fi

    # Get snapshot of currently connected peers AFTER onetry
    local post_peers="/tmp/cjdh_post_peers.$$"
    bash -c "$CLI getpeerinfo" 2>/dev/null \
        | jq -r '.[] | select(.network=="cjdns") | .addr' 2>/dev/null \
        | while IFS= read -r raw; do
            canon_host "$(cjdns_host_from_maybe_bracketed "$raw")"
        done | sort -u > "$post_peers"

    # Find new connections (diff post - pre)
    local new_connections="/tmp/cjdh_new_conn.$$"
    comm -13 "$pre_peers" "$post_peers" > "$new_connections" 2>/dev/null

    local connected_count
    connected_count="$(wc -l < "$new_connections" 2>/dev/null || echo 0)"

    # Report results
    echo
    print_divider
    printf "${C_BOLD}Onetry Results:${C_RESET}\n"
    printf "  Dispatched:  %s\n" "$dispatched"
    if (( connected_count > 0 )); then
        printf "  ${C_SUCCESS}${C_BOLD}Connected:   %s${C_RESET}\n" "$connected_count"

        echo
        printf "  ${C_SUCCESS}New connections:${C_RESET}\n"
        while IFS= read -r addr; do
            [[ -n "$addr" ]] || continue
            printf "    ${C_SUCCESS}✓${C_RESET} %s\n" "$addr"

            # Auto-confirm connected addresses
            if ! db_is_in_confirmed "$addr"; then
                echo "$addr" >> "/tmp/cjdh_run_new_confirmed.$$" 2>/dev/null
            fi
            db_upsert_confirmed "$addr"
            db_upsert_master "$addr" "onetry_connected"
        done < "$new_connections"
    else
        printf "  ${C_MUTED}Connected:   0${C_RESET}\n"
    fi
    print_divider

    # Cleanup
    rm -f "$pre_peers" "$post_peers" "$new_connections"

    return 0
}

# ============================================================================
# Batch Onetry from Database Table
# ============================================================================
onetry_all_master() {
    print_box "ONETRY: ALL MASTER LIST"

    local master_count
    master_count="$(db_count_master)"

    if (( master_count == 0 )); then
        status_warn "Master list is empty, nothing to try"
        return 0
    fi

    status_info "Master list contains $master_count addresses"
    echo

    # Capture connected peers at START
    local start_peers="/tmp/cjdh_onetry_start_peers.$$"
    bash -c "$CLI getpeerinfo" 2>/dev/null \
        | jq -r '.[] | select(.network=="cjdns") | .addr' 2>/dev/null \
        | while IFS= read -r raw; do
            canon_host "$(cjdns_host_from_maybe_bracketed "$raw")"
        done | sort -u > "$start_peers" 2>/dev/null || true

    local start_count=0
    [[ -f "$start_peers" ]] && start_count=$(wc -l < "$start_peers" 2>/dev/null || echo 0)

    printf "  ${C_BOLD}CJDNS Bitcoin peers connected:${C_RESET} %s\n" "$start_count"
    if (( start_count > 0 )); then
        while IFS= read -r addr; do
            [[ -n "$addr" ]] || continue
            printf "    %s\n" "$addr"
        done < "$start_peers"
    fi
    echo

    # Get all addresses from master table
    local addresses
    mapfile -t addresses < <(db_get_all_master)

    onetry_addresses "${addresses[@]}"

    # Capture connected peers at END
    local end_peers="/tmp/cjdh_onetry_end_peers.$$"
    bash -c "$CLI getpeerinfo" 2>/dev/null \
        | jq -r '.[] | select(.network=="cjdns") | .addr' 2>/dev/null \
        | while IFS= read -r raw; do
            canon_host "$(cjdns_host_from_maybe_bracketed "$raw")"
        done | sort -u > "$end_peers" 2>/dev/null || true

    local end_count=0
    [[ -f "$end_peers" ]] && end_count=$(wc -l < "$end_peers" 2>/dev/null || echo 0)

    # Show summary
    echo
    print_section "Connection Summary"
    printf "  ${C_BOLD}CJDNS Bitcoin peers:${C_RESET}\n"
    printf "    At start:  %s connected\n" "$start_count"
    printf "    At end:    %s connected\n" "$end_count"

    if (( end_count > 0 )); then
        echo
        printf "  ${C_SUCCESS}Connected now:${C_RESET}\n"
        while IFS= read -r addr; do
            [[ -n "$addr" ]] || continue
            printf "    ${C_SUCCESS}✓${C_RESET} %s\n" "$addr"
        done < "$end_peers"
    fi

    # Cleanup
    rm -f "$start_peers" "$end_peers"
}

onetry_all_confirmed() {
    print_box "ONETRY: ALL CONFIRMED LIST"

    local confirmed_count
    confirmed_count="$(db_count_confirmed)"

    if (( confirmed_count == 0 )); then
        status_warn "Confirmed list is empty, nothing to try"
        return 0
    fi

    status_info "Confirmed list contains $confirmed_count addresses (known Bitcoin nodes)"
    echo

    # Capture connected peers at START
    local start_peers="/tmp/cjdh_onetry_start_peers.$$"
    bash -c "$CLI getpeerinfo" 2>/dev/null \
        | jq -r '.[] | select(.network=="cjdns") | .addr' 2>/dev/null \
        | while IFS= read -r raw; do
            canon_host "$(cjdns_host_from_maybe_bracketed "$raw")"
        done | sort -u > "$start_peers" 2>/dev/null || true

    local start_count=0
    [[ -f "$start_peers" ]] && start_count=$(wc -l < "$start_peers" 2>/dev/null || echo 0)

    printf "  ${C_BOLD}CJDNS Bitcoin peers connected:${C_RESET} %s\n" "$start_count"
    if (( start_count > 0 )); then
        while IFS= read -r addr; do
            [[ -n "$addr" ]] || continue
            printf "    %s\n" "$addr"
        done < "$start_peers"
    fi
    echo

    # Get all addresses from confirmed table
    local addresses
    mapfile -t addresses < <(db_get_all_confirmed)

    onetry_addresses "${addresses[@]}"

    # Capture connected peers at END
    local end_peers="/tmp/cjdh_onetry_end_peers.$$"
    bash -c "$CLI getpeerinfo" 2>/dev/null \
        | jq -r '.[] | select(.network=="cjdns") | .addr' 2>/dev/null \
        | while IFS= read -r raw; do
            canon_host "$(cjdns_host_from_maybe_bracketed "$raw")"
        done | sort -u > "$end_peers" 2>/dev/null || true

    local end_count=0
    [[ -f "$end_peers" ]] && end_count=$(wc -l < "$end_peers" 2>/dev/null || echo 0)

    # Show summary
    echo
    print_section "Connection Summary"
    printf "  ${C_BOLD}CJDNS Bitcoin peers:${C_RESET}\n"
    printf "    At start:  %s connected\n" "$start_count"
    printf "    At end:    %s connected\n" "$end_count"

    if (( end_count > 0 )); then
        echo
        printf "  ${C_SUCCESS}Connected now:${C_RESET}\n"
        while IFS= read -r addr; do
            [[ -n "$addr" ]] || continue
            printf "    ${C_SUCCESS}✓${C_RESET} %s\n" "$addr"
        done < "$end_peers"
    fi

    # Cleanup
    rm -f "$start_peers" "$end_peers"
}

# ============================================================================
# Onetry only NEW addresses (for harvester mode)
# ============================================================================
onetry_new_addresses() {
    print_section "Testing New Addresses"

    # Get addresses that were discovered this run (written to temp file during harvest)
    local new_addresses=()

    if [[ -f "/tmp/cjdh_all_new.$$" ]]; then
        mapfile -t new_addresses < <(sort -u "/tmp/cjdh_all_new.$$")
        rm -f "/tmp/cjdh_all_new.$$"
    fi

    local count=${#new_addresses[@]}

    if (( count == 0 )); then
        echo
        status_info "No new addresses discovered this run (all addresses already known)"
        return 0
    fi

    echo
    printf "${C_BOLD}Testing newly discovered addresses from this harvest:${C_RESET}\n"
    printf "  ${C_INFO}New this run:      %s addresses${C_RESET}\n\n" "$count"

    printf "${C_DIM}Note: These addresses were just discovered and not yet tested.${C_RESET}\n"
    printf "${C_DIM}Successful connections will be auto-confirmed.${C_RESET}\n"
    echo

    onetry_addresses "${new_addresses[@]}"
}

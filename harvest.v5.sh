#!/usr/bin/env bash
# CJDNS Address Harvester v5
# Simplified, cleaner, prettier

set -euo pipefail

# ============================================================================
# Environment Setup
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${SCRIPT_DIR}"
DB_PATH="${BASE_DIR}/state.db"

# Load all v5 modules
source "${SCRIPT_DIR}/lib/v5/utils.sh"      # canon_host function
source "${SCRIPT_DIR}/lib/v5/ui.sh"         # UI functions and colors
source "${SCRIPT_DIR}/lib/v5/db.sh"         # Database functions
source "${SCRIPT_DIR}/lib/v5/detect.sh"     # Detection and verification
source "${SCRIPT_DIR}/lib/v5/frontier.sh"   # Frontier expansion (unchanged)
source "${SCRIPT_DIR}/lib/v5/harvest.sh"    # Harvesting modules
source "${SCRIPT_DIR}/lib/v5/onetry.sh"     # Onetry execution
source "${SCRIPT_DIR}/lib/v5/display.sh"    # Status display

# Export variables for submodules
export BASE_DIR DB_PATH

# ============================================================================
# Database Management Functions
# ============================================================================
export_database_to_txt() {
    print_box "EXPORT DATABASE TO TXT FILE"

    local out="./cjdns-bitcoin-seed-list.txt"
    local date_now
    date_now="$(date +%Y-%m-%d)"

    {
        echo "As of: $date_now"
        echo
        echo "KNOWN: CJDNS fc** fc00 addresses with bitcoin nodes"
        echo "== CONFIRMED BITCOIN NODES (confirmed.host) =="
        sqlite3 "$DB_PATH" "SELECT '  ' || host FROM confirmed ORDER BY host;"
        echo
        echo "== ALL DISCOVERED CJDNS ADDRESSES (master.host) =="
        sqlite3 "$DB_PATH" "SELECT '  ' || host FROM master ORDER BY host;"
    } > "$out"

    echo
    printf "  ${C_SUCCESS}✓ Exported database to:${C_RESET} %s\n" "$out"
    echo
    printf "  ${C_BOLD}Summary:${C_RESET}\n"
    printf "    Confirmed:  %s\n" "$(db_count_confirmed)"
    printf "    Master:     %s\n" "$(db_count_master)"
}

update_database_from_repo() {
    print_box "DATABASE UPDATER"

    echo
    printf "  ${C_INFO}Checking GitHub repo for updated seed database...${C_RESET}\n"
    echo

    local repo_url="https://raw.githubusercontent.com/mbhillrn/CJDNS-Bitcoin-Node-Address-Harvester/main/lib/seeddb.db"
    local local_seeddb="${BASE_DIR}/lib/seeddb.db"

    # Check if remote file is newer than local
    local remote_last_modified
    remote_last_modified=$(curl -sI "$repo_url" | grep -i '^last-modified:' | cut -d' ' -f2- | tr -d '\r')

    if [[ -z "$remote_last_modified" ]]; then
        echo
        printf "  ${C_WARNING}⚠ Could not check remote file timestamp${C_RESET}\n"
        printf "  Proceeding with download anyway...\n"
        echo
    elif [[ -f "$local_seeddb" ]]; then
        # Convert remote timestamp to epoch seconds
        local remote_epoch
        remote_epoch=$(date -d "$remote_last_modified" +%s 2>/dev/null || echo 0)

        # Get local file modification time
        local local_epoch
        local_epoch=$(stat -c %Y "$local_seeddb" 2>/dev/null || echo 0)

        if (( remote_epoch > 0 && local_epoch > 0 && remote_epoch <= local_epoch )); then
            echo
            printf "  ${C_SUCCESS}✓ Local seeddb.db is already up to date${C_RESET}\n"
            printf "  Remote file has not been modified since your last update.\n"
            echo
            printf "  ${C_INFO}Checking for new addresses anyway...${C_RESET}\n"
        else
            echo
            printf "  ${C_INFO}📥 Newer version available, downloading...${C_RESET}\n"
        fi
        echo
    fi

    # Download latest seeddb.db from GitHub
    local temp_seeddb="/tmp/seeddb_download_$$.db"

    if ! curl -sf -o "$temp_seeddb" "$repo_url" 2>/dev/null; then
        echo
        status_error "Failed to download seed database from GitHub"
        printf "  Check your internet connection or try again later.\n"
        return 1
    fi

    # Compare confirmed addresses
    local repo_confirmed="/tmp/repo_confirmed_$$.txt"
    local local_confirmed="/tmp/local_confirmed_$$.txt"

    # Get confirmed addresses from downloaded seeddb
    sqlite3 "$temp_seeddb" "SELECT host FROM confirmed ORDER BY host;" > "$repo_confirmed" 2>/dev/null

    # Get confirmed addresses from local state.db (if exists)
    if [[ -f "$DB_PATH" ]]; then
        sqlite3 "$DB_PATH" "SELECT host FROM confirmed ORDER BY host;" > "$local_confirmed" 2>/dev/null
    else
        touch "$local_confirmed"
    fi

    # Find NEW confirmed addresses (in repo but not in local)
    local new_confirmed="/tmp/new_confirmed_$$.txt"
    comm -23 "$repo_confirmed" "$local_confirmed" > "$new_confirmed"

    local new_count
    new_count=$(wc -l < "$new_confirmed" 2>/dev/null || echo 0)

    if (( new_count == 0 )); then
        echo
        printf "  ${C_SUCCESS}✓ Your database is up to date!${C_RESET}\n"
        printf "  No new confirmed Bitcoin node addresses found in repo.\n"

        # Still update local seeddb.db
        cp "$temp_seeddb" "$local_seeddb"
        echo
        printf "  ${C_INFO}ℹ Local seeddb.db refreshed from repo${C_RESET}\n"

        rm -f "$temp_seeddb" "$repo_confirmed" "$local_confirmed" "$new_confirmed"
        return 0
    fi

    # Found new confirmed addresses!
    echo
    printf "  ${C_SUCCESS}${C_BOLD}Found %s new confirmed Bitcoin node address(es)!${C_RESET}\n" "$new_count"
    echo
    printf "  ${C_INFO}New addresses:${C_RESET}\n"
    while IFS= read -r addr; do
        [[ -n "$addr" ]] || continue
        printf "    ${C_SUCCESS}+${C_RESET} %s\n" "$addr"
    done < "$new_confirmed"

    echo
    read -r -p "  Create backup and add these addresses to your database? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo
        printf "  ${C_MUTED}Update cancelled${C_RESET}\n"

        # Still update local seeddb.db
        cp "$temp_seeddb" "$local_seeddb"
        echo
        printf "  ${C_INFO}ℹ Local seeddb.db refreshed from repo${C_RESET}\n"

        rm -f "$temp_seeddb" "$repo_confirmed" "$local_confirmed" "$new_confirmed"
        return 0
    fi

    # Create backup before updating
    echo
    printf "  ${C_INFO}Creating backup...${C_RESET}\n"
    local timestamp
    timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
    local backup_dir="${BASE_DIR}/bak"
    mkdir -p "$backup_dir"
    local backup_file="${backup_dir}/state_${timestamp}.db"

    if [[ -f "$DB_PATH" ]]; then
        cp "$DB_PATH" "$backup_file"
        printf "  ${C_SUCCESS}✓ Backup created:${C_RESET} %s\n" "$(basename "$backup_file")"
    fi

    # Add new confirmed addresses to state.db
    local added=0
    while IFS= read -r addr; do
        [[ -n "$addr" ]] || continue
        db_upsert_confirmed "$addr"
        db_upsert_master "$addr" "repo_update"
        added=$((added + 1))
    done < "$new_confirmed"

    # Update local seeddb.db
    cp "$temp_seeddb" "$local_seeddb"

    echo
    printf "  ${C_SUCCESS}${C_BOLD}✓ Database updated successfully!${C_RESET}\n"
    printf "    Added:           %s confirmed address(es)\n" "$added"
    printf "    Backup saved:    %s\n" "bak/$(basename "$backup_file")"
    printf "    seeddb.db:       Updated from repo\n"

    # Cleanup
    rm -f "$temp_seeddb" "$repo_confirmed" "$local_confirmed" "$new_confirmed"
}

delete_database() {
    print_box "DELETE DATABASE"

    echo
    printf "  ${C_ERROR}${C_BOLD}WARNING:${C_RESET} This will delete state.db\n"
    printf "  You will need to reseed or rebuild the database on next run.\n"
    echo
    read -r -p "  Are you sure? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$DB_PATH"
        echo
        printf "  ${C_SUCCESS}✓ Database deleted${C_RESET}\n"
        echo
        read -r -p "Press Enter to set up new database..."
        check_database_and_show_stats
    else
        echo
        printf "  ${C_MUTED}Cancelled${C_RESET}\n"
    fi
}

backup_database() {
    print_box "BACKUP DATABASE"

    if [[ ! -f "$DB_PATH" ]]; then
        echo
        status_error "No database found to backup"
        return 1
    fi

    # Create backups directory if it doesn't exist
    local backup_dir="${BASE_DIR}/bak"
    mkdir -p "$backup_dir"

    # Generate backup filename with timestamp
    local timestamp
    timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
    local backup_file="${backup_dir}/state_${timestamp}.db"

    # Copy database to backup
    cp "$DB_PATH" "$backup_file"

    echo
    printf "  ${C_SUCCESS}✓ Database backed up to:${C_RESET}\n"
    printf "    %s\n" "$backup_file"
    echo
    printf "  ${C_BOLD}Summary:${C_RESET}\n"
    printf "    Master:     %s addresses\n" "$(db_count_master)"
    printf "    Confirmed:  %s addresses\n" "$(db_count_confirmed)"
}

restore_database() {
    print_box "RESTORE DATABASE FROM BACKUP"

    local backup_dir="${BASE_DIR}/bak"

    if [[ ! -d "$backup_dir" ]]; then
        echo
        status_error "No backup directory found"
        return 1
    fi

    # List available backups
    local backups=()
    mapfile -t backups < <(ls -1 "$backup_dir"/state_*.db 2>/dev/null | sort -r)

    if (( ${#backups[@]} == 0 )); then
        echo
        status_error "No backup databases found"
        return 1
    fi

    echo
    printf "  ${C_BOLD}Available backups:${C_RESET}\n\n"

    local idx=1
    for backup in "${backups[@]}"; do
        local backup_name
        backup_name="$(basename "$backup")"
        # Extract timestamp from filename: state_2026-01-19_12-30-45.db
        local timestamp
        timestamp="${backup_name#state_}"
        timestamp="${timestamp%.db}"
        timestamp="${timestamp//_/ }"

        local backup_size
        backup_size="$(du -h "$backup" | cut -f1)"

        printf "  ${C_INFO}%s)${C_RESET} %s (%s)\n" "$idx" "$timestamp" "$backup_size"
        idx=$((idx + 1))
    done

    echo
    printf "  ${C_MUTED}0)${C_RESET} Cancel\n"
    echo

    read -r -p "Choose backup to restore [1-${#backups[@]}, 0=cancel]: " choice

    if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
        echo
        printf "  ${C_MUTED}Cancelled${C_RESET}\n"
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
        echo
        status_error "Invalid choice"
        return 1
    fi

    local selected_backup="${backups[$((choice - 1))]}"

    echo
    printf "  ${C_WARNING}${C_BOLD}WARNING:${C_RESET} This will replace the current database\n"
    echo
    read -r -p "  Are you sure? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        cp "$selected_backup" "$DB_PATH"
        echo
        printf "  ${C_SUCCESS}✓ Database restored from backup${C_RESET}\n"
        echo
        printf "  ${C_BOLD}Current database:${C_RESET}\n"
        printf "    Master:     %s addresses\n" "$(db_count_master)"
        printf "    Confirmed:  %s addresses\n" "$(db_count_confirmed)"
    else
        echo
        printf "  ${C_MUTED}Cancelled${C_RESET}\n"
    fi
}

delete_backups() {
    print_box "DELETE BACKUP DATABASES"

    local backup_dir="${BASE_DIR}/bak"

    if [[ ! -d "$backup_dir" ]]; then
        echo
        status_error "No backup directory found"
        return 1
    fi

    # List available backups
    local backups=()
    mapfile -t backups < <(ls -1 "$backup_dir"/state_*.db 2>/dev/null | sort -r)

    if (( ${#backups[@]} == 0 )); then
        echo
        status_error "No backup databases found"
        return 1
    fi

    echo
    printf "  ${C_BOLD}Available backups:${C_RESET}\n\n"

    local idx=1
    for backup in "${backups[@]}"; do
        local backup_name
        backup_name="$(basename "$backup")"
        local timestamp
        timestamp="${backup_name#state_}"
        timestamp="${timestamp%.db}"
        timestamp="${timestamp//_/ }"

        local backup_size
        backup_size="$(du -h "$backup" | cut -f1)"

        printf "  ${C_INFO}%s)${C_RESET} %s (%s)\n" "$idx" "$timestamp" "$backup_size"
        idx=$((idx + 1))
    done

    echo
    printf "  ${C_ERROR}A)${C_RESET} Delete ALL backups\n"
    printf "  ${C_MUTED}0)${C_RESET} Cancel\n"
    echo

    read -r -p "Choose backup to delete [1-${#backups[@]}, A=all, 0=cancel]: " choice

    if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
        echo
        printf "  ${C_MUTED}Cancelled${C_RESET}\n"
        return 0
    fi

    if [[ "$choice" =~ ^[Aa]$ ]]; then
        echo
        printf "  ${C_ERROR}${C_BOLD}WARNING:${C_RESET} This will delete ALL ${#backups[@]} backup(s)\n"
        echo
        read -r -p "  Are you sure? [y/N]: " confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -f "$backup_dir"/state_*.db
            echo
            printf "  ${C_SUCCESS}✓ All backups deleted${C_RESET}\n"
        else
            echo
            printf "  ${C_MUTED}Cancelled${C_RESET}\n"
        fi
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
        echo
        status_error "Invalid choice"
        return 1
    fi

    local selected_backup="${backups[$((choice - 1))]}"
    local backup_name
    backup_name="$(basename "$selected_backup")"

    echo
    printf "  ${C_WARNING}Delete backup:${C_RESET} %s\n" "$backup_name"
    echo
    read -r -p "  Are you sure? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$selected_backup"
        echo
        printf "  ${C_SUCCESS}✓ Backup deleted${C_RESET}\n"
    else
        echo
        printf "  ${C_MUTED}Cancelled${C_RESET}\n"
    fi
}

seed_database_from_seeddb() {
    local seed_mode="$1"  # "confirmed_only", "confirmed_with_onetry", "all"

    local seeddb="${BASE_DIR}/lib/seeddb.db"
    if [[ ! -f "$seeddb" ]]; then
        status_error "Seed database not found at: $seeddb"
        return 1
    fi

    echo
    printf "  ${C_INFO}Seeding database from:${C_RESET} %s\n" "$seeddb"

    # Initialize blank database
    db_init

    case "$seed_mode" in
        "confirmed_only"|"confirmed_with_onetry")
            # Seed only confirmed list (and add to master)
            local confirmed_addresses
            mapfile -t confirmed_addresses < <(sqlite3 "$seeddb" "SELECT host FROM confirmed;")

            local count=0
            for addr in "${confirmed_addresses[@]}"; do
                [[ -n "$addr" ]] || continue
                db_upsert_confirmed "$addr"
                db_upsert_master "$addr" "seeded"
                count=$((count + 1))
            done

            echo
            printf "  ${C_SUCCESS}✓ Seeded %s confirmed addresses${C_RESET}\n" "$count"

            if [[ "$seed_mode" == "confirmed_with_onetry" ]]; then
                echo
                printf "  ${C_INFO}Attempting connection to seeded addresses...${C_RESET}\n"
                sleep 2
                onetry_all_confirmed
            fi
            ;;

        "all")
            # Seed everything (master + confirmed)
            echo
            printf "  ${C_INFO}Seeding complete database (master + confirmed)...${C_RESET}\n"

            # Seed master
            local master_count=0
            while IFS= read -r addr; do
                [[ -n "$addr" ]] || continue
                db_upsert_master "$addr" "seeded"
                master_count=$((master_count + 1))
            done < <(sqlite3 "$seeddb" "SELECT host FROM master;")

            # Seed confirmed
            local confirmed_count=0
            while IFS= read -r addr; do
                [[ -n "$addr" ]] || continue
                db_upsert_confirmed "$addr"
                confirmed_count=$((confirmed_count + 1))
            done < <(sqlite3 "$seeddb" "SELECT host FROM confirmed;")

            echo
            printf "  ${C_SUCCESS}✓ Seeded %s master addresses${C_RESET}\n" "$master_count"
            printf "  ${C_SUCCESS}✓ Seeded %s confirmed addresses${C_RESET}\n" "$confirmed_count"
            ;;
    esac
}

show_database_first_run_menu() {
    print_box "DATABASE SETUP"

    echo
    printf "  ${C_WARNING}No database detected${C_RESET}\n"
    echo
    printf "  ${C_BOLD}Would you like to:${C_RESET}\n\n"
    printf "  ${C_SUCCESS}1)${C_RESET} Seed confirmed CJDNS Bitcoin node addresses and attempt connection ${C_SUCCESS}(RECOMMENDED)${C_RESET}\n"
    printf "     └─ Seeds database with known Bitcoin nodes and connects via onetry\n\n"
    printf "  ${C_INFO}2)${C_RESET} Seed confirmed CJDNS Bitcoin node addresses only\n"
    printf "     └─ Seeds database with known Bitcoin nodes, returns to menu\n\n"
    printf "  ${C_WARNING}3)${C_RESET} Continue without seeding\n"
    printf "     └─ Database will be created blank during first harvest\n\n"
    printf "  ${C_MUTED}4)${C_RESET} Seed complete database (master + confirmed) ${C_ERROR}(Advanced)${C_RESET}\n"
    printf "     └─ Seeds ALL addresses, including non-Bitcoin nodes\n\n"
    printf "  ${C_ERROR}0)${C_RESET} Exit\n\n"

    local choice
    read -r -p "Choice [1-4, 0=exit]: " choice

    case "$choice" in
        1)
            seed_database_from_seeddb "confirmed_with_onetry"
            ;;
        2)
            seed_database_from_seeddb "confirmed_only"
            ;;
        3)
            echo
            printf "  ${C_INFO}Continuing with blank database${C_RESET}\n"
            sleep 1
            db_init
            ;;
        4)
            seed_database_from_seeddb "all"
            ;;
        0)
            echo
            log_success "Goodbye!"
            exit 0
            ;;
        *)
            echo
            status_error "Invalid choice. Please enter 1, 2, 3, 4, or 0"
            sleep 2
            show_database_first_run_menu
            return
            ;;
    esac

    echo
    read -r -p "Press Enter to continue to main menu..."
}

check_database_and_show_stats() {
    if [[ ! -f "$DB_PATH" ]]; then
        show_database_first_run_menu
        return
    fi

    # Database exists, show quick stats
    local master_count confirmed_count last_modified
    master_count="$(db_count_master)"
    confirmed_count="$(db_count_confirmed)"
    last_modified="$(stat -c %y "$DB_PATH" 2>/dev/null | cut -d' ' -f1)"

    echo
    printf "  ${C_SUCCESS}✓ Database found:${C_RESET} %s\n" "$DB_PATH"
    printf "    Last updated:  %s\n" "$last_modified"
    printf "    Master:        %s addresses\n" "$master_count"
    printf "    Confirmed:     %s addresses\n" "$confirmed_count"
    sleep 1
}

# ============================================================================
# Main Menu
# ============================================================================
show_main_menu() {
    clear
    print_box "CJDNS ADDRESS HARVESTER v5"

    echo
    printf "${C_BOLD}Choose operation:${C_RESET}\n\n"
    printf "  ${C_SUCCESS}1)${C_RESET} Run Harvester\n"
    printf "     └─ Harvest local nodestore and frontier search (with options to harvest\n"
    printf "        from other machines on local network), then attempt Bitcoin Core\n"
    printf "        connection via onetry\n\n"
    printf "  ${C_INFO}2)${C_RESET} Bitcoin Core: Attempt connection to all known CONFIRMED CJDNS Bitcoin\n"
    printf "     Node Addresses\n"
    printf "     └─ Retry database addresses with known associated Bitcoin nodes\n\n"
    printf "  ${C_WARNING}3)${C_RESET} Bitcoin Core: Attempt connection to ALL CJDNS addresses in database,\n"
    printf "     including those unlikely to have Bitcoin Core nodes\n"
    printf "     └─ Try connecting to all discovered addresses. EXHAUSTIVE, may be time\n"
    printf "        consuming dependent upon size of database. Recommended only if\n"
    printf "        you're bored :)\n\n"
    printf "  ${C_SUCCESS}4)${C_RESET} Database Updater: Check repo for newly confirmed Bitcoin node addresses\n"
    printf "     └─ Downloads latest seeddb.db from GitHub and adds any new confirmed\n"
    printf "        addresses to your database (will not erase, only add if new)\n\n"
    printf "  ${C_MUTED}5)${C_RESET} Database: Create txt file showing all discovered CJDNS addresses\n"
    printf "     └─ Creates cjdns-bitcoin-seed-list.txt in program directory\n\n"
    printf "  ${C_INFO}6)${C_RESET} Database: Backup current database\n"
    printf "     └─ Creates timestamped backup in bak/ directory\n\n"
    printf "  ${C_WARNING}7)${C_RESET} Database: Restore from backup\n"
    printf "     └─ Restore database from previous backup\n\n"
    printf "  ${C_ERROR}8)${C_RESET} Database: Delete backup databases\n"
    printf "     └─ Delete individual or all backup databases\n\n"
    printf "  ${C_ERROR}9)${C_RESET} Database: Delete current database (state.db)\n"
    printf "     └─ Deletes/resets current database, prompting setup on next run\n\n"
    printf "  ${C_ERROR}0)${C_RESET} Exit\n\n"
}

# ============================================================================
# Run Summary Display
# ============================================================================
show_run_summary() {
    echo
    print_section "Run Summary"

    # Get connected peers NOW
    local end_peers="/tmp/cjdh_run_end_peers.$$"
    bash -c "$CLI getpeerinfo" 2>/dev/null \
        | jq -r '.[] | select(.network=="cjdns") | .addr' 2>/dev/null \
        | while IFS= read -r raw; do
            canon_host "$(cjdns_host_from_maybe_bracketed "$raw")"
        done | sort -u > "$end_peers" 2>/dev/null || true

    # Count connected peers
    local start_count=0 end_count=0
    [[ -f "/tmp/cjdh_run_start_peers.$$" ]] && start_count=$(wc -l < "/tmp/cjdh_run_start_peers.$$" 2>/dev/null || echo 0)
    [[ -f "$end_peers" ]] && end_count=$(wc -l < "$end_peers" 2>/dev/null || echo 0)

    # Count NEW addresses
    local new_master_count=0 new_confirmed_count=0
    [[ -f "/tmp/cjdh_run_new_master.$$" ]] && new_master_count=$(sort -u "/tmp/cjdh_run_new_master.$$" 2>/dev/null | wc -l || echo 0)
    [[ -f "/tmp/cjdh_run_new_confirmed.$$" ]] && new_confirmed_count=$(sort -u "/tmp/cjdh_run_new_confirmed.$$" 2>/dev/null | wc -l || echo 0)

    # Display connection status
    printf "  ${C_BOLD}CJDNS Bitcoin Peers:${C_RESET}\n"
    printf "    At start:  %s connected\n" "$start_count"
    printf "    At end:    %s connected\n" "$end_count"

    if (( start_count > 0 )) && [[ -f "/tmp/cjdh_run_start_peers.$$" ]]; then
        echo
        printf "  ${C_DIM}Connected at start:${C_RESET}\n"
        while IFS= read -r addr; do
            [[ -n "$addr" ]] || continue
            printf "    %s\n" "$addr"
        done < "/tmp/cjdh_run_start_peers.$$"
    fi

    if (( end_count > 0 )) && [[ -f "$end_peers" ]]; then
        echo
        printf "  ${C_DIM}Connected at end:${C_RESET}\n"
        while IFS= read -r addr; do
            [[ -n "$addr" ]] || continue
            printf "    %s\n" "$addr"
        done < "$end_peers"
    fi

    # Display NEW addresses added this run
    echo
    printf "  ${C_BOLD}New Addresses This Run:${C_RESET}\n"
    printf "    Master:     %s new\n" "$new_master_count"
    printf "    Confirmed:  %s new\n" "$new_confirmed_count"

    if (( new_master_count > 0 )) && [[ -f "/tmp/cjdh_run_new_master.$$" ]]; then
        echo
        printf "  ${C_SUCCESS}New to master:${C_RESET}\n"
        sort -u "/tmp/cjdh_run_new_master.$$" 2>/dev/null | while IFS= read -r addr; do
            [[ -n "$addr" ]] || continue
            printf "    ${C_SUCCESS}+${C_RESET} %s\n" "$addr"
        done
    fi

    if (( new_confirmed_count > 0 )) && [[ -f "/tmp/cjdh_run_new_confirmed.$$" ]]; then
        echo
        printf "  ${C_SUCCESS}New to confirmed:${C_RESET}\n"
        sort -u "/tmp/cjdh_run_new_confirmed.$$" 2>/dev/null | while IFS= read -r addr; do
            [[ -n "$addr" ]] || continue
            printf "    ${C_SUCCESS}✓${C_RESET} %s\n" "$addr"
        done
    fi

    # Cleanup temp files
    rm -f "/tmp/cjdh_run_start_peers.$$" "$end_peers" "/tmp/cjdh_run_new_master.$$" "/tmp/cjdh_run_new_confirmed.$$"
}

# ============================================================================
# Harvester Mode (Option 1)
# ============================================================================
run_harvester_mode() {
    print_box "HARVESTER MODE"

    # Ask for run mode
    echo
    echo "Run mode:"
    echo "  1) Once (single pass, then exit)"
    echo "  2) Continuous (loop)"
    echo
    local run_mode
    read -r -p "Choice [1/2]: " run_mode

    local scan_interval=60
    local harvest_remote="no"

    if [[ "$run_mode" == "2" ]]; then
        # Ask for scan interval
        echo
        read -r -p "Seconds between scans [default: 60]: " scan_interval
        [[ -z "$scan_interval" || ! "$scan_interval" =~ ^[0-9]+$ ]] && scan_interval=60
    fi

    # Ask about remote nodestore
    echo
    echo "Almost all set..."
    echo
    if prompt_yn "Do you have other machines on your local network with CJDNS that you would like to scan simultaneously (UNCOMMON)?"; then
        harvest_remote="yes"
        echo
        status_info "Remote harvesting will scan NodeStore + Frontier on other CJDNS nodes"
        status_info "Setting up automatic login (SSH keys) for each remote host"
        status_warn "EXPERIMENTAL FUNCTION: Disable this if experiencing errors"
        echo

        # Configure remote hosts
        source "${SCRIPT_DIR}/lib/v5/remote.sh"
        configure_remote_hosts

        if [[ "${#REMOTE_HOSTS[@]}" -eq 0 ]]; then
            status_warn "No remote hosts configured, skipping remote harvest"
            harvest_remote="no"
        else
            export HARVEST_REMOTE=yes
        fi
    fi

    echo
    status_ok "Configuration complete"
    echo

    # Main harvester loop
    local loop_count=0
    while true; do
        loop_count=$((loop_count + 1))

        log_info "Harvest loop $loop_count starting"
        echo

        # Show current database status
        local master_count confirmed_count
        master_count="$(db_count_master)"
        confirmed_count="$(db_count_confirmed)"
        print_db_stats "$master_count" "$confirmed_count"

        # Display current status
        display_cjdns_router

        # Capture connected peers at START of run
        bash -c "$CLI getpeerinfo" 2>/dev/null \
            | jq -r '.[] | select(.network=="cjdns") | .addr' 2>/dev/null \
            | while IFS= read -r raw; do
                canon_host "$(cjdns_host_from_maybe_bracketed "$raw")"
            done | sort -u > "/tmp/cjdh_run_start_peers.$$" 2>/dev/null || true

        display_bitcoin_peers

        # Initialize run tracking files
        : > "/tmp/cjdh_run_new_master.$$"
        : > "/tmp/cjdh_run_new_confirmed.$$"

        # Harvest addresses
        harvest_nodestore
        harvest_remote_nodestore
        harvest_frontier
        harvest_remote_frontier
        harvest_addrman
        harvest_connected_peers

        # Show updated database counts
        echo
        master_count="$(db_count_master)"
        confirmed_count="$(db_count_confirmed)"
        print_db_stats "$master_count" "$confirmed_count" "DATABASE STATUS (AFTER HARVEST)"

        # Onetry new addresses
        onetry_new_addresses

        # Show final database counts
        echo
        master_count="$(db_count_master)"
        confirmed_count="$(db_count_confirmed)"
        print_db_stats "$master_count" "$confirmed_count" "FINAL DATABASE STATUS"

        # Show run summary
        show_run_summary

        # Check if stop requested
        if (( HARVEST_STOP_REQUESTED == 1 )); then
            log_warn "Stop requested, exiting"
            break
        fi

        # Exit if run-once mode
        if [[ "$run_mode" == "1" ]]; then
            echo
            log_success "Single pass complete"
            echo
            read -r -p "Press Enter to return to main menu..."
            break
        fi

        # Sleep with countdown
        log_info "Sleeping ${scan_interval}s until next scan"
        local remaining=$scan_interval
        while (( remaining > 0 )); do
            printf "  ${C_MUTED}%ss remaining...${C_RESET}\r" "$remaining"
            sleep 1
            remaining=$((remaining - 1))

            # Check for stop request during sleep
            if (( HARVEST_STOP_REQUESTED == 1 )); then
                echo
                log_warn "Stop requested during sleep, exiting"
                exit 0
            fi
        done
        echo
    done
}

# ============================================================================
# Main Entry Point
# ============================================================================
main() {
    # Detect and confirm Bitcoin Core
    detect_and_confirm_bitcoin

    # Detect and confirm CJDNS
    detect_and_confirm_cjdns

    # Run preflight checks
    run_preflight_checks

    # Check database and show stats (or first-run setup)
    check_database_and_show_stats

    # Main menu loop
    while true; do
        show_main_menu

        local choice
        read -r -p "Choice [1-9, 0=exit]: " choice

        case "$choice" in
            1)
                run_harvester_mode
                ;;
            2)
                onetry_all_confirmed
                echo
                read -r -p "Press Enter to continue..."
                ;;
            3)
                onetry_all_master
                echo
                read -r -p "Press Enter to continue..."
                ;;
            4)
                update_database_from_repo
                echo
                read -r -p "Press Enter to continue..."
                ;;
            5)
                export_database_to_txt
                echo
                read -r -p "Press Enter to continue..."
                ;;
            6)
                backup_database
                echo
                read -r -p "Press Enter to continue..."
                ;;
            7)
                restore_database
                echo
                read -r -p "Press Enter to continue..."
                ;;
            8)
                delete_backups
                echo
                read -r -p "Press Enter to continue..."
                ;;
            9)
                delete_database
                ;;
            0)
                echo
                log_success "Goodbye!"
                exit 0
                ;;
            *)
                status_error "Invalid choice: $choice"
                sleep 2
                ;;
        esac
    done
}

# Run main
main "$@"

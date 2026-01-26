#!/usr/bin/env bash
# ============================================================================
# db-multitool.sh - Database Multi-Machine Merge Tool
# ============================================================================
# Standalone utility to merge state.db files from multiple machines.
# Collects databases via SSH/SCP and merges unique addresses into local DB.
# ============================================================================

# Don't use set -e, we handle errors manually
set -uo pipefail

# ============================================================================
# ANSI Color Palette (matches main harvester style)
# ============================================================================
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_SUCCESS='\033[38;5;120m'
C_WARNING='\033[38;5;214m'
C_ERROR='\033[38;5;203m'
C_INFO='\033[38;5;111m'
C_MUTED='\033[38;5;245m'
C_HEADER='\033[1;36m'
C_SUBHEADER='\033[38;5;147m'
C_NEW='\033[1;38;5;226m'

# ============================================================================
# Globals
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DB="$SCRIPT_DIR/state.db"
BACKUP_DB="$SCRIPT_DIR/state.db.multitool-backup"
CONFIG_FILE="$SCRIPT_DIR/.db-multitool.conf"
TMP_DIR="/tmp/db-multitool-$$"

declare -a REMOTE_DBS=()
declare -a REMOTE_HOSTS=()
declare -a REMOTE_PATHS=()
declare -a REMOTE_USERS=()
declare -a REMOTE_PASSWORDS=()

# ============================================================================
# UI Functions
# ============================================================================
print_box() {
    local title="$1"
    local width=72
    local title_len=${#title}
    local padding=$(( width - title_len - 2 ))

    printf "\n${C_HEADER}"
    printf '╔'
    printf '═%.0s' $(seq 1 $width)
    printf '╗\n'
    printf '║ %s' "$title"
    printf '%*s' "$padding" ""
    printf ' ║\n'
    printf '╚'
    printf '═%.0s' $(seq 1 $width)
    printf '╝\n'
    printf "${C_RESET}\n"
}

print_section() {
    local title="$1"
    printf "\n${C_BOLD}${C_HEADER}▶ %s${C_RESET}\n" "$title"
}

print_divider() {
    printf "${C_MUTED}%s${C_RESET}\n" "$(printf '─%.0s' $(seq 1 72))"
}

status_ok() {
    printf "${C_SUCCESS}✓${C_RESET} %s\n" "$1"
}

status_warn() {
    printf "${C_WARNING}⚠${C_RESET} %s\n" "$1"
}

status_error() {
    printf "${C_ERROR}✗${C_RESET} %s\n" "$1"
}

status_info() {
    printf "${C_INFO}ℹ${C_RESET} %s\n" "$1"
}

# ============================================================================
# Dependency Check
# ============================================================================
check_deps() {
    local missing=()
    local packages=()

    if ! command -v sqlite3 >/dev/null 2>&1; then
        missing+=("sqlite3")
        packages+=("sqlite3")
    fi
    if ! command -v sshpass >/dev/null 2>&1; then
        missing+=("sshpass")
        packages+=("sshpass")
    fi
    if ! command -v scp >/dev/null 2>&1; then
        missing+=("scp")
        packages+=("openssh-client")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        status_warn "Missing dependencies: ${missing[*]}"
        echo
        printf "  Would you like to install them now? [Y/n]: "
        read -r install_answer
        install_answer="${install_answer:-y}"

        if [[ "$install_answer" == "y" || "$install_answer" == "Y" ]]; then
            echo
            printf "  Installing ${packages[*]}..."
            if sudo apt-get install -y "${packages[@]}" >/dev/null 2>&1; then
                printf " ${C_SUCCESS}done${C_RESET}\n"
                echo
            else
                printf " ${C_ERROR}failed${C_RESET}\n"
                status_error "Could not install dependencies. Try manually:"
                echo "  sudo apt-get install ${packages[*]}"
                exit 1
            fi
        else
            status_info "Install them manually with: sudo apt-get install ${packages[*]}"
            exit 1
        fi
    fi
}

# ============================================================================
# Cleanup
# ============================================================================
cleanup() {
    if [[ -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# ============================================================================
# Config File Functions (just stores defaults for convenience)
# ============================================================================
LAST_IP=""
LAST_PATH="~/state.db"
LAST_USER=""

load_defaults() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # Source the config file to load LAST_* variables
        source "$CONFIG_FILE" 2>/dev/null || true
    fi
}

save_defaults() {
    # Save the last used values as defaults for next time
    if [[ -n "${REMOTE_HOSTS[0]:-}" ]]; then
        {
            echo "# db-multitool defaults"
            echo "LAST_IP=\"${REMOTE_HOSTS[0]}\""
            echo "LAST_PATH=\"${REMOTE_PATHS[0]}\""
            echo "LAST_USER=\"${REMOTE_USERS[0]}\""
        } > "$CONFIG_FILE"
    fi
}

# ============================================================================
# Collect Remote Machine Info
# ============================================================================
collect_remotes() {
    # Load saved defaults
    load_defaults

    print_section "Add Remote Machines"
    echo
    status_info "Enter details for each remote machine with a state.db to merge."
    status_info "Press Enter to use default values shown in [brackets]."
    status_info "Leave IP blank and press Enter when done adding machines."
    echo

    local add_more="y"
    local idx=1

    while [[ "$add_more" == "y" || "$add_more" == "Y" ]]; do
        print_divider
        printf "${C_BOLD}Remote Machine #%d${C_RESET}\n" "$idx"
        echo

        # IP Address (show default if we have one)
        if [[ -n "$LAST_IP" ]]; then
            printf "  IP Address (or hostname) [%s]: " "$LAST_IP"
        else
            printf "  IP Address (or hostname): "
        fi
        read -r ip

        # Use default if empty and we have one
        if [[ -z "$ip" && -n "$LAST_IP" && $idx -eq 1 ]]; then
            ip="$LAST_IP"
            printf "  ${C_MUTED}Using: %s${C_RESET}\n" "$ip"
        fi

        # Empty IP means done
        if [[ -z "$ip" ]]; then
            if [[ ${#REMOTE_HOSTS[@]} -eq 0 ]]; then
                status_warn "No remote machines added. Will only work with local database."
            fi
            break
        fi

        # Path to state.db
        printf "  Path to state.db [%s]: " "$LAST_PATH"
        read -r dbpath
        if [[ -z "$dbpath" ]]; then
            dbpath="$LAST_PATH"
            printf "  ${C_MUTED}Using: %s${C_RESET}\n" "$dbpath"
        fi

        # Username
        if [[ -n "$LAST_USER" ]]; then
            printf "  SSH Username [%s]: " "$LAST_USER"
        else
            printf "  SSH Username: "
        fi
        read -r username
        if [[ -z "$username" && -n "$LAST_USER" ]]; then
            username="$LAST_USER"
            printf "  ${C_MUTED}Using: %s${C_RESET}\n" "$username"
        fi

        if [[ -z "$username" ]]; then
            status_error "Username is required. Skipping this machine."
            continue
        fi

        # Password (always prompt, never save)
        printf "  SSH Password: "
        read -rs password
        echo

        if [[ -z "$password" ]]; then
            status_error "Password is required. Skipping this machine."
            continue
        fi

        # Store
        REMOTE_HOSTS+=("$ip")
        REMOTE_PATHS+=("$dbpath")
        REMOTE_USERS+=("$username")
        REMOTE_PASSWORDS+=("$password")

        # Update defaults for next prompt
        LAST_IP="$ip"
        LAST_PATH="$dbpath"
        LAST_USER="$username"

        status_ok "Added: $username@$ip:$dbpath"
        idx=$((idx + 1))

        echo
        printf "  Add another remote machine? [y/N]: "
        read -r add_more
        add_more="${add_more:-n}"
    done

    # Save defaults for next run
    save_defaults
}

# ============================================================================
# Fetch Remote Databases
# ============================================================================
fetch_remote_dbs() {
    if [[ ${#REMOTE_HOSTS[@]} -eq 0 ]]; then
        return 0
    fi

    print_section "Fetching Remote Databases"
    echo

    mkdir -p "$TMP_DIR"

    local idx=0
    local success=0
    local failed=0

    for host in "${REMOTE_HOSTS[@]}"; do
        local user="${REMOTE_USERS[$idx]}"
        local pass="${REMOTE_PASSWORDS[$idx]}"
        local path="${REMOTE_PATHS[$idx]}"
        local dest="$TMP_DIR/remote_${idx}_${host//[^a-zA-Z0-9]/_}.db"

        printf "  Fetching from %s@%s..." "$user" "$host"

        if SSHPASS="$pass" sshpass -e scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${user}@${host}:${path}" "$dest" 2>/dev/null; then
            printf " ${C_SUCCESS}done${C_RESET}\n"
            REMOTE_DBS+=("$dest")
            success=$((success + 1))
        else
            printf " ${C_ERROR}failed${C_RESET}\n"
            failed=$((failed + 1))
        fi

        idx=$((idx + 1))
    done

    echo
    status_info "Fetched: $success, Failed: $failed"
}

# ============================================================================
# Analyze Databases
# ============================================================================
analyze_dbs() {
    print_section "Analyzing Databases"
    echo

    # Build list of all DBs to analyze
    local all_dbs=()

    if [[ -f "$LOCAL_DB" ]]; then
        all_dbs+=("$LOCAL_DB")
        status_ok "Local database: $LOCAL_DB"
    else
        status_warn "No local database found at $LOCAL_DB"
    fi

    for db in "${REMOTE_DBS[@]}"; do
        all_dbs+=("$db")
        status_ok "Remote database: $(basename "$db")"
    done

    if [[ ${#all_dbs[@]} -lt 1 ]]; then
        status_error "No databases to analyze!"
        exit 1
    fi

    echo
    print_divider
    printf "${C_BOLD}Database Contents:${C_RESET}\n\n"

    for db in "${all_dbs[@]}"; do
        local name
        if [[ "$db" == "$LOCAL_DB" ]]; then
            name="LOCAL"
        else
            name="$(basename "$db" .db)"
        fi

        local master_count confirmed_count
        master_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM master;" 2>/dev/null || echo "0")
        confirmed_count=$(sqlite3 "$db" "SELECT COUNT(*) FROM confirmed;" 2>/dev/null || echo "0")

        printf "  %-40s Master: %4s  Confirmed: %4s\n" "$name" "$master_count" "$confirmed_count"
    done

    echo
}

# ============================================================================
# Calculate Merge Differences
# ============================================================================
calculate_diff() {
    print_section "Calculating Merge"
    echo

    if [[ ! -f "$LOCAL_DB" ]]; then
        status_warn "No local database - will create new one with all remote data."
        return 0
    fi

    if [[ ${#REMOTE_DBS[@]} -eq 0 ]]; then
        status_warn "No remote databases to merge."
        return 0
    fi

    # Create temp DB for union of all remotes
    local union_db="$TMP_DIR/union.db"

    # Initialize with schema
    sqlite3 "$union_db" <<'SQL'
CREATE TABLE IF NOT EXISTS master (
  host TEXT PRIMARY KEY,
  first_seen_ts INTEGER NOT NULL,
  last_seen_ts INTEGER NOT NULL,
  source_flags TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS confirmed (
  host TEXT PRIMARY KEY,
  first_confirmed_ts INTEGER NOT NULL,
  last_confirmed_ts INTEGER NOT NULL,
  confirm_count INTEGER NOT NULL DEFAULT 1
);
SQL

    # Merge all remotes into union db
    for db in "${REMOTE_DBS[@]}"; do
        # Merge master
        sqlite3 "$union_db" <<SQL
ATTACH DATABASE '$db' AS remote;
INSERT INTO master(host, first_seen_ts, last_seen_ts, source_flags)
SELECT host, first_seen_ts, last_seen_ts, source_flags FROM remote.master
WHERE true
ON CONFLICT(host) DO UPDATE SET
  first_seen_ts = MIN(master.first_seen_ts, excluded.first_seen_ts),
  last_seen_ts = MAX(master.last_seen_ts, excluded.last_seen_ts),
  source_flags = CASE
    WHEN master.source_flags = '' THEN excluded.source_flags
    WHEN excluded.source_flags = '' THEN master.source_flags
    ELSE master.source_flags || ',' || excluded.source_flags
  END;
DETACH DATABASE remote;
SQL

        # Merge confirmed
        sqlite3 "$union_db" <<SQL
ATTACH DATABASE '$db' AS remote;
INSERT INTO confirmed(host, first_confirmed_ts, last_confirmed_ts, confirm_count)
SELECT host, first_confirmed_ts, last_confirmed_ts, confirm_count FROM remote.confirmed
WHERE true
ON CONFLICT(host) DO UPDATE SET
  first_confirmed_ts = MIN(confirmed.first_confirmed_ts, excluded.first_confirmed_ts),
  last_confirmed_ts = MAX(confirmed.last_confirmed_ts, excluded.last_confirmed_ts),
  confirm_count = confirmed.confirm_count + excluded.confirm_count;
DETACH DATABASE remote;
SQL
    done

    # Now find what's NOT in local
    NEW_MASTER_COUNT=$(sqlite3 "$union_db" <<SQL
ATTACH DATABASE '$LOCAL_DB' AS local;
SELECT COUNT(*) FROM master WHERE host NOT IN (SELECT host FROM local.master);
SQL
)

    NEW_CONFIRMED_COUNT=$(sqlite3 "$union_db" <<SQL
ATTACH DATABASE '$LOCAL_DB' AS local;
SELECT COUNT(*) FROM confirmed WHERE host NOT IN (SELECT host FROM local.confirmed);
SQL
)

    # Get the actual new hosts for display
    NEW_MASTER_HOSTS=$(sqlite3 "$union_db" <<SQL
ATTACH DATABASE '$LOCAL_DB' AS local;
SELECT host FROM master WHERE host NOT IN (SELECT host FROM local.master) ORDER BY host;
SQL
)

    NEW_CONFIRMED_HOSTS=$(sqlite3 "$union_db" <<SQL
ATTACH DATABASE '$LOCAL_DB' AS local;
SELECT host FROM confirmed WHERE host NOT IN (SELECT host FROM local.confirmed) ORDER BY host;
SQL
)

    # Also count updates (existing hosts with newer data)
    UPDATE_MASTER_COUNT=$(sqlite3 "$union_db" <<SQL
ATTACH DATABASE '$LOCAL_DB' AS local;
SELECT COUNT(*) FROM master m
WHERE m.host IN (SELECT host FROM local.master)
  AND (m.first_seen_ts < (SELECT first_seen_ts FROM local.master WHERE host = m.host)
       OR m.last_seen_ts > (SELECT last_seen_ts FROM local.master WHERE host = m.host));
SQL
)

    UPDATE_CONFIRMED_COUNT=$(sqlite3 "$union_db" <<SQL
ATTACH DATABASE '$LOCAL_DB' AS local;
SELECT COUNT(*) FROM confirmed c
WHERE c.host IN (SELECT host FROM local.confirmed)
  AND (c.first_confirmed_ts < (SELECT first_confirmed_ts FROM local.confirmed WHERE host = c.host)
       OR c.last_confirmed_ts > (SELECT last_confirmed_ts FROM local.confirmed WHERE host = c.host));
SQL
)

    # Store for later use
    UNION_DB="$union_db"
}

# ============================================================================
# Show Summary
# ============================================================================
show_summary() {
    print_box "MERGE SUMMARY"

    local local_master local_confirmed
    if [[ -f "$LOCAL_DB" ]]; then
        local_master=$(sqlite3 "$LOCAL_DB" "SELECT COUNT(*) FROM master;" 2>/dev/null || echo "0")
        local_confirmed=$(sqlite3 "$LOCAL_DB" "SELECT COUNT(*) FROM confirmed;" 2>/dev/null || echo "0")
    else
        local_master=0
        local_confirmed=0
    fi

    printf "  ${C_BOLD}Current Local Database:${C_RESET}\n"
    printf "    Master:    %s addresses\n" "$local_master"
    printf "    Confirmed: %s addresses\n" "$local_confirmed"
    echo

    if [[ ${#REMOTE_DBS[@]} -eq 0 ]]; then
        status_info "No remote databases fetched - nothing to merge."
        return 1
    fi

    printf "  ${C_BOLD}New Addresses from Remotes:${C_RESET}\n"

    if [[ "${NEW_MASTER_COUNT:-0}" -gt 0 ]]; then
        printf "    ${C_NEW}Master:    +%s new addresses${C_RESET}\n" "$NEW_MASTER_COUNT"
    else
        printf "    ${C_MUTED}Master:    +0 new addresses${C_RESET}\n"
    fi

    if [[ "${NEW_CONFIRMED_COUNT:-0}" -gt 0 ]]; then
        printf "    ${C_NEW}Confirmed: +%s new addresses${C_RESET}\n" "$NEW_CONFIRMED_COUNT"
    else
        printf "    ${C_MUTED}Confirmed: +0 new addresses${C_RESET}\n"
    fi

    echo
    printf "  ${C_BOLD}Updates to Existing:${C_RESET}\n"
    printf "    Master:    %s addresses with updated timestamps\n" "${UPDATE_MASTER_COUNT:-0}"
    printf "    Confirmed: %s addresses with updated timestamps\n" "${UPDATE_CONFIRMED_COUNT:-0}"
    echo

    # Show the new addresses if not too many
    if [[ "${NEW_MASTER_COUNT:-0}" -gt 0 && "${NEW_MASTER_COUNT:-0}" -le 20 ]]; then
        printf "  ${C_BOLD}New Master Addresses:${C_RESET}\n"
        while IFS= read -r host; do
            [[ -n "$host" ]] && printf "    ${C_NEW}+${C_RESET} %s\n" "$host"
        done <<< "$NEW_MASTER_HOSTS"
        echo
    fi

    if [[ "${NEW_CONFIRMED_COUNT:-0}" -gt 0 && "${NEW_CONFIRMED_COUNT:-0}" -le 20 ]]; then
        printf "  ${C_BOLD}New Confirmed Addresses:${C_RESET}\n"
        while IFS= read -r host; do
            [[ -n "$host" ]] && printf "    ${C_NEW}+${C_RESET} %s\n" "$host"
        done <<< "$NEW_CONFIRMED_HOSTS"
        echo
    fi

    print_divider

    # Check if there's anything to merge
    if [[ "${NEW_MASTER_COUNT:-0}" -eq 0 && "${NEW_CONFIRMED_COUNT:-0}" -eq 0 && \
          "${UPDATE_MASTER_COUNT:-0}" -eq 0 && "${UPDATE_CONFIRMED_COUNT:-0}" -eq 0 ]]; then
        status_info "Databases are already in sync! Nothing to merge."
        return 1
    fi

    return 0
}

# ============================================================================
# Perform Merge
# ============================================================================
do_merge() {
    print_section "Merging into Local Database"
    echo

    # Backup first
    if [[ -f "$LOCAL_DB" ]]; then
        printf "  Creating backup..."
        cp "$LOCAL_DB" "$BACKUP_DB"
        printf " ${C_SUCCESS}done${C_RESET} (%s)\n" "$BACKUP_DB"
    else
        # Create fresh database
        printf "  Creating new database..."
        sqlite3 "$LOCAL_DB" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS master (
  host TEXT PRIMARY KEY,
  first_seen_ts INTEGER NOT NULL,
  last_seen_ts INTEGER NOT NULL,
  source_flags TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS confirmed (
  host TEXT PRIMARY KEY,
  first_confirmed_ts INTEGER NOT NULL,
  last_confirmed_ts INTEGER NOT NULL,
  confirm_count INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS attempts (
  host TEXT PRIMARY KEY,
  last_attempt_ts INTEGER,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  last_result TEXT,
  last_fail_ts INTEGER,
  consecutive_fail INTEGER NOT NULL DEFAULT 0,
  cooldown_until_ts INTEGER
);
SQL
        printf " ${C_SUCCESS}done${C_RESET}\n"
    fi

    # Merge from union db
    printf "  Merging master table..."
    sqlite3 "$LOCAL_DB" <<SQL
ATTACH DATABASE '$UNION_DB' AS src;
INSERT INTO master(host, first_seen_ts, last_seen_ts, source_flags)
SELECT host, first_seen_ts, last_seen_ts, source_flags FROM src.master
WHERE true
ON CONFLICT(host) DO UPDATE SET
  first_seen_ts = MIN(master.first_seen_ts, excluded.first_seen_ts),
  last_seen_ts = MAX(master.last_seen_ts, excluded.last_seen_ts),
  source_flags = CASE
    WHEN master.source_flags = '' THEN excluded.source_flags
    WHEN excluded.source_flags = '' THEN master.source_flags
    WHEN instr(master.source_flags, excluded.source_flags) > 0 THEN master.source_flags
    ELSE master.source_flags || ',' || excluded.source_flags
  END;
DETACH DATABASE src;
SQL
    printf " ${C_SUCCESS}done${C_RESET}\n"

    printf "  Merging confirmed table..."
    sqlite3 "$LOCAL_DB" <<SQL
ATTACH DATABASE '$UNION_DB' AS src;
INSERT INTO confirmed(host, first_confirmed_ts, last_confirmed_ts, confirm_count)
SELECT host, first_confirmed_ts, last_confirmed_ts, confirm_count FROM src.confirmed
WHERE true
ON CONFLICT(host) DO UPDATE SET
  first_confirmed_ts = MIN(confirmed.first_confirmed_ts, excluded.first_confirmed_ts),
  last_confirmed_ts = MAX(confirmed.last_confirmed_ts, excluded.last_confirmed_ts),
  confirm_count = confirmed.confirm_count + excluded.confirm_count;
DETACH DATABASE src;
SQL
    printf " ${C_SUCCESS}done${C_RESET}\n"

    echo

    # Show new counts
    local new_master new_confirmed
    new_master=$(sqlite3 "$LOCAL_DB" "SELECT COUNT(*) FROM master;")
    new_confirmed=$(sqlite3 "$LOCAL_DB" "SELECT COUNT(*) FROM confirmed;")

    status_ok "Merge complete!"
    printf "    Master:    %s addresses\n" "$new_master"
    printf "    Confirmed: %s addresses\n" "$new_confirmed"
    echo
}

# ============================================================================
# Push Updated DB to Remotes
# ============================================================================
push_to_remotes() {
    if [[ ${#REMOTE_HOSTS[@]} -eq 0 ]]; then
        return 0
    fi

    print_section "Pushing Updated Database to Remote Machines"
    echo

    local idx=0
    local success=0
    local failed=0

    for host in "${REMOTE_HOSTS[@]}"; do
        local user="${REMOTE_USERS[$idx]}"
        local pass="${REMOTE_PASSWORDS[$idx]}"
        local path="${REMOTE_PATHS[$idx]}"

        printf "  Pushing to %s@%s..." "$user" "$host"

        if SSHPASS="$pass" sshpass -e scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "$LOCAL_DB" "${user}@${host}:${path}" 2>/dev/null; then
            printf " ${C_SUCCESS}done${C_RESET}\n"
            success=$((success + 1))
        else
            printf " ${C_ERROR}failed${C_RESET}\n"
            failed=$((failed + 1))
        fi

        idx=$((idx + 1))
    done

    echo
    status_info "Pushed: $success, Failed: $failed"
}

# ============================================================================
# Main
# ============================================================================
main() {
    print_box "DATABASE MULTI-TOOL"
    printf "  Merge state.db files from multiple machines\n"
    printf "  Local DB: %s\n\n" "$LOCAL_DB"

    # Check dependencies
    check_deps

    # Collect remote machine info
    collect_remotes

    # Fetch remote databases
    fetch_remote_dbs

    # Analyze all databases
    analyze_dbs

    # Calculate what needs merging
    calculate_diff

    # Show summary
    if ! show_summary; then
        echo
        status_info "Exiting - nothing to do."
        exit 0
    fi

    # Ask to merge
    echo
    printf "${C_BOLD}Add all addresses to local database?${C_RESET} [y/N]: "
    read -r do_merge_answer

    if [[ "$do_merge_answer" == "y" || "$do_merge_answer" == "Y" ]]; then
        do_merge

        # Ask to push back
        if [[ ${#REMOTE_HOSTS[@]} -gt 0 ]]; then
            echo
            printf "${C_BOLD}Push updated database back to remote machines?${C_RESET} [y/N]: "
            read -r push_answer

            if [[ "$push_answer" == "y" || "$push_answer" == "Y" ]]; then
                push_to_remotes
            fi
        fi

        echo
        status_ok "All done!"
    else
        echo
        status_info "Merge cancelled. No changes made."
    fi
}

# Run
main "$@"

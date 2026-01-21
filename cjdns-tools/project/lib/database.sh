#!/usr/bin/env bash
# Database Module - SQLite peer quality tracking

# Database location
DB_FILE="$BACKUP_DIR/peer_tracking.db"

# Check if database is locked
check_database_lock() {
    local lock_file="${DB_FILE}-journal"
    local wal_file="${DB_FILE}-wal"
    local shm_file="${DB_FILE}-shm"

    # Check for SQLite lock files
    if [ -f "$lock_file" ] || [ -f "$wal_file" ] || [ -f "$shm_file" ]; then
        return 0  # Locked
    fi

    # Try to access the database
    if ! sqlite3 "$DB_FILE" "SELECT 1;" &>/dev/null 2>&1; then
        return 0  # Locked or inaccessible
    fi

    return 1  # Not locked
}

# Remove database lock files
remove_database_lock() {
    local lock_file="${DB_FILE}-journal"
    local wal_file="${DB_FILE}-wal"
    local shm_file="${DB_FILE}-shm"

    print_info "Removing lock files..."
    rm -f "$lock_file" "$wal_file" "$shm_file" 2>/dev/null

    # Try to recover with sqlite3
    sqlite3 "$DB_FILE" "PRAGMA integrity_check;" &>/dev/null || {
        print_warning "Database may be corrupted. Consider resetting it."
        return 1
    }

    return 0
}

# Initialize database
init_database() {
    # Check if database exists and is locked
    if [ -f "$DB_FILE" ]; then
        if check_database_lock; then
            print_warning "Database appears to be locked or in use"
            echo
            echo "This can happen if:"
            echo "  - Another instance of this tool is running"
            echo "  - The tool was previously terminated unexpectedly"
            echo

            if ask_yes_no "Do you want to unlock the database?"; then
                if ! remove_database_lock; then
                    print_error "Failed to unlock database"
                    if ask_yes_no "Reset database instead? (This will delete all tracking history)"; then
                        reset_database
                    else
                        return 1
                    fi
                else
                    print_success "Database unlocked"
                fi
            else
                print_error "Cannot proceed with locked database"
                echo
                echo "Please ensure no other instances are running, then try again."
                return 1
            fi
        fi
        return 0
    fi

    # Create new database
    sqlite3 "$DB_FILE" <<'EOF'
CREATE TABLE IF NOT EXISTS peers (
    address TEXT PRIMARY KEY,
    state TEXT,
    first_seen INTEGER,
    last_seen INTEGER,
    last_state_change INTEGER,
    consecutive_checks_in_state INTEGER DEFAULT 0,
    established_count INTEGER DEFAULT 0,
    unresponsive_count INTEGER DEFAULT 0,
    other_count INTEGER DEFAULT 0,
    quality_score REAL DEFAULT 0
);
EOF
    local result=$?

    # Set proper permissions on database file
    if [ $result -eq 0 ] && [ -f "$DB_FILE" ]; then
        chmod 644 "$DB_FILE" 2>/dev/null
    fi

    # Migrate existing database if needed
    local has_state_change=$(sqlite3 "$DB_FILE" "PRAGMA table_info(peers);" | grep -c "last_state_change" || echo 0)
    if [ "$has_state_change" -eq 0 ]; then
        sqlite3 "$DB_FILE" <<'EOF'
ALTER TABLE peers ADD COLUMN last_state_change INTEGER DEFAULT 0;
ALTER TABLE peers ADD COLUMN consecutive_checks_in_state INTEGER DEFAULT 0;
EOF
    fi

    return $result
}

# Update peer in database
update_peer_state() {
    local address="$1"
    local state="$2"
    local now=$(date +%s)

    # Check if peer exists in config
    local in_config=0
    if jq -e --arg addr "$address" '.interfaces.UDPInterface[].connectTo | has($addr)' "$CJDNS_CONFIG" &>/dev/null; then
        in_config=1
    fi

    # If not in config, remove from database
    if [ "$in_config" -eq 0 ]; then
        sqlite3 "$DB_FILE" "DELETE FROM peers WHERE address='$address';"
        return 0
    fi

    # Check if peer exists in database
    local exists=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM peers WHERE address='$address';")

    if [ "$exists" -eq 0 ]; then
        # New peer - insert
        sqlite3 "$DB_FILE" <<EOF
INSERT INTO peers (address, state, first_seen, last_seen, last_state_change, consecutive_checks_in_state, established_count, unresponsive_count, other_count)
VALUES ('$address', '$state', $now, $now, $now, 1, 0, 0, 0);
EOF
    fi

    # Get current state from database
    local current_state=$(sqlite3 "$DB_FILE" "SELECT state FROM peers WHERE address='$address';")

    # Check if state changed
    if [ "$current_state" != "$state" ]; then
        # State changed - reset consecutive checks and update last_state_change
        case "$state" in
            ESTABLISHED)
                sqlite3 "$DB_FILE" <<EOF
UPDATE peers SET
    state='$state',
    last_seen=$now,
    last_state_change=$now,
    consecutive_checks_in_state=1,
    established_count=established_count+1
WHERE address='$address';
EOF
                ;;
            UNRESPONSIVE)
                sqlite3 "$DB_FILE" <<EOF
UPDATE peers SET
    state='$state',
    last_seen=$now,
    last_state_change=$now,
    consecutive_checks_in_state=1,
    unresponsive_count=unresponsive_count+1
WHERE address='$address';
EOF
                ;;
            *)
                sqlite3 "$DB_FILE" <<EOF
UPDATE peers SET
    state='$state',
    last_seen=$now,
    last_state_change=$now,
    consecutive_checks_in_state=1,
    other_count=other_count+1
WHERE address='$address';
EOF
                ;;
        esac
    else
        # State same - increment consecutive checks
        case "$state" in
            ESTABLISHED)
                sqlite3 "$DB_FILE" <<EOF
UPDATE peers SET
    last_seen=$now,
    consecutive_checks_in_state=consecutive_checks_in_state+1,
    established_count=established_count+1
WHERE address='$address';
EOF
                ;;
            UNRESPONSIVE)
                sqlite3 "$DB_FILE" <<EOF
UPDATE peers SET
    last_seen=$now,
    consecutive_checks_in_state=consecutive_checks_in_state+1,
    unresponsive_count=unresponsive_count+1
WHERE address='$address';
EOF
                ;;
            *)
                sqlite3 "$DB_FILE" <<EOF
UPDATE peers SET
    last_seen=$now,
    consecutive_checks_in_state=consecutive_checks_in_state+1,
    other_count=other_count+1
WHERE address='$address';
EOF
                ;;
        esac
    fi

    # Recalculate quality score
    sqlite3 "$DB_FILE" <<EOF
UPDATE peers SET
    quality_score = CASE
        WHEN (established_count + unresponsive_count + other_count) = 0 THEN 50.0
        ELSE (CAST(established_count AS REAL) / (established_count + unresponsive_count + other_count)) * 100.0
    END
WHERE address='$address';
EOF
}

# Get peer quality score
get_peer_quality() {
    local address="$1"
    sqlite3 "$DB_FILE" "SELECT quality_score FROM peers WHERE address='$address';" 2>/dev/null || echo "0"
}

# Get peer stats
get_peer_stats() {
    local address="$1"
    sqlite3 "$DB_FILE" "SELECT state, established_count, unresponsive_count, first_seen FROM peers WHERE address='$address';" 2>/dev/null
}

# Get all peers sorted by quality
get_all_peers_by_quality() {
    sqlite3 "$DB_FILE" "SELECT address, state, quality_score, established_count, unresponsive_count, first_seen, last_state_change, consecutive_checks_in_state FROM peers ORDER BY quality_score DESC;" 2>/dev/null
}

# Reset database
reset_database() {
    if [ -f "$DB_FILE" ]; then
        rm -f "$DB_FILE"
    fi
    init_database
}

# Clean database (remove peers not in config)
clean_database() {
    local count=0

    # Get all addresses from database
    local db_peers=$(sqlite3 "$DB_FILE" "SELECT address FROM peers;" 2>/dev/null)

    while IFS= read -r address; do
        [ -z "$address" ] && continue

        # Check if in config
        if ! jq -e --arg addr "$address" '.interfaces.UDPInterface[].connectTo | has($addr)' "$CJDNS_CONFIG" &>/dev/null; then
            sqlite3 "$DB_FILE" "DELETE FROM peers WHERE address='$address';"
            count=$((count + 1))
        fi
    done <<< "$db_peers"

    echo "$count"
}

# Format timestamp to human-readable
format_timestamp() {
    local timestamp="$1"
    date -d "@$timestamp" "+%b %d, %Y %H:%M" 2>/dev/null || echo "Unknown"
}

# Format time since timestamp (human readable)
time_since() {
    local timestamp="$1"
    local now=$(date +%s)
    local diff=$((now - timestamp))

    if [ "$diff" -lt 60 ]; then
        echo "${diff}s ago"
    elif [ "$diff" -lt 3600 ]; then
        echo "$((diff / 60))m ago"
    elif [ "$diff" -lt 86400 ]; then
        echo "$((diff / 3600))h ago"
    else
        echo "$((diff / 86400))d ago"
    fi
}

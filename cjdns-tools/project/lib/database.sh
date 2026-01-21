#!/usr/bin/env bash
# Database Module - SQLite peer quality tracking

# Database location
DB_FILE="$BACKUP_DIR/peer_tracking.db"

# Initialize database
init_database() {
    if [ ! -f "$DB_FILE" ]; then
        sqlite3 "$DB_FILE" <<'EOF'
CREATE TABLE IF NOT EXISTS peers (
    address TEXT PRIMARY KEY,
    state TEXT,
    first_seen INTEGER,
    last_seen INTEGER,
    established_count INTEGER DEFAULT 0,
    unresponsive_count INTEGER DEFAULT 0,
    other_count INTEGER DEFAULT 0,
    quality_score REAL DEFAULT 0
);
EOF
        return $?
    fi
    return 0
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
INSERT INTO peers (address, state, first_seen, last_seen, established_count, unresponsive_count, other_count)
VALUES ('$address', '$state', $now, $now, 0, 0, 0);
EOF
    fi

    # Update counts based on state
    case "$state" in
        ESTABLISHED)
            sqlite3 "$DB_FILE" <<EOF
UPDATE peers SET
    state='$state',
    last_seen=$now,
    established_count=established_count+1
WHERE address='$address';
EOF
            ;;
        UNRESPONSIVE)
            sqlite3 "$DB_FILE" <<EOF
UPDATE peers SET
    state='$state',
    last_seen=$now,
    unresponsive_count=unresponsive_count+1
WHERE address='$address';
EOF
            ;;
        *)
            sqlite3 "$DB_FILE" <<EOF
UPDATE peers SET
    state='$state',
    last_seen=$now,
    other_count=other_count+1
WHERE address='$address';
EOF
            ;;
    esac

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
    sqlite3 "$DB_FILE" "SELECT address, state, quality_score, established_count, unresponsive_count, first_seen FROM peers ORDER BY quality_score DESC;" 2>/dev/null
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

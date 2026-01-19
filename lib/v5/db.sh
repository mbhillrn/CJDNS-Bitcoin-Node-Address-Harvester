#!/usr/bin/env bash
# CJDNS Harvester v5 - Database Functions

# Requires: canon_host function, BASE_DIR, DB_PATH

# ============================================================================
# Database Initialization
# ============================================================================
db_init() {
    mkdir -p "$BASE_DIR"

    sqlite3 "$DB_PATH" <<'SQL' >/dev/null
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;

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
}

# ============================================================================
# Insert/Update Functions
# ============================================================================
db_upsert_master() {
    # Usage: db_upsert_master host source
    local host src="$2"
    host="$(canon_host "${1:-}")"
    [[ -n "$host" ]] || return 0

    local now
    now="$(date +%s)"

    sqlite3 "$DB_PATH" <<SQL >/dev/null
INSERT INTO master(host, first_seen_ts, last_seen_ts, source_flags)
VALUES ('$host', $now, $now, '$src')
ON CONFLICT(host) DO UPDATE SET
  last_seen_ts=excluded.last_seen_ts,
  source_flags=CASE
    WHEN instr(master.source_flags, '$src')>0 THEN master.source_flags
    WHEN master.source_flags=='' THEN '$src'
    ELSE master.source_flags || ',' || '$src'
  END;
SQL
}

db_upsert_confirmed() {
    # Usage: db_upsert_confirmed host
    local host
    host="$(canon_host "${1:-}")"
    [[ -n "$host" ]] || return 0

    local now
    now="$(date +%s)"

    sqlite3 "$DB_PATH" <<SQL >/dev/null
INSERT INTO confirmed(host, first_confirmed_ts, last_confirmed_ts, confirm_count)
VALUES ('$host', $now, $now, 1)
ON CONFLICT(host) DO UPDATE SET
  last_confirmed_ts=excluded.last_confirmed_ts,
  confirm_count=confirm_count+1;
SQL
}

# ============================================================================
# Query Functions
# ============================================================================
db_count_master() {
    sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM master;" 2>/dev/null || echo "0"
}

db_count_confirmed() {
    sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM confirmed;" 2>/dev/null || echo "0"
}

db_get_all_master() {
    sqlite3 "$DB_PATH" "SELECT host FROM master ORDER BY last_seen_ts DESC;" 2>/dev/null
}

db_get_all_confirmed() {
    sqlite3 "$DB_PATH" "SELECT host FROM confirmed ORDER BY last_confirmed_ts DESC;" 2>/dev/null
}

db_is_in_master() {
    local host
    host="$(canon_host "${1:-}")"
    [[ -n "$host" ]] || return 1

    local count
    count="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM master WHERE host='$host';" 2>/dev/null || echo "0")"
    (( count > 0 ))
}

# ============================================================================
# Helper to check if address is new
# ============================================================================
db_check_new() {
    # Returns 0 if NEW, 1 if existing
    local host
    host="$(canon_host "${1:-}")"
    [[ -n "$host" ]] || return 1

    db_is_in_master "$host" && return 1  # Exists
    return 0  # New
}

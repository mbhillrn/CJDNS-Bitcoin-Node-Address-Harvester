#!/usr/bin/env bash
# Master Peer List Module - Local peer cache management

# File locations
MASTER_LIST="$BACKUP_DIR/master_peer_list.json"
PEER_SOURCES="$BACKUP_DIR/peer_sources.json"

# Initialize master peer list
init_master_list() {
    if [ ! -f "$MASTER_LIST" ]; then
        echo '{"ipv4": {}, "ipv6": {}}' > "$MASTER_LIST"
    fi

    if [ ! -f "$PEER_SOURCES" ]; then
        cat > "$PEER_SOURCES" <<'EOF'
{
  "sources": [
    {
      "name": "hyperboria/peers",
      "type": "github",
      "url": "https://github.com/hyperboria/peers.git",
      "enabled": true
    },
    {
      "name": "yangm97/peers",
      "type": "github",
      "url": "https://github.com/yangm97/peers.git",
      "enabled": true
    },
    {
      "name": "cwinfo/hyperboria-peers",
      "type": "github",
      "url": "https://github.com/cwinfo/hyperboria-peers.git",
      "enabled": true
    },
    {
      "name": "kaotisk-hund",
      "type": "json",
      "url": "https://raw.githubusercontent.com/kaotisk-hund/python-cjdns-peering-tools/master/peers.json",
      "enabled": true
    }
  ]
}
EOF
    fi
}

# Update master list from online sources
update_master_list() {
    local temp_dir=$(mktemp -d)
    local updated_ipv4="$temp_dir/updated_ipv4.json"
    local updated_ipv6="$temp_dir/updated_ipv6.json"

    echo '{}' > "$updated_ipv4"
    echo '{}' > "$updated_ipv6"

    # Get enabled sources
    local sources=$(jq -r '.sources[] | select(.enabled==true) | @json' "$PEER_SOURCES")

    while IFS= read -r source_json; do
        [ -z "$source_json" ] && continue

        local name=$(echo "$source_json" | jq -r '.name')
        local type=$(echo "$source_json" | jq -r '.type')
        local url=$(echo "$source_json" | jq -r '.url')

        print_info "Updating from: $name"

        if [ "$type" = "github" ]; then
            update_from_github "$url" "$name" "$temp_dir" "$updated_ipv4" "$updated_ipv6"
        elif [ "$type" = "json" ]; then
            update_from_json "$url" "$updated_ipv4" "$updated_ipv6"
        fi
    done <<< "$sources"

    # Merge with existing master list
    local current_ipv4=$(jq '.ipv4' "$MASTER_LIST")
    local current_ipv6=$(jq '.ipv6' "$MASTER_LIST")

    local new_ipv4=$(jq -s '.[0] * .[1]' <(echo "$current_ipv4") "$updated_ipv4")
    local new_ipv6=$(jq -s '.[0] * .[1]' <(echo "$current_ipv6") "$updated_ipv6")

    # Save updated master list
    jq -n --argjson v4 "$new_ipv4" --argjson v6 "$new_ipv6" \
        '{ipv4: $v4, ipv6: $v6}' > "$MASTER_LIST"

    rm -rf "$temp_dir"

    # Return counts
    local count_ipv4=$(echo "$new_ipv4" | jq 'length')
    local count_ipv6=$(echo "$new_ipv6" | jq 'length')
    echo "$count_ipv4|$count_ipv6"
}

# Update from GitHub repository
update_from_github() {
    local url="$1"
    local name="$2"
    local temp_dir="$3"
    local output_ipv4="$4"
    local output_ipv6="$5"

    local repo_dir="$temp_dir/$name"

    if ! git clone --depth 1 --quiet "$url" "$repo_dir" 2>/dev/null; then
        print_warning "Failed to clone $name"
        return 1
    fi

    cd "$repo_dir" || return 1

    # Find all .k files
    local k_files=$(find . -name "*.k" -type f 2>/dev/null)
    [ -z "$k_files" ] && return 1

    while IFS= read -r peer_file; do
        [ -z "$peer_file" ] && continue

        if ! jq empty "$peer_file" 2>/dev/null; then
            continue
        fi

        # Extract IPv4 and IPv6
        local ipv4_data=$(jq 'to_entries | map(select(.key | startswith("[") | not)) | from_entries' "$peer_file" 2>/dev/null)
        local ipv6_data=$(jq 'to_entries | map(select(.key | startswith("["))) | from_entries' "$peer_file" 2>/dev/null)

        if [ -n "$ipv4_data" ] && [ "$ipv4_data" != "{}" ]; then
            jq -s '.[0] * .[1]' "$output_ipv4" <(echo "$ipv4_data") > "$output_ipv4.tmp"
            mv "$output_ipv4.tmp" "$output_ipv4"
        fi

        if [ -n "$ipv6_data" ] && [ "$ipv6_data" != "{}" ]; then
            jq -s '.[0] * .[1]' "$output_ipv6" <(echo "$ipv6_data") > "$output_ipv6.tmp"
            mv "$output_ipv6.tmp" "$output_ipv6"
        fi
    done <<< "$k_files"

    cd - >/dev/null
}

# Update from raw JSON URL
update_from_json() {
    local url="$1"
    local output_ipv4="$2"
    local output_ipv6="$3"

    local temp_file=$(mktemp)

    if ! wget -q -O "$temp_file" "$url" 2>/dev/null; then
        rm -f "$temp_file"
        return 1
    fi

    if ! jq empty "$temp_file" 2>/dev/null; then
        rm -f "$temp_file"
        return 1
    fi

    # Split into IPv4 and IPv6
    local ipv4_data=$(jq 'to_entries | map(select(.key | startswith("[") | not)) | from_entries' "$temp_file" 2>/dev/null)
    local ipv6_data=$(jq 'to_entries | map(select(.key | startswith("["))) | from_entries' "$temp_file" 2>/dev/null)

    if [ -n "$ipv4_data" ] && [ "$ipv4_data" != "{}" ]; then
        jq -s '.[0] * .[1]' "$output_ipv4" <(echo "$ipv4_data") > "$output_ipv4.tmp"
        mv "$output_ipv4.tmp" "$output_ipv4"
    fi

    if [ -n "$ipv6_data" ] && [ "$ipv6_data" != "{}" ]; then
        jq -s '.[0] * .[1]' "$output_ipv6" <(echo "$ipv6_data") > "$output_ipv6.tmp"
        mv "$output_ipv6.tmp" "$output_ipv6"
    fi

    rm -f "$temp_file"
}

# Reset master list (delete and re-download)
reset_master_list() {
    if [ -f "$MASTER_LIST" ]; then
        rm -f "$MASTER_LIST"
    fi
    init_master_list
    update_master_list
}

# Get peers from master list
get_master_peers() {
    local protocol="$1"  # "ipv4" or "ipv6"

    if [ ! -f "$MASTER_LIST" ]; then
        echo "{}"
        return
    fi

    jq -r ".$protocol" "$MASTER_LIST" 2>/dev/null || echo "{}"
}

# Get master list counts
get_master_counts() {
    local ipv4_count=$(jq '.ipv4 | length' "$MASTER_LIST" 2>/dev/null || echo 0)
    local ipv6_count=$(jq '.ipv6 | length' "$MASTER_LIST" 2>/dev/null || echo 0)
    echo "$ipv4_count|$ipv6_count"
}

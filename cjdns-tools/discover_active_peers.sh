#!/usr/bin/env bash
# Test all CJDNS peers from hyperboria/peers repo
# Find which ones are ACTUALLY active

set -e

PEERS_DIR="/tmp/cjdns_peers_$$/peers"
OUTPUT_IPV4="/tmp/active_peers_ipv4_$$.json"
OUTPUT_IPV6="/tmp/active_peers_ipv6_$$.json"

echo "======================================"
echo "CJDNS Peer Discovery & Testing"
echo "======================================"
echo

# Clone repo if not already done
if [ ! -d "$PEERS_DIR" ]; then
    echo "Cloning peers repository..."
    mkdir -p "$(dirname "$PEERS_DIR")"
    git clone --depth 1 https://github.com/hyperboria/peers.git "$PEERS_DIR" 2>/dev/null
    echo "✓ Cloned"
else
    echo "Using existing repo at $PEERS_DIR"
fi

cd "$PEERS_DIR"

echo
echo "Scanning for all peer files..."
ALL_K_FILES=$(find . -name "*.k" -type f)
TOTAL_FILES=$(echo "$ALL_K_FILES" | wc -l)
echo "Found $TOTAL_FILES peer files"
echo

# Initialize output
echo "{}" > "$OUTPUT_IPV4"
echo "{}" > "$OUTPUT_IPV6"

echo "Extracting peer information..."
echo "======================================"

CURRENT=0
IPV4_COUNT=0
IPV6_COUNT=0

while IFS= read -r peer_file; do
    CURRENT=$((CURRENT + 1))

    # Read the JSON file
    if ! peer_json=$(cat "$peer_file" 2>/dev/null); then
        continue
    fi

    # Check if it's valid JSON
    if ! echo "$peer_json" | jq empty 2>/dev/null; then
        continue
    fi

    echo "[$CURRENT/$TOTAL_FILES] Processing: $peer_file"

    # Get all IPv4 addresses (no brackets)
    ipv4_addrs=$(echo "$peer_json" | jq -r 'keys[] | select(startswith("[") | not)' 2>/dev/null || echo "")

    if [ -n "$ipv4_addrs" ]; then
        while IFS= read -r address; do
            [ -z "$address" ] && continue

            # Extract this peer's data
            peer_data=$(echo "$peer_json" | jq --arg addr "$address" '{($addr): .[$addr]}' 2>/dev/null)

            if [ -n "$peer_data" ]; then
                # Merge into output
                echo "$peer_data" | jq -s --slurpfile existing "$OUTPUT_IPV4" '.[0] * $existing[0]' > /tmp/merged_$$.json
                mv /tmp/merged_$$.json "$OUTPUT_IPV4"
                IPV4_COUNT=$((IPV4_COUNT + 1))
            fi
        done <<< "$ipv4_addrs"
    fi

    # Get all IPv6 addresses (with brackets)
    ipv6_addrs=$(echo "$peer_json" | jq -r 'keys[] | select(startswith("["))' 2>/dev/null || echo "")

    if [ -n "$ipv6_addrs" ]; then
        while IFS= read -r address; do
            [ -z "$address" ] && continue

            # Extract this peer's data
            peer_data=$(echo "$peer_json" | jq --arg addr "$address" '{($addr): .[$addr]}' 2>/dev/null)

            if [ -n "$peer_data" ]; then
                # Merge into output
                echo "$peer_data" | jq -s --slurpfile existing "$OUTPUT_IPV6" '.[0] * $existing[0]' > /tmp/merged_$$.json
                mv /tmp/merged_$$.json "$OUTPUT_IPV6"
                IPV6_COUNT=$((IPV6_COUNT + 1))
            fi
        done <<< "$ipv6_addrs"
    fi

done <<< "$ALL_K_FILES"

echo
echo "======================================"
echo "Extraction Complete"
echo "======================================"
echo "IPv4 peers found: $IPV4_COUNT"
echo "IPv6 peers found: $IPV6_COUNT"
echo
echo "IPv4 peers saved to: $OUTPUT_IPV4"
echo "IPv6 peers saved to: $OUTPUT_IPV6"
echo

# Now test reachability (ping test)
echo "======================================"
echo "Testing Peer Reachability (IPv4)"
echo "======================================"
echo "This may take a while..."
echo

ACTIVE_OUTPUT="/tmp/active_peers_ipv4_tested_$$.json"
echo "{}" > "$ACTIVE_OUTPUT"

TESTED=0
ACTIVE=0

while IFS= read -r address; do
    [ -z "$address" ] && continue
    TESTED=$((TESTED + 1))

    # Extract IP (remove port)
    IP="${address%:*}"

    echo -n "[$TESTED/$IPV4_COUNT] Testing $address ($IP)... "

    # Ping test (1 packet, 2 second timeout)
    if ping -c 1 -W 2 "$IP" >/dev/null 2>&1; then
        echo "✓ ACTIVE"

        # Copy this peer to active list
        peer_data=$(jq --arg addr "$address" '{($addr): .[$addr]}' "$OUTPUT_IPV4" 2>/dev/null)

        if [ -n "$peer_data" ]; then
            echo "$peer_data" | jq -s --slurpfile existing "$ACTIVE_OUTPUT" '.[0] * $existing[0]' > /tmp/merged_$$.json
            mv /tmp/merged_$$.json "$ACTIVE_OUTPUT"
            ACTIVE=$((ACTIVE + 1))
        fi
    else
        echo "✗ unreachable"
    fi

done < <(jq -r 'keys[]' "$OUTPUT_IPV4" 2>/dev/null)

echo
echo "======================================"
echo "Testing Complete"
echo "======================================"
echo "Total tested:  $TESTED"
echo "Active peers:  $ACTIVE"
echo "Dead peers:    $((TESTED - ACTIVE))"
echo
echo "Active peers saved to: $ACTIVE_OUTPUT"
echo

# Display active peers
if [ "$ACTIVE" -gt 0 ]; then
    echo "======================================"
    echo "ACTIVE PEERS (IPv4)"
    echo "======================================"
    jq -r 'to_entries[] | "Address:    \(.key)\nPeerName:   \(.value.peerName // "N/A")\nContact:    \(.value.contact // "N/A")\nPublicKey:  \(.value.publicKey)\nPassword:   \(.value.password)\nLogin:      \(.value.login // "default-login")\n"' "$ACTIVE_OUTPUT"
fi

echo
echo "To use these peers:"
echo "  1. Review the list in: $ACTIVE_OUTPUT"
echo "  2. Use add_peer_safe.sh to add them to your config"
echo "  3. Compare against your existing config: /etc/cjdroute_51888.conf"
echo

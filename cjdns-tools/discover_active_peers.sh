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

    # Extract IPv4 peers (addresses without brackets)
    while IFS= read -r address; do
        [ -z "$address" ] && continue

        # Get peer details
        login=$(echo "$peer_json" | jq -r ".[\"$address\"].login // \"default-login\"")
        password=$(echo "$peer_json" | jq -r ".[\"$address\"].password")
        publicKey=$(echo "$peer_json" | jq -r ".[\"$address\"].publicKey")
        peerName=$(echo "$peer_json" | jq -r ".[\"$address\"].peerName // \"unknown\"")
        contact=$(echo "$peer_json" | jq -r ".[\"$address\"].contact // \"N/A\"")

        # Add to IPv4 output
        echo "$peer_json" | jq --arg addr "$address" \
            "{($addr): .[$addr]}" > /tmp/peer_entry_$$.json

        jq -s '.[0] * .[1]' "$OUTPUT_IPV4" /tmp/peer_entry_$$.json > /tmp/merged_$$.json
        mv /tmp/merged_$$.json "$OUTPUT_IPV4"
        rm -f /tmp/peer_entry_$$.json

        IPV4_COUNT=$((IPV4_COUNT + 1))

    done < <(echo "$peer_json" | jq -r 'keys[] | select(startswith("[") | not)')

    # Extract IPv6 peers (addresses with brackets)
    while IFS= read -r address; do
        [ -z "$address" ] && continue

        # Add to IPv6 output
        echo "$peer_json" | jq --arg addr "$address" \
            "{($addr): .[$addr]}" > /tmp/peer_entry_$$.json

        jq -s '.[0] * .[1]' "$OUTPUT_IPV6" /tmp/peer_entry_$$.json > /tmp/merged_$$.json
        mv /tmp/merged_$$.json "$OUTPUT_IPV6"
        rm -f /tmp/peer_entry_$$.json

        IPV6_COUNT=$((IPV6_COUNT + 1))

    done < <(echo "$peer_json" | jq -r 'keys[] | select(startswith("["))')

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
        jq --arg addr "$address" \
            "{($addr): .[$addr]}" "$OUTPUT_IPV4" > /tmp/peer_entry_$$.json

        jq -s '.[0] * .[1]' "$ACTIVE_OUTPUT" /tmp/peer_entry_$$.json > /tmp/merged_$$.json
        mv /tmp/merged_$$.json "$ACTIVE_OUTPUT"
        rm -f /tmp/peer_entry_$$.json

        ACTIVE=$((ACTIVE + 1))
    else
        echo "✗ unreachable"
    fi

done < <(jq -r 'keys[]' "$OUTPUT_IPV4")

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

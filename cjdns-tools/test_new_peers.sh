#!/bin/bash

# Test connectivity to new CJDNS peers before adding them
# Usage: ./test_new_peers.sh <ipv4_peers.json> <ipv6_peers.json> <config_file>

set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <ipv4_peers.json> <ipv6_peers.json> <config_file>"
    echo "Example: sudo $0 /tmp/cjdns_peer_discovery_*/all_ipv4_peers.json /tmp/cjdns_peer_discovery_*/all_ipv6_peers.json /etc/cjdroute_51888.conf"
    exit 1
fi

IPV4_PEERS="$1"
IPV6_PEERS="$2"
CONFIG="$3"

if [ ! -f "$IPV4_PEERS" ]; then
    echo "Error: IPv4 peers file not found: $IPV4_PEERS"
    exit 1
fi

if [ ! -f "$IPV6_PEERS" ]; then
    echo "Error: IPv6 peers file not found: $IPV6_PEERS"
    exit 1
fi

if [ ! -f "$CONFIG" ]; then
    echo "Error: Config file not found: $CONFIG"
    exit 1
fi

WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

echo "========================================"
echo "Testing NEW CJDNS Peers for Connectivity"
echo "========================================"
echo

# Extract existing peers from config
echo "[1] Extracting existing peers from config..."
jq -r '.interfaces.UDPInterface[0].connectTo // {} | keys[]' "$CONFIG" > "$WORKDIR/existing_ipv4.txt" 2>/dev/null || touch "$WORKDIR/existing_ipv4.txt"
jq -r '.interfaces.UDPInterface[1].connectTo // {} | keys[]' "$CONFIG" > "$WORKDIR/existing_ipv6.txt" 2>/dev/null || touch "$WORKDIR/existing_ipv6.txt"

EXISTING_IPV4=$(wc -l < "$WORKDIR/existing_ipv4.txt")
EXISTING_IPV6=$(wc -l < "$WORKDIR/existing_ipv6.txt")

echo "  Current IPv4 peers: $EXISTING_IPV4"
echo "  Current IPv6 peers: $EXISTING_IPV6"
echo

# Find new IPv4 peers
echo "[2] Finding NEW IPv4 peers..."
jq -r 'keys[]' "$IPV4_PEERS" > "$WORKDIR/all_ipv4.txt"
grep -vxFf "$WORKDIR/existing_ipv4.txt" "$WORKDIR/all_ipv4.txt" > "$WORKDIR/new_ipv4.txt" || true
NEW_IPV4_COUNT=$(wc -l < "$WORKDIR/new_ipv4.txt")
echo "  Found $NEW_IPV4_COUNT new IPv4 peers"
echo

# Find new IPv6 peers
echo "[3] Finding NEW IPv6 peers..."
jq -r 'keys[]' "$IPV6_PEERS" > "$WORKDIR/all_ipv6.txt"
grep -vxFf "$WORKDIR/existing_ipv6.txt" "$WORKDIR/all_ipv6.txt" > "$WORKDIR/new_ipv6.txt" || true
NEW_IPV6_COUNT=$(wc -l < "$WORKDIR/new_ipv6.txt")
echo "  Found $NEW_IPV6_COUNT new IPv6 peers"
echo

# Test IPv4 peers
echo "========================================"
echo "Testing IPv4 Peers (this may take a while)"
echo "========================================"
echo

ACTIVE_IPV4=0
TESTED_IPV4=0

> "$WORKDIR/active_ipv4.json"
echo "{" >> "$WORKDIR/active_ipv4.json"

while IFS= read -r addr; do
    if [ -z "$addr" ]; then
        continue
    fi

    TESTED_IPV4=$((TESTED_IPV4 + 1))

    # Extract IP and port
    IP=$(echo "$addr" | cut -d: -f1)
    PORT=$(echo "$addr" | cut -d: -f2)

    # Get peer info
    PEER_INFO=$(jq -r --arg addr "$addr" '.[$addr]' "$IPV4_PEERS")
    PEER_NAME=$(echo "$PEER_INFO" | jq -r '.peerName // "unknown"')

    echo -n "[$TESTED_IPV4/$NEW_IPV4_COUNT] Testing $IP ($PEER_NAME)... "

    # Ping test with 2 second timeout
    if ping -c 2 -W 2 "$IP" >/dev/null 2>&1; then
        echo "✓ ACTIVE"
        ACTIVE_IPV4=$((ACTIVE_IPV4 + 1))

        # Add to active peers JSON
        if [ $ACTIVE_IPV4 -gt 1 ]; then
            echo "," >> "$WORKDIR/active_ipv4.json"
        fi
        echo -n "  \"$addr\": $PEER_INFO" >> "$WORKDIR/active_ipv4.json"
    else
        echo "✗ No response"
    fi
done < "$WORKDIR/new_ipv4.txt"

echo >> "$WORKDIR/active_ipv4.json"
echo "}" >> "$WORKDIR/active_ipv4.json"

echo
echo "IPv4 Results: $ACTIVE_IPV4 active out of $NEW_IPV4_COUNT tested"
echo

# Test IPv6 peers
echo "========================================"
echo "Testing IPv6 Peers (this may take a while)"
echo "========================================"
echo

ACTIVE_IPV6=0
TESTED_IPV6=0

> "$WORKDIR/active_ipv6.json"
echo "{" >> "$WORKDIR/active_ipv6.json"

while IFS= read -r addr; do
    if [ -z "$addr" ]; then
        continue
    fi

    TESTED_IPV6=$((TESTED_IPV6 + 1))

    # Extract IPv6 address (remove brackets and port)
    IPV6=$(echo "$addr" | sed 's/^\[\(.*\)\]:.*$/\1/')

    # Get peer info
    PEER_INFO=$(jq -r --arg addr "$addr" '.[$addr]' "$IPV6_PEERS")
    PEER_NAME=$(echo "$PEER_INFO" | jq -r '.peerName // "unknown"')

    echo -n "[$TESTED_IPV6/$NEW_IPV6_COUNT] Testing $IPV6 ($PEER_NAME)... "

    # Ping6 test with 2 second timeout
    if ping -6 -c 2 -W 2 "$IPV6" >/dev/null 2>&1; then
        echo "✓ ACTIVE"
        ACTIVE_IPV6=$((ACTIVE_IPV6 + 1))

        # Add to active peers JSON
        if [ $ACTIVE_IPV6 -gt 1 ]; then
            echo "," >> "$WORKDIR/active_ipv6.json"
        fi
        echo -n "  \"$addr\": $PEER_INFO" >> "$WORKDIR/active_ipv6.json"
    else
        echo "✗ No response"
    fi
done < "$WORKDIR/new_ipv6.txt"

echo >> "$WORKDIR/active_ipv6.json"
echo "}" >> "$WORKDIR/active_ipv6.json"

echo
echo "IPv6 Results: $ACTIVE_IPV6 active out of $NEW_IPV6_COUNT tested"
echo

# Save results
RESULTS_DIR="/tmp/cjdns_tested_peers_$$"
mkdir -p "$RESULTS_DIR"
cp "$WORKDIR/active_ipv4.json" "$RESULTS_DIR/"
cp "$WORKDIR/active_ipv6.json" "$RESULTS_DIR/"

echo "========================================"
echo "Testing Complete"
echo "========================================"
echo
echo "Active IPv4 peers: $ACTIVE_IPV4 / $NEW_IPV4_COUNT"
echo "Active IPv6 peers: $ACTIVE_IPV6 / $NEW_IPV6_COUNT"
echo
echo "Results saved to:"
echo "  IPv4: $RESULTS_DIR/active_ipv4.json"
echo "  IPv6: $RESULTS_DIR/active_ipv6.json"
echo
echo "Next steps:"
echo "  1. Review the active peers"
echo "  2. Use add_peer_safe.sh to add IPv4 peers"
echo "  3. Manually add IPv6 peers to your config"
echo

if [ $ACTIVE_IPV4 -gt 0 ]; then
    echo "Sample active IPv4 peers (first 5):"
    jq -r 'to_entries[0:5][] | "  \(.key) - \(.value.peerName // "unknown")"' "$RESULTS_DIR/active_ipv4.json" 2>/dev/null || echo "  (none)"
    echo
fi

if [ $ACTIVE_IPV6 -gt 0 ]; then
    echo "Sample active IPv6 peers (first 5):"
    jq -r 'to_entries[0:5][] | "  \(.key) - \(.value.peerName // "unknown")"' "$RESULTS_DIR/active_ipv6.json" 2>/dev/null || echo "  (none)"
fi

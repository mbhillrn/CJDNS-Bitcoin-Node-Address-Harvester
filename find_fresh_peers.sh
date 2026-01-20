#!/usr/bin/env bash
# Find fresh CJDNS public peers from GitHub

set -e

echo "Fetching fresh public peers from hyperboria/peers repository..."
echo

TEMP_DIR="/tmp/cjdns_peers_$$"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

# Clone the public peers repository
if git clone --depth 1 https://github.com/hyperboria/peers.git 2>/dev/null; then
    echo "✓ Peers repository cloned"
else
    echo "✗ Failed to clone repository"
    exit 1
fi

cd peers

echo
echo "Available regions:"
echo "=================="
find . -type d -mindepth 1 -maxdepth 1 | sed 's|./||' | grep -v '\.git'

echo
echo "Searching for active IPv4 UDP peers..."
echo "======================================"

# Find all .k files (peer configs)
find . -name "*.k" -type f | while read -r peer_file; do
    # Extract relevant info
    peer_data=$(cat "$peer_file")

    # Check if it has IPv4 UDP interface
    if echo "$peer_data" | jq -e '.[] | select(has("address") and (.address | contains(":")) and (.address | contains("[") | not))' >/dev/null 2>&1; then
        echo
        echo "File: $peer_file"
        echo "$peer_data" | jq -r '.[] | select(has("address") and (.address | contains(":")) and (.address | contains("[") | not)) |
            "  Address:    \(.address)\n" +
            "  Login:      \(.login // "N/A")\n" +
            "  Password:   \(.password)\n" +
            "  PublicKey:  \(.publicKey)\n" +
            "  Contact:    \(.contact // "N/A")\n" +
            "  PeerName:   \(.peerName // "N/A")"'
    fi
done

echo
echo
echo "======================================"
echo "Fresh peers found above!"
echo "======================================"
echo
echo "To test a peer before adding:"
echo "  1. Pick an address from above"
echo "  2. Try pinging it: ping -c 3 <IP_ADDRESS>"
echo "  3. If it responds, it's likely active"
echo
echo "Temp directory: $TEMP_DIR"
echo "You can browse manually: cd $TEMP_DIR/peers"

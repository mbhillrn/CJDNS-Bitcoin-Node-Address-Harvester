#!/usr/bin/env bash
# Remove UNRESPONSIVE peers from config (IPv4 section ONLY)

set -e

CONFIG="/etc/cjdroute_51888.conf"
BACKUP_DIR="/etc/cjdns_backups"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo)${NC}"
    exit 1
fi

mkdir -p "$BACKUP_DIR"

echo "======================================"
echo "CJDNS Dead Peer Removal Tool"
echo "======================================"
echo

# Get list of UNRESPONSIVE peers
echo "Scanning for UNRESPONSIVE peers..."
echo

DEAD_PEERS="/tmp/dead_peers_$$.txt"
: > "$DEAD_PEERS"

page=0
while true; do
    result=$(cjdnstool -a 127.0.0.1 -p 11234 -P NONE cexec InterfaceController_peerStats --page=$page 2>/dev/null)
    [ -z "$result" ] && break

    # Extract UNRESPONSIVE peers with their addresses
    echo "$result" | jq -r '.peers[]? | select(.state == "UNRESPONSIVE") | .lladdr' >> "$DEAD_PEERS" 2>/dev/null || true

    peers=$(echo "$result" | jq -r '.peers[]?' 2>/dev/null)
    [ -z "$peers" ] && break

    page=$((page + 1))
done

# Filter out IPv6 addresses (only remove IPv4)
grep -v '^\[' "$DEAD_PEERS" > "${DEAD_PEERS}.ipv4" 2>/dev/null || : > "${DEAD_PEERS}.ipv4"

DEAD_COUNT=$(wc -l < "${DEAD_PEERS}.ipv4")

if [ "$DEAD_COUNT" -eq 0 ]; then
    echo -e "${GREEN}No dead IPv4 peers found!${NC}"
    rm -f "$DEAD_PEERS" "${DEAD_PEERS}.ipv4"
    exit 0
fi

echo -e "${YELLOW}Found $DEAD_COUNT dead IPv4 peers:${NC}"
cat "${DEAD_PEERS}.ipv4" | nl
echo

read -p "Remove these peers from config? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled."
    rm -f "$DEAD_PEERS" "${DEAD_PEERS}.ipv4"
    exit 0
fi

# Backup
BACKUP_FILE="${BACKUP_DIR}/cjdroute_51888.conf.$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG" "$BACKUP_FILE"
echo -e "${GREEN}✓ Backup created: $BACKUP_FILE${NC}"
echo

# Remove each dead peer from IPv4 interface
BEFORE_COUNT=$(jq '.interfaces.UDPInterface[0].connectTo | length' "$CONFIG")

echo "Removing dead peers..."
while read -r dead_addr; do
    echo "  Removing: $dead_addr"
    jq --arg addr "$dead_addr" \
        'del(.interfaces.UDPInterface[0].connectTo[$addr])' \
        "$CONFIG" > "${CONFIG}.tmp"
    mv "${CONFIG}.tmp" "$CONFIG"
done < "${DEAD_PEERS}.ipv4"

# Validate
if jq empty "$CONFIG" 2>/dev/null; then
    echo -e "${GREEN}✓ JSON validation passed${NC}"
else
    echo -e "${RED}✗ JSON validation failed! Restoring backup...${NC}"
    cp "$BACKUP_FILE" "$CONFIG"
    rm -f "$DEAD_PEERS" "${DEAD_PEERS}.ipv4"
    exit 1
fi

AFTER_COUNT=$(jq '.interfaces.UDPInterface[0].connectTo | length' "$CONFIG")
IPV6_COUNT=$(jq '.interfaces.UDPInterface[1].connectTo | length' "$CONFIG")

echo
echo "======================================"
echo -e "${GREEN}SUCCESS!${NC}"
echo "======================================"
echo "IPv4 peers: $BEFORE_COUNT → $AFTER_COUNT (removed $((BEFORE_COUNT - AFTER_COUNT)))"
echo "IPv6 peers: $IPV6_COUNT (unchanged)"
echo
echo "To apply changes, restart cjdroute:"
echo "  sudo systemctl restart cjdroute-51888"
echo
echo "To revert:"
echo "  sudo cp $BACKUP_FILE $CONFIG"
echo "  sudo systemctl restart cjdroute-51888"
echo

rm -f "$DEAD_PEERS" "${DEAD_PEERS}.ipv4"

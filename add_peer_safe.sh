#!/usr/bin/env bash
# Safely add a peer to cjdroute config (IPv4 section ONLY)

set -e

CONFIG="/etc/cjdroute_51888.conf"
BACKUP_DIR="/etc/cjdns_backups"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo)${NC}"
    exit 1
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

echo "======================================"
echo "CJDNS Peer Addition Tool (SAFE MODE)"
echo "======================================"
echo
echo -e "${YELLOW}This script will ONLY add to IPv4 interface${NC}"
echo -e "${YELLOW}IPv6 interface will NOT be touched${NC}"
echo
echo "Current config: $CONFIG"
echo

# Backup current config
BACKUP_FILE="${BACKUP_DIR}/cjdroute_51888.conf.$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG" "$BACKUP_FILE"
echo -e "${GREEN}✓ Backup created: $BACKUP_FILE${NC}"
echo

# Show current peer count
CURRENT_IPV4_PEERS=$(jq '.interfaces.UDPInterface[0].connectTo | length' "$CONFIG")
echo "Current IPv4 peers: $CURRENT_IPV4_PEERS"
echo

# Get peer information
echo "Enter new peer information:"
echo "----------------------------"
read -p "Peer address (e.g., 1.2.3.4:5678): " PEER_ADDRESS
read -p "Login: " PEER_LOGIN
read -p "Password: " PEER_PASSWORD
read -p "Public key: " PEER_PUBKEY
read -p "Peer name (optional): " PEER_NAME
read -p "Contact (optional): " PEER_CONTACT

echo
echo "Peer to add:"
echo "  Address:   $PEER_ADDRESS"
echo "  Login:     $PEER_LOGIN"
echo "  Password:  $PEER_PASSWORD"
echo "  PublicKey: $PEER_PUBKEY"
echo "  Name:      $PEER_NAME"
echo "  Contact:   $PEER_CONTACT"
echo

read -p "Add this peer? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

# Create peer JSON
PEER_JSON=$(jq -n \
    --arg login "$PEER_LOGIN" \
    --arg password "$PEER_PASSWORD" \
    --arg pubkey "$PEER_PUBKEY" \
    --arg name "$PEER_NAME" \
    --arg contact "$PEER_CONTACT" \
    '{
        login: $login,
        password: $password,
        publicKey: $pubkey,
        peerName: (if $name != "" then $name else null end),
        contact: (if $contact != "" then $contact else null end)
    } | with_entries(select(.value != null))')

# Add peer to IPv4 interface (index 0) ONLY
echo
echo "Adding peer to IPv4 interface..."

jq --arg addr "$PEER_ADDRESS" --argjson peer "$PEER_JSON" \
    '.interfaces.UDPInterface[0].connectTo[$addr] = $peer' \
    "$CONFIG" > "${CONFIG}.tmp"

# Validate JSON
if jq empty "${CONFIG}.tmp" 2>/dev/null; then
    echo -e "${GREEN}✓ JSON validation passed${NC}"
    mv "${CONFIG}.tmp" "$CONFIG"
else
    echo -e "${RED}✗ JSON validation failed! Config NOT modified.${NC}"
    echo -e "${YELLOW}Restoring from backup...${NC}"
    cp "$BACKUP_FILE" "$CONFIG"
    rm -f "${CONFIG}.tmp"
    exit 1
fi

# Show new peer count
NEW_IPV4_PEERS=$(jq '.interfaces.UDPInterface[0].connectTo | length' "$CONFIG")
echo -e "${GREEN}✓ Peer added successfully${NC}"
echo
echo "IPv4 peers: $CURRENT_IPV4_PEERS → $NEW_IPV4_PEERS"
echo

# Verify IPv6 interface unchanged
IPV6_PEERS=$(jq '.interfaces.UDPInterface[1].connectTo | length' "$CONFIG")
if [ "$IPV6_PEERS" = "1" ]; then
    echo -e "${GREEN}✓ IPv6 interface unchanged (still 1 peer)${NC}"
else
    echo -e "${RED}✗ WARNING: IPv6 interface was modified!${NC}"
    echo -e "${YELLOW}Restoring from backup...${NC}"
    cp "$BACKUP_FILE" "$CONFIG"
    exit 1
fi

echo
echo "======================================"
echo -e "${GREEN}SUCCESS!${NC}"
echo "======================================"
echo
echo "To apply changes, restart cjdroute:"
echo "  sudo systemctl restart cjdroute-51888"
echo
echo "To revert changes:"
echo "  sudo cp $BACKUP_FILE $CONFIG"
echo "  sudo systemctl restart cjdroute-51888"
echo

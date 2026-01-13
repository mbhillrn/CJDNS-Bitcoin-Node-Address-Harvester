#!/usr/bin/env bash
set -u

sudo apt-get update
sudo apt-get install -y \
  sqlite3 \
  jq \
  curl \
  openssh-client \
  iputils-ping

echo
echo "Installed base deps."
echo "You still need:"
echo "  - bitcoin-cli (Bitcoin Core)"
echo "  - cjdnstool + cjdns with admin enabled"

# CJDNS Bitcoin Core Address Harvester

Harvests **cjdns (fc00::)** Bitcoin Core peers by scraping CJDNS NodeStore and other cjdnstool expansions for Bitcoin Core peer discovery, then probing candidates via `bitcoin-cli addnode onetry`. Confirmed nodes and history are tracked in a local SQLite database.

---

## Purpose
This project exists to discover **Bitcoin Core nodes reachable over CJDNS (fc00::)** by:
- Scraping CJDNS NodeStore
- Expanding via cjdns peer information
- Probing candidates with Bitcoin Core itself
- CJDNS SEED ADDRESS TEXT FILE: ./cjdns-bitcoin-seed-list.txt contains all known addresses as of 1/13/2026. 
 - This file is unlikely to be updated, however, state.db will likely be updated every once in a while with new addresses if found.

---

## PREP / WARNINGS

**This tool writes runtime state directly into the project directory.**

Runtime files include:
- **`state.db`** – SQLite database of *all discovered fc addresses, DELETE if you want a FRESH DATABASE, and NOT MY HARVESTED ADDRESSES*
  - **THIS FILE IS INCLUDED IN THE REPO - AND MAY BE UPDATED AS TIME GOES ON**
  - It contains every fc address I have discovered, plus which ones are confirmed Bitcoin nodes. If you leave it in, it will gradually test all the addresses I have harvested with addnode, onetry.
  - You may delete it to start fresh; the program will recreate it automatically
- **`harvest.local.conf`** – Local runtime configuration. Created automatically when program is run.

Dependency installation and notes:
- Run or review: `./scripts/install_deps_ubuntu.sh`
- Linux (tested on Ubuntu)
---

## Features
- Harvest cjdns IPv6 candidates from:
  - Local CJDNS NodeStore
  - Remote NodeStore on other LAN machines (SSH)
  - Optional **Frontier Expansion** (PeerInfo → getPeers)
- Probe candidates using Bitcoin Core (`addnode onetry`)
- Persistent tracking in `state.db`:
  - **Master** list (all candidates)
  - **Confirmed** list (verified Bitcoin Core nodes)
  - Attempt history, cooldowns, and discovery source
- **Smart Mode** loop scheduling with periodic rechecks

---

## Requirements
- Linux
- Bitcoin Core (`bitcoin-cli`)
- `sqlite3`
- `jq`
- `curl`
- `ssh` client (for remote NodeStore harvesting)
- CJDNS with admin enabled

> This project expects `cjdnstool` to be installed and able to communicate with your CJDNS admin socket/port. Detection is automatic in most cases.

---

## Database Notes (`./state.db`)
- I included the database I have harvested in this repo. If you wish to start new, just delete or rename the state.db out of your project folder. 
- If you decide to leave it in, you can onetry all of the confirmed list via options, or with smart mode automatically just by letting it run for some time. 

The database stores **all discovered cjdns fc00 addresses**, sourced from:
- CJDNS NodeStore
- Bitcoin Core peer data
- Frontier expansion scans

Tracked lists:
- **Master** – every fc address discovered
- **Confirmed** – fc addresses verified to host Bitcoin Core nodes

Additional metadata includes:
- Discovery source
- Attempt counts and failures
- Timing data used by Smart Mode retry logic

---

## Running the Harvester

From inside the project directory:

```bash
./harvest.sh --run
```

The script will attempt to auto-detect:
- `bitcoin-cli` location
- Bitcoin Core datadir
- `bitcoin.conf`
- CJDNS admin IP/port (usually `127.0.0.1:11234`)

You will be prompted to confirm or override detected values.

---

## Smart Mode (Recommended)

Smart Mode automates harvesting with minimal configuration and safe pacing.

You will be prompted for:
- **Seconds between SMART scans**
- **Enable Frontier Expansion**
  - If enabled, how often it should run (every N scans)
- **Harvest remote NodeStore** (advanced)

### NodeStore Requirements

**Remote NodeStore harvesting WILL NOT WORK unless:**
- SSH is enabled on the remote machine(s)
- Passwordless SSH via secure keys is configured
- The same username exists on all target machines
- The user has sufficient privileges

You will be asked for:
- Host/IP (single or comma-separated)
  - Example: `192.168.0.4` or `192.168.0.4,192.168.0.5`

Preflight checks will validate admin access, compatibility, and required tools.

---

## Manual Mode (Advanced)

If Smart Mode is disabled, additional controls are exposed:

- Seconds between scans
- Enable Frontier Expansion
- Harvest remote NodeStore
- **Retry master list every N scans**
  - Retries *entire* master list via `addnode onetry`
  - Can be time-consuming on large databases
  - Recommended values: `50–100`, `0` disables
- **Recheck confirmed list every N scans**
  - Attempts reconnection to all confirmed nodes
- Seconds between `onetry` attempts
- Grace period after `onetry` batches
- **Enable informational ping** (optional)
  - Improves NodeStore freshness in practice
- Ping timeout (if ping enabled)

---

## License

MIT


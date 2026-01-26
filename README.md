# CJDNS Bitcoin Core Address Harvester

**Find Bitcoin nodes on the CJDNS mesh network (fc00:: addresses)**

---

## Support This Project

If you find this tool useful, support is appreciated:

**Bitcoin:** `bc1qy63057zemrskq0n02avq9egce4cpuuenm5ztf5`

---

## What Is This?

This is a tool developed to discover Bitcoin Core nodes running on CJDNS. It works by:

1. Scanning your local CJDNS NodeStore for addresses
2. Using "frontier expansion" to discover more nodes through peers
3. Testing each address to see if it's running Bitcoin Core
4. Keeping track of everything in a local database

This project focuses on practical discovery and tracking of Bitcoin nodes reachable over CJDNS networking. 

---

## Why Would I Want This?

If you're running Bitcoin Core over CJDNS, you probably want to find other nodes to connect to as Core seems to prefer ipv4, ipv6, TOR, or i2p. This tool automates that cjdns discovery process and maintains a database of known nodes so you don't have to manually hunt and add.

The included seed database (`lib/seeddb.db`) contains confirmed Bitcoin nodes and other discovered CJDNS addresses that you can optionally use as a starter database. I'm currently updating that seedlist frequently, and there is an option within the program to update your database with newly found addresses uploaded to the repo.

---

## Quick Start

**Requirements (the program validates prereqs prior to running):**
- Linux (tested on Ubuntu)
- Bitcoin Core with CJDNS support (tested on v30)
- CJDNS running with admin interface enabled
- `cjdnstool` installed (`npm install -g cjdnstool`)
- Standard tools: `jq`, `sqlite3`, `bash`

**Install dependencies:**
```bash
./scripts/install_deps_ubuntu.sh
```

**Run the harvester:**
```bash
./harvest.v5.sh
```

### First Run Setup

On first run, the script will:
1. Auto-detect your Bitcoin Core and CJDNS settings
2. Check if you have a database (`state.db`)
3. If no database exists, offer you seeding options:
   - **Option 1 (RECOMMENDED):** Seed confirmed Bitcoin nodes + connect via onetry
   - **Option 2:** Seed confirmed Bitcoin nodes only
   - **Option 3:** Continue with blank database
   - **Option 4 (Advanced):** Seed complete database (all addresses, not just Bitcoin nodes)

**For first-time users:** Choose option 1. This will:
- Copy confirmed Bitcoin node addresses from `lib/seeddb.db`
- Immediately attempt to connect to them via Bitcoin Core
- Get you connected to known nodes fastest

**Why not option 4 by default?** The complete database includes hundreds of CJDNS addresses that may never run Bitcoin nodes. This can make some operations time-consuming. Option 4 is mainly useful if you're harvesting CJDNS addresses for other purposes. Who knows, you may get lucky and have had someone who just installed Core over CJDNS. 

### Main Menu Options

After setup, you'll see the main menu with 9 options:

1. **Run Harvester** - Discover and test new addresses (local + optional remote). Can single run, or in a loop. Recommend letting the loop run for a while when getting started.
2. **Connect to confirmed nodes** - Attempt connection to all known Bitcoin nodes from database.
3. **Connect to all addresses** - Exhaustive connection test. Attempts the bitcoin node addresses, as well as all the other cjdns addresses in the database who were not seen with Core nodes attached. 
4. **Database Updater** - Check project's GitHub Repo for updated confirmed nodes and add them to your database
5. **Export database to txt** - Creates `cjdns-bitcoin-seed-list.txt`
6. **Backup database** - Create timestamped backup in `bak/` directory
7. **Restore from backup** - Restore database from previous backup
8. **Delete backups** - Manage backup files
9. **Delete database** - Reset and reseed from scratch

---

## Features

### Version 5 (Current)
- **9-option menu** - Harvesting, connection testing, database management, database updates
- **First-run wizard** - Seed from included confirmed nodes or start fresh
- **Automatic everything** - Detects your Bitcoin/CJDNS setup automatically
- **Local harvesting** - Scans your NodeStore and frontier peers
- **Remote harvesting** - Can scan other CJDNS machines on your LAN (experimental!)
- **Smart testing** - Only tests NEW addresses each run, doesn't re-test known ones
- **Connection tracking** - Shows connected peers at start/end of each run
- **Run summary** - Clear stats showing what was discovered and confirmed
- **Database backup/restore** - Timestamped backups with easy restoration
- **Export to txt** - Generate seed list file from your database
- **Clean interface** - Pretty colors, progress bars, animated indicators
- **Database tracking** - Remembers all addresses and which ones have Bitcoin nodes

### Remote Harvesting (Experimental!)
This feature allows scanning other CJDNS-enabled machines on your LAN via SSH. The setup wizard is simple and assists with SSH key configuration.

---

## The Database

### Database Files

- **`state.db`** - Your active database (created automatically, gitignored)
- **`lib/seeddb.db`** - Included seed database with confirmed nodes and discovered addresses
- **`bak/state_*.db`** - Timestamped backup files (created via Option 6)

### Database Tables

The database has two main tables:

- **Master list** (`master.host`) - Every fc00 address discovered
  - Includes ALL addresses found via any harvesting method

- **Confirmed list** (`confirmed.host`) - Addresses that successfully connected to a Bitcoin Core node
  - Only includes addresses running Bitcoin Core

When the harvester runs, it only tests NEW addresses. To test bitcoin core connectivity to the master or confirmed, use selection 2 or 3 from the main menu separately.

### Address Format

All CJDNS addresses in the database are stored in **full expanded IPv6 format**, not shortened/compressed format. For example:
- Full format: `fc00:0000:0000:0000:0000:0000:0000:0001`
- Compressed format: `fc00::1` (NOT used)

This prevents duplicate entries when the same address is discovered in different formats. If you manually add addresses to the database, make sure to use the full expanded format to avoid issues.

### Seed Database Options

On first run (or after deleting `state.db`), you can choose how to initialize your database:

1. **Confirmed nodes only (Recommended)** - ~27 addresses with Bitcoin nodes
   - Fast initial connection
   - Clean database with only useful addresses
   - Best for most users

2. **Complete database** - Hundreds of CJDNS addresses
   - Includes all discovered addresses (not just Bitcoin nodes)
   - Useful if harvesting CJDNS addresses for other purposes
   - Makes some operations slower due to database size

### Note About CJDNS and Bitcoin Addrman

CJDNS addresses may not be as attractive to Bitcoin's addrman (address manager) when other protocols like IPv4, IPv6, or Tor are also available. Bitcoin Core tends to prefer more established networks for peer diversity. The harvester helps overcome this by actively discovering and connecting to CJDNS-specific nodes.

---

## How It Works

### Discovery Sources

1. **NodeStore** - Your local CJDNS routing table
2. **Frontier Expansion** - Queries direct peers
3. **Bitcoin Addrman** - Addresses Bitcoin Core already knows about
4. **Connected Peers** - Any address Core is currently connected to
5. **Remote NodeStore** - Same as #1 but on other LAN machines (if configured)
6. **Remote Frontier** - Same as #2 but on other LAN machines (if configured)

### Testing Process

Addresses are tested using Bitcoin Core's `addnode <address> onetry` command. getpeerinfo is later used to determine if a peer has been found.

---

## Configuration

The harvester detects settings, and asks you a few questions on first run:

1. **Bitcoin Core location** - Usually auto-detected
2. **CJDNS admin settings** - Usually auto-detected (127.0.0.1:11234)
3. **Run mode** - Once (single pass) or Continuous (loop forever)
4. **Scan interval** - How many seconds between loops (default: 60)
5. **Remote harvesting** - Do you want to scan other machines? (optional)

---

## Database Multi-Tool

The `db-multitool.sh` script is a standalone utility for merging databases from multiple machines.

**Run it:**
```bash
./db-multitool.sh
```

**Features:**
- Interactively collect remote machine credentials (IP, DB path, user, password)
- Fetch remote `state.db` files via SSH/SCP
- Automatically backup local database before merging
- Analyze and show what's unique across all databases
- Merge unique addresses into your local database
- Optionally push the merged database back to all remote machines

**Requirements:**
- `sshpass` - for password-based SCP (`sudo apt-get install sshpass`)
- `sqlite3` - for database operations

This is useful if you're running the harvester on multiple machines and want to consolidate all discovered addresses into one master database.

---

## Files

```
harvest.v5.sh           # Main script (run this!)
db-multitool.sh         # Database merge utility (standalone)
state.db                # Your active database (auto-created, gitignored)
lib/
  ├── seeddb.db        # Seed database with confirmed nodes (can be updated from main menu)
  └── v5/              # Version 5 modules
      ├── ui.sh        # Pretty colors and formatting
      ├── db.sh        # Database operations
      ├── detect.sh    # Auto-detect Bitcoin/CJDNS
      ├── harvest.sh   # All harvesting functions
      ├── onetry.sh    # Testing logic
      ├── display.sh   # Status displays
      ├── frontier.sh  # Frontier expansion
      ├── remote.sh    # Remote host SSH setup
      └── utils.sh     # Helper functions (IPv6 normalization)
bak/                    # Database backups (created by Option 6)
  └── state_*.db       # Timestamped backup files
scripts/
  └── install_deps_ubuntu.sh  # Dependency installer
cjdns-bitcoin-seed-list.txt  # Exported address list (created by Option 5)
```

---

## Troubleshooting

**"cjdnstool: command not found"**
```bash
npm install -g cjdnstool
```

**"sqlite3: command not found"**
```bash
sudo apt-get install sqlite3
```

**Remote harvesting isn't working**
- Make sure SSH is enabled on the remote machine
- The setup wizard will walk you through configuring SSH keys
- Can test manually with: `ssh user@remotehost cjdnstool -a 127.0.0.1 -p 11234 -P NONE cexec Core_nodeInfo`

**No addresses being discovered**
- Check that CJDNS is actually running: `cjdnstool -a 127.0.0.1 -p 11234 -P NONE cexec Core_nodeInfo`
- Make sure you have some CJDNS peers connected
- Frontier expansion won't work if you don't have the ReachabilityCollector module enabled

---

## Version History

### v5.1 (January 2026) - Database Management & UX Polish
- Added Database Updater: Check GitHub for newly confirmed nodes (Option 4)
- Added first-run database wizard with seeding options
- Database backup/restore functionality (Options 6, 7, 8)
- Export database to txt file (Option 5)
- Connection tracking shows peers at start/end of runs
- Run summary with clear statistics
- Animated progress indicators
- Improved color coding (green for recommended, red for advanced)
- Delete database now returns to setup wizard
- Seed database (lib/seeddb.db) included for easy first-time setup
- state.db now gitignored (user-specific)

### v5.0 (January 2026) - Complete Rewrite
- Simplified from ~3,800 lines to ~1,500 lines
- Removed confusing Smart/Manual mode distinction
- Much prettier interface with colors and progress indicators
- Better error handling and user feedback
- Added remote frontier expansion
- Fixed logic bugs around address re-testing
- Everything just works now

### v4.0 (December 2025)
- Original version with Smart/Manual modes
- Worked but was unnecessarily complex
- Kept re-testing addresses that were already known
- Interface was functional but ugly

---

## Contributing

This is a hobby project but I'm happy to accept pull requests! Feel free to:

- Please post any questions, issues, reports, found addresses in [GitHub Discussions](https://github.com/mbhillrn/CJDNS-Bitcoin-Node-Address-Harvester/discussions)!

- Or, just open an issue or PR on GitHub.

---

## Credits

- Maintained by the project author.

---

## License

MIT

---

## Support Development

**Bitcoin:** `bc1qy63057zemrskq0n02avq9egce4cpuuenm5ztf5`

I'll keep updating the database as I find more addresses.

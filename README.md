# CJDNS Bitcoin Core Address Harvester

**Find Bitcoin nodes on the CJDNS mesh network (fc00:: addresses)**

---

## Support This Project

If you find this tool useful, please consider donating:

**Bitcoin:** `bc1qy63057zemrskq0n02avq9egce4cpuuenm5ztf5`

Any amount is appreciated!

---

## What Is This?

This is a tool I built over a couple months to discover Bitcoin Core nodes running on CJDNS (the mesh network using fc00:: IPv6 addresses). It works by:

1. Scanning your local CJDNS NodeStore for addresses
2. Using "frontier expansion" to discover more nodes through your peers
3. Testing each address to see if it's running Bitcoin Core
4. Keeping track of everything in a local database

I wrote this mostly as a hobby project to learn more about CJDNS and Bitcoin networking. Got a lot of help from AI to make the interface look nice and handle edge cases properly.

---

## Why Would I Want This?

If you're running Bitcoin Core over CJDNS, you probably want to find other nodes to connect to. This tool automates that discovery process and maintains a database of known nodes so you don't have to manually hunt for peers.

The included `state.db` database has many addresses I've discovered and update somewhat regularly. You can use it as-is or start fresh.

---

## Quick Start

**Requirements:**
- Linux (tested on Ubuntu)
- Bitcoin Core with CJDNS support
- CJDNS running with admin interface enabled
- `cjdnstool` installed (`npm install -g cjdnstool`)
- Standard tools: `jq`, `sqlite3`, `bash`

**Install dependencies (Ubuntu):**
```bash
./scripts/install_deps_ubuntu.sh
```

**Run the harvester:**
```bash
./harvest.v5.sh
```

The script will auto-detect your Bitcoin Core and CJDNS settings, then present you with three options:

1. **Run harvester** - Continuously discover and test new addresses
2. **Onetry master list** - Test all discovered addresses
3. **Onetry confirmed list** - Reconnect to known Bitcoin nodes

**First-time users:** Start with option 3 to quickly connect your Bitcoin node to the confirmed CJDNS addresses in the database. This gets you connected to known nodes right away. After that, you can run option 1 to continuously discover new addresses.

---

## Features

### Version 5 (Current)
- **Simple 3-option menu** - No confusing modes, just pick what you want to do
- **Automatic everything** - Detects your Bitcoin/CJDNS setup automatically
- **Local harvesting** - Scans your NodeStore and frontier peers
- **Remote harvesting** - Can scan other CJDNS machines on your LAN (experimental!)
- **Smart testing** - Only tests NEW addresses each run, doesn't re-test known ones
- **Clean interface** - Pretty colors, progress bars, actual useful information
- **Database tracking** - Remembers all addresses and which ones have Bitcoin nodes

### Remote Harvesting (Experimental!)
If you have other machines on your network running CJDNS, you can scan their NodeStores AND run frontier expansion on them too. The setup wizard will walk you through configuring SSH keys for automatic login.

This is pretty niche (who has multiple CJDNS nodes on their LAN?) but it works great if you do!

---

## The Database (`state.db`)

The included database has addresses I've been collecting and update somewhat regularly. You can:

- **Use it as-is** - Already has many confirmed Bitcoin nodes
- **Start fresh** - Just delete or rename `state.db` and it'll create a new one

The database has two main lists:

- **Master list** - Every fc00:: address ever discovered
- **Confirmed list** - Addresses that successfully connected (running Bitcoin Core)

When the harvester runs, it only tests NEW addresses it hasn't seen before. Addresses that are already in the master list don't get tested again (unless you explicitly choose option 2 or 3 from the menu).

---

## How It Works

### Discovery Sources

1. **NodeStore** - Your local CJDNS routing table
2. **Frontier Expansion** - Queries your direct peers for THEIR peers (2-hop discovery)
3. **Bitcoin Addrman** - Addresses Bitcoin Core already knows about
4. **Connected Peers** - Any address you're currently connected to
5. **Remote NodeStore** - Same as #1 but on other machines (if configured)
6. **Remote Frontier** - Same as #2 but on other machines (if configured)

### Testing Process

After discovering addresses, the harvester uses Bitcoin Core's `addnode <address> onetry` command to test each one. If it connects successfully, that address gets added to the confirmed list.

There's a 10-second wait after testing to let connections establish, then it checks `getpeerinfo` to see what actually connected.

---

## Configuration

The harvester asks you a few questions on first run:

1. **Bitcoin Core location** - Usually auto-detected
2. **CJDNS admin settings** - Usually auto-detected (127.0.0.1:11234)
3. **Run mode** - Once (single pass) or Continuous (loop forever)
4. **Scan interval** - How many seconds between loops (default: 60)
5. **Remote harvesting** - Do you want to scan other machines? (optional)

All settings are saved in `harvest.local.conf` so you don't have to re-enter them every time.

---

## Files in This Repo

```
harvest.v5.sh           # Main script (run this!)
state.db                # Address database (included)
lib/v5/                 # Version 5 modules
  ├── ui.sh            # Pretty colors and formatting
  ├── db.sh            # Database operations
  ├── detect.sh        # Auto-detect Bitcoin/CJDNS
  ├── harvest.sh       # All harvesting functions
  ├── onetry.sh        # Testing logic
  ├── display.sh       # Status displays
  ├── frontier.sh      # Frontier expansion
  ├── remote.sh        # Remote host SSH setup
  └── utils.sh         # Helper functions
scripts/
  ├── canon_host.sh    # IPv6 normalization
  └── install_deps_ubuntu.sh  # Dependency installer
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
- Test manually first: `ssh user@remotehost cjdnstool -a 127.0.0.1 -p 11234 -P NONE cexec Core_nodeInfo`

**No addresses being discovered**
- Check that CJDNS is actually running: `cjdnstool -a 127.0.0.1 -p 11234 -P NONE cexec Core_nodeInfo`
- Make sure you have some CJDNS peers connected
- Frontier expansion won't work if you don't have the ReachabilityCollector module enabled

---

## Version History

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

- Report bugs
- Suggest features
- Fix my terrible code
- Improve the documentation

Just open an issue or PR on GitHub.

---

## Credits

Written by mbhillrn over a couple months of spare time. Got tons of help from AI for:
- Making the interface not look like trash
- Fixing logic bugs I couldn't figure out
- Adding all the pretty colors and progress bars
- Generally making it professional-looking

The core idea and Bitcoin/CJDNS integration is all mine though!

---

## License

MIT - Do whatever you want with this

---

## Support Development

If this tool helped you discover Bitcoin nodes or you just think it's cool:

**Bitcoin:** `bc1qy63057zemrskq0n02avq9egce4cpuuenm5ztf5`

I'll keep updating the database as I find more addresses. Any amount is appreciated!

Thanks for using my harvester!

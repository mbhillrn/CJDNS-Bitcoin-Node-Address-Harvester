# Library Modules

Code modules used by the CJDNS Bitcoin Core harvester.

## Version 5 (Current)

All v5 modules are in `lib/v5/`:

- **ui.sh** - UI formatting, colors, progress indicators, box drawing
- **db.sh** - SQLite database operations (master/confirmed lists)
- **detect.sh** - Auto-detection of Bitcoin Core and CJDNS settings
- **harvest.sh** - All harvesting functions (nodestore, frontier, remote, etc.)
- **onetry.sh** - Bitcoin Core connection testing logic
- **display.sh** - Status displays (router info, peer lists, etc.)
- **frontier.sh** - Frontier expansion (getPeerInfo → getPeers → key2ip6)
- **remote.sh** - Remote host SSH configuration and file upload
- **utils.sh** - Helper functions (canon_host for IPv6 normalization)

## Version 4 (Legacy)

Old v4 code is in `lib/harvest/` - kept for reference but not actively used.

---

**Support this project:** `bc1qy63057zemrskq0n02avq9egce4cpuuenm5ztf5`

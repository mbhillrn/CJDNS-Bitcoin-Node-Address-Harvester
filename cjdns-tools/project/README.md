# CJDNS Peer Manager

An interactive, portable tool for managing CJDNS peers. Automatically detects your cjdns installation, discovers new peers from multiple sources, tests connectivity, and safely adds peers to your configuration.

## Features

- **Auto-Detection**: Automatically finds your cjdns config file and running service
- **Smart Fallbacks**: If auto-detection fails, provides manual selection options
- **Multi-Source Discovery**: Fetches peers from GitHub repositories and other sources
- **Connectivity Testing**: Tests peers before adding them to your config
- **Safe Config Modification**: Creates backups before making any changes, validates JSON
- **Field Preservation**: Preserves all peer fields exactly as they appear in sources (no synthetic fields)
- **Portable**: Uses relative paths - works anywhere you place it
- **Interactive**: User-friendly menus with y/n validation

## Requirements

This tool requires the following to be installed on your system:

```bash
sudo apt-get install jq git wget
```

You also need **cjdnstool** to communicate with your cjdns instance:
- https://github.com/furetosan/cjdnstool

## Usage

### Running the Tool

```bash
cd cjdns-tools/project
sudo ./cjdns-manager.sh
```

**Note**: `sudo` is required because the tool needs to:
- Read/write cjdns config files (typically in `/etc`)
- Restart the cjdns service
- Query cjdns via cjdnstool

### First Run

On first run, the tool will:

1. **Check for required tools** (jq, git, wget, cjdnstool)
2. **Auto-detect your cjdns installation**:
   - Scans running systemd services for cjdns
   - Extracts config file location from service
   - Falls back to listing `/etc/cjdroute_*.conf` files if needed
3. **Ask for confirmation** on detected config and service
4. **Extract admin connection info** from your config
5. **Test connection** to cjdns to ensure it's working

If auto-detection fails or finds multiple configs, you'll be asked to select or manually specify the correct one.

### Main Menu Options

```
1) View current peer status
   - Shows ESTABLISHED vs UNRESPONSIVE peers
   - Connects to cjdns via admin interface

2) Discover new peers from online sources
   - Fetches from GitHub: hyperboria/peers, yangm97/peers, cwinfo/hyperboria-peers
   - Tries kaotisk-hund/python-cjdns-peering-tools
   - Filters out peers already in your config
   - Shows samples of discovered peers

3) Test peer connectivity
   - Pings discovered peers to check if they're online
   - Separates active vs unreachable peers
   - Required before adding peers

4) Add new peers to config
   - Adds tested active peers to your config
   - Creates backup before modification
   - Validates JSON before writing
   - Preserves all fields exactly as they appear in sources
   - Offers to restart cjdns service

5) Remove unresponsive peers
   - Lists peers with UNRESPONSIVE state
   - Removes them from config (IPv4 only by default)
   - Creates backup before modification

6) Restart cjdns service
   - Restarts your detected cjdns service
   - Verifies it's responding after restart

0) Exit
```

## Workflow

Typical workflow for adding new peers:

1. Run the tool: `sudo ./cjdns-manager.sh`
2. Select **option 2** to discover peers
3. Select **option 3** to test connectivity
4. Select **option 4** to add active peers
5. Choose whether to restart cjdns service

## Portability

This tool is designed to be portable. All paths are relative to the script directory.

To move the tool from `cjdns-tools/project/` to `cjdns-tools/`:

```bash
cd cjdns-tools
mv project/* .
rmdir project
```

Everything will continue to work as long as the directory structure is preserved:

```
cjdns-tools/
├── cjdns-manager.sh
├── lib/
│   ├── detect.sh
│   ├── ui.sh
│   ├── peers.sh
│   └── config.sh
└── README.md
```

## How Detection Works

### Config File Detection

1. **Smart Detection**: Scans systemd services for `cjd*` pattern
2. **Service Analysis**: Reads service files and status to find config path
3. **Pattern Matching**: Looks for `/etc/cjdroute_NNNN.conf` pattern
4. **Fallback**: Lists all matching files in `/etc` if needed
5. **Manual Override**: Allows you to specify custom path if all else fails

### Admin Connection

Extracts from your config:
```json
"admin": {
  "bind": "127.0.0.1:11234",
  "password": "NONE"
}
```

Uses this info for all cjdnstool communication.

## Safety Features

- **Always creates backups** before modifying config
- **Validates JSON** after every modification
- **Asks for confirmation** before making changes
- **Preserves exact field structure** from peer sources
- **Never overwrites** without validation
- **Graceful error messages** explaining what went wrong

## Testing

The tool has been tested with:
- cjdnstool (modern Rust-based version)
- Multiple cjdns config formats (IPv4, IPv6, dual-stack)
- Various systemd service naming schemes

## Troubleshooting

### "cjdnstool not found"

Install cjdnstool from: https://github.com/furetosan/cjdnstool

### "Cannot connect to cjdns admin interface"

Make sure cjdns is running:
```bash
sudo systemctl status cjdroute
# or
sudo systemctl status cjdroute-NNNN
```

### "Config validation failed"

The tool detected invalid JSON. Your original config is safe (not modified).
Check the backup file location shown in the error message.

### "Failed to clone repository"

Check your internet connection. Some sources may be temporarily down.
The tool will continue with sources that work.

## License

This tool is provided as-is for managing CJDNS peer connections.

## Contributing

This tool is part of the CJDNS-Bitcoin-Node-Address-Harvester project.

# lib/harvest (Version 4 - Legacy)

**Note:** This is the old v4 code. It's kept for reference but not actively used.

**For current code, see `lib/v5/`** which has the rewritten, simplified version.

## What This Was

Original harvester modules for v4 that handled:
- NodeStore ingestion (local and remote)
- Frontier expansion
- Bitcoin Core peer discovery
- `addnode onetry` dispatch and tracking
- Batch confirmation via peer snapshots
- Host parsing and IPv6 canonicalization

## Why It Was Replaced

Version 4 worked but was:
- Too complex (~3,800 lines of code)
- Had confusing Smart/Manual modes
- Re-tested addresses that were already known
- Hard to maintain and debug

Version 5 simplified everything down to ~1,500 lines with a much cleaner interface.

---

**Support this project:** `bc1qy63057zemrskq0n02avq9egce4cpuuenm5ztf5`

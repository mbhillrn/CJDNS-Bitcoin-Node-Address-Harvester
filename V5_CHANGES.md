# CJDNS Harvester v5 - Changes Summary

## Overview
Complete rewrite of the harvester with ~60% code reduction while preserving all essential functionality. Focus on simplicity, clarity, and improved user experience.

## What Changed

### 1. **Simplified Menu Structure** (3 options instead of Smart/Manual modes)
```
1) Run harvester (continuous discovery)
2) Onetry master list (all discovered addresses)
3) Onetry confirmed list (addresses with known Bitcoin nodes)
```

### 2. **Removed Complexity**
- ❌ Smart Mode vs Manual Mode distinction
- ❌ Informational ping (doesn't affect routing)
- ❌ Complex wizard with excessive prompts
- ❌ Retry/recheck master during harvest loops (moved to menu option 2)
- ❌ Inline timing configuration prompts

### 3. **Improved User Interface**
- ✅ Consistent color scheme throughout
- ✅ Better visual hierarchy with boxes and sections
- ✅ Progress indicators for long operations
- ✅ Clear status messages (✓ ⚠ ✗ ℹ)
- ✅ Prettier database statistics display
- ✅ Enhanced frontier expansion feedback
- ✅ Consolidated NodeStore display (highlight NEW addresses)
- ✅ Cleaner CJDNS router display (established peers only)
- ✅ Better Bitcoin Core peers display (unique count + IN/OUT marking)

### 4. **Hardcoded Sensible Defaults**
- Default scan interval: 60 seconds (configurable at runtime)
- Grace period after onetry: 5 seconds (fixed)
- Frontier expansion: Always enabled (if tools available)

### 5. **Detection & Preflight**
All checks run **BEFORE** main menu:
1. Bitcoin Core detection with confirmation
2. CJDNS detection with confirmation
3. Preflight checks (connectivity, frontier capability)

### 6. **Preserved Essential Functionality**
- ✅ Address normalization via `canon_host()` (IPv6 explosion)
- ✅ Addrman harvesting (`getnodeaddresses`)
- ✅ Auto-add connected peers to confirmed
- ✅ NodeStore harvesting
- ✅ Frontier expansion (unchanged from v4)
- ✅ Remote NodeStore via SSH
- ✅ Database schema (unchanged)
- ✅ Graceful shutdown (Ctrl+C handling)

## File Structure

### New v5 Files
```
harvest.v5.sh              # Main entry point (new)
lib/v5/
  ui.sh                    # UI functions and colors (new)
  db.sh                    # Database functions (simplified)
  detect.sh                # Detection and verification (simplified)
  harvest.sh               # Harvesting orchestration (new)
  onetry.sh                # Onetry execution (new)
  display.sh               # Status display functions (new)
  frontier.sh              # Frontier expansion (copied unchanged from v4)
  utils.sh                 # canon_host function (copied from scripts/)
```

### Preserved v4 Files
All original v4 files remain intact in:
- `harvest.sh` (original)
- `lib/` (original v4 modules)
- `scripts/` (original scripts)

## Code Size Reduction

| Component | v4 Lines | v5 Lines | Reduction |
|-----------|----------|----------|-----------|
| UI/Colors | 803 | 200 | 75% |
| Detection | 460 | 300 | 35% |
| Wizard | 715 | 0 | 100% |
| Harvesting | 657 | 250 | 62% |
| Onetry | 605 | 150 | 75% |
| Display | (mixed) | 150 | N/A |
| Main | 234 | 180 | 23% |
| **Total** | **~3,800** | **~1,500** | **61%** |

## Migration Guide

### Running v5
```bash
# Run v5 (new)
./harvest.v5.sh

# Run v4 (original - still available)
./harvest.sh --run
```

### Restoring to v4
If v5 doesn't work as expected:

```bash
# Option 1: Reset to v4-stable tag
git reset --hard v4-stable

# Option 2: Keep v5 work but switch to v4
git checkout -b v5-attempt  # Save v5 work
git checkout v4-stable
```

## Testing Checklist

- [ ] Bitcoin Core detection works
- [ ] CJDNS detection works
- [ ] Preflight checks pass
- [ ] Menu displays correctly
- [ ] Option 1: Harvester mode (continuous)
  - [ ] NodeStore harvesting
  - [ ] Frontier expansion
  - [ ] Addrman harvesting
  - [ ] Remote NodeStore (if configured)
  - [ ] Onetry new addresses
  - [ ] Loop with configurable interval
- [ ] Option 2: Onetry master list
- [ ] Option 3: Onetry confirmed list
- [ ] Graceful shutdown (Ctrl+C)
- [ ] Database operations (master, confirmed tables)
- [ ] Address normalization (IPv6 explosion)

## Known Issues / TODO

- [ ] User testing required
- [ ] Documentation update needed
- [ ] Consider renaming harvest.v5.sh → harvest.sh after validation

## Feedback

Please test and report:
- What works well
- What's broken
- What's confusing
- What could be better

---

**v4-stable restore point created:** Tag `v4-stable` at commit 2f28955

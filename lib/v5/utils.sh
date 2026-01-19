#!/usr/bin/env bash
# canon_host: normalize IPv4/IPv6/host strings for consistent comparisons.
canon_host() {
  local raw="${1:-}"
  [[ -n "$raw" ]] || { echo ""; return 0; }
  python3 - "$raw" 2>/dev/null <<'PY'
import ipaddress, sys
h=(sys.argv[1] or "").strip().lower()
# Strip [addr]:port safely
if h.startswith('['):
    h=h[1:]
if ']' in h:
    h=h.split(']')[0]
try:
    ip=ipaddress.ip_address(h)
    print(ip.exploded if ip.version==6 else str(ip))
except Exception:
    print(h)
PY
}

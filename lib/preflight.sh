# ------------------------------------------------------------------------
# run_cmd_capture TAG CMD...
# Captures stdout+stderr of CMD, optionally logs via dbg(), echoes output,
# and returns CMD's exit code.
#
# Usage patterns in this repo:
#   out="$(run_cmd_capture "tag" bash -lc "$CLI getpeerinfo")"
#   run_cmd_capture "tag" sqlite3 "$DB_PATH" "SELECT 1;" >/dev/null
# ------------------------------------------------------------------------
run_cmd_capture() {
  local tag="$1"; shift || true
  local out rc

  if [[ $# -eq 0 ]]; then
    echo ""
    return 0
  fi

  # Execute: if caller passed multiple args, run directly (preserves quoting).
  # If caller passed a single string, run via bash -lc to support pipes/redirs.
  if [[ $# -eq 1 ]]; then
    out="$(bash -lc "$1" 2>&1)"; rc=$?
  else
    out="$("$@" 2>&1)"; rc=$?
  fi

  # Optional debug hook (dbg may be a no-op, which is fine)
  if declare -F dbg >/dev/null 2>&1; then
    dbg "run_cmd_capture tag=$tag rc=$rc bytes=${#out}"
  fi

  echo "$out"
  return $rc
}



# ------------------------------------------------------------------------
# run_cmd_capture_json TAG CMD...
# Captures ONLY stdout of CMD (so jq won't choke), streams stderr to >&2.
# Echoes stdout, returns CMD's exit code.
# ------------------------------------------------------------------------
run_cmd_capture_json() {
  local tag="$1"; shift || true
  local out rc

  if [[ $# -eq 0 ]]; then
    echo ""
    return 0
  fi

  if [[ $# -eq 1 ]]; then
    out="$(bash -lc "$1" 2> >(sed "s/^/[${tag}] /" >&2))"; rc=$?
  else
    out="$("$@" 2> >(sed "s/^/[${tag}] /" >&2))"; rc=$?
  fi

  if declare -F dbg >/dev/null 2>&1; then
    dbg "run_cmd_capture_json tag=$tag rc=$rc bytes=${#out}"
  fi

  echo "$out"
  return $rc
}

# cjdnsharvest v5 - preflight helpers
# Style: plain ASCII status tags: [OK] [WARN] [FAIL]

cjdh_print() { printf '%s\n' "$*"; }

cjdh_require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || {
      cjdh_print "[FAIL] missing command: $c"
      return 1
    }
  done
  return 0
}

cjdh_fixpath_if_needed() {
  # Defensive PATH for cron/systemd/weird shells.
  # Avoid stomping a good PATH, only repair if essentials missing.
  if ! command -v /usr/bin/env >/dev/null 2>&1; then
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  fi
  # If core utilities missing, restore sane PATH.
  if ! command -v sh >/dev/null 2>&1 || ! command -v awk >/dev/null 2>&1 || ! command -v sed >/dev/null 2>&1; then
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  fi
}

cjdh_cjdns_admin_probe() {
  # Args: addr port
  local addr="${1:-${CJDNS_ADMIN_ADDR:-127.0.0.1}}"
  local port="${2:-${CJDNS_ADMIN_PORT:-11234}}"
  # First check: can we talk to admin
  if cjdnstool -a "$addr" -p "$port" -P NONE cexec Core_nodeInfo >/dev/null 2>&1; then
    cjdh_print "[OK] cjdns admin responding at $addr:$port"
    return 0
  fi

  cjdh_print "[FAIL] cjdns admin NOT responding at $addr:$port"
  cjdh_print "      Quick fix checklist:"
  cjdh_print "        1) Is cjdns running?  systemctl list-units --type=service | grep -i cjd"
  cjdh_print "        2) What config is used?  systemctl cat cjdroute-*.service"
  cjdh_print "        3) Ensure admin bind exists in that config (commonly 127.0.0.1:11234)"
  cjdh_print "        4) Restart:  sudo systemctl restart <your cjdroute service>"
  cjdh_print "        5) Re-test:  cjdnstool ... cexec Core_nodeInfo"
  return 1
}

cjdh_frontier_capability_probe() {
  # Returns 0 only if all required Frontier primitives work on THIS node.
  local addr="${1:-${CJDNS_ADMIN_ADDR:-127.0.0.1}}"
  local port="${2:-${CJDNS_ADMIN_PORT:-11234}}"
  local timeout_ms="${3:-2000}"

  # ReachabilityCollector_getPeerInfo page 0 must parse and have peers array
  local tmp="/tmp/cjdh_frontier_probe.$$"
  rm -f "$tmp" 2>/dev/null || true

  if ! cjdnstool -a "$addr" -p "$port" -P NONE cexec ReachabilityCollector_getPeerInfo --page=0 >"$tmp" 2>/dev/null; then
    cjdh_print "[FAIL] Frontier: ReachabilityCollector_getPeerInfo failed"
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi

  local p
  p="$(jq -r '.peers[0].pathThemToUs // empty' "$tmp" 2>/dev/null || true)"
  if [[ -z "$p" ]]; then
    cjdh_print "[FAIL] Frontier: no pathThemToUs found on page 0"
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi

  # RouterModule_getPeers must succeed for at least one path on page 0
  local ok="no"
  local i path
  for i in 0 1 2 3 4 5 6 7; do
    path="$(jq -r ".peers[$i].pathThemToUs // empty" "$tmp" 2>/dev/null || true)"
    [[ -n "$path" ]] || continue
    if cjdnstool -a "$addr" -p "$port" -P NONE cexec RouterModule_getPeers --path="$path" --timeout="$timeout_ms" 2>/dev/null \
      | jq -e '.error == "none" and (.peers|type=="array")' >/dev/null 2>&1; then
      ok="yes"
      break
    fi
  done
  rm -f "$tmp" 2>/dev/null || true

  if [[ "$ok" != "yes" ]]; then
    cjdh_print "[FAIL] Frontier: RouterModule_getPeers did not accept any sampled paths (not_found is common; all failing is not)"
    return 1
  fi

  # key2ip6 must exist
  if ! cjdnstool util key2ip6 "v0.0000.0000.0000.0001.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.k" >/dev/null 2>&1; then
    # Some builds error on invalid key; we only care that 'util key2ip6' exists.
    # So check help output instead.
    cjdnstool util key2ip6 --help >/dev/null 2>&1 || {
      cjdh_print "[FAIL] Frontier: cjdnstool util key2ip6 not available"
      return 1
    }
  fi

  cjdh_print "[OK] Frontier capability probe passed"
  return 0
}

cjdh_version_banner() {
  # Best-effort. Not all builds provide --version.
  local cjdt cjdroute
  cjdt="$(command -v cjdnstool 2>/dev/null || true)"
  cjdroute="$(command -v cjdroute 2>/dev/null || true)"

  cjdh_print "Build info:"
  cjdh_print "  cjdnstool: ${cjdt:-missing}"
  cjdh_print "  cjdroute:  ${cjdroute:-missing}"
  cjdnstool --version 2>/dev/null | sed 's/^/  cjdnstool --version: /' || true
  cjdroute  --version 2>/dev/null | sed 's/^/  cjdroute  --version: /' || true
}


# ------------------------------------------------------------------------
# cjdh_json_must_start TAG TEXT
# Returns 0 only if TEXT looks like JSON (starts with { or [ after whitespace).
# If not, prints a helpful error and returns 1.
# ------------------------------------------------------------------------
cjdh_json_must_start() {
  local tag="${1:-json}"
  local txt="${2:-}"
  local head
  head="$(printf '%s' "$txt" | sed -e 's/^[[:space:]]*//' | head -c 1)"
  if [[ "$head" == "{" || "$head" == "[" ]]; then
    return 0
  fi
  echo "[$tag] ERROR: expected JSON but got:" >&2
  printf '%s\n' "$txt" | sed -n '1,8p' | sed "s/^/[$tag]   /" >&2
  return 1
}

preflight_run() {
  cjdh_fixpath_if_needed

  cjdh_print ""
  cjdh_print "Preflight checks"

  # Hard requirements
  if ! cjdh_require_cmd bash sqlite3 jq python3 cjdnstool; then
    cjdh_print ""
    cjdh_print "Install missing dependencies and retry."
    return 1
  fi

  # cjdns admin must respond (this toolchain depends on it)
  if ! cjdh_cjdns_admin_probe "${CJDNS_ADMIN_ADDR:-127.0.0.1}" "${CJDNS_ADMIN_PORT:-11234}"; then
    return 1
  fi

  # Frontier capability only if enabled
  if [[ "${FRONTIER_ENABLE:-no}" == "yes" ]]; then
    if ! cjdh_frontier_capability_probe "${CJDNS_ADMIN_ADDR:-127.0.0.1}" "${CJDNS_ADMIN_PORT:-11234}" "${FRONTIER_TIMEOUT_MS:-2000}"; then
      cjdh_print "[WARN] Frontier enabled but capability probe failed."
      cjdh_print "       You can set FRONTIER_ENABLE=no or fix your cjdns build/admin perms."
      return 1
    fi
  fi
  # OPTIONAL_DEPS_V5
  # Optional deps: only required if the corresponding feature is enabled.
  if [[ "${HARVEST_REMOTE_NODESTORE:-no}" == "yes" || "${SMART_HARVEST_REMOTE_NODESTORE:-no}" == "yes" ]]; then
    if ! command -v ssh >/dev/null 2>&1; then
      cjdh_print "[FAIL] missing command: ssh (required for remote nodestore)"
      return 1
    fi
  else
    if ! command -v ssh >/dev/null 2>&1; then
      cjdh_print "[WARN] ssh not installed (only needed for remote nodestore)"
    fi
  fi

  if [[ "${PING_ENABLE:-no}" == "yes" ]]; then
    if ! command -v ping6 /dev/null 2>&1 && ! command -v ping /dev/null 2>&1 >/dev/null 2>&1; then
      cjdh_print "[WARN] ping/ping6 not installed (ICMP fallback only; cjdnstool ping still works)"
    fi
  fi

  cjdh_print "[OK] preflight passed"
  return 0
}


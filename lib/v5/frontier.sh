# cjdnsharvest v5 - Frontier Expansion
#
# Output: newline-separated fc.. IPv6 addresses to stdout
# Progress: stderr lines beginning with [frontier]

cjdh_frontier_expand() {
  local addr="${1:-${CJDNS_ADMIN_ADDR:-127.0.0.1}}"
  local port="${2:-${CJDNS_ADMIN_PORT:-11234}}"
  local timeout_ms="${3:-2000}"

  # Progress tuning
  local report_every="${CJDHARV_FRONTIER_REPORT_EVERY:-10}"

  local d="/tmp/cjdh_frontier.$$"
  mkdir -p "$d" || return 1
  trap 'rm -rf "${d:-}" 2>/dev/null || true' RETURN

  local paths="$d/paths.txt"
  local keys_full="$d/keys_full.txt"
  local ips="$d/ips.txt"
  : >"$paths"; : >"$keys_full"; : >"$ips"

  # 1) Page peerinfo: start at 0; stop at first page with 0 peers
  local page=0
  while :; do
    local pj="$d/peerinfo.$page.json"
    if ! cjdnstool -a "$addr" -p "$port" -P NONE cexec ReachabilityCollector_getPeerInfo --page="$page" >"$pj" 2>/dev/null; then
      break
    fi

    local n
    n="$(jq '.peers | length' "$pj" 2>/dev/null || echo 0)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    (( n > 0 )) || break

    jq -r '.peers[]? | .pathThemToUs // empty' "$pj" >>"$paths" 2>/dev/null || true
    page=$((page+1))
  done

  sort -u -o "$paths" "$paths" 2>/dev/null || true
  [[ -s "$paths" ]] || { printf "[frontier] no paths (peerinfo empty)\n" >&2; return 0; }

  local total_paths done_paths
  total_paths="$(wc -l < "$paths" 2>/dev/null || echo 0)"
  done_paths=0
  printf "[frontier] paths=%s timeout_ms=%s\n" "$total_paths" "$timeout_ms" >&2

  # 2) For each path, call getPeers; keep only successful responses; collect peers[] strings
  while IFS= read -r cjdh_route_path; do
    [[ -n "$cjdh_route_path" ]] || continue

    cjdnstool -a "$addr" -p "$port" -P NONE cexec RouterModule_getPeers --path="$cjdh_route_path" --timeout="$timeout_ms" 2>/dev/null \
      | jq -r 'select(((.error?=="none") or (.result?=="peers")) and (.peers|type=="array")) | .peers[]?' 2>/dev/null \
      >>"$keys_full" || true

    done_paths=$((done_paths+1))
    if (( report_every > 0 )) && (( done_paths % report_every == 0 )); then
      printf "[frontier] getPeers %s/%s\n" "$done_paths" "$total_paths" >&2
    fi
  done <"$paths"

  sort -u -o "$keys_full" "$keys_full" 2>/dev/null || true
  [[ -s "$keys_full" ]] || { printf "[frontier] no peer keys\n" >&2; return 0; }

  # 3) key2ip6 wants "<pubkey>.k"
  local total_keys done_keys
  total_keys="$(wc -l < "$keys_full" 2>/dev/null || echo 0)"
  done_keys=0
  printf "[frontier] keys=%s\n" "$total_keys" >&2

  while IFS= read -r kfull; do
    [[ -n "$kfull" ]] || continue

    # Extract "<pubkey>.k" from "v21.0000....<pubkey>.k"
    local k_pub
    k_pub="$(awk -F. '{print $(NF-1) ".k"}' <<<"$kfull")"

    cjdnstool util key2ip6 "$k_pub" 2>/dev/null | awk '{print $2}' >>"$ips" || true

    done_keys=$((done_keys+1))
    if (( report_every > 0 )) && (( done_keys % report_every == 0 )); then
      printf "[frontier] key2ip6 %s/%s\n" "$done_keys" "$total_keys" >&2
    fi
  done <"$keys_full"

  # Output normalized fc addresses (stdout)
  tr '[:upper:]' '[:lower:]' <"$ips" \
    | grep -E '^fc[0-9a-f:]+' \
    | sort -u
}

# cjdnsharvest v5 - environment detection helpers
# Goal: auto-detect bitcoin-cli datadir/conf and cjdns admin addr/port, then verify.

cjdh_die(){ printf '%s\n' "$*" >&2; exit 1; }
cjdh_trim(){ awk '{$1=$1}1' <<<"${1:-}"; }

cjdh_yesno_default_no() {
  local prompt="${1:?prompt}"
  local ans
  read -r -p "$prompt [y/N]: " ans || true
  ans="${ans,,}"
  [[ "$ans" == "y" || "$ans" == "yes" ]]
}

cjdh_prompt_path() {
  local label="${1:?label}"
  local def="${2:-}"
  local ans
  read -r -p "$label (${def}): " ans || true
  ans="$(cjdh_trim "$ans")"
  [[ -z "$ans" ]] && ans="$def"
  printf '%s\n' "$ans"
}

cjdh_find_bitcoin_cli_bin() {
  # Prefer explicit config var if set; else PATH lookup.
  if [[ -n "${BITCOIN_CLI_BIN:-}" ]] && command -v "$BITCOIN_CLI_BIN" >/dev/null 2>&1; then
    printf '%s\n' "$BITCOIN_CLI_BIN"
    return 0
  fi

  if command -v bitcoin-cli >/dev/null 2>&1; then
    command -v bitcoin-cli
    return 0
  fi

  # common location on some installs
  if [[ -x /usr/local/bin/bitcoin-cli ]]; then
    printf '%s\n' /usr/local/bin/bitcoin-cli
    return 0
  fi

  return 1
}

cjdh_try_extract_bitcoind_args() {
  # Prints "DATADIR|CONF" if found, else empty.
  local line dd cf exec argv

  # 1) Running process args (best)
  if command -v pgrep >/dev/null 2>&1; then
    line="$(pgrep -a bitcoind 2>/dev/null | head -n1 || true)"
    if [[ -n "$line" ]]; then
      dd="$(sed -n 's/.* -datadir=\([^ ]\+\).*/\1/p' <<<"$line" | head -n1)"
      [[ -z "$dd" ]] && dd="$(sed -n 's/.* -datadir[[:space:]]\([^ ]\+\).*/\1/p' <<<"$line" | head -n1)"
      cf="$(sed -n 's/.* -conf=\([^ ]\+\).*/\1/p' <<<"$line" | head -n1)"
      [[ -z "$cf" ]] && cf="$(sed -n 's/.* -conf[[:space:]]\([^ ]\+\).*/\1/p' <<<"$line" | head -n1)"
      if [[ -n "$dd" || -n "$cf" ]]; then
        printf '%s|%s\n' "${dd:-}" "${cf:-}"
        return 0
      fi
    fi
  fi

  # 2) systemd unit ExecStart (parse argv[] blob if present)
  if command -v systemctl >/dev/null 2>&1; then
    for unit in bitcoind.service bitcoin.service; do
      exec="$(systemctl show -p ExecStart --value "$unit" 2>/dev/null || true)"
      [[ -n "$exec" ]] || continue

      argv="$(sed -n 's/.*argv\[\]=\([^;]*\).*/\1/p' <<<"$exec" | head -n1)"
      [[ -z "$argv" ]] && argv="$exec"

      dd="$(sed -n 's/.* -datadir=\([^ ]\+\).*/\1/p' <<<" $argv" | head -n1)"
      [[ -z "$dd" ]] && dd="$(sed -n 's/.* -datadir[[:space:]]\([^ ]\+\).*/\1/p' <<<" $argv" | head -n1)"
      cf="$(sed -n 's/.* -conf=\([^ ]\+\).*/\1/p' <<<" $argv" | head -n1)"
      [[ -z "$cf" ]] && cf="$(sed -n 's/.* -conf[[:space:]]\([^ ]\+\).*/\1/p' <<<" $argv" | head -n1)"

      if [[ -n "$dd" || -n "$cf" ]]; then
        printf '%s|%s\n' "${dd:-}" "${cf:-}"
        return 0
      fi
    done
  fi

  echo ""
  return 0
}


cjdh_parse_datadir_from_conf() {
  # Args: conf_path
  # Prints datadir if present, else empty.
  local conf="${1:-}"
  [[ -n "$conf" && -f "$conf" ]] || { echo ""; return 0; }
  local line
  line="$(grep -E '^[[:space:]]*datadir[[:space:]]*=' "$conf" 2>/dev/null | tail -n1 || true)"
  if [[ -z "$line" ]]; then
    echo ""
    return 0
  fi
  line="${line#*=}"
  line="$(cjdh_trim "$line")"
  line="${line%\"}"
  line="${line#\"}"
  echo "$line"
  return 0
}

cjdh_guess_paths_from_conf() {
  # Args: conf_path
  # Prints "DATADIR|CONF" if conf exists, else empty.
  local conf="${1:-}" dd
  [[ -n "$conf" && -f "$conf" ]] || { echo ""; return 0; }
  dd="$(cjdh_parse_datadir_from_conf "$conf")"
  if [[ -z "$dd" ]]; then
    dd="$(cd "$(dirname "$conf")" 2>/dev/null && pwd -P)"
  fi
  printf '%s|%s\n' "${dd:-}" "$conf"
  return 0
}

cjdh_common_bitcoin_conf_candidates() {
  printf '%s\n' \
    "${HOME}/.bitcoin/bitcoin.conf" \
    "/srv/bitcoin/bitcoin.conf" \
    "/srv/bitcoind/bitcoin.conf" \
    "/etc/bitcoin/bitcoin.conf" \
    "/etc/bitcoind/bitcoin.conf" \
    "/var/lib/bitcoin/bitcoin.conf" \
    "/var/bitcoin/bitcoin.conf" \
    "/opt/bitcoin/bitcoin.conf"
}

cjdh_quick_find_bitcoin_conf() {
  # Quick search for bitcoin.conf in common roots.
  local root cand
  for root in /etc /srv /var /opt "${HOME}"; do
    [[ -d "$root" ]] || continue
    cand="$(find "$root" -maxdepth 4 -name bitcoin.conf -type f 2>/dev/null | head -n1 || true)"
    if [[ -n "$cand" ]]; then
      echo "$cand"
      return 0
    fi
  done
  echo ""
  return 0
}

cjdh_detect_bitcoin_paths() {
  # Prints "DATADIR|CONF" if detected, else empty.
  local guess dd cf cand

  guess="$(cjdh_try_extract_bitcoind_args)"
  dd="${guess%%|*}"
  cf="${guess#*|}"
  if [[ "$dd" != "$guess" || "$cf" != "$guess" ]]; then
    if [[ -n "$cf" && -f "$cf" && -z "$dd" ]]; then
      guess="$(cjdh_guess_paths_from_conf "$cf")"
      echo "$guess"
      return 0
    fi
    if [[ -n "$dd" && -d "$dd" && -z "$cf" ]]; then
      cf="$dd/bitcoin.conf"
      [[ -f "$cf" ]] || cf=""
    fi
    if [[ -n "$dd" || -n "$cf" ]]; then
      printf '%s|%s\n' "${dd:-}" "${cf:-}"
      return 0
    fi
  fi

  while IFS= read -r cand; do
    [[ -n "$cand" && -f "$cand" ]] || continue
    cjdh_guess_paths_from_conf "$cand"
    return 0
  done < <(cjdh_common_bitcoin_conf_candidates)

  cand="$(cjdh_quick_find_bitcoin_conf)"
  if [[ -n "$cand" ]]; then
    cjdh_guess_paths_from_conf "$cand"
    return 0
  fi

  echo ""
  return 0
}

cjdh_default_bitcoin_datadir() {
  # Default Core datadir is ~/.bitcoin on Linux.
  printf '%s\n' "${HOME}/.bitcoin"
}

cjdh_verify_bitcoin_cli() {
  # Args: cli_bin datadir conf
  # Returns 0 if getnetworkinfo works with the provided args.
  # Important: many installs work with -conf only (no -datadir needed/desired).
  local bin="${1:?bin}" dd="${2:-}" cf="${3:-}"
  local cmd=("$bin")

  if [[ -n "$cf" ]]; then
    cmd+=("-conf=$cf")
  fi
  if [[ -n "$dd" ]]; then
    cmd+=("-datadir=$dd")
  fi

  # First try with whatever we have
  if "${cmd[@]}" getnetworkinfo >/dev/null 2>&1; then
    return 0
  fi

  # If datadir+conf failed but conf exists, retry with conf only.
  if [[ -n "$cf" ]]; then
    cmd=("$bin" "-conf=$cf")
    "${cmd[@]}" getnetworkinfo >/dev/null 2>&1
    return $?
  fi

  return 1
}


cjdh_build_bitcoin_cli() {
  # Output: a complete CLI string, e.g. "/usr/bin/bitcoin-cli -datadir=... -conf=..."
  local bin dd cf guess

  bin="$(cjdh_find_bitcoin_cli_bin)" || {
    cjdh_die "Could not find bitcoin-cli in PATH. Install Bitcoin Core or set BITCOIN_CLI_BIN in harvest.conf."
  }

  # If config already has explicit values, trust them first.
  dd="${BITCOIN_DATADIR:-}"
  cf="${BITCOIN_CONF:-}"

  if [[ -n "$dd" || -n "$cf" ]]; then
    if cjdh_verify_bitcoin_cli "$bin" "$dd" "$cf"; then
      {
      local out="$bin"
      [[ -n "$dd" ]] && out="$out -datadir=$dd"
      [[ -n "$cf" ]] && out="$out -conf=$cf"
      printf '%s
' "$out"
    }
      return 0
    fi
    # fall through to detect if saved values don't verify
  fi

  guess="$(cjdh_detect_bitcoin_paths)"
  dd="${guess%%|*}"
  cf="${guess#*|}"
  [[ "$dd" == "$guess" ]] && dd="" && cf=""
  # Fill missing pieces with sane defaults
  # If we already discovered a conf, do NOT guess datadir (conf-only installs are common).
  if [[ -z "$cf" ]]; then
    [[ -z "$dd" ]] && dd="$(cjdh_default_bitcoin_datadir)"
    cf="$dd/bitcoin.conf"
  fi

  # Verify guess
  if ! cjdh_verify_bitcoin_cli "$bin" "$dd" "$cf"; then
    # Ask operator
    printf '%s\n' "Bitcoin Core paths could not be verified automatically."
    dd="$(cjdh_prompt_path "Bitcoin datadir" "$dd")"
    cf="$(cjdh_prompt_path "Bitcoin conf file" "$cf")"
    cjdh_verify_bitcoin_cli "$bin" "$dd" "$cf" || cjdh_die "Those paths still don't work. Aborting."
  else
    printf '%s\n' "Detected Bitcoin Core:" >&2

    printf '%s\n' "  bitcoin-cli: $bin" >&2

    printf '%s\n' "  datadir:     $dd" >&2

    printf '%s\n' "  conf:        $cf" >&2

    echo
    echo "Detected settings:"
    printf "  bitcoin-cli : %s\n" "${BITCOIN_CLI_BIN:-<unset>}"
    printf "  datadir     : %s\n" "${BITCOIN_DATADIR:-<unset>}"
    printf "  conf        : %s\n" "${BITCOIN_CONF:-<unset>}"
    printf "  cjdns admin : %s:%s\n" "${CJDNS_ADMIN_ADDR:-<unset>}" "${CJDNS_ADMIN_PORT:-<unset>}"
    printf "  remote user : %s\n" "${REMOTE_NODESTORE_USER:-<unset>}"
    printf "  remote host : %s\n" "${REMOTE_NODESTORE_HOST:-<unset>}"
    echo
    if cjdh_yesno_default_no "Use these detected settings?"; then
      :
    else
      dd="$(cjdh_prompt_path "Bitcoin datadir" "$dd")"
      cf="$(cjdh_prompt_path "Bitcoin conf file" "$cf")"
      cjdh_verify_bitcoin_cli "$bin" "$dd" "$cf" || cjdh_die "Those paths don't work. Aborting."
    fi
  fi

  # Persist into variables for caller
  BITCOIN_CLI_BIN="$bin"
  BITCOIN_DATADIR="$dd"
  BITCOIN_CONF="$cf"

  {
      local out="$bin"
      [[ -n "$dd" ]] && out="$out -datadir=$dd"
      [[ -n "$cf" ]] && out="$out -conf=$cf"
      printf '%s
' "$out"
    }
}

# ---- cjdns admin detection ----
cjdh_verify_cjdns_admin() {
  local addr="${1:?addr}" port="${2:?port}"
  cjdnstool -a "$addr" -p "$port" -P NONE cexec Core_nodeInfo >/dev/null 2>&1
}

cjdh_detect_cjdns_admin() {
  # DERIVE_ADMIN_FROM_CONF
  # Uses CJDNS_ADMIN_ADDR/CJDNS_ADMIN_PORT if set; else:
  #  1) try default 11234
  #  2) derive from active cjdroute config (systemd ExecStart -c ... or scan /etc/cjdroute*.conf)
  #  3) prompt as last resort
  local addr port cand conf det

  addr="${CJDNS_ADMIN_ADDR:-127.0.0.1}"
  port="${CJDNS_ADMIN_PORT:-}"

  # 0) If explicitly set and works, trust it.
  if [[ -n "$port" ]] && cjdh_verify_cjdns_admin "$addr" "$port"; then
    printf '%s|%s\n' "$addr" "$port"
    return 0
  fi

  # 1) Default only (non-random)
  if cjdh_verify_cjdns_admin "$addr" "11234"; then
    printf '%s|%s\n' "$addr" "11234"
    return 0
  fi

  # 2) Derive from config
  conf="$(cjdh_detect_cjdroute_conf)"
  if [[ -n "$conf" ]]; then
    det="$(cjdh_parse_admin_bind_from_conf "$conf")"
    if [[ "$det" == *"|"* ]]; then
      cand_addr="${det%%|*}"
      cand_port="${det#*|}"
      # If addr not explicitly set by user, adopt what config says
      if [[ -z "${CJDNS_ADMIN_ADDR:-}" ]]; then
        addr="$cand_addr"
      fi
      if [[ -n "$cand_port" ]] && cjdh_verify_cjdns_admin "$addr" "$cand_port"; then
        printf '%s|%s\n' "$addr" "$cand_port"
        return 0
      fi
    fi
  fi

  # 3) Last resort: prompt
  printf '%s\n' "Could not detect cjdns admin port automatically."
  if [[ -n "$conf" ]]; then
    printf '%s\n' "  Found cjdroute config: $conf"
    printf '%s\n' "  (If admin.bind is set there, ensure it matches what you enter.)"
  fi

  addr="$(cjdh_prompt_path "cjdns admin addr" "$addr")"
  port="$(cjdh_prompt_path "cjdns admin port" "11234")"
  cjdh_verify_cjdns_admin "$addr" "$port" || cjdh_die "cjdns admin not reachable at ${addr}:${port}."
  printf '%s|%s\n' "$addr" "$port"
}

# ---- cjdns config/service detection (portable-ish) ----

cjdh_detect_cjdroute_service() {
  # Prints the most likely active cjdroute systemd unit name, else empty.
  command -v systemctl >/dev/null 2>&1 || { echo ""; return 0; }

  # Prefer "active (running)" units matching cjdroute*
  local units
  units="$(systemctl list-units --type=service --state=running 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^cjdroute.*\.service$' || true)"
  if [[ -n "$units" ]]; then
    echo "$units" | head -n1
    return 0
  fi

  # Fallback: any loaded unit
  units="$(systemctl list-units --type=service 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^cjdroute.*\.service$' || true)"
  if [[ -n "$units" ]]; then
    echo "$units" | head -n1
    return 0
  fi

  echo ""
  return 0
}

cjdh_detect_cjdroute_conf() {
  # Prints absolute config path if found, else empty.
  # Strategy:
  #  1) systemd unit ExecStart contains "-c <path>" or "--config <path>"
  #  2) fallback scan common locations for cjdroute*.conf
  command -v systemctl >/dev/null 2>&1 || { echo ""; return 0; }

  local unit
  unit="$(cjdh_detect_cjdroute_service)"
  if [[ -n "$unit" ]]; then
    local exec
    exec="$(systemctl show -p ExecStart --value "$unit" 2>/dev/null || true)"
    # systemctl show encodes ExecStart in a semi-structured way; still parseable for "-c" tokens.
    # Try -c /path and --config /path
    local conf=""
    conf="$(sed -n 's/.*[[:space:]]-c[[:space:]]\([^ ;"]\+\).*/\1/p' <<<"$exec" | head -n1)"
    if [[ -z "$conf" ]]; then
      conf="$(sed -n 's/.*[[:space:]]--config[=[:space:]]\([^ ;"]\+\).*/\1/p' <<<"$exec" | head -n1)"
    fi
    if [[ -n "$conf" && -f "$conf" ]]; then
      echo "$conf"
      return 0
    fi
  fi

  # Fallback scan (best effort)
  local cand
  for cand in /etc/cjdroute*.conf /usr/local/etc/cjdroute*.conf; do
    [[ -f "$cand" ]] || continue
    echo "$cand"
    return 0
  done

  echo ""
  return 0
}

cjdh_parse_admin_bind_from_conf() {
  # Args: conf_path
  # Prints "addr|port" if found, else empty.
  local conf="${1:-}"
  [[ -n "$conf" && -f "$conf" ]] || { echo ""; return 0; }

  # We avoid jq here; cjdroute conf can be JSON5-ish.
  # Parse a line like: "bind": "127.0.0.1:11234"
  # under an admin block.
  local bind=""
  bind="$(grep -Eo '"bind"[[:space:]]*:[[:space:]]*"[^"]+"' "$conf" 2>/dev/null | head -n1 || true)"
  if [[ -z "$bind" ]]; then
    echo ""
    return 0
  fi
  bind="${bind#*\"}"
  bind="${bind%\"}"

  # bind is addr:port (addr may be 127.0.0.1 or ::1)
  local addr port
  addr="${bind%:*}"
  port="${bind##*:}"
  [[ "$addr" != "$bind" && "$port" =~ ^[0-9]+$ ]] || { echo ""; return 0; }
  echo "${addr}|${port}"
  return 0
}

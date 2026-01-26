#!/usr/bin/env bash
# CJDNS Harvester v5 - Detection and Verification

# Requires: ui.sh functions

# ============================================================================
# Helper Functions
# ============================================================================
# Prompt yes/no with N as default (empty = no)
prompt_yn() {
    local prompt="$1"
    local ans
    while true; do
        read -r -p "$prompt [y/N] (default - N): " ans || true
        ans="${ans,,}"  # lowercase

        if [[ "$ans" == "y" || "$ans" == "yes" ]]; then
            return 0  # true
        elif [[ "$ans" == "n" || "$ans" == "no" || -z "$ans" ]]; then
            return 1  # false
        else
            printf "${C_ERROR}Invalid response. Please answer 'y' or 'n'.${C_RESET}\n"
        fi
    done
}

# Prompt yes/no with Y as default (empty = yes)
prompt_yn_yes() {
    local prompt="$1"
    local ans
    while true; do
        read -r -p "$prompt [Y/n] (default - Y): " ans || true
        ans="${ans,,}"  # lowercase

        if [[ "$ans" == "y" || "$ans" == "yes" || -z "$ans" ]]; then
            return 0  # true
        elif [[ "$ans" == "n" || "$ans" == "no" ]]; then
            return 1  # false
        else
            printf "${C_ERROR}Invalid response. Please answer 'y' or 'n'.${C_RESET}\n"
        fi
    done
}

prompt_path() {
    local label="$1"
    local default="$2"
    local ans
    read -r -p "$label [$default]: " ans || true
    ans="${ans// /}"  # trim spaces
    [[ -z "$ans" ]] && ans="$default"
    printf '%s\n' "$ans"
}

# ============================================================================
# Bitcoin Core Detection
# ============================================================================
find_bitcoin_cli() {
    if command -v bitcoin-cli >/dev/null 2>&1; then
        command -v bitcoin-cli
        return 0
    fi
    if [[ -x /usr/local/bin/bitcoin-cli ]]; then
        printf '%s\n' /usr/local/bin/bitcoin-cli
        return 0
    fi
    return 1
}

detect_bitcoin_paths() {
    # Try to extract datadir/conf from running bitcoind process
    local line dd cf

    if command -v pgrep >/dev/null 2>&1; then
        line="$(pgrep -a bitcoind 2>/dev/null | head -n1 || true)"
        if [[ -n "$line" ]]; then
            dd="$(sed -n 's/.* -datadir=\([^ ]\+\).*/\1/p' <<<"$line" | head -n1)"
            cf="$(sed -n 's/.* -conf=\([^ ]\+\).*/\1/p' <<<"$line" | head -n1)"
            if [[ -n "$dd" || -n "$cf" ]]; then
                printf '%s|%s\n' "${dd:-}" "${cf:-}"
                return 0
            fi
        fi
    fi

    # Try systemd
    if command -v systemctl >/dev/null 2>&1; then
        for unit in bitcoind.service bitcoin.service; do
            local exec argv
            exec="$(systemctl show -p ExecStart --value "$unit" 2>/dev/null || true)"
            [[ -n "$exec" ]] || continue

            argv="$(sed -n 's/.*argv\[\]=\([^;]*\).*/\1/p' <<<"$exec" | head -n1)"
            [[ -z "$argv" ]] && argv="$exec"

            dd="$(sed -n 's/.* -datadir=\([^ ]\+\).*/\1/p' <<<" $argv" | head -n1)"
            cf="$(sed -n 's/.* -conf=\([^ ]\+\).*/\1/p' <<<" $argv" | head -n1)"

            if [[ -n "$dd" || -n "$cf" ]]; then
                printf '%s|%s\n' "${dd:-}" "${cf:-}"
                return 0
            fi
        done
    fi

    echo ""
}

default_bitcoin_datadir() {
    if [[ -d "$HOME/.bitcoin" ]]; then
        echo "$HOME/.bitcoin"
    elif [[ -d "/srv/bitcoin" ]]; then
        echo "/srv/bitcoin"
    else
        echo "$HOME/.bitcoin"
    fi
}

verify_bitcoin_cli() {
    local bin="$1"
    local dd="$2"
    local cf="$3"

    local cmd=("$bin")
    [[ -n "$cf" ]] && cmd+=("-conf=$cf")
    [[ -n "$dd" ]] && cmd+=("-datadir=$dd")

    "${cmd[@]}" getnetworkinfo >/dev/null 2>&1
}

detect_and_confirm_bitcoin() {
    print_section "Bitcoin Core Detection"

    local bin dd cf guess

    # Find bitcoin-cli
    bin="$(find_bitcoin_cli)" || {
        status_error "Could not find bitcoin-cli in PATH"
        echo "Please install Bitcoin Core or ensure bitcoin-cli is in your PATH"
        exit 1
    }

    # Detect paths
    guess="$(detect_bitcoin_paths)"
    dd="${guess%%|*}"
    cf="${guess#*|}"
    [[ "$dd" == "$guess" ]] && dd="" && cf=""

    # Fill missing with defaults
    if [[ -z "$cf" ]]; then
        [[ -z "$dd" ]] && dd="$(default_bitcoin_datadir)"
        cf="$dd/bitcoin.conf"
    fi

    # Verify or prompt
    if verify_bitcoin_cli "$bin" "$dd" "$cf"; then
        echo
        echo "Detected Bitcoin Core:"
        echo "  bitcoin-cli: $bin"
        echo "  datadir:     $dd"
        echo "  conf:        $cf"
        echo

        if prompt_yn_yes "Use these detected settings?"; then
            BITCOIN_CLI_BIN="$bin"
            BITCOIN_DATADIR="$dd"
            BITCOIN_CONF="$cf"
            status_ok "Bitcoin Core configured"
        else
            dd="$(prompt_path "Bitcoin datadir" "$dd")"
            cf="$(prompt_path "Bitcoin conf" "$cf")"
            if verify_bitcoin_cli "$bin" "$dd" "$cf"; then
                BITCOIN_CLI_BIN="$bin"
                BITCOIN_DATADIR="$dd"
                BITCOIN_CONF="$cf"
                status_ok "Bitcoin Core configured (manual)"
            else
                status_error "Unable to connect to Bitcoin Core with those settings"
                exit 1
            fi
        fi
    else
        status_warn "Auto-detection failed, manual entry required"
        echo
        dd="$(prompt_path "Bitcoin datadir" "$dd")"
        cf="$(prompt_path "Bitcoin conf" "$cf")"
        if verify_bitcoin_cli "$bin" "$dd" "$cf"; then
            BITCOIN_CLI_BIN="$bin"
            BITCOIN_DATADIR="$dd"
            BITCOIN_CONF="$cf"
            status_ok "Bitcoin Core configured (manual)"
        else
            status_error "Unable to connect to Bitcoin Core"
            exit 1
        fi
    fi

    # Build CLI command
    CLI="$bin"
    [[ -n "$dd" ]] && CLI="$CLI -datadir=$dd"
    [[ -n "$cf" ]] && CLI="$CLI -conf=$cf"
    export CLI
}

# ============================================================================
# CJDNS Detection
# ============================================================================
verify_cjdns_admin() {
    local addr="$1"
    local port="$2"
    cjdnstool -a "$addr" -p "$port" -P NONE cexec Core_nodeInfo >/dev/null 2>&1
}

detect_cjdns_admin() {
    local addr="${CJDNS_ADMIN_ADDR:-127.0.0.1}"
    local port="${CJDNS_ADMIN_PORT:-11234}"

    # Try default
    if verify_cjdns_admin "$addr" "$port"; then
        printf '%s|%s\n' "$addr" "$port"
        return 0
    fi

    # Try to find from config
    local conf
    for conf in /etc/cjdroute.conf ~/.cjdroute.conf /etc/cjdroute*.conf; do
        [[ -f "$conf" ]] || continue
        local cport
        cport="$(grep -A1 '"admin"' "$conf" 2>/dev/null | grep '"bind"' | sed -n 's/.*:\([0-9]\+\)".*/\1/p' | head -n1)"
        if [[ -n "$cport" ]] && verify_cjdns_admin "$addr" "$cport"; then
            printf '%s|%s\n' "$addr" "$cport"
            return 0
        fi
    done

    # Not found
    echo ""
}

detect_and_confirm_cjdns() {
    print_section "CJDNS Detection"

    local addr port guess

    # Check if cjdnstool exists
    if ! command -v cjdnstool >/dev/null 2>&1; then
        status_error "cjdnstool not found in PATH"
        echo "Please install cjdnstool: npm install -g cjdnstool"
        exit 1
    fi

    # Detect admin settings
    guess="$(detect_cjdns_admin)"
    if [[ -n "$guess" ]]; then
        addr="${guess%%|*}"
        port="${guess#*|}"

        echo
        echo "Detected CJDNS:"
        echo "  admin addr:  $addr"
        echo "  admin port:  $port"
        echo "  password:    (none assumed)"
        echo

        if prompt_yn_yes "Use these detected settings?"; then
            CJDNS_ADMIN_ADDR="$addr"
            CJDNS_ADMIN_PORT="$port"
            status_ok "CJDNS configured"
        else
            addr="$(prompt_path "CJDNS admin address" "$addr")"
            port="$(prompt_path "CJDNS admin port" "$port")"
            if verify_cjdns_admin "$addr" "$port"; then
                CJDNS_ADMIN_ADDR="$addr"
                CJDNS_ADMIN_PORT="$port"
                status_ok "CJDNS configured (manual)"
            else
                status_error "Unable to connect to CJDNS admin at ${addr}:${port}"
                exit 1
            fi
        fi
    else
        status_warn "Auto-detection failed, manual entry required"
        echo
        addr="$(prompt_path "CJDNS admin address" "127.0.0.1")"
        port="$(prompt_path "CJDNS admin port" "11234")"
        if verify_cjdns_admin "$addr" "$port"; then
            CJDNS_ADMIN_ADDR="$addr"
            CJDNS_ADMIN_PORT="$port"
            status_ok "CJDNS configured (manual)"
        else
            status_error "Unable to connect to CJDNS admin"
            exit 1
        fi
    fi

    export CJDNS_ADMIN_ADDR CJDNS_ADMIN_PORT
}

# ============================================================================
# Preflight Checks
# ============================================================================
run_preflight_checks() {
    print_section "Preflight Checks"

    # Test Bitcoin Core
    show_progress "Testing Bitcoin Core connection"
    if bash -c "$CLI getnetworkinfo" >/dev/null 2>&1; then
        show_progress_done
        status_ok "Bitcoin Core responding"
    else
        show_progress_fail
        status_error "Bitcoin Core not responding"
        exit 1
    fi

    # Test CJDNS admin
    show_progress "Testing CJDNS admin connection"
    if cjdnstool -a "$CJDNS_ADMIN_ADDR" -p "$CJDNS_ADMIN_PORT" -P NONE cexec Core_nodeInfo >/dev/null 2>&1; then
        show_progress_done
        status_ok "CJDNS admin responding"
    else
        show_progress_fail
        status_error "CJDNS admin not responding"
        exit 1
    fi

    # Test frontier capability (ReachabilityCollector)
    show_progress "Testing frontier expansion capability"
    if cjdnstool -a "$CJDNS_ADMIN_ADDR" -p "$CJDNS_ADMIN_PORT" -P NONE cexec ReachabilityCollector_getPeerInfo --page=0 >/dev/null 2>&1; then
        show_progress_done
        status_ok "Frontier expansion available"
        FRONTIER_AVAILABLE=1
    else
        show_progress_fail
        status_warn "Frontier expansion NOT available (will use nodestore only)"
        FRONTIER_AVAILABLE=0
    fi

    export FRONTIER_AVAILABLE

    echo
    status_ok "All preflight checks passed"
    echo
}

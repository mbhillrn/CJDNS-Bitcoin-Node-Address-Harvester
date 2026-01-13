#!/usr/bin/env bash
# cjdnsharvest v5 - modular loader (named modules)

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# If this script is located in lib/harvest/, step up to the project root.
if [[ -d "$ROOT_DIR/lib/harvest" ]]; then
  BASE_DIR="$ROOT_DIR"

# LOCAL_CONF_FALLBACK_V2
# Per-machine overrides (not committed). Lives next to CONF_PATH.
LOCAL_CONF_PATH="${LOCAL_CONF_PATH:-${BASE_DIR:-.}/harvest.local.conf}"

elif [[ -d "$ROOT_DIR/../lib/harvest" ]]; then
  BASE_DIR="$(cd "$ROOT_DIR/.." && pwd)"
else
  BASE_DIR="$ROOT_DIR"
fi

export CJDH_ROOT="$BASE_DIR"
# Existing standalone libs (leave as-is)
[[ -f "$BASE_DIR/lib/preflight.sh" ]] && source "$BASE_DIR/lib/preflight.sh"
  [[ -f "$BASE_DIR/lib/detect.sh"    ]] && source "$BASE_DIR/lib/detect.sh"
[[ -f "$BASE_DIR/lib/frontier.sh"  ]] && source "$BASE_DIR/lib/frontier.sh"

# Named harvester modules (ordered)
source "$BASE_DIR/lib/harvest/bootstrap_ui_dbconf.sh"
source "$BASE_DIR/lib/harvest/wizard_prompts.sh"
source "$BASE_DIR/lib/harvest/ingest_sources.sh"
source "$BASE_DIR/lib/harvest/run_phase4_onetry.sh"
source "$BASE_DIR/lib/harvest/probes_cli_main.sh"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

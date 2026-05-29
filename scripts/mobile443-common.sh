#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/opt/mobile443/config.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

BASE_DIR="/opt/mobile443"
STATE_DIR="/var/lib/mobile443"
LISTS_DIR="${BASE_DIR}/lists"
ASNS_FILE="${BASE_DIR}/asns.conf"
ALLOW_CACHE_FILE="${STATE_DIR}/prefixes.txt"
LOCK_FILE="${STATE_DIR}/lock"

IPSET_ALLOW_NAME="allowed_mobile_443"
IPSET_ALLOW_TMP_NAME="${IPSET_ALLOW_NAME}_tmp"
IPSET_GOV_NAME="traf_guard_government"
IPSET_GOV_TMP_NAME="${IPSET_GOV_NAME}_tmp"
IPSET_ANTISCANNER_NAME="traf_guard_antiscanner"
IPSET_ANTISCANNER_TMP_NAME="${IPSET_ANTISCANNER_NAME}_tmp"
IPSET_DEFERRED_BLOCK_NAME="mobile443_deferred_block"

PRECHECK_CHAIN="TRAF_GUARD_PRECHECK"
CHAIN_NAME="FILTER_MOBILE_443"
LOG_PREFIX="MOBILE443_BLOCK: "
GOV_LOG_PREFIX="MOBILE443_TG_GOV: "
ANTISCANNER_LOG_PREFIX="MOBILE443_TG_SCAN: "

GOV_LIST_FILE="${LISTS_DIR}/government_networks.list"
ANTISCANNER_LIST_FILE="${LISTS_DIR}/antiscanner.list"

TRAF_GUARD_BASE_URL="${TRAF_GUARD_BASE_URL:-https://raw.githubusercontent.com/wh3r3ar3you/traffic-guard-lists/refs/heads/main/public}"
GOV_LIST_URL="${GOV_LIST_URL:-${TRAF_GUARD_BASE_URL}/government_networks.list}"
ANTISCANNER_LIST_URL="${ANTISCANNER_LIST_URL:-${TRAF_GUARD_BASE_URL}/antiscanner.list}"

ENABLE_TRAF_GUARD="${ENABLE_TRAF_GUARD:-true}"
ENABLE_TRAF_GUARD_GOVERNMENT="${ENABLE_TRAF_GUARD_GOVERNMENT:-true}"
ENABLE_TRAF_GUARD_ANTISCANNER="${ENABLE_TRAF_GUARD_ANTISCANNER:-true}"
ENABLE_MOBILE_ALLOW="${ENABLE_MOBILE_ALLOW:-true}"
ENABLE_TELEGRAM="${ENABLE_TELEGRAM:-${TG_ENABLED:-false}}"
MOBILE443_MIN_NOTIFY_BYTES="${MOBILE443_MIN_NOTIFY_BYTES:-0}"

read -r -a PORT_LIST <<< "${PORTS:-443}"

log() {
  echo "[$(date '+%F %T')] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

bool_is_true() {
  [[ "${1:-false}" == "true" ]]
}

ensure_deps() {
  need_cmd curl
  need_cmd ipset
  need_cmd iptables
  need_cmd flock
  if bool_is_true "$ENABLE_MOBILE_ALLOW"; then
    need_cmd jq
  fi
}

ensure_dirs() {
  mkdir -p "$BASE_DIR" "$STATE_DIR" "$LISTS_DIR"
}

ensure_set_pair() {
  local set_name="$1"
  local tmp_name="$2"
  ipset create "$set_name" hash:net family inet hashsize 65536 maxelem 524288 -exist
  ipset create "$tmp_name" hash:net family inet hashsize 65536 maxelem 524288 -exist
}

ensure_ipsets() {
  if bool_is_true "$ENABLE_TRAF_GUARD"; then
    if bool_is_true "$ENABLE_TRAF_GUARD_GOVERNMENT"; then
      ensure_set_pair "$IPSET_GOV_NAME" "$IPSET_GOV_TMP_NAME"
    fi
    if bool_is_true "$ENABLE_TRAF_GUARD_ANTISCANNER"; then
      ensure_set_pair "$IPSET_ANTISCANNER_NAME" "$IPSET_ANTISCANNER_TMP_NAME"
    fi
  fi
  if bool_is_true "$ENABLE_MOBILE_ALLOW"; then
    ensure_set_pair "$IPSET_ALLOW_NAME" "$IPSET_ALLOW_TMP_NAME"
  fi
  if bool_is_true "$ENABLE_TELEGRAM"; then
    ipset create "$IPSET_DEFERRED_BLOCK_NAME" hash:ip family inet hashsize 4096 maxelem 65536 timeout 3600 -exist
  fi
}

destroy_set_if_exists() {
  ipset destroy "$1" 2>/dev/null || true
}

count_lines() {
  local file="$1"
  [[ -f "$file" ]] || {
    echo 0
    return
  }
  wc -l < "$file" | tr -d ' '
}

validate_ipv4_cidr() {
  local prefix="$1"
  local ip mask octet
  local IFS=.

  [[ "$prefix" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || return 1
  ip="${prefix%/*}"
  mask="${prefix#*/}"

  [[ "$mask" =~ ^[0-9]+$ ]] || return 1
  (( mask >= 0 && mask <= 32 )) || return 1

  for octet in $ip; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

download_and_validate_list() {
  local url="$1"
  local destination="$2"
  local label="$3"
  local raw_tmp clean_tmp line normalized valid_count old_count

  raw_tmp="$(mktemp)"
  clean_tmp="$(mktemp)"
  trap 'rm -f "$raw_tmp" "$clean_tmp"' RETURN

  log "Downloading ${label}: ${url}"
  curl -fsS --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 \
    "$url" -o "$raw_tmp"

  valid_count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    normalized="$(echo "$line" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$normalized" ]] || continue

    if validate_ipv4_cidr "$normalized"; then
      echo "$normalized" >> "$clean_tmp"
      valid_count=$(( valid_count + 1 ))
    else
      log "WARN ${label}: skip invalid entry '${normalized}'"
    fi
  done < "$raw_tmp"

  if (( valid_count == 0 )); then
    log "ERROR ${label}: no valid CIDR entries"
    return 1
  fi

  sort -Vu "$clean_tmp" -o "$clean_tmp"
  old_count="$(count_lines "$destination")"
  if (( old_count > 0 )); then
    local min_safe=$(( old_count * 70 / 100 ))
    if (( valid_count < min_safe )); then
      log "ERROR ${label}: too few entries after update (${valid_count} < ${min_safe})"
      return 1
    fi
  fi

  install -m 0644 "$clean_tmp" "$destination"
  log "${label} entries: ${valid_count}"
}

rebuild_ipset_from_file() {
  local target_set="$1"
  local tmp_set="$2"
  local file="$3"
  local label="$4"

  [[ -f "$file" ]] || {
    log "WARN ${label}: file not found: ${file}"
    return 1
  }

  ipset flush "$tmp_set"
  while IFS= read -r prefix || [[ -n "$prefix" ]]; do
    [[ -n "$prefix" ]] || continue
    ipset add "$tmp_set" "$prefix" -exist
  done < "$file"

  ipset swap "$tmp_set" "$target_set"
  ipset flush "$tmp_set"
  log "${label} loaded into ${target_set}"
}

delete_jump_if_exists() {
  local chain="$1"
  local proto="$2"
  local port="$3"

  while iptables -C "$chain" -p "$proto" --dport "$port" -j "$CHAIN_NAME" 2>/dev/null; do
    iptables -D "$chain" -p "$proto" --dport "$port" -j "$CHAIN_NAME"
  done
}

prepare_chains() {
  iptables -N "$PRECHECK_CHAIN" 2>/dev/null || true
  iptables -F "$PRECHECK_CHAIN"

  if bool_is_true "$ENABLE_TRAF_GUARD"; then
    if bool_is_true "$ENABLE_TRAF_GUARD_GOVERNMENT"; then
      iptables -A "$PRECHECK_CHAIN" -m set --match-set "$IPSET_GOV_NAME" src \
        -m limit --limit 30/min --limit-burst 10 \
        -j LOG --log-prefix "$GOV_LOG_PREFIX" --log-level 4
      iptables -A "$PRECHECK_CHAIN" -m set --match-set "$IPSET_GOV_NAME" src -j DROP
    fi
    if bool_is_true "$ENABLE_TRAF_GUARD_ANTISCANNER"; then
      iptables -A "$PRECHECK_CHAIN" -m set --match-set "$IPSET_ANTISCANNER_NAME" src \
        -m limit --limit 30/min --limit-burst 10 \
        -j LOG --log-prefix "$ANTISCANNER_LOG_PREFIX" --log-level 4
      iptables -A "$PRECHECK_CHAIN" -m set --match-set "$IPSET_ANTISCANNER_NAME" src -j DROP
    fi
  fi

  iptables -N "$CHAIN_NAME" 2>/dev/null || true
  iptables -F "$CHAIN_NAME"
  iptables -A "$CHAIN_NAME" -j "$PRECHECK_CHAIN"

  if bool_is_true "$ENABLE_MOBILE_ALLOW"; then
    # 1) ACCEPT mobile ASN IPs immediately
    iptables -A "$CHAIN_NAME" -m set --match-set "$IPSET_ALLOW_NAME" src -j ACCEPT

    if bool_is_true "$ENABLE_TELEGRAM"; then
      # 2) Fast-fail IPs that were already identified and deferred-blocked by the monitor
      iptables -A "$CHAIN_NAME" -p tcp -m set --match-set "$IPSET_DEFERRED_BLOCK_NAME" src \
        -j REJECT --reject-with tcp-reset
      iptables -A "$CHAIN_NAME" -p udp -m set --match-set "$IPSET_DEFERRED_BLOCK_NAME" src \
        -j REJECT --reject-with icmp-port-unreachable
      iptables -A "$CHAIN_NAME" -m set --match-set "$IPSET_DEFERRED_BLOCK_NAME" src -j DROP
      # 3) LOG non-mobile IPs but let them through so xray can log the user email
      if (( MOBILE443_MIN_NOTIFY_BYTES > 0 )); then
        # Log only after a non-mobile connection has spent enough bytes.
        # The monitor sends Telegram and schedules the deferred block from this log.
        iptables -A "$CHAIN_NAME" \
          -m connbytes --connbytes "${MOBILE443_MIN_NOTIFY_BYTES}:" --connbytes-dir both --connbytes-mode bytes \
          -m limit --limit 30/min --limit-burst 10 \
          -j LOG --log-prefix "$LOG_PREFIX" --log-level 4
      else
        iptables -A "$CHAIN_NAME" -m limit --limit 30/min --limit-burst 10 \
          -j LOG --log-prefix "$LOG_PREFIX" --log-level 4
      fi
      # No DROP here — connection passes to xray, monitor will add IP to deferred block
    else
      # Telegram disabled — immediate LOG + DROP as before
      iptables -A "$CHAIN_NAME" -m limit --limit 30/min --limit-burst 10 \
        -j LOG --log-prefix "$LOG_PREFIX" --log-level 4
      iptables -A "$CHAIN_NAME" -j DROP
    fi
  else
    iptables -A "$CHAIN_NAME" -j RETURN
  fi
}

attach_chain() {
  local chain port

  for port in "${PORT_LIST[@]}"; do
    for chain in INPUT FORWARD; do
      delete_jump_if_exists "$chain" tcp "$port"
      delete_jump_if_exists "$chain" udp "$port"
      iptables -I "$chain" 1 -p tcp --dport "$port" -j "$CHAIN_NAME"
      iptables -I "$chain" 1 -p udp --dport "$port" -j "$CHAIN_NAME"
    done

    if iptables -nL DOCKER-USER >/dev/null 2>&1; then
      delete_jump_if_exists DOCKER-USER tcp "$port"
      delete_jump_if_exists DOCKER-USER udp "$port"
      iptables -I DOCKER-USER 1 -p tcp --dport "$port" -j "$CHAIN_NAME"
      iptables -I DOCKER-USER 1 -p udp --dport "$port" -j "$CHAIN_NAME"
    fi
  done
}

apply_rules() {
  ensure_dirs
  ensure_ipsets
  prepare_chains
  attach_chain
}

send_tg() {
  local chat_id="$1"
  local text="$2"

  [[ -z "${TG_BOT_TOKEN:-}" ]] && return
  curl -sS --max-time 10 \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${chat_id}" \
    -d "text=${text}" \
    -d "parse_mode=HTML" >/dev/null 2>&1 || true
}

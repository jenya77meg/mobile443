#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/sbin/mobile443-common.sh

mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || {
  log "Another mobile443 job is already running"
  exit 0
}

ensure_deps
ensure_dirs
ensure_ipsets

if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_GOVERNMENT"; then
  rebuild_ipset_from_file "$IPSET_GOV_NAME" "$IPSET_GOV_TMP_NAME" "$GOV_LIST_FILE" "government_networks" || true
fi

if bool_is_true "$ENABLE_TRAF_GUARD" && bool_is_true "$ENABLE_TRAF_GUARD_ANTISCANNER"; then
  rebuild_ipset_from_file "$IPSET_ANTISCANNER_NAME" "$IPSET_ANTISCANNER_TMP_NAME" "$ANTISCANNER_LIST_FILE" "antiscanner" || true
fi

if bool_is_true "$ENABLE_MOBILE_ALLOW"; then
  if [[ -s "$ALLOW_CACHE_FILE" ]]; then
    rebuild_ipset_from_file "$IPSET_ALLOW_NAME" "$IPSET_ALLOW_TMP_NAME" "$ALLOW_CACHE_FILE" "mobile allowlist"
  else
    log "WARN mobile allowlist cache not found: $ALLOW_CACHE_FILE"
  fi
fi

apply_rules
log "Cache applied"

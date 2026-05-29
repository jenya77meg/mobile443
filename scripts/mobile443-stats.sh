#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/sbin/mobile443-common.sh

STATS_BLOCKED_FILE="${STATE_DIR}/stats_blocked.txt"

[[ "${ENABLE_TELEGRAM:-false}" == "true" ]] || exit 0
[[ -n "${TG_ADMIN_ID:-}" ]] || exit 0

total_blocked=0
unique_ips=0
top_ips=""

if [[ -f "$STATS_BLOCKED_FILE" && -s "$STATS_BLOCKED_FILE" ]]; then
  total_blocked=$(wc -l < "$STATS_BLOCKED_FILE" | tr -d ' ')
  unique_ips=$(awk '{print $3}' "$STATS_BLOCKED_FILE" | sort -u | wc -l | tr -d ' ')
  top_ips=$(awk '{print $3}' "$STATS_BLOCKED_FILE" | sort | uniq -c | sort -rn | head -10)
fi

allow_count=$(ipset list "$IPSET_ALLOW_NAME" 2>/dev/null | awk '/Number of entries/ {print $4}') || allow_count="N/A"
gov_count=$(ipset list "$IPSET_GOV_NAME" 2>/dev/null | awk '/Number of entries/ {print $4}') || gov_count="N/A"
antiscanner_count=$(ipset list "$IPSET_ANTISCANNER_NAME" 2>/dev/null | awk '/Number of entries/ {print $4}') || antiscanner_count="N/A"

msg="📊 <b>Статистика mobile443</b>
📅 Период: последние 24 часа

🚫 Заблокировано соединений: <b>${total_blocked}</b>
🌐 Уникальных заблокированных IP: <b>${unique_ips}</b>
📋 Mobile allowlist: <b>${allow_count}</b>
🛑 Traffic Guard government: <b>${gov_count}</b>
🛑 Traffic Guard antiscanner: <b>${antiscanner_count}</b>
🔌 Отслеживаемые порты: <b>${PORT_LIST[*]}</b>"

if [[ -n "$top_ips" ]]; then
  msg+="

🔝 <b>Топ заблокированных IP:</b>
<pre>${top_ips}</pre>"
fi

send_tg "$TG_ADMIN_ID" "$msg"

mv "$STATS_BLOCKED_FILE" "${STATS_BLOCKED_FILE}.prev" 2>/dev/null || true
touch "$STATS_BLOCKED_FILE"

log "Daily stats sent to admin (tg:${TG_ADMIN_ID})"

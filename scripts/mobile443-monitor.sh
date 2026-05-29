#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/sbin/mobile443-common.sh

NOTIFIED_FILE="${STATE_DIR}/notified.txt"
STATS_BLOCKED_FILE="${STATE_DIR}/stats_blocked.txt"
TG_ALERTS_FILE="${STATE_DIR}/tg_alerts.txt"
PENDING_BLOCK_DIR="${STATE_DIR}/pending_deferred"
NOTIFY_COOLDOWN=3600
DEFERRED_BLOCK_DELAY="${DEFERRED_BLOCK_DELAY:-30}"
ADMIN_ALERT_COOLDOWN=1800

mkdir -p "$STATE_DIR" "$PENDING_BLOCK_DIR"
rm -f "$PENDING_BLOCK_DIR"/*
touch "$NOTIFIED_FILE" "$STATS_BLOCKED_FILE" "$TG_ALERTS_FILE"

should_notify() {
  local key="$1"
  local now last_notified diff

  now=$(date +%s)
  last_notified=$(grep "^${key} " "$NOTIFIED_FILE" 2>/dev/null | tail -1 | awk '{print $2}') || true

  if [[ -z "$last_notified" ]]; then
    return 0
  fi

  diff=$(( now - last_notified ))
  [[ $diff -ge $NOTIFY_COOLDOWN ]]
}

mark_notified() {
  local key="$1"
  local now tmp_file

  now=$(date +%s)
  tmp_file="$(mktemp)"
  grep -v "^${key} " "$NOTIFIED_FILE" > "$tmp_file" 2>/dev/null || true
  echo "${key} ${now}" >> "$tmp_file"
  install -m 0644 "$tmp_file" "$NOTIFIED_FILE"
  rm -f "$tmp_file"
}

should_notify_admin_alert() {
  local key="$1"
  local now last_notified diff

  now=$(date +%s)
  last_notified=$(grep "^${key} " "$TG_ALERTS_FILE" 2>/dev/null | tail -1 | awk '{print $2}') || true

  if [[ -z "$last_notified" ]]; then
    return 0
  fi

  diff=$(( now - last_notified ))
  [[ $diff -ge $ADMIN_ALERT_COOLDOWN ]]
}

mark_admin_alert() {
  local key="$1"
  local now tmp_file

  now=$(date +%s)
  tmp_file="$(mktemp)"
  grep -v "^${key} " "$TG_ALERTS_FILE" > "$tmp_file" 2>/dev/null || true
  echo "${key} ${now}" >> "$tmp_file"
  install -m 0644 "$tmp_file" "$TG_ALERTS_FILE"
  rm -f "$tmp_file"
}

find_xray_line_by_ip() {
  local ip="$1"
  [[ -z "${XRAY_ACCESS_LOG:-}" || ! -f "${XRAY_ACCESS_LOG:-}" ]] && return

  tail -n 50000 "$XRAY_ACCESS_LOG" 2>/dev/null     | grep -Fw "$ip"     | tail -1 || true
}

xray_line_is_healthcheck() {
  local line="$1"

  [[ "$line" == *"tcp:www.gstatic.com:443"*     || "$line" == *"tcp:www.google.com:443"*     || "$line" == *"tcp:connectivitycheck.gstatic.com:443"*     || "$line" == *"generate_204"* ]]
}

extract_email_from_xray_line() {
  local line="$1"
  echo "$line" | grep -oP 'email:\s*\K\S+' | tail -1 || true
}

find_user_by_ip() {
  local ip="$1"
  local line

  line=$(find_xray_line_by_ip "$ip")
  extract_email_from_xray_line "$line"
}

get_remnawave_user() {
  local user_id="$1"
  [[ -z "${REMNAWAVE_API_URL:-}" || -z "${REMNAWAVE_API_TOKEN:-}" ]] && return

  curl -sS --max-time 10 \
    -H "Authorization: Bearer ${REMNAWAVE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "${REMNAWAVE_API_URL}/api/users/by-id/${user_id}" 2>/dev/null || true
}

extract_tg_id() {
  local api_response="$1"
  local tg_id="" username=""

  if [[ "${TG_ID_SOURCE:-telegramId}" == "username" ]]; then
    username=$(echo "$api_response" | jq -r '.response.username // empty' 2>/dev/null)
    if [[ -n "$username" ]]; then
      tg_id=$(echo "$username" | rev | cut -d'_' -f1 | rev)
    fi
  elif [[ "${TG_ID_SOURCE:-telegramId}" == "username_custom" ]]; then
    username=$(echo "$api_response" | jq -r '.response.username // empty' 2>/dev/null)
    if [[ -n "$username" ]]; then
      if [[ -z "${TG_USERNAME_SEPARATOR:-}" ]]; then
        tg_id="$username"
      else
        tg_id=$(echo "$username" | rev | cut -d"${TG_USERNAME_SEPARATOR}" -f1 | rev)
      fi
    fi
  else
    tg_id=$(echo "$api_response" | jq -r '.response.telegramId // empty' 2>/dev/null)
  fi

  echo "$tg_id"
}

add_to_deferred_block() {
  local ip="$1"
  ipset add "$IPSET_DEFERRED_BLOCK_NAME" "$ip" timeout 3600 -exist 2>/dev/null || true
  log "Added ${ip} to deferred block ipset for 1 hour"
}

schedule_deferred_block() {
  local ip="$1"
  local delay="${DEFERRED_BLOCK_DELAY:-30}"
  local marker="${PENDING_BLOCK_DIR}/${ip}"

  if ipset test "$IPSET_DEFERRED_BLOCK_NAME" "$ip" >/dev/null 2>&1; then
    log "Deferred block already active for ${ip}"
    return
  fi

  if ! ( set -o noclobber; : > "$marker" ) 2>/dev/null; then
    log "Deferred block already scheduled for ${ip}"
    return
  fi

  log "Scheduling ${ip} for deferred block in ${delay}s"
  (
    sleep "$delay"
    add_to_deferred_block "$ip"
    rm -f "$marker"
  ) &
}

find_xray_line_by_ip_with_retry() {
  local ip="$1"
  local retries=5
  local delay=1
  local attempt line email

  for (( attempt=1; attempt<=retries; attempt++ )); do
    line=$(find_xray_line_by_ip "$ip")
    email=$(extract_email_from_xray_line "$line")
    if [[ -n "$email" ]]; then
      echo "$line"
      return
    fi
    if (( attempt < retries )); then
      sleep "$delay"
    fi
  done
}

find_user_by_ip_with_retry() {
  local ip="$1"
  local line

  line=$(find_xray_line_by_ip_with_retry "$ip")
  extract_email_from_xray_line "$line"
}

process_blocked() {
  local src_ip="$1"
  local dst_port="$2"
  local now_ts xray_line email api_response has_response tg_id msg

  now_ts=$(date '+%F %T')
  echo "${now_ts} ${src_ip} ${dst_port}" >> "$STATS_BLOCKED_FILE"

  [[ "${ENABLE_TELEGRAM:-false}" == "true" ]] || return

  # Wait for the IP to appear in xray access.log (connection is allowed through first)
  xray_line=$(find_xray_line_by_ip_with_retry "$src_ip")
  email=$(extract_email_from_xray_line "$xray_line")
  if [[ -z "$email" ]]; then
    # Do not add to deferred block if NOT found. 
    # This gives slow connections time to establish and appear in access.log on the next log trigger.
    return
  fi

  # Connectivity probes should not notify users or put the IP into deferred block.
  if xray_line_is_healthcheck "$xray_line"; then
    log "Blocked ${src_ip}:${dst_port} - health-check probe for user '${email}', notification skipped"
    return
  fi


  api_response=$(get_remnawave_user "$email")
  if [[ -z "$api_response" ]]; then
    log "Blocked ${src_ip}:${dst_port} - failed to get user '${email}' from Remnawave API"
    schedule_deferred_block "$src_ip"
    return
  fi

  has_response=$(echo "$api_response" | jq -r '.response // empty' 2>/dev/null)
  if [[ -z "$has_response" || "$has_response" == "null" ]]; then
    log "Blocked ${src_ip}:${dst_port} - user '${email}' not found in Remnawave panel"
    schedule_deferred_block "$src_ip"
    return
  fi

  tg_id=$(extract_tg_id "$api_response")
  if [[ -z "$tg_id" || "$tg_id" == "null" ]]; then
    log "Blocked ${src_ip}:${dst_port} - user '${email}' has no telegram ID (source: ${TG_ID_SOURCE:-telegramId})"
    schedule_deferred_block "$src_ip"
    return
  fi

  if should_notify "$tg_id"; then
    if [[ -n "${TG_CUSTOM_MESSAGE:-}" ]]; then
      msg="${TG_CUSTOM_MESSAGE//\{ip\}/${src_ip}}"
      msg="$(printf '%b' "$msg")"
    else
      msg="⚠️ <b>Внимание!</b>

Соединение с IP <code>${src_ip}</code> было прервано. 

Данный сервер предназначен <b>исключительно для обхода мобильных глушилок</b>, подключение через Wi-Fi не поддерживается, и соединения будут разрываться автоматически.

Пожалуйста, переключитесь на <b>мобильный интернет</b> (МТС, Билайн, МегаФон, Tele2, Ростелеком, и др.) для стабильной работы."

    fi
    send_tg "$tg_id" "$msg"
    mark_notified "$tg_id"
    log "Notified tg:${tg_id} (${email}) about blocked IP ${src_ip}"
  else
    log "Blocked ${src_ip}:${dst_port} - tg:${tg_id} already notified recently"
  fi

  schedule_deferred_block "$src_ip"
}

process_traf_guard_alert() {
  local src_ip="$1"
  local dst_port="$2"
  local reason="$3"
  local key msg

  echo "$(date '+%F %T') ${src_ip} ${dst_port} ${reason}" >> "$STATS_BLOCKED_FILE"

  [[ "${ENABLE_TELEGRAM:-false}" == "true" ]] || return
  [[ -n "${TG_ADMIN_ID:-}" ]] || return

  key="${reason}_${src_ip}_${dst_port}"
  if ! should_notify_admin_alert "$key"; then
    log "Traffic Guard alert suppressed for ${src_ip}:${dst_port} (${reason})"
    return
  fi

  msg="🚨 <b>Traffic Guard alert</b>

Попытка подключения с IP <code>${src_ip}</code> к порту <code>${dst_port}</code>.

Причина блокировки: <b>${reason}</b>."

  send_tg "$TG_ADMIN_ID" "$msg"
  mark_admin_alert "$key"
  log "Traffic Guard alert sent for ${src_ip}:${dst_port} (${reason})"
}

get_log_stream() {
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -k -f -n 0 --no-pager 2>/dev/null
  elif [[ -f /var/log/kern.log ]]; then
    tail -F /var/log/kern.log
  elif [[ -f /var/log/syslog ]]; then
    tail -F /var/log/syslog
  else
    log "ERROR: Cannot find kernel log source"
    exit 1
  fi
}

log "Monitor started, watching for blocked connections..."

get_log_stream | while IFS= read -r line; do
  if [[ "$line" == *"$LOG_PREFIX"* || "$line" == *"$GOV_LOG_PREFIX"* || "$line" == *"$ANTISCANNER_LOG_PREFIX"* ]]; then
    src_ip=""
    dst_port=""
    reason=""

    if [[ "$line" =~ SRC=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
      src_ip="${BASH_REMATCH[1]}"
    fi

    if [[ "$line" =~ DPT=([0-9]+) ]]; then
      dst_port="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$src_ip" && -n "$dst_port" ]]; then
      if [[ "$line" == *"$GOV_LOG_PREFIX"* ]]; then
        reason="government_networks"
        process_traf_guard_alert "$src_ip" "$dst_port" "$reason"
      elif [[ "$line" == *"$ANTISCANNER_LOG_PREFIX"* ]]; then
        reason="antiscanner"
        process_traf_guard_alert "$src_ip" "$dst_port" "$reason"
      else
        process_blocked "$src_ip" "$dst_port"
      fi
    fi
  fi
done

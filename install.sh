#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID:-}" -ne 0 ]]; then
  echo "Запустите от root: sudo $0" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -d -m 0755 /opt/mobile443/lists
install -d -m 0755 /var/lib/mobile443
install -m 0755 "${ROOT}"/scripts/mobile443-*.sh /usr/local/sbin/

if [[ ! -f /opt/mobile443/config.conf ]]; then
  install -m 0600 "${ROOT}/config.conf.example" /opt/mobile443/config.conf
  echo "Создан /opt/mobile443/config.conf — отредактируйте перед использованием."
fi

if [[ ! -f /opt/mobile443/asns.conf ]]; then
  install -m 0644 "${ROOT}/examples/asns.conf.example" /opt/mobile443/asns.conf
fi

install -m 0644 "${ROOT}"/systemd/* /etc/systemd/system/
systemctl daemon-reload

if [[ ! -f /etc/sysctl.d/99-mobile443.conf ]]; then
  echo 'net.netfilter.nf_conntrack_acct = 1' > /etc/sysctl.d/99-mobile443.conf
  sysctl -p /etc/sysctl.d/99-mobile443.conf
fi

echo "Установка завершена. Настройте /opt/mobile443/config.conf, затем:"
echo "  systemctl enable --now mobile443-apply.service mobile443-monitor.service"
echo "  systemctl enable --now mobile443-update.timer mobile443-stats.timer"
echo "  systemctl start mobile443-update.service"

# mobile443

Файрвол и мониторинг для нод Remnawave/Xray с LTE/мобильными входами на портах **443** и **8443**.

Клиенты не с мобильного интернета (домашний Wi‑Fi, проводной канал) определяются по ASN allowlist, при необходимости блокируются через iptables и получают уведомление в Telegram. Есть интеграция с API Remnawave для `telegramId` пользователя.

## Возможности

- **Allowlist мобильных ASN** — префиксы подтягиваются из RIPEstat по ASN из `asns.conf`
- **Traffic Guard** — списки government и antiscanner (ipset + iptables precheck)
- **Отложенная блокировка** — временный DROP после уведомления в Telegram (задержка настраивается)
- **Порог по трафику** — `MOBILE443_MIN_NOTIFY_BYTES` откладывает лог/уведомление, пока одно соединение не превысит N байт (меньше ложных срабатываний от health check)
- **Фильтр health check** — не шлёт уведомления по «пробным» строкам access.log Xray
- **Telegram** — уведомления пользователям и ежедневная статистика админу

## Требования

- Linux: `iptables`, `ipset`, `curl`, `jq`, `flock`
- Установка от root
- Нода Remnawave с access.log по пути из `config.conf`
- По желанию: API-токен панели Remnawave для поиска пользователей

## Быстрая установка

```bash
git clone https://github.com/jenya77meg/mobile443.git
cd mobile443
sudo ./install.sh
sudo cp config.conf.example /opt/mobile443/config.conf
sudo nano /opt/mobile443/config.conf
sudo cp examples/asns.conf.example /opt/mobile443/asns.conf
sudo systemctl enable --now mobile443-apply.service mobile443-monitor.service
sudo systemctl enable --now mobile443-update.timer mobile443-stats.timer
sudo mobile443-update.sh   # или: systemctl start mobile443-update.service
```

## Структура на сервере

| Путь | Назначение |
|------|------------|
| `/opt/mobile443/config.conf` | Секреты и переключатели (не в git) |
| `/opt/mobile443/asns.conf` | Разрешённые мобильные ASN |
| `/opt/mobile443/lists/` | Скачанные blocklist |
| `/var/lib/mobile443/` | Состояние, кэши, cooldown уведомлений |
| `/usr/local/sbin/mobile443-*.sh` | Скрипты |

## Настройка

См. [`config.conf.example`](config.conf.example). Для Telegram и поиска пользователей в Remnawave нужны:

- `TG_BOT_TOKEN`, `TG_ADMIN_ID`
- `REMNAWAVE_API_URL`, `REMNAWAVE_API_TOKEN`
- `XRAY_ACCESS_LOG`

Для порога по объёму трафика включите учёт байт соединений:

```bash
sudo sysctl -w net.netfilter.nf_conntrack_acct=1
echo 'net.netfilter.nf_conntrack_acct = 1' | sudo tee /etc/sysctl.d/99-mobile443.conf
```

## Сервисы systemd

| Unit | Назначение |
|------|------------|
| `mobile443-apply.service` | Применить ipset/iptables из кэша |
| `mobile443-monitor.service` | Следить за логом ядра / уведомлять пользователей |
| `mobile443-update.service` | Обновить allowlist и списки |
| `mobile443-update.timer` | Ежедневно в 00:00 UTC |
| `mobile443-stats.timer` | Статистика админу в 09:00 UTC |

## Лицензия

MIT — см. [LICENSE](LICENSE).

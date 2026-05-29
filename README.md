# mobile443

Firewall and monitoring stack for Remnawave/Xray nodes that expose LTE/mobile-only endpoints on ports **443** and **8443**.

Non-mobile clients (home Wi‑Fi, fixed broadband) are detected via ASN allowlists, optionally blocked with iptables, and notified in Telegram. Integrates with Remnawave API for per-user `telegramId`.

## Features

- **Mobile ASN allowlist** — prefixes fetched from RIPEstat for ASNs listed in `asns.conf`
- **Traffic Guard** — government and antiscanner blocklists (ipset + iptables precheck)
- **Deferred block** — temporary drop after Telegram notification (configurable delay)
- **Volume threshold** — `MOBILE443_MIN_NOTIFY_BYTES` delays log/notify until a connection exceeds N bytes (reduces false positives from health checks)
- **Health-check filter** — skips notifications for probe-like Xray access log lines
- **Telegram** — user notifications and daily admin stats

## Requirements

- Linux with `iptables`, `ipset`, `curl`, `jq`, `flock`
- Root for install
- Remnawave node with access log at path configured in `config.conf`
- Optional: Remnawave Panel API token for resolving users

## Quick install

```bash
git clone https://github.com/jenya77meg/mobile443.git
cd mobile443
sudo ./install.sh
sudo cp config.conf.example /opt/mobile443/config.conf
sudo nano /opt/mobile443/config.conf
sudo cp examples/asns.conf.example /opt/mobile443/asns.conf
sudo systemctl enable --now mobile443-apply.service mobile443-monitor.service
sudo systemctl enable --now mobile443-update.timer mobile443-stats.timer
sudo mobile443-update.sh   # or: systemctl start mobile443-update.service
```

## Layout on server

| Path | Purpose |
|------|---------|
| `/opt/mobile443/config.conf` | Secrets and toggles (not in git) |
| `/opt/mobile443/asns.conf` | Allowed mobile ASNs |
| `/opt/mobile443/lists/` | Downloaded blocklists |
| `/var/lib/mobile443/` | Runtime state, caches, notify cooldown |
| `/usr/local/sbin/mobile443-*.sh` | Scripts |

## Configuration

See [`config.conf.example`](config.conf.example). Required for Telegram + Remnawave user lookup:

- `TG_BOT_TOKEN`, `TG_ADMIN_ID`
- `REMNAWAVE_API_URL`, `REMNAWAVE_API_TOKEN`
- `XRAY_ACCESS_LOG`

Enable connection byte accounting for the volume threshold:

```bash
sudo sysctl -w net.netfilter.nf_conntrack_acct=1
echo 'net.netfilter.nf_conntrack_acct = 1' | sudo tee /etc/sysctl.d/99-mobile443.conf
```

## Services

| Unit | Role |
|------|------|
| `mobile443-apply.service` | Apply ipset/iptables from cache |
| `mobile443-monitor.service` | Tail kernel log / notify users |
| `mobile443-update.service` | Refresh allowlists and lists |
| `mobile443-update.timer` | Daily 00:00 UTC |
| `mobile443-stats.timer` | Daily stats 09:00 UTC |

## License

MIT — see [LICENSE](LICENSE).

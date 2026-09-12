# Быстрый старт: только Traffic Guard

Режим для ноды с VPN/сайтом на порту **443**, в том числе WA. Блокируются входящие IPv4-адреса из двух списков Traffic Guard. Ограничение по мобильным операторам, порог трафика и отложенные баны выключены. Остальные адреса проходят к последующим правилам существующего firewall: Traffic Guard сам не открывает порт, который там закрыт.

Домашний интернет, Wi-Fi и мобильные сети обрабатываются одинаково. Совпадение со списком блокируется сразу в ядре, без монитора и очереди.

## 1. Новая установка на Ubuntu/Debian

Команды выполняются **на целевом сервере от root** (`sudo -i`). Если `/opt/mobile443/config.conf` уже существует, используйте раздел [перехода с установленного mobile443](#переход-с-установленного-mobile443).

```bash
set -e
test ! -e /opt/mobile443/config.conf

apt-get update
apt-get install -y git curl iptables ipset jq util-linux
git clone https://github.com/jenya77meg/mobile443.git /opt/mobile443-repo
cd /opt/mobile443-repo

./install.sh
install -m 0600 examples/config.traffic-guard-only.conf /opt/mobile443/config.conf

# Фоновые уведомления не нужны для самого firewall.
systemctl disable --now mobile443-monitor.service mobile443-stats.timer
systemctl stop mobile443-stats.service

# Сначала скачать списки и применить правила; при ошибке set -e остановит блок.
systemctl start mobile443-update.service

# Восстановление из кэша после загрузки и дальнейшее обновление списков.
systemctl enable mobile443-apply.service
systemctl enable --now mobile443-update.timer
```

`install.sh` копирует файлы и включает учёт байтов conntrack, но сам не запускает фильтрацию. Первое применение выполняет `mobile443-update.service` после загрузки списков. Файл `asns.conf`, созданный установщиком, в этом режиме не используется. `jq` установлен для совместимости с общим установщиком/скриптами; обновлению только Traffic Guard он не нужен.

Готовый профиль задаёт `PORTS="443"`: правила добавляются для TCP и UDP этого порта в `INPUT`, `FORWARD` и, если цепочка существует, `DOCKER-USER`. Другие порты, например 22/2222, в этот профиль не включены. Для другого VPN-порта измените `PORTS` **до первого запуска**.

## 2. Что включить и выключить

Полный профиль: [`examples/config.traffic-guard-only.conf`](../examples/config.traffic-guard-only.conf).

| Настройка | Значение | Действие |
|---|---|---|
| `ENABLE_TRAF_GUARD` | `true` | Включить проверку Traffic Guard |
| `ENABLE_TRAF_GUARD_GOVERNMENT` | `true` | Включить `government_networks.list` |
| `ENABLE_TRAF_GUARD_ANTISCANNER` | `true` | Включить `antiscanner.list` |
| `ENABLE_MOBILE_ALLOW` | **`false`** | Отключить мобильный allowlist, порог и mobile-баны |
| `ENABLE_TELEGRAM`, `TG_ENABLED` | `false` | Не отправлять уведомления |
| `RELAY_MODE` | `false` | В этом профиле не задействован |

`INSTALL_PROFILE` сейчас не используется установщиком или скриптами для выбора режима. Режим задают перечисленные флаги. `MOBILE443_MIN_NOTIFY_BYTES`, `DEFERRED_BLOCK_DELAY`, `XRAY_ACCESS_LOG` и токен Remnawave для Traffic Guard без уведомлений не нужны.

**Не выключайте только Telegram при оставленном `ENABLE_MOBILE_ALLOW="true"`: это включает немедленный DROP адресов вне мобильного allowlist.** Для Traffic Guard без ограничений операторов обязательно `ENABLE_MOBILE_ALLOW="false"`.

| Служба или таймер | Нужное состояние |
|---|---|
| `mobile443-apply.service` | `enabled`: восстановление списков и правил из кэша при загрузке |
| `mobile443-update.timer` | `enabled`, `active`: ежедневное обновление |
| `mobile443-update.service` | Запускается таймером или вручную; это oneshot |
| `mobile443-monitor.service` | `disabled`, `inactive` без уведомлений |
| `mobile443-stats.timer` | `disabled`, `inactive` без уведомлений |

После успешного завершения oneshot-служба может показывать `inactive (dead)` — проверяйте её `Result` и `ExecMainStatus`. У таймера `OnCalendar=*-*-* 00:00:00`: запуск в полночь **в часовом поясе сервера**. Точное следующее время показывает `systemctl list-timers mobile443-update.timer`.

## 3. Активные блоклисты и откуда берутся ASN

В готовом профиле включены ровно эти два источника из репозитория [shadow-netlab/traffic-guard-lists](https://github.com/shadow-netlab/traffic-guard-lists):

| Список | Прямая ссылка | Кэш на сервере | Активный ipset |
|---|---|---|---|
| Сети, отнесённые автором списка к государственным/аффилированным организациям | [government_networks.list](https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list) | `/opt/mobile443/lists/government_networks.list` | `traf_guard_government` |
| Адреса и сети антисканера | [antiscanner.list](https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list) | `/opt/mobile443/lists/antiscanner.list` | `traf_guard_antiscanner` |

На проверке 13 сентября 2026 года оба URL отвечали HTTP 200. После удаления повторов и неподдерживаемых записей получалось **2784 IPv4-префикса government** и **155 IPv4-префиксов antiscanner**. Размеры меняются с обновлениями; актуальное состояние — содержимое ipset на вашей ноде.

**Traffic Guard в mobile443 загружает готовые IP/CIDR, а не получает «все ASN для блокировки».** В исходном `government_networks.list` есть комментарии с ASN и названиями организаций. Блокируются только перечисленные под ними подсети: упоминание, например, AS12389 не означает автоматической блокировки всех сетей этого ASN. `antiscanner.list` содержит адреса/подсети без отдельного перечня ASN. Источник данных и критерии ведения описаны в [README автора списков](https://github.com/shadow-netlab/traffic-guard-lists#readme).

`/opt/mobile443/asns.conf` — другой механизм: это **разрешающий** список мобильных ASN. Только при `ENABLE_MOBILE_ALLOW="true"` скрипт запрашивает их анонсируемые сети через `https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS<номер>`. В режиме Traffic Guard этот запрос не выполняется, файл `asns.conf` не определяет блокировки.

Скачанный файл очищается от комментариев, проверяется и загружается через временный ipset с `swap`. Пустой результат и слишком сильное сокращение списка отклоняются. Исходники могут содержать IPv6, но текущая реализация mobile443 загружает только IPv4 и применяет правила через `iptables`; IPv6 этим профилем не защищён.

В `config.conf.example` используется `shadow-netlab`, а резервный URL в `scripts/mobile443-common.sh` пока содержит старое имя `wh3r3ar3you`. Поэтому готовый профиль задаёт три URL-переменные явно. Если заданы `GOV_LIST_URL` и `ANTISCANNER_LIST_URL`, изменение только `TRAF_GUARD_BASE_URL` не заменяет эти отдельные адреса.

Посмотреть именно **эффективные URL** установленной копии, не выводя токены из конфига:

```bash
bash -c '
source /usr/local/sbin/mobile443-common.sh
printf "government: %s\nantiscanner: %s\n" "$GOV_LIST_URL" "$ANTISCANNER_LIST_URL"
'
```

## 4. Проверка после запуска

```bash
systemctl show mobile443-update.service -p Result -p ExecMainStatus
systemctl is-enabled mobile443-apply.service mobile443-update.timer
systemctl list-timers mobile443-update.timer
journalctl -u mobile443-update.service -n 30 --no-pager

ipset list traf_guard_government | sed -n '1,/^Members:/p'
ipset list traf_guard_antiscanner | sed -n '1,/^Members:/p'
iptables -S TRAF_GUARD_PRECHECK
iptables -S FILTER_MOBILE_443
iptables -S INPUT | grep FILTER_MOBILE_443
```

Ожидается `Result=success`, `ExecMainStatus=0`, непустые два ipset и цепочка `FILTER_MOBILE_443` с переходом в `TRAF_GUARD_PRECHECK`, затем `RETURN`. В ней не должно быть разрешения `allowed_mobile_443`, порогового `connbytes` или ссылок на `mobile443_deferred_block`. В `TRAF_GUARD_PRECHECK` должны быть правила `DROP` для обоих включённых наборов.

При подключении через TCP-мост нода проверяет IP **моста**, который видит firewall. Чтобы проверить конкретный адрес панели или моста:

```bash
read -r -p 'IP панели или моста: ' CHECK_IP
ipset test traf_guard_government "$CHECK_IP" || true
ipset test traf_guard_antiscanner "$CHECK_IP" || true
```

Если адрес входит в набор, соединения с него на защищаемый порт будут блокироваться. Мобильный `asns.conf` не является исключением из Traffic Guard. Отдельные установленные ранее цепочки вроде `SCANNERS-BLOCK` и наборы `SCANNERS-BLOCK-V4`/`SCANNERS-BLOCK-V6` этим профилем не управляются и могут продолжать блокировать независимо.

После перезагрузки или изменения UFW/Docker повторно проверьте наличие переходов в цепочки. Для повторного применения сохранённых списков используйте `systemctl start mobile443-apply.service`.

## Переход с установленного mobile443

Для существующей установки **не заменяйте весь конфиг профилем**: сохраните свои URL и другие настройки. На работающем сервере выполняйте команды последовательно от root.

```bash
set -e
backup_dir="/opt/mobile443/backups/traffic-guard-only-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$backup_dir"
cp -a /opt/mobile443/config.conf "$backup_dir/config.conf"
iptables-save > "$backup_dir/iptables.rules"

systemctl disable --now mobile443-monitor.service mobile443-stats.timer mobile443-update.timer
systemctl stop mobile443-stats.service
# Дождаться уже запущенного обновления/применения после остановки таймера.
flock /var/lib/mobile443/lock true
```

Измените `/opt/mobile443/config.conf` по таблице флагов выше. **Сохраните прежнее `PORTS` при этом переходе:** старые переходы для исключённых портов автоматически не удаляются. Изменение набора защищаемых портов выполняйте отдельно с проверкой `INPUT`, `FORWARD` и `DOCKER-USER`.

Затем обновите списки и перепримените правила:

```bash
set -e
systemctl start mobile443-update.service
systemctl enable mobile443-apply.service
systemctl enable --now mobile443-update.timer
```

Выполните проверки из раздела выше. После успешного применения правила больше не ссылаются на mobile-ban ipset; старые записи в нём не участвуют в этом фильтре. Просто остановить монитор или поменять конфиг недостаточно — ранее установленные правила остаются до переприменения. Если загрузка не удалась, команда завершится ошибкой и старые правила могут остаться активными; проверьте журнал, не считайте переход завершённым.

## Только административные уведомления — по желанию

Для самого Traffic Guard этот раздел не нужен. Если требуются уведомления об адресах из двух блоклистов, сохраните `ENABLE_MOBILE_ALLOW="false"`, выставьте `ENABLE_TELEGRAM="true"`, заполните `TG_BOT_TOKEN` и `TG_ADMIN_ID`, затем выполните:

```bash
systemctl enable mobile443-monitor.service
systemctl restart mobile443-monitor.service
```

API Remnawave и локальный `access.log` для таких уведомлений не требуются. `mobile443-stats.timer` включайте отдельно, только если нужна ежедневная сводка. Отправка уведомлений может ждать сеть; сами блокировки Traffic Guard выполняются независимо и сразу.

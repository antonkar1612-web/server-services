# server-services

Docker Compose и скрипты управления сервисами.

## Структура

    scripts/
      wg-manager.sh           — управление WireGuard
      wg-manager.env.example  — пример (~/secrets/wg-manager.env)
      backup-all.sh           — бэкап секретов + WG + docker volumes
      backup.env.example      — пример (~/secrets/backup.env)
    docs/
      prompt.md               — контекст для нового чата

## wg-manager.sh

    sudo ./scripts/wg-manager.sh <команда>

Команды: init, adopt, add, remove, list, qr, qr-term, export,
reload, show, status, mail, config.

Зависит от `/root/secrets/server-infra.env` (SERVER_IP, WG_PORT,
WG_NETWORK — создан `bootstrap.sh` из репозитория `server-infra`).

## update-all.sh

    sudo ./scripts/update-all.sh [--apt-only|--docker-only|--dry-run]

Обновление: `apt update && upgrade` + `docker compose pull && up -d` во
всех каталогах из `COMPOSE_DIRS`. Лог: `/var/log/update-all.log`.
Конфиг: `/root/secrets/update.env` (опционально).

## healthcheck.sh

    sudo ./scripts/healthcheck.sh [--quiet]

Сводка: docker, wg, ufw, fail2ban, диск, RAM, load, systemd.
Exit 1 если есть проблемы. `--quiet` — только проблемы.

## wg-include-blocked.sh — VPN только для заблокированных

    sudo ./scripts/wg-include-blocked.sh --update   # собрать CIDR
    sudo ./scripts/wg-include-blocked.sh --apply    # применить

Через VPN идёт **только** трафик к заблокированным в РФ ресурсам:
Telegram, Discord, YouTube/Google, Meta, Twitter/X. Остальное (Yandex,
Mail.ru, Госуслуги, банки) — напрямую через провайдера.

**Плюсы:** IP провайдера не «засвечен» на зарубежных ресурсах, обычные
сайты работают с российской скоростью, не нужно бояться блокировки за
использование VPN.

**Списки:** встроены в скрипт (Telegram, Discord, Google, Meta, Twitter).
Дополнять — в переменных `TELEGRAM_CIDR`, `DISCORD_CIDR` и т.д.
Или включить `EXTERNAL_SOURCES` (например, V3nilla/IPSets-For-Bypass).

**Альтернатива:** `wg-exclude-ru.sh` — обратная стратегия (через VPN всё,
кроме РФ). Использовать, если нужно скрыть весь зарубежный трафик.

## backup-all.sh

    sudo ./scripts/backup-all.sh

Бэкап: `/root/secrets/`, `/etc/wireguard/`, docker volumes.
Результат: `/var/backups/server-services/`, ротация (`KEEP_DAYS=14`).
Конфиг: `/root/secrets/backup.env` (опционально).

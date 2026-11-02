# server-services

Docker Compose и скрипты управления сервисами. Прикладной слой поверх
[`server-infra`](https://github.com/antonkar1612-web/server-infra).

## Структура

    docker-compose.yml        — Portainer (loopback 127.0.0.1:9000)
    scripts/
      backup-all.sh           — бэкап секретов + docker volumes
      backup.env.example      — пример (~/secrets/backup.env)
      update-all.sh           — apt + docker compose
      update.env.example      — пример (~/secrets/update.env)
      healthcheck.sh          — сводка состояния
      extra.zone.example      — доп. домены для WG-скриптов (не используется)
      wg-manager.sh           — WireGuard (НЕ используется по умолчанию)
      wg-manager.env.example  — пример (~/secrets/wg-manager.env)
      wg-exclude-ru.sh        — WireGuard split-tunnel (НЕ используется)
      wg-include-blocked.sh   — WireGuard VPN для заблокированных (НЕ используется)
    docs/
      prompt.md               — контекст для нового чата

## docker-compose.yml — Portainer

Portainer CE слушает **только loopback** `127.0.0.1:9000` — наружу не
открыт, UFW-правил не требует. Доступ через SSH-туннель с локальной
машины:

    ssh -L 9000:localhost:9000 anton@<SERVER_IP>

Затем в браузере: <http://localhost:9000>. При первом входе задать
admin-пароль (хранить в менеджере паролей, в Git не коммитить).

Volume: `server-services_portainer_data` — попадает в `backup-all.sh`
через `DOCKER_VOLUMES` в `/root/secrets/backup.env`.

## update-all.sh

    sudo ./scripts/update-all.sh [--apt-only|--docker-only|--dry-run]

Обновление: `apt update && upgrade` + `docker compose pull && up -d` во
всех каталогах из `COMPOSE_DIRS`. Лог: `/var/log/update-all.log`.
Конфиг: `/root/secrets/update.env` (опционально).

Пример `/root/secrets/update.env`:

    COMPOSE_DIRS="/root/server-services"
    APT_AUTOREMOVE=true
    DOCKER_PRUNE=false

## healthcheck.sh

    sudo ./scripts/healthcheck.sh [--quiet]

Сводка: docker, ufw, fail2ban, диск, RAM, load, systemd.
Проверка WireGuard выводит warning, если WG не установлен — это **норма**
для развёртываний без WG. `--quiet` — только проблемы.

## backup-all.sh

    sudo ./scripts/backup-all.sh

Бэкап: `SOURCES` (по умолчанию `/root/secrets`) + docker volumes из
`DOCKER_VOLUMES`. Результат: `/var/backups/server-services/`, ротация
(`KEEP_DAYS=14`). Конфиг: `/root/secrets/backup.env` (опционально).

Пример `/root/secrets/backup.env`:

    BACKUP_DIR=/var/backups/server-services
    KEEP_DAYS=14
    MIN_FREE_MB=500
    SOURCES="/root/secrets"
    DOCKER_VOLUMES="server-services_portainer_data"

## WireGuard-скрипты (опционально, не используются по умолчанию)

`wg-manager.sh`, `wg-exclude-ru.sh`, `wg-include-blocked.sh` — для
развёртываний с WireGuard (запуск `server-infra/bootstrap.sh` **без**
`INSTALL_WG=no`). В текущем развёртывании WG не установлен, скрипты
не запускаются. При запуске без WG `backup-all.sh` и `healthcheck.sh`
корректно работают — просто пропускают WG-часть.

## Правила

- Секреты — только `/root/secrets/`, никогда в Git.
- Все скрипты идемпотентны, `bash -n` чист.
- Compose-файлы — в каталоге, указанном в `COMPOSE_DIRS`.

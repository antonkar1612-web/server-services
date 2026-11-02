# Промт-блок для нового чата (server-services v0.5.0)

Вставьте блок ниже в начало чата с ассистентом.

## Контекст: server-services (прикладной слой) — v0.5.0

- Репозиторий: https://github.com/antonkar1612-web/server-services
- Назначение: Docker Compose + конфиги + скрипты управления сервисами.
  Базовая инфраструктура — отдельный репозиторий `server-infra`.
- Публикация: локальный `/root/services-src/` → репозиторий,
  минорный бамп тега, push.
- Стек: Ubuntu 24.04, Docker 29.x, Docker Compose v5.x.

## Состав

    docker-compose.yml        — Portainer CE, только 127.0.0.1:9000
    scripts/backup-all.sh     — бэкап секретов + docker volumes
    scripts/update-all.sh     — apt + docker compose по COMPOSE_DIRS
    scripts/healthcheck.sh    — сводка состояния
    scripts/wg-manager.sh     — WireGuard (НЕ используется, если INSTALL_WG=no)
    scripts/wg-exclude-ru.sh   — WireGuard split-tunnel (НЕ используется)
    scripts/wg-include-blocked.sh — WireGuard VPN (НЕ используется)

## Portainer

- Образ: `portainer/portainer-ce:latest`
- Порт: `127.0.0.1:9000:9000` — **только loopback**, наружу не открыт.
- Доступ: `ssh -L 9000:localhost:9000 anton@<SERVER_IP>` →
  <http://localhost:9000>.
- UFW-правил для 9000 **не добавлять** (порт не должен слушать наружу).
- Volume: `server-services_portainer_data` (входит в бэкап через
  `DOCKER_VOLUMES` в `/root/secrets/backup.env`).
- `/var/run/docker.sock` монтируется **read-only** (`:ro`).

## Конфиги в /root/secrets/ (chmod 600)

- `server-infra.env` — из `server-infra/bootstrap.sh` (`ADMIN_USER`,
  `SSH_PORT`, `SERVER_IP`; `WG_*` — только если `INSTALL_WG=yes`).
- `backup.env` — `BACKUP_DIR`, `KEEP_DAYS`, `MIN_FREE_MB`, `SOURCES`,
  `DOCKER_VOLUMES`. Пример: `scripts/backup.env.example`.
- `update.env` — `COMPOSE_DIRS`, `APT_AUTOREMOVE`, `DOCKER_PRUNE`.
  Пример: `scripts/update.env.example`.
- Секреты никогда не коммитить в Git. `.gitignore` уже исключает
  `.env`, `secrets/`, `*.log`, `*.conf`.

## WireGuard — опционально, по умолчанию ВЫКЛЮЧЕН

- В текущем развёртывании (`forcibly`) WG **не установлен**
  (`INSTALL_WG=no` в `server-infra/bootstrap.sh`).
- WG-скрипты (`wg-manager.sh`, `wg-exclude-ru.sh`,
  `wg-include-blocked.sh`) **не запускать**, пока нет явного запроса
  и пока WG не установлен.
- `backup-all.sh` и `healthcheck.sh` от WG **не зависят** —
  `/etc/wireguard` просто пропускается, `healthcheck.sh` выдаёт warning
  «wg не установлен» (это норма).
- **НЕ предлагать** WireGuard, VPN, SNAT, MASQUERADE, MSS clamping,
  MTU experiments без явного запроса — это откатано.

## Правила для ассистента

- Один шаг = одна команда/скрипт, с проверкой вывода.
- Перед изменением сети/UFW/Docker — **сначала спросить**.
- Идемпотентность обязательна, `bash -n` для скриптов.
- Секреты — только `/root/secrets/`, никогда в Git.
- Не выдумывать диагностические скрипты без конкретной задачи —
  сначала уточнить точный симптом.
- Учитывать бесплатный лимит OpenRouter (50 запросов/день).

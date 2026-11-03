# server-services

Docker Compose и скрипты управления сервисами. Прикладной слой поверх
[`server-infra`](https://github.com/antonkar1612-web/server-infra).

## Структура

    docker-compose.yml        — Portainer (loopback 127.0.0.1:9000)
    scripts/
      backup-all.sh           — локальный бэкап секретов + docker volumes
      backup-to-gdrive.sh     — выгрузка локальных бэкапов в Google Drive
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

## healthcheck.sh

    sudo ./scripts/healthcheck.sh [--quiet]

Сводка: docker, ufw, fail2ban, диск, RAM, load, systemd.
Проверка WireGuard выводит warning, если WG не установлен — это **норма**
для развёртываний без WG. `--quiet` — только проблемы.

## Локальный бэкап (backup-all.sh)

    sudo ./scripts/backup-all.sh

Бэкап: `SOURCES` (по умолчанию `/root/secrets`) + docker volumes из
`DOCKER_VOLUMES`. Результат: `/var/backups/server-services/`, ротация
(`KEEP_DAYS=14`). Конфиг: `/root/secrets/backup.env` (опционально).

## Внешний бэкап в Google Drive (backup-to-gdrive.sh)

    sudo ./scripts/backup-to-gdrive.sh

Синхронизирует локальную папку `/var/backups/server-services/` в папку
`server-backups` на Google Drive с помощью `rclone sync`. Удаленные
локально старые архивы также удаляются в облаке (защита от переполнения).

**Настройка rclone (один раз):**
1. Установить: `curl https://rclone.org/install.sh | bash`
2. Создать OAuth Client ID (тип Desktop app) в Google Cloud Console.
3. Выполнить `rclone config` на сервере, авторизоваться через
   `rclone authorize` на локальном ПК.
4. Убедиться, что папка `server-backups` создана на Диске.

**Восстановление из облака при полной потере VPS:**
```bash
apt-get install -y rclone
# настроить rclone (как выше) или перенести ~/.config/rclone/rclone.conf
mkdir -p /var/backups/server-services
rclone copy gdrive:server-backups /var/backups/server-services/
# далее распаковать архивы (см. docs/prompt.md)
Расписание (cron)
03:00 — backup-all.sh (локальный бэкап)

03:30 — backup-to-gdrive.sh (выгрузка в Google Drive)

04:00 (Вс) — update-all.sh (обновления)

WireGuard-скрипты (опционально, не используются)
wg-manager.sh, wg-exclude-ru.sh, wg-include-blocked.sh — для
развёртываний с WireGuard. В текущем развёртывании WG не установлен,
скрипты не запускаются. backup-all.sh и healthcheck.sh корректно
работают без WG.

Правила
Секреты — только /root/secrets/, никогда в Git.

Все скрипты идемпотентны, bash -n чист.
EOF
echo "README updated"

text

### Шаг 2. Обновляем docs/prompt.md

```bash
cd /root/server-services && cat > docs/prompt.md <<'EOF'
# Промт-блок для нового чата (server-services v0.6.0)

Вставьте блок ниже в начало чата с ассистентом.

## Контекст: server-services (прикладной слой) — v0.6.0

- Репозиторий: https://github.com/antonkar1612-web/server-services
- Назначение: Docker Compose + конфиги + скрипты управления сервисами.
  Базовая инфраструктура — отдельный репозиторий `server-infra`.
- Стек: Ubuntu 24.04, Docker 29.x, Docker Compose v5.x.

## Состав

    docker-compose.yml        — Portainer CE, только 127.0.0.1:9000
    scripts/backup-all.sh     — локальный бэкап секретов + docker volumes
    scripts/backup-to-gdrive.sh — выгрузка архивов в Google Drive
    scripts/update-all.sh     — apt + docker compose по COMPOSE_DIRS
    scripts/healthcheck.sh    — сводка состояния
    scripts/wg-manager.sh     — WireGuard (НЕ используется, если INSTALL_WG=no)

## Portainer

- Образ: `portainer/portainer-ce:latest`
- Порт: `127.0.0.1:9000:9000` — **только loopback**, наружу не открыт.
- Доступ: `ssh -L 9000:localhost:9000 anton@<SERVER_IP>` →
  <http://localhost:9000>.
- UFW-правил для 9000 **не добавлять**.
- Volume: `server-services_portainer_data`.
- `/var/run/docker.sock` монтируется **read-only** (`:ro`).

## Бэкапы (локально + Google Drive)

- **03:00** — `backup-all.sh` создаёт архивы в `/var/backups/server-services/`
  (secrets + volume Portainer). Ротация 14 дней.
- **03:30** — `backup-to-gdrive.sh` делает `rclone sync` этой папки в
  `gdrive:server-backups`. Старые файлы удаляются и локально, и в облаке.

### Настройка rclone (особенности)

- **Service Accounts не работают** для личных Google Дисков с 2025 года
  (ошибка `403 storageQuotaExceeded` — у SA нет своего хранилища).
- Используется **OAuth (личный аккаунт)**:
  1. В Google Cloud Console создать OAuth Client ID (тип Desktop app).
  2. Опубликовать приложение (Publish App), иначе тестовые пользователи
     могут не добавляться. Для публикации нужны Home page и Privacy link
     (можно использовать GitHub Pages).
  3. На сервере: `rclone config` → `n` (без браузера) → вставить токен,
     сгенерированный на локальном ПК через `rclone authorize`.
- Конфиг rclone: `~/.config/rclone/rclone.conf` (chmod 600).
- Папка на Диске: `server-backups`.

### Восстановление из облака

```bash
# после установки rclone и настройки доступа
mkdir -p /var/backups/server-services
rclone copy gdrive:server-backups /var/backups/server-services/
# распаковка secrets:
tar -xzf /var/backups/server-services/files-*.tar.gz -C /
# распаковка Portainer volume (при остановленном контейнере):
docker compose -f /root/server-services/docker-compose.yml stop portainer
MOUNT=$(docker volume inspect -f '{{.Mountpoint}}' server-services_portainer_data)
tar -xzf /var/backups/server-services/volume-*.tar.gz -C "$MOUNT"
docker compose -f /root/server-services/docker-compose.yml up -d
Конфиги в /root/secrets/ (chmod 600)
server-infra.env — из server-infra/bootstrap.sh.

backup.env — BACKUP_DIR, KEEP_DAYS, MIN_FREE_MB, SOURCES,
DOCKER_VOLUMES. Пример: scripts/backup.env.example.

update.env — COMPOSE_DIRS, APT_AUTOREMOVE, DOCKER_PRUNE.

Секреты никогда не коммитить в Git.

WireGuard — опционально, по умолчанию ВЫКЛЮЧЕН
В текущем развёртывании WG не установлен (INSTALL_WG=no).

WG-скрипты не запускать без явного запроса.

backup-all.sh и healthcheck.sh работают без WG.

Правила для ассистента
Один шаг = одна команда/скрипт, с проверкой вывода.

Перед изменением сети/UFW/Docker — сначала спросить.

Идемпотентность обязательна, bash -n для скриптов.

Секреты — только /root/secrets/ и ~/.config/rclone/, никогда в Git.

Не выдумывать диагностические скрипты без конкретной задачи —
сначала уточнить точный симптом.

Учитывать бесплатный лимит OpenRouter (50 запросов/день).


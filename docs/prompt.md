# Промт-блок для нового чата (server-services)

## Контекст

- Репозиторий: https://github.com/antonkar1612-web/server-services
- Назначение: Docker Compose + конфиги + скрипты управления.
- Слой прикладной; базовая инфраструктура — server-infra.
- Публикация: `/root/publish-services.sh` (копирует `/root/services-src/`
  в репозиторий, авто-бампит минорную версию тега, пушит).

## scripts/wg-manager.sh

Управление WireGuard: init, adopt, add, remove, list, qr, qr-term,
export, reload, show, status, mail, config.

- adopt — подхватывает wg0.conf от bootstrap.sh
- Конфиги: /root/secrets/server-infra.env, /root/secrets/wg-manager.env
- Log: /var/log/wg-manager.log

## scripts/update-all.sh

Обновление apt + docker compose.

- Флаги: --apt-only, --docker-only, --dry-run
- COMPOSE_DIRS — список каталогов с docker-compose.yml
- Конфиг: /root/secrets/update.env
- Log: /var/log/update-all.log

## scripts/healthcheck.sh

Сводка состояния: docker, wg, ufw, fail2ban, диск, RAM, load, systemd.

- Exit 1 если есть проблемы
- --quiet — только проблемы

## scripts/backup-all.sh

Бэкап: /root/secrets, /etc/wireguard, docker volumes.

- BACKUP_DIR=/var/backups/server-services
- KEEP_DAYS=14, MIN_FREE_MB=500
- Lock через flock, идемпотентен
- Конфиг: /root/secrets/backup.env (опционально)
- Log: /var/log/backup-all.log

## Правила

- Секреты — только в ~/secrets/, никогда в Git
- Все скрипты идемпотентны
- shellcheck clean
- OpenRouter — 50 запросов/день

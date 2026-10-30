# server-services

Docker Compose и скрипты управления сервисами.

## Структура

    scripts/
      wg-manager.sh          — управление WireGuard (клиенты, QR, mail)
      wg-manager.env.example — пример конфига (~/secrets/wg-manager.env)
    docs/
      prompt.md              — контекст для нового чата

## wg-manager.sh

Команды: init, adopt, add, remove, list, qr, qr-term, export, reload,
show, status, mail, config.

Зависит от `/root/secrets/server-infra.env` (SERVER_IP, WG_PORT,
WG_NETWORK — создан `bootstrap.sh` из репозитория `server-infra`).
SMTP для `mail` — в `/root/secrets/wg-manager.env`.

Подробнее: `./scripts/wg-manager.sh` без аргументов.

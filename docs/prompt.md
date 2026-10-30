# Промт-блок для нового чата (server-services)

## Контекст

- Репозиторий: https://github.com/antonkar1612-web/server-services
- Назначение: Docker Compose + конфиги сервисов + скрипты управления.
- Слой: прикладной. Базовая инфраструктура — в server-infra.

## scripts/wg-manager.sh

Управление WireGuard: клиенты, QR, mail.

- Команды: init, adopt, add, remove, list, qr, qr-term, export, reload,
  show, status, mail, config.
- Конфиги:
  - /root/secrets/server-infra.env — SERVER_IP (внешн.), WG_PORT, WG_NETWORK
  - /root/secrets/wg-manager.env — WAN_IF, SERVER_HOST override, SMTP_*
  - /etc/wireguard/wg0.conf — серверный конфиг WG
- adopt: подхватывает wg0.conf, созданный bootstrap.sh (не падает)
- Log: /var/log/wg-manager.log
- shellcheck clean

## Правила

- Секреты — только в ~/secrets/, никогда в Git
- Все скрипты идемпотентны
- shellcheck в CI
- OpenRouter — лимит 50 запросов/день

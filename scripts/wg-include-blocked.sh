#!/usr/bin/env bash
# wg-include-blocked.sh — через VPN идёт только трафик к заблокированным в РФ ресурсам.
# Весь остальной трафик (включая российские сайты) идёт напрямую.
#
#   sudo ./wg-include-blocked.sh              # применить списки по умолчанию
#   sudo ./wg-include-blocked.sh --update     # только обновить CIDR-файлы
#   sudo ./wg-include-blocked.sh --apply      # только применить (без скачивания)
#   sudo ./wg-include-blocked.sh --dry-run    # показать, что будет сделано
#   sudo ./wg-include-blocked.sh --list       # показать текущий AllowedIPs

set -euo pipefail

LOG_FILE="${WG_INCLUDE_LOG:-/var/log/wg-include-blocked.log}"
if [[ "$(id -u)" == "0" ]] && command -v tee >/dev/null; then
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  [[ -w "$(dirname "$LOG_FILE")" ]] && touch "$LOG_FILE" 2>/dev/null && \
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

# --- Пути ---
BLOCKED_DIR="/var/lib/wg-manager/blocked"
BLOCKED_COMBINED="$BLOCKED_DIR/combined.cidr"
ALLOWED_CACHE="/var/lib/wg-manager/allowed-blocked.txt"
CLIENTS_DIR="/etc/wireguard/clients"
SERVER_ENV="/root/secrets/server-infra.env"
MANAGER_ENV="/root/secrets/wg-manager.env"

# --- Источники CIDR ---
# 1. Встроенные списки (правьте/дополняйте под себя)
TELEGRAM_CIDR="91.108.0.0/16
149.154.160.0/20
185.76.151.0/24
95.161.64.0/20"

DISCORD_CIDR="66.22.0.0/16
162.159.128.0/18
195.62.89.0/24"

YOUTUBE_GOOGLE_CIDR="142.250.0.0/15
172.217.0.0/16
216.58.0.0/16
216.239.32.0/19
64.233.160.0/19
74.125.0.0/16
108.177.0.0/17
173.194.0.0/16
207.126.144.0/22
208.117.254.0/24"

META_CIDR="31.13.0.0/16
129.134.0.0/17
157.240.0.0/16
173.252.64.0/18
185.60.216.0/22
57.144.0.0/14"

TWITTER_X_CIDR="104.244.40.0/21
185.45.4.0/22
193.239.88.0/21
199.16.156.0/22
199.59.148.0/22
202.160.128.0/19
209.237.192.0/18"

# Дополнительно: новостные/медиа (по желанию)
MEDIA_CIDR="151.101.0.0/16
199.232.0.0/16
212.42.0.0/16"

# 2. Внешние источники (опционально)
# Репозиторий V3nilla (списки для обхода блокировок):
#   https://github.com/V3nilla/IPSets-For-Bypass-in-Russia
# Можно включить, раскомментировав URL и функцию download_external()
EXTERNAL_SOURCES=()

# --- Флаги ---
DO_UPDATE=1
DO_APPLY=1
DRY_RUN=0
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)  DO_APPLY=0 ;;
    --apply)   DO_UPDATE=0 ;;
    --dry-run) DRY_RUN=1 ;;
    --list)    LIST_ONLY=1 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
  shift
done

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# --- Сбор CIDR ---
collect_cidr() {
  mkdir -p "$BLOCKED_DIR"
  : > "$BLOCKED_COMBINED"

  {
    echo "# Telegram"
    printf '%s\n' "$TELEGRAM_CIDR" | grep -v '^$'

    echo "# Discord"
    printf '%s\n' "$DISCORD_CIDR" | grep -v '^$'

    echo "# YouTube / Google"
    printf '%s\n' "$YOUTUBE_GOOGLE_CIDR" | grep -v '^$'

    echo "# Meta (Facebook, Instagram, WhatsApp)"
    printf '%s\n' "$META_CIDR" | grep -v '^$'

    echo "# Twitter / X"
    printf '%s\n' "$TWITTER_X_CIDR" | grep -v '^$'

    echo "# Media (BBC, DW, и т.п.)"
    printf '%s\n' "$MEDIA_CIDR" | grep -v '^$'
  } >> "$BLOCKED_COMBINED"

  # Внешние источники (если включены)
  local url
  for url in "${EXTERNAL_SOURCES[@]}"; do
    [[ -z "$url" ]] && continue
    echo "# External: $url" >> "$BLOCKED_COMBINED"
    if curl -fsSL --max-time 20 "$url" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' >> "$BLOCKED_COMBINED"; then
      log "  загружено: $url"
    else
      warn "  не удалось загрузить: $url"
    fi
  done

  local count
  count=$(grep -cvE '^#|^$' "$BLOCKED_COMBINED")
  log "Собрано CIDR: $count (в $BLOCKED_COMBINED)"
}

# --- Определение IP сервера (SERVER_IP из env, Endpoint из клиента, ifconfig.me) ---
load_server_ip() {
  SERVER_IP_DETECTED=""

  if [[ -f "$SERVER_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$SERVER_ENV"
    [[ -n "${SERVER_IP:-}" ]] && SERVER_IP_DETECTED="$SERVER_IP"
  fi

  if [[ -z "$SERVER_IP_DETECTED" ]]; then
    shopt -s nullglob
    local conf ip
    for conf in /etc/wireguard/clients/*.conf; do
      ip=$(grep -E '^Endpoint' "$conf" | head -1 | sed -E 's/^Endpoint[[:space:]]*=[[:space:]]*([0-9.]+):.*/\1/')
      [[ -n "$ip" ]] && { SERVER_IP_DETECTED="$ip"; break; }
    done
    shopt -u nullglob
  fi

  if [[ -z "$SERVER_IP_DETECTED" ]]; then
    SERVER_IP_DETECTED=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)
  fi

  [[ -n "$SERVER_IP_DETECTED" ]] || die "не удалось определить IP сервера (SERVER_IP в $SERVER_ENV, Endpoint в клиенте или ifconfig.me)"
  log "IP сервера: $SERVER_IP_DETECTED"
}

# --- Вычисление AllowedIPs (только заблокированные + сервер) ---
compute_allowed() {
  local server_host="$1"
  log "Формирую AllowedIPs только из заблокированных сетей + IP сервера"

  python3 - "$BLOCKED_COMBINED" "$server_host" > "$ALLOWED_CACHE" <<'PY'
import sys, ipaddress
from pathlib import Path

blocked_path = Path(sys.argv[1])
server_host = sys.argv[2]

nets = []
for line in blocked_path.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    try:
        nets.append(ipaddress.ip_network(line, strict=False))
    except ValueError:
        pass
nets = list(ipaddress.collapse_addresses(nets))

# Добавляем IP сервера
try:
    nets.append(ipaddress.ip_network(server_host + "/32", strict=False))
except ValueError:
    pass

nets = list(ipaddress.collapse_addresses(nets))
print(", ".join(str(n) for n in nets))
PY

  [[ -s "$ALLOWED_CACHE" ]] || die "AllowedIPs пуст"
  local count
  count=$(tr ',' '\n' < "$ALLOWED_CACHE" | wc -l)
  log "Готово: $count CIDR в AllowedIPs"
}

# --- Применение к клиентам ---
apply_to_clients() {
  local allowed dns mtu
  allowed="$(cat "$ALLOWED_CACHE")"
  [[ -n "$allowed" ]] || die "AllowedIPs пуст"

  dns="1.1.1.1"
  mtu="1380"
  if [[ -f "$MANAGER_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$MANAGER_ENV"
    [[ -n "${CLIENT_DNS:-}" ]] && dns="$CLIENT_DNS"
    [[ -n "${CLIENT_MTU:-}" ]] && mtu="$CLIENT_MTU"
  fi

  shopt -s nullglob
  local clients=("$CLIENTS_DIR"/*.conf)
  shopt -u nullglob
  [[ ${#clients[@]} -eq 0 ]] && { warn "нет клиентских конфигов"; return 0; }

  local conf updated=0
  for conf in "${clients[@]}"; do
    if grep -qE '^AllowedIPs[[:space:]]*=' "$conf"; then
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "   DRY: обновил бы $conf (DNS=$dns, MTU=$mtu)"
      else
        sed -i "s|^AllowedIPs[[:space:]]*=.*|AllowedIPs = ${allowed}|" "$conf"
        sed -i -E "s|^DNS[[:space:]]*=.*|DNS        = ${dns}|" "$conf"
        sed -i -E "s|^MTU[[:space:]]*=.*|MTU        = ${mtu}|" "$conf"
        echo "   обновлён: $conf ($(wc -c < "$conf") байт)"
      fi
      updated=$((updated + 1))
    else
      warn "нет AllowedIPs в $conf"
    fi
  done
  log "Обновлено: $updated"
}

# --- Показать текущий AllowedIPs ---
show_allowed() {
  if [[ -f "$ALLOWED_CACHE" ]]; then
    echo "=== Текущий AllowedIPs ($ALLOWED_CACHE) ==="
    cat "$ALLOWED_CACHE"
  else
    echo "AllowedIPs ещё не сформирован"
  fi
}

# --- Главная ---
main() {
  [[ $EUID -eq 0 ]] || die "запуск от root"

  if [[ "$LIST_ONLY" == "1" ]]; then
    show_allowed
    exit 0
  fi

  if [[ "$DO_UPDATE" == "1" ]]; then
    collect_cidr
  else
    [[ -f "$BLOCKED_COMBINED" ]] || die "нет $BLOCKED_COMBINED, запустите с --update"
  fi

  if [[ "$DO_APPLY" == "1" ]]; then
    load_server_ip
    compute_allowed "$SERVER_IP_DETECTED"
    apply_to_clients
  fi

  log "=== готово ==="
}

main "$@"

#!/usr/bin/env bash
# wg-exclude-ru.sh — split tunneling: исключает российские сети из AllowedIPs.
#
#   sudo ./wg-exclude-ru.sh              # top-1000 + extra + применить
#   sudo ./wg-exclude-ru.sh --top 300    # top-300 + extra
#   sudo ./wg-exclude-ru.sh --no-top     # полный ru.zone + extra
#   sudo ./wg-exclude-ru.sh --update     # только скачать ru.zone
#   sudo ./wg-exclude-ru.sh --apply      # только применить
#   sudo ./wg-exclude-ru.sh --dry-run    # показать без изменений

set -euo pipefail

LOG_FILE="${WG_EXCLUDE_LOG:-/var/log/wg-exclude-ru.log}"
if [[ "$(id -u)" == "0" ]] && command -v tee >/dev/null; then
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  [[ -w "$(dirname "$LOG_FILE")" ]] && touch "$LOG_FILE" 2>/dev/null && \
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

RU_ZONE_CACHE="/var/lib/wg-manager/ru.zone"
EXTRA_ZONE="/var/lib/wg-manager/extra.zone"
RU_ZONE_EFFECTIVE=""
ALLOWED_IPS_CACHE="/var/lib/wg-manager/allowed-ips.txt"
SERVER_ENV="/root/secrets/server-infra.env"
MANAGER_ENV="/root/secrets/wg-manager.env"
CLIENTS_DIR="/etc/wireguard/clients"

RU_ZONE_URL="https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone"
RU_ZONE_FALLBACK="https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/cascade/ru.zone"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

DO_UPDATE=1
DO_APPLY=1
DRY_RUN=0
TOP_N=1000

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)  DO_APPLY=0 ;;
    --apply)   DO_UPDATE=0 ;;
    --dry-run) DRY_RUN=1 ;;
    --no-top)  TOP_N=0 ;;
    --top)
      shift
      [[ -n "${1:-}" && "$1" =~ ^[0-9]+$ ]] || die "--top требует число"
      TOP_N="$1"
      ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
  shift
done

ensure_extra_zone() {
  mkdir -p "$(dirname "$EXTRA_ZONE")"
  if [[ ! -f "$EXTRA_ZONE" ]]; then
    log "Создаю $EXTRA_ZONE (Yandex, Mail.ru/VK — вручную дополняйте)"
    cat > "$EXTRA_ZONE" <<'EX'
# Yandex
5.255.192.0/18
5.255.255.0/24
37.9.64.0/18
37.140.128.0/18
77.88.0.0/18
87.250.192.0/18
87.250.224.0/19
93.158.128.0/18
95.108.128.0/17
100.43.64.0/18
178.154.128.0/17
185.32.187.0/24
213.180.192.0/19
213.180.204.0/24
213.180.206.0/23
213.180.208.0/21
213.180.216.0/24
213.180.218.0/24
# Mail.ru / VK
94.100.180.0/22
94.100.184.0/21
217.69.128.0/18
# Gosuslugi
95.161.76.0/22
109.207.8.0/21
# Sber
194.54.14.0/24
194.54.15.0/24
EX
    chmod 644 "$EXTRA_ZONE"
  fi
}

download_ru_zone() {
  mkdir -p "$(dirname "$RU_ZONE_CACHE")"
  log "Скачиваю ru.zone с ipdeny.com"
  if curl -fsSL --max-time 30 -o "${RU_ZONE_CACHE}.tmp" "$RU_ZONE_URL" 2>/dev/null \
     && [[ -s "${RU_ZONE_CACHE}.tmp" ]]; then
    mv "${RU_ZONE_CACHE}.tmp" "$RU_ZONE_CACHE"
    chmod 644 "$RU_ZONE_CACHE"
    log "Скачано: $(wc -l < "$RU_ZONE_CACHE") подсетей"
    return 0
  fi
  warn "ipdeny.com недоступен, fallback на GitHub"
  rm -f "${RU_ZONE_CACHE}.tmp"
  if curl -fsSL --max-time 30 -o "${RU_ZONE_CACHE}.tmp" "$RU_ZONE_FALLBACK"; then
    mv "${RU_ZONE_CACHE}.tmp" "$RU_ZONE_CACHE"
    chmod 644 "$RU_ZONE_CACHE"
    log "Fallback загружен: $(wc -l < "$RU_ZONE_CACHE")"
    return 0
  fi
  die "не удалось получить ru.zone"
}

filter_top_n() {
  local n="$1"
  local out="${RU_ZONE_CACHE}.top${n}"
  log "Отбираю top-${n} крупнейших подсетей"
  python3 - "$RU_ZONE_CACHE" "$n" "$out" <<'PY'
import sys, ipaddress
from pathlib import Path
inp, n, out = Path(sys.argv[1]), int(sys.argv[2]), Path(sys.argv[3])
nets = []
for line in inp.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"): continue
    try: nets.append(ipaddress.ip_network(line, strict=False))
    except ValueError: pass
nets.sort(key=lambda x: x.num_addresses, reverse=True)
top = list(ipaddress.collapse_addresses(nets[:n]))
covered = sum(x.num_addresses for x in top)
out.write_text("\n".join(str(x) for x in top) + "\n")
print(f"  отобрано: {len(top)} подсетей, покрытие: {covered:,} IP")
PY
  RU_ZONE_EFFECTIVE="$out"
}

load_server_host() {
  if [[ -f "$SERVER_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$SERVER_ENV"
  fi
  if [[ -z "${SERVER_IP:-}" ]]; then
    SERVER_IP=$(awk -F': ' '/^Endpoint/{print $2; exit}' /etc/wireguard/wg0.conf 2>/dev/null | cut -d: -f1 || true)
  fi
  [[ -n "$SERVER_IP" ]] || die "не удалось определить IP сервера"
  echo "$SERVER_IP"
}

compute_allowed_ips() {
  local server_host="$1"
  local sources=("$RU_ZONE_EFFECTIVE")
  [[ -f "$EXTRA_ZONE" ]] && sources+=("$EXTRA_ZONE")

  log "Вычисляю AllowedIPs из: ${sources[*]}"
  python3 - "$server_host" "${sources[@]}" > "$ALLOWED_IPS_CACHE" <<'PY'
import sys, ipaddress
from pathlib import Path

server_host = sys.argv[1]
sources = sys.argv[2:]

ru_nets = []
for src in sources:
    for line in Path(src).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"): continue
        try: ru_nets.append(ipaddress.ip_network(line, strict=False))
        except ValueError: pass
ru_nets = list(ipaddress.collapse_addresses(ru_nets))

exclude = list(ru_nets)
# 0.0.0.0/8 — "this network", Android/iOS отвергают маршруты с 0.0.0.0
for cidr in ["0.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
             "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
             "100.64.0.0/10", "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"]:
    exclude.append(ipaddress.ip_network(cidr, strict=False))
try:
    exclude.append(ipaddress.ip_network(server_host + "/32", strict=False))
except ValueError:
    pass
exclude = list(ipaddress.collapse_addresses(exclude))

allowed = [ipaddress.ip_network("0.0.0.0/0")]
for net in exclude:
    new_a = []
    for a in allowed:
        if net.subnet_of(a):
            new_a.extend(a.address_exclude(net))
        else:
            new_a.append(a)
    allowed = new_a
allowed = list(ipaddress.collapse_addresses(allowed))

print(", ".join(str(n) for n in allowed))
PY

  [[ -s "$ALLOWED_IPS_CACHE" ]] || die "AllowedIPs пуст"
  local count size first
  count=$(tr ',' '\n' < "$ALLOWED_IPS_CACHE" | wc -l)
  size=$(wc -c < "$ALLOWED_IPS_CACHE")
  first=$(head -c 30 "$ALLOWED_IPS_CACHE")
  log "Готово: $count CIDR, $size байт, первая: $first..."
}

apply_to_clients() {
  local allowed dns mtu
  allowed="$(cat "$ALLOWED_IPS_CACHE")"
  [[ -n "$allowed" ]] || die "AllowedIPs пуст"

  dns="77.88.8.8, 77.88.8.1"
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
  [[ ${#clients[@]} -eq 0 ]] && { warn "нет клиентских конфигов в $CLIENTS_DIR"; return 0; }

  local conf updated=0
  for conf in "${clients[@]}"; do
    if grep -qE '^AllowedIPs[[:space:]]*=' "$conf"; then
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "   DRY: обновил бы $conf (DNS=$dns, MTU=$mtu)"
      else
        sed -i "s|^AllowedIPs[[:space:]]*=.*|AllowedIPs = ${allowed}|" "$conf"
        sed -i -E "s|^DNS[[:space:]]*=.*|DNS        = ${dns}|" "$conf"
        sed -i -E "s|^MTU[[:space:]]*=.*|MTU        = ${mtu}|" "$conf"
        echo "   обновлён: $conf ($(wc -c < "$conf") байт, DNS=$dns, MTU=$mtu)"
      fi
      updated=$((updated + 1))
    else
      warn "нет строки AllowedIPs в $conf"
    fi
  done
  log "Обновлено: $updated"
}

main() {
  [[ $EUID -eq 0 ]] || die "запуск от root"
  ensure_extra_zone
  RU_ZONE_EFFECTIVE="$RU_ZONE_CACHE"

  if [[ "$DO_UPDATE" == "1" ]]; then
    download_ru_zone
  else
    [[ -f "$RU_ZONE_CACHE" ]] || die "нет $RU_ZONE_CACHE, запустите с --update"
  fi

  if [[ "$TOP_N" -gt 0 ]]; then
    filter_top_n "$TOP_N"
  fi

  if [[ "$DO_APPLY" == "1" ]]; then
    local server_ip
    server_ip="$(load_server_host)"
    compute_allowed_ips "$server_ip"
    apply_to_clients
  fi

  log "=== готово ==="
}

main "$@"

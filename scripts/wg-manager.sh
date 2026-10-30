#!/usr/bin/env bash
#
# wg-manager.sh — управление WireGuard: клиенты, QR, mail.
# Конфиги: /root/secrets/server-infra.env, /root/secrets/wg-manager.env
# Команды: init, adopt, add, remove, list, qr, qr-term, export,
#          reload, show, status, mail, config, help

set -euo pipefail

LOG_FILE="${WG_MANAGER_LOG:-/var/log/wg-manager.log}"
if [[ "$(id -u)" == "0" ]] && command -v tee >/dev/null; then
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  if touch "$LOG_FILE" 2>/dev/null; then
    exec > >(tee -a "$LOG_FILE") 2>&1
  fi
fi

INFRA_ENV="/root/secrets/server-infra.env"
MANAGER_ENV="/root/secrets/wg-manager.env"
LEGACY_CONF="${WG_MANAGER_CONFIG:-/etc/wireguard/wg-manager.conf}"

log()  { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "Ошибка: $*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "запустите от root"; }
require_wg()   { command -v wg >/dev/null || die "не установлен wireguard-tools"; }

load_config() {
  local _external_ip=""
  if [[ -f "$INFRA_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$INFRA_ENV"
    _external_ip="${SERVER_IP:-}"
    : "${WG_PORT:=51820}"
    : "${WG_NETWORK:=10.30.0.0/24}"
  fi
  if [[ -f "$MANAGER_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$MANAGER_ENV"
  fi
  if [[ -f "$LEGACY_CONF" ]]; then
    # shellcheck disable=SC1090
    source "$LEGACY_CONF"
  fi

  : "${IFACE:=wg0}"
  : "${WG_DIR:=/etc/wireguard}"
  : "${PORT:=${WG_PORT:-51820}}"
  : "${SUBNET_NET:=${WG_NETWORK:-10.30.0.0/24}}"
  : "${WG_SERVER_IP:=${SUBNET_NET%.*}.1}"
  : "${SERVER_HOST:=${_external_ip}}"
  : "${CLIENT_DNS:=77.88.8.8, 77.88.8.1}"
  : "${CLIENT_MTU:=1380}"
  : "${CLIENT_IP_START:=2}"
  : "${CLIENT_IP_END:=254}"
  : "${GEN_QR:=true}"
  : "${KEEP_ARCHIVE:=false}"
  : "${ARCHIVE_DIR:=/var/lib/wg-manager/archives}"

  detect_wan_if
  detect_server_host

  SERVER_CONF="${WG_DIR}/${IFACE}.conf"
  CLIENTS_DIR="${WG_DIR}/clients"
}

detect_wan_if() {
  [[ -n "${WAN_IF:-}" ]] && return 0
  WAN_IF="$(ip -4 route 2>/dev/null | awk '/^default/{print $5; exit}' || true)"
  [[ -n "$WAN_IF" ]] || die "не удалось определить WAN_IF, задайте в $MANAGER_ENV"
}

detect_server_host() {
  [[ -n "${SERVER_HOST:-}" ]] && return 0
  if command -v curl >/dev/null; then
    SERVER_HOST="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  fi
  [[ -n "$SERVER_HOST" ]] || die "SERVER_HOST не определён, задайте в $MANAGER_ENV"
}

validate_config() {
  [[ "$SUBNET_NET" =~ ^[0-9.]+/[0-9]+$ ]] || die "SUBNET_NET некорректен: $SUBNET_NET"
  [[ "$WG_SERVER_IP" =~ ^[0-9.]+$ ]]     || die "WG_SERVER_IP некорректен: $WG_SERVER_IP"
  [[ "$PORT"       =~ ^[0-9]+$ ]]        || die "PORT некорректен: $PORT"
  local net="${SUBNET_NET%/*}"
  [[ "${WG_SERVER_IP%.*}" == "${net%.*}" ]] \
    || die "WG_SERVER_IP ($WG_SERVER_IP) не входит в SUBNET_NET ($SUBNET_NET)"
  ip link show "$WAN_IF" >/dev/null 2>&1 || warn "WAN_IF '$WAN_IF' не найден"
}

ensure_dirs() {
  mkdir -p "$WG_DIR" "$CLIENTS_DIR" "$ARCHIVE_DIR"
  chmod 700 "$WG_DIR" "$CLIENTS_DIR"
  chmod 700 "$ARCHIVE_DIR" 2>/dev/null || true
}

ensure_qrencode() {
  [[ "$GEN_QR" == "true" ]] || return 0
  command -v qrencode >/dev/null && return 0
  log "Устанавливаю qrencode..."
  if command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq qrencode
  elif command -v dnf >/dev/null; then dnf install -y -q qrencode
  elif command -v yum >/dev/null; then yum install -y -q qrencode
  elif command -v pacman >/dev/null; then pacman -Sy --noconfirm qrencode
  elif command -v apk >/dev/null; then apk add --no-cache qrencode
  else warn "qrencode не установлен — PNG не создаются"; GEN_QR=false
  fi
}

enable_forwarding() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  echo "net.ipv4.ip_forward = 1" >/etc/sysctl.d/99-wireguard.conf
  sysctl --system >/dev/null
}

used_ips() {
  [[ -f "$SERVER_CONF" ]] || return 0
  grep -E '^[[:space:]]*AllowedIPs[[:space:]]*=' "$SERVER_CONF" \
    | sed -E 's/.*=[[:space:]]*([0-9.]+)\/32.*/\1/' \
    | grep -E '^[0-9.]+$' | sort -u || true
}

next_free_ip() {
  local used prefix i ip
  used="$(used_ips)"
  prefix="${WG_SERVER_IP%.*}"
  for i in $(seq "$CLIENT_IP_START" "$CLIENT_IP_END"); do
    ip="${prefix}.${i}"
    grep -qx "$ip" <<<"$used" || { echo "$ip"; return 0; }
  done
  die "нет свободных IP в $SUBNET_NET"
}

server_pubkey() {
  local priv
  priv="$(awk '/^[[:space:]]*PrivateKey[[:space:]]*=/{print $3; exit}' "$SERVER_CONF")"
  [[ -n "$priv" ]] || die "не найден PrivateKey в $SERVER_CONF"
  echo "$priv" | wg pubkey
}

apply_config() {
  wg show "$IFACE" >/dev/null 2>&1 || return 0
  if ! wg syncconf "$IFACE" <(wg-quick strip "$IFACE") 2>/dev/null; then
    warn "изменения применятся после restart wg-quick@${IFACE}"
  fi
}

human_bytes() {
  awk -v b="$1" 'BEGIN{
    if (b+0 < 1024)            printf "%dB",  b
    else if (b+0 < 1048576)    printf "%.1fK", b/1024
    else if (b+0 < 1073741824) printf "%.1fM", b/1048576
    else                       printf "%.1fG", b/1073741824
  }'
}

gen_qr_one() {
  local conf="$1"
  [[ "$GEN_QR" == "true" ]] || return 0
  [[ -f "$conf" ]] || return 0
  local base="${conf##*/}"; base="${base%.conf}"
  local qr="${CLIENTS_DIR}/${base}.png"
  if qrencode -t PNG -o "$qr" -s 8 -m 2 -l M < "$conf"; then
    chmod 600 "$qr"
    echo "    QR:  $qr"
  else
    warn "не удалось создать QR для $conf"
  fi
}

gen_client() {
  local NAME="$1"
  local IP="${2:-}"
  [[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || die "недопустимое имя: '$NAME'"
  [[ -f "$SERVER_CONF" ]] || die "нет $SERVER_CONF — сначала init или adopt"

  local CLIENT_CONF="${CLIENTS_DIR}/${NAME}.conf"
  if [[ -f "$CLIENT_CONF" ]]; then
    warn "клиент '$NAME' уже существует"; return 1
  fi

  if [[ -z "$IP" ]]; then
    IP="$(next_free_ip)"
  else
    [[ "$IP" =~ ^[0-9.]+$ ]] || die "некорректный IP: $IP"
    if used_ips | grep -qx "$IP"; then
      warn "IP $IP уже занят"; return 1
    fi
  fi

  log "Создаю клиента '$NAME' ($IP)"
  local C_PRIV C_PUB PSK S_PUB
  C_PRIV="$(wg genkey)"
  C_PUB="$(echo "$C_PRIV" | wg pubkey)"
  PSK="$(wg genpsk)"
  S_PUB="$(server_pubkey)"

  local ALLOWED_IPS="0.0.0.0/0, ::/0"
  if [[ -s /var/lib/wg-manager/allowed-ips.txt ]]; then
    ALLOWED_IPS="$(cat /var/lib/wg-manager/allowed-ips.txt)"
    log "  AllowedIPs: split-tunnel (${ALLOWED_IPS:0:40}...)"
  fi

  cat >"$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = ${C_PRIV}
Address    = ${IP}/24
DNS        = ${CLIENT_DNS}
MTU        = ${CLIENT_MTU}

[Peer]
PublicKey    = ${S_PUB}
PresharedKey = ${PSK}
Endpoint     = ${SERVER_HOST}:${PORT}
AllowedIPs   = ${ALLOWED_IPS}
PersistentKeepalive = 25
EOF
  chmod 600 "$CLIENT_CONF"

  cat >>"$SERVER_CONF" <<EOF

[Peer]
# ${NAME}
PublicKey    = ${C_PUB}
PresharedKey = ${PSK}
AllowedIPs   = ${IP}/32
EOF

  apply_config
  gen_qr_one "$CLIENT_CONF"

  echo "    Конфиг: $CLIENT_CONF"
  echo "    IP:     $IP"
}

cmd_config() {
  load_config
  echo "INFRA_ENV:   $INFRA_ENV $([[ -f $INFRA_ENV ]] && echo '(есть)' || echo '(нет)')"
  echo "MANAGER_ENV: $MANAGER_ENV $([[ -f $MANAGER_ENV ]] && echo '(есть)' || echo '(нет)')"
  echo "LEGACY_CONF: $LEGACY_CONF $([[ -f $LEGACY_CONF ]] && echo '(есть)' || echo '(нет)')"
  echo "------------------------------------------------------------"
  echo "IFACE=${IFACE}"
  echo "WG_DIR=${WG_DIR}"
  echo "SERVER_CONF=${SERVER_CONF}"
  echo "CLIENTS_DIR=${CLIENTS_DIR}"
  echo "PORT=${PORT}"
  echo "SUBNET_NET=${SUBNET_NET}"
  echo "WG_SERVER_IP=${WG_SERVER_IP}  (внутренний адрес wg0)"
  echo "SERVER_HOST=${SERVER_HOST}  (endpoint для клиентов)"
  echo "WAN_IF=${WAN_IF}"
  echo "CLIENT_DNS=${CLIENT_DNS}"
  echo "CLIENT_MTU=${CLIENT_MTU}"
  echo "CLIENT_IP_START=${CLIENT_IP_START}"
  echo "CLIENT_IP_END=${CLIENT_IP_END}"
  echo "GEN_QR=${GEN_QR}"
  echo "ARCHIVE_DIR=${ARCHIVE_DIR}"
  echo "KEEP_ARCHIVE=${KEEP_ARCHIVE}"
}

cmd_init() {
  require_root; require_wg
  load_config; validate_config
  ensure_dirs; ensure_qrencode; enable_forwarding

  if [[ -f "$SERVER_CONF" ]]; then
    die "$SERVER_CONF уже существует. Используйте 'adopt' или удалите вручную."
  fi

  log "Создаю $SERVER_CONF"
  local S_PRIV S_PUB
  S_PRIV="$(wg genkey)"
  S_PUB="$(echo "$S_PRIV" | wg pubkey)"

  cat >"$SERVER_CONF" <<EOF
[Interface]
Address    = ${WG_SERVER_IP}/24
ListenPort = ${PORT}
PrivateKey = ${S_PRIV}
MTU        = ${CLIENT_MTU}
PostUp     = iptables -t nat -A POSTROUTING -s ${SUBNET_NET} -o ${WAN_IF} -j MASQUERADE
PostDown   = iptables -t nat -D POSTROUTING -s ${SUBNET_NET} -o ${WAN_IF} -j MASQUERADE
EOF
  chmod 600 "$SERVER_CONF"

  systemctl enable "wg-quick@${IFACE}" >/dev/null 2>&1 || true
  systemctl start  "wg-quick@${IFACE}" >/dev/null 2>&1 || wg-quick up "$IFACE"

  log "Публичный ключ сервера: $S_PUB"
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${PORT}/udp" >/dev/null || true
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true
    ufw reload >/dev/null || true
  fi
  wg show || true
}

cmd_adopt() {
  require_root; require_wg
  load_config; validate_config
  ensure_dirs; ensure_qrencode; enable_forwarding

  [[ -f "$SERVER_CONF" ]] || die "$SERVER_CONF не существует — используйте 'init'"
  log "Adopt: $SERVER_CONF существует, подхватываю"

  local addr port
  addr="$(awk '/^[[:space:]]*Address[[:space:]]*=/{print $3; exit}' "$SERVER_CONF")"
  port="$(awk '/^[[:space:]]*ListenPort[[:space:]]*=/{print $3; exit}' "$SERVER_CONF")"
  [[ -n "$addr" ]] || die "в $SERVER_CONF нет Address"
  [[ -n "$port" ]] || die "в $SERVER_CONF нет ListenPort"

  if [[ "$port" != "$PORT" ]]; then
    warn "в конфиге порт $port, в env $PORT — использую из конфига"
    PORT="$port"
  fi
  if [[ "${addr%/*}" != "$WG_SERVER_IP" ]]; then
    warn "в конфиге Address $addr, env WG_SERVER_IP $WG_SERVER_IP — использую из конфига"
    WG_SERVER_IP="${addr%/*}"
  fi

  if ! grep -q '^PostUp' "$SERVER_CONF"; then
    log "Дописываю PostUp/PostDown"
    cat >>"$SERVER_CONF" <<EOF
PostUp     = iptables -t nat -A POSTROUTING -s ${SUBNET_NET} -o ${WAN_IF} -j MASQUERADE
PostDown   = iptables -t nat -D POSTROUTING -s ${SUBNET_NET} -o ${WAN_IF} -j MASQUERADE
EOF
  fi

  systemctl is-enabled "wg-quick@${IFACE}" >/dev/null 2>&1 \
    || systemctl enable "wg-quick@${IFACE}" >/dev/null 2>&1 || true
  systemctl is-active "wg-quick@${IFACE}" >/dev/null 2>&1 \
    || systemctl start "wg-quick@${IFACE}" 2>/dev/null \
    || wg-quick up "$IFACE" 2>/dev/null || true

  log "Adopt OK"
  wg show "$IFACE" 2>/dev/null | head -3 || true
}

cmd_add() {
  require_root; require_wg
  load_config; validate_config; ensure_dirs; ensure_qrencode
  local NAME="${1:-}" IP="${2:-}"
  [[ -z "$NAME" ]] && die "использование: $0 add <имя> [ip]"
  gen_client "$NAME" "$IP"
}

cmd_remove() {
  require_root; load_config; ensure_dirs
  local NAME="${1:-}"
  [[ -z "$NAME" ]] && die "использование: $0 remove <имя>"
  local CLIENT_CONF="${CLIENTS_DIR}/${NAME}.conf"
  [[ -f "$CLIENT_CONF" ]] || die "клиент '$NAME' не найден"
  log "Удаляю клиента '$NAME'"
  python3 - "$SERVER_CONF" "$NAME" <<'PY'
import sys, re
path, name = sys.argv[1], sys.argv[2]
with open(path) as f: text = f.read()
parts = re.split(r'(?=\[Peer\])', text)
out = [p for p in parts if not (p.startswith('[Peer]') and re.search(rf'^\s*#\s*{re.escape(name)}\s*$', p, re.M))]
with open(path, 'w') as f: f.write(''.join(out))
PY
  rm -f "$CLIENT_CONF" "${CLIENTS_DIR}/${NAME}.png"
  apply_config
  log "Клиент '$NAME' удалён"
}

cmd_list() {
  load_config
  [[ -f "$SERVER_CONF" ]] || die "серверный конфиг не найден"
  echo "Клиенты в $SERVER_CONF:"
  echo
  awk '
    /^\[Peer\]/ {name="?"; ip="?"; inpeer=1}
    inpeer && /^#/ {name=$0; sub(/^#\s*/, "", name)}
    inpeer && /AllowedIPs/ {ip=$3}
    inpeer && /^$/ {if(name!="?") printf "  %-20s %s\n", name, ip; inpeer=0}
    END {if(inpeer && name!="?") printf "  %-20s %s\n", name, ip}
  ' "$SERVER_CONF"
  echo
  echo "Конфигов: $(find "$CLIENTS_DIR" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l)"
}

cmd_qr() {
  require_root; load_config; ensure_dirs; ensure_qrencode
  [[ "$GEN_QR" == "true" ]] || die "QR отключены (GEN_QR=false)"
  shopt -s nullglob
  local files=( "$CLIENTS_DIR"/*.conf )
  shopt -u nullglob
  [[ ${#files[@]} -gt 0 ]] || die "нет клиентских конфигов"
  local conf
  for conf in "${files[@]}"; do gen_qr_one "$conf"; done
}

cmd_qr_term() {
  load_config; ensure_qrencode
  local NAME="${1:-}"
  [[ -z "$NAME" ]] && die "использование: $0 qr-term <имя>"
  local CLIENT_CONF="${CLIENTS_DIR}/${NAME}.conf"
  [[ -f "$CLIENT_CONF" ]] || die "клиент '$NAME' не найден"
  qrencode -t ANSIUTF8 < "$CLIENT_CONF"
}

cmd_export() {
  load_config
  local NAME="${1:-}"
  [[ -z "$NAME" ]] && die "использование: $0 export <имя>"
  local CLIENT_CONF="${CLIENTS_DIR}/${NAME}.conf"
  [[ -f "$CLIENT_CONF" ]] || die "клиент '$NAME' не найден"
  cat "$CLIENT_CONF"
}

cmd_reload() {
  require_root; load_config
  [[ -f "$SERVER_CONF" ]] || die "нет $SERVER_CONF"
  log "Применяю $SERVER_CONF без разрыва"
  wg syncconf "$IFACE" <(wg-quick strip "$IFACE")
  log "OK"
}

cmd_show() {
  require_root; load_config
  wg show "$IFACE" >/dev/null 2>&1 || die "интерфейс $IFACE не поднят"
  local map_file
  map_file="$(mktemp)"
  awk '
    $1=="[Peer]"               {inpeer=1; name="?"; key=""}
    inpeer && /^#/             {name=$0; sub(/^#\s*/, "", name)}
    inpeer && $1=="PublicKey"  {key=$3}
    inpeer && NF==0            {if(key) print key "\t" name; inpeer=0}
    END                        {if(inpeer && key) print key "\t" name}
  ' "$SERVER_CONF" > "$map_file"

  printf "%-16s %-15s %-22s %-10s %-10s %-14s\n" \
    "NAME" "IP" "ENDPOINT" "RX" "TX" "LAST HANDSHAKE"
  printf '%.0s-' {1..92}; echo

  local now; now="$(date +%s)"
  # shellcheck disable=SC2034  # psk/keepalive нужны для позиционного чтения
  while IFS=$'\t' read -r pub _psk endpoint allowed handshake rx tx _keepalive; do
    local name ip hs
    name="$(awk -v k="$pub" '$1==k {print $2; exit}' "$map_file")"
    [[ -z "$name" ]] && name="(unknown)"
    ip="${allowed%%,*}"; ip="${ip%/*}"
    [[ -z "$endpoint" || "$endpoint" == "(none)" ]] && endpoint="-"
    if [[ "$handshake" == "0" || -z "$handshake" ]]; then
      hs="never"
    else
      local diff=$(( now - handshake ))
      if   [[ $diff -lt 60    ]]; then hs="${diff}s ago"
      elif [[ $diff -lt 3600  ]]; then hs="$((diff/60))m ago"
      elif [[ $diff -lt 86400 ]]; then hs="$((diff/3600))h ago"
      else                             hs="$((diff/86400))d ago"
      fi
    fi
    printf "%-16s %-15s %-22s %-10s %-10s %-14s\n" \
      "$name" "$ip" "$endpoint" "$(human_bytes "$rx")" "$(human_bytes "$tx")" "$hs"
  done < <(wg show "$IFACE" dump | tail -n +2)
  rm -f "$map_file"
}

cmd_status() {
  load_config
  local iface_status="down"
  wg show "$IFACE" >/dev/null 2>&1 && iface_status="up"
  local peers=0 online=0
  if [[ "$iface_status" == "up" ]]; then
    peers="$(wg show "$IFACE" peers 2>/dev/null | wc -l)"
    online="$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk -v now="$(date +%s)" '$2>0 && now-$2<180' | wc -l)"
  fi
  echo "Interface:  $IFACE ($iface_status)"
  echo "Port:       $PORT"
  echo "Subnet:     $SUBNET_NET"
  echo "Endpoint:   $SERVER_HOST:$PORT"
  echo "Peers:      $peers (online: $online)"
  echo "Config:     $SERVER_CONF"
  echo "Clients:    $(find "$CLIENTS_DIR" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l)"
}

cmd_mail() {
  require_root; load_config
  local var
  for var in SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_SECURE \
             MAIL_FROM MAIL_TO MAIL_SUBJECT_PREFIX; do
    [[ -v "$var" ]] || die "переменная '$var' не задана в $MANAGER_ENV"
  done
  command -v python3 >/dev/null || die "нужен python3"

  shopt -s nullglob
  local pngs=( "$CLIENTS_DIR"/*.png )
  shopt -u nullglob
  if [[ ${#pngs[@]} -eq 0 ]]; then
    log "PNG не найдены — генерирую"; cmd_qr
    shopt -s nullglob; pngs=( "$CLIENTS_DIR"/*.png ); shopt -u nullglob
  fi
  [[ ${#pngs[@]} -gt 0 ]] || die "нет PNG для отправки"

  local arch_name arch_path
  arch_name="wg-qr-$(date +%Y%m%d-%H%M%S).tar.gz"
  arch_path="${ARCHIVE_DIR}/${arch_name}"
  log "Упаковываю ${#pngs[@]} PNG в $arch_path"
  local basenames=()
  for f in "${pngs[@]}"; do basenames+=("$(basename "$f")"); done
  tar -czf "$arch_path" -C "$CLIENTS_DIR" "${basenames[@]}"
  chmod 600 "$arch_path"

  export SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_SECURE
  export MAIL_FROM MAIL_TO MAIL_SUBJECT_PREFIX
  export ARCH_PATH="$arch_path" ARCH_NAME="$arch_name"

  python3 <<'PY'
import os, sys, ssl, smtplib, datetime
from email.message import EmailMessage
host=os.environ["SMTP_HOST"]; port=int(os.environ["SMTP_PORT"])
user=os.environ["SMTP_USER"]; pwd=os.environ["SMTP_PASS"]
secure=os.environ["SMTP_SECURE"].lower()
mail_from=os.environ["MAIL_FROM"]
mail_to=[x.strip() for x in os.environ["MAIL_TO"].split(",") if x.strip()]
prefix=os.environ["MAIL_SUBJECT_PREFIX"]
arch_path=os.environ["ARCH_PATH"]; arch_name=os.environ["ARCH_NAME"]
subject=f"{prefix} {datetime.date.today().isoformat()}"
msg=EmailMessage()
msg["From"]=mail_from; msg["To"]=", ".join(mail_to); msg["Subject"]=subject
msg.set_content("Здравствуйте!\n\nВо вложении архив с QR-кодами клиентских WireGuard-конфигов.\nФайлы содержат приватные ключи — храните их в защищённом месте.\n\nАрхив: "+arch_name+"\n")
with open(arch_path,"rb") as f: data=f.read()
msg.add_attachment(data,maintype="application",subtype="gzip",filename=arch_name)
try:
    if secure=="ssl":
        ctx=ssl.create_default_context()
        with smtplib.SMTP_SSL(host,port,context=ctx,timeout=30) as s:
            s.login(user,pwd); s.send_message(msg)
    elif secure=="starttls":
        with smtplib.SMTP(host,port,timeout=30) as s:
            s.ehlo(); s.starttls(context=ssl.create_default_context()); s.ehlo()
            s.login(user,pwd); s.send_message(msg)
    else:
        with smtplib.SMTP(host,port,timeout=30) as s:
            s.login(user,pwd); s.send_message(msg)
except Exception as e:
    print(f"[!] Ошибка отправки: {e}", file=sys.stderr); sys.exit(1)
print(f"[+] Письмо отправлено: {', '.join(mail_to)}")
PY

  [[ "$KEEP_ARCHIVE" == "true" ]] || { rm -f "$arch_path"; log "Архив удалён"; }
}

case "${1:-}" in
  config)  cmd_config ;;
  init)    cmd_init ;;
  adopt)   cmd_adopt ;;
  add)     shift; cmd_add "$@" ;;
  remove)  shift; cmd_remove "$@" ;;
  list)    cmd_list ;;
  qr)      cmd_qr ;;
  qr-term) shift; cmd_qr_term "$@" ;;
  export)  shift; cmd_export "$@" ;;
  reload)  cmd_reload ;;
  show)    cmd_show ;;
  status)  cmd_status ;;
  mail)    cmd_mail ;;
  *)
    cat <<EOF
wg-manager.sh — управление WireGuard

Использование: $0 <команда> [аргументы]

Команды:
  init                 Создать wg0.conf с нуля
  adopt                Подхватить существующий wg0.conf (из bootstrap.sh)
  add <имя> [ip]       Добавить клиента (PNG QR при GEN_QR=true)
  remove <имя>         Удалить клиента
  list                 Список клиентов из wg0.conf
  qr                   Пересобрать все PNG QR
  qr-term <имя>        QR в терминал (ANSI)
  export <имя>         Показать клиентский конфиг в stdout
  reload               Применить wg0.conf без разрыва
  show                 Таблица клиентов (rx/tx/handshake)
  status               Краткая сводка
  mail                 Отправить архив QR на почту (SMTP из \$MANAGER_ENV)
  config               Показать текущие настройки

Конфиги:
  $INFRA_ENV
  $MANAGER_ENV
  $LEGACY_CONF
EOF
    exit 1 ;;
esac

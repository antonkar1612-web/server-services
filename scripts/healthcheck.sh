#!/usr/bin/env bash
# healthcheck.sh — сводка состояния сервера: docker, wg, ufw, диск, fail2ban.
#
#   sudo ./healthcheck.sh
#   sudo ./healthcheck.sh --quiet   # только проблемы, exit != 0 если есть

set -euo pipefail

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

ok()   { [[ "$QUIET" == "1" ]] || echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; ISSUES=$((ISSUES + 1)); }
err()  { echo "  ❌ $*"; ISSUES=$((ISSUES + 1)); }
hdr()  { [[ "$QUIET" == "1" ]] || { echo ""; echo "=== $* ==="; }; }

ISSUES=0

check_docker() {
  hdr "Docker"
  if ! command -v docker >/dev/null; then err "docker не установлен"; return; fi
  if systemctl is-active --quiet docker; then ok "docker active"; else err "docker не запущен"; fi
  local n; n="$(docker ps -q 2>/dev/null | wc -l)"
  ok "контейнеров запущено: $n"
  local unhealthy
  unhealthy="$(docker ps --filter health=unhealthy -q 2>/dev/null | wc -l)"
  if [[ "$unhealthy" -eq 0 ]]; then
    ok "unhealthy: 0"
  else
    err "unhealthy контейнеров: $unhealthy"
  fi
}

check_wireguard() {
  hdr "WireGuard"
  if ! command -v wg >/dev/null; then err "wg не установлен"; return; fi
  local iface
  for iface in /etc/wireguard/*.conf; do
    [[ -f "$iface" ]] || continue
    local name; name="$(basename "$iface" .conf)"
    if wg show "$name" >/dev/null 2>&1; then
      local peers; peers="$(wg show "$name" peers | wc -l)"
      ok "wg0 '$name' up, peers: $peers"
    else
      err "wg0 '$name' down"
    fi
  done
}

check_ufw() {
  hdr "Firewall"
  if ! command -v ufw >/dev/null; then warn "ufw не установлен"; return; fi
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    ok "ufw active"
  else
    err "ufw неактивен"
  fi
}

check_fail2ban() {
  hdr "fail2ban"
  if ! command -v fail2ban-client >/dev/null; then warn "fail2ban не установлен"; return; fi
  if systemctl is-active --quiet fail2ban; then
    local banned
    banned="$(fail2ban-client status 2>/dev/null | grep -oP 'Jail list:\s+\K.*' || true)"
    ok "fail2ban active (jails: ${banned:-none})"
  else
    err "fail2ban не запущен"
  fi
}

check_disk() {
  hdr "Диск"
  local use path pct
  for path in / /var /root; do
    [[ -d "$path" ]] || continue
    pct="$(df -P "$path" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
    use="$(df -h "$path" | awk 'NR==2 {print $5}')"
    if [[ "$pct" -ge 90 ]]; then
      err "$path занято $use"
    elif [[ "$pct" -ge 75 ]]; then
      warn "$path занято $use"
    else
      ok "$path занято $use"
    fi
  done
}

check_memory() {
  hdr "RAM"
  local total used pct
  total="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  used="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
  pct=$(( 100 - used * 100 / total ))
  if [[ "$pct" -ge 90 ]]; then
    err "RAM занято ${pct}%"
  elif [[ "$pct" -ge 75 ]]; then
    warn "RAM занято ${pct}%"
  else
    ok "RAM занято ${pct}%"
  fi
}

check_load() {
  hdr "Load"
  local la1 la5 la15 cores
  read -r la1 la5 la15 _ < /proc/loadavg
  cores="$(nproc)"
  ok "load: $la1 / $la5 / $la15 (cores: $cores)"
  if awk -v l="$la1" -v c="$cores" 'BEGIN { exit (l > c*1.5) ? 0 : 1 }'; then
    err "load1 > 1.5 * cores"
  fi
}

check_services() {
  hdr "Systemd"
  local svc
  for svc in docker wg-quick@wg0 fail2ban ssh; do
    if systemctl list-unit-files "$svc.service" >/dev/null 2>&1 \
       && systemctl is-active --quiet "$svc" 2>/dev/null; then
      ok "$svc active"
    elif systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
      err "$svc не запущен"
    fi
  done
}

main() {
  local start; start="$(date +%s)"
  check_docker
  check_wireguard
  check_ufw
  check_fail2ban
  check_services
  check_disk
  check_memory
  check_load
  local dur=$(( $(date +%s) - start ))
  echo ""
  if [[ "$ISSUES" -eq 0 ]]; then
    echo "✅ Всё в порядке (${dur}s)"
    exit 0
  else
    echo "⚠️  Проблем: $ISSUES (${dur}s)"
    exit 1
  fi
}

main

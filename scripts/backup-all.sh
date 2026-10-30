#!/usr/bin/env bash
# backup-all.sh — бэкап секретов, WireGuard, docker volumes.
#
#   sudo ./backup-all.sh
#   BACKUP_CONFIG=/path ./backup-all.sh
#
# Конфиг: /root/secrets/backup.env (опционально)

set -euo pipefail

LOG_FILE="${BACKUP_LOG:-/var/log/backup-all.log}"
if [[ "$(id -u)" == "0" ]] && command -v tee >/dev/null; then
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  if touch "$LOG_FILE" 2>/dev/null; then
    exec > >(tee -a "$LOG_FILE") 2>&1
  fi
fi

CONFIG_FILE="${BACKUP_CONFIG:-/root/secrets/backup.env}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  : "${BACKUP_DIR:=/var/backups/server-services}"
  : "${KEEP_DAYS:=14}"
  : "${MIN_FREE_MB:=500}"
  : "${LOCK_FILE:=/var/run/backup-all.lock}"
  : "${SOURCES:=/root/secrets /etc/wireguard}"
  : "${DOCKER_VOLUMES:=}"

  read -ra SOURCES_ARR <<< "$SOURCES"
  read -ra VOLUMES_ARR <<< "$DOCKER_VOLUMES"
}

acquire_lock() {
  command -v flock >/dev/null || die "нет flock (apt-get install util-linux)"
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    die "бэкап уже выполняется (lock: $LOCK_FILE)"
  fi
}

check_sources() {
  [[ ${#SOURCES_ARR[@]} -gt 0 ]] || die "SOURCES пуст"
  local src found=0
  for src in "${SOURCES_ARR[@]}"; do
    if [[ -e "$src" ]]; then
      found=$((found + 1))
    else
      warn "источник отсутствует: $src"
    fi
  done
  [[ $found -gt 0 ]] || die "ни один из SOURCES не найден: $SOURCES"
}

check_free_space() {
  mkdir -p "$BACKUP_DIR"
  local avail_mb
  avail_mb="$(df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
  [[ -n "$avail_mb" ]] || die "не удалось проверить место в $BACKUP_DIR"
  [[ "$avail_mb" -ge "$MIN_FREE_MB" ]] \
    || die "мало места в $BACKUP_DIR: ${avail_mb}MB < ${MIN_FREE_MB}MB"
  log "свободно на $BACKUP_DIR: ${avail_mb}MB"
}

backup_files() {
  local ts="$1"
  local out="${BACKUP_DIR}/files-${ts}.tar.gz"
  log "архивирую: ${SOURCES_ARR[*]} → $out"

  local rc=0
  tar -czf "$out" --warning=no-file-changed "${SOURCES_ARR[@]}" 2>/dev/null || rc=$?
  if [[ $rc -ne 0 && $rc -ne 1 ]]; then
    die "tar failed rc=$rc"
  fi
  if [[ $rc -eq 1 ]]; then
    warn "tar: были изменяемые файлы — архив создан"
  fi

  chmod 600 "$out"
  log "создан $out ($(du -h "$out" | cut -f1))"
  LAST_ARCHIVE="$out"
}

backup_volumes() {
  local ts="$1"
  if [[ ${#VOLUMES_ARR[@]} -eq 0 ]]; then
    log "DOCKER_VOLUMES пуст — volumes не бэкапятся"
    return 0
  fi
  command -v docker >/dev/null || { warn "docker не установлен — volumes пропущены"; return 0; }

  local vol mount out
  for vol in "${VOLUMES_ARR[@]}"; do
    mount="$(docker volume inspect -f '{{.Mountpoint}}' "$vol" 2>/dev/null || true)"
    if [[ -z "$mount" || ! -d "$mount" ]]; then
      warn "volume '$vol' не найден (mountpoint: '${mount:-}')"
      continue
    fi
    out="${BACKUP_DIR}/volume-${vol}-${ts}.tar.gz"
    log "volume '$vol' → $out"
    tar -czf "$out" -C "$mount" . 2>/dev/null || warn "tar warnings при '$vol'"
    chmod 600 "$out"
    log "создан $out ($(du -h "$out" | cut -f1))"
  done
}

verify_archive() {
  log "проверяю целостность $LAST_ARCHIVE"
  tar -tzf "$LAST_ARCHIVE" >/dev/null || die "повреждён архив $LAST_ARCHIVE"
}

cleanup_old() {
  log "удаляю бэкапы старше $KEEP_DAYS дней из $BACKUP_DIR"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' \
    -mtime "+${KEEP_DAYS}" -print -delete || true
}

main() {
  [[ $EUID -eq 0 ]] || die "запуск от root"
  load_config
  acquire_lock
  check_sources
  check_free_space

  local ts; ts="$(date +%Y%m%d-%H%M%S-%N)"
  LAST_ARCHIVE=""
  backup_files "$ts"
  verify_archive
  backup_volumes "$ts"
  cleanup_old

  log "=== бэкап завершён: $BACKUP_DIR ==="
  find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' \
    -printf '%M %10s  %f\n' 2>/dev/null | sort -k3 || true
}

main "$@"

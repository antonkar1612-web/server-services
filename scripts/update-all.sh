#!/usr/bin/env bash
# update-all.sh — обновление apt + docker compose сервисов.
#
#   sudo ./update-all.sh
#   sudo ./update-all.sh --apt-only
#   sudo ./update-all.sh --docker-only
#   sudo ./update-all.sh --dry-run
#
# Конфиг: /root/secrets/update.env (опционально)

set -euo pipefail

LOG_FILE="${UPDATE_LOG:-/var/log/update-all.log}"
if [[ "$(id -u)" == "0" ]] && command -v tee >/dev/null; then
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  if touch "$LOG_FILE" 2>/dev/null; then
    exec > >(tee -a "$LOG_FILE") 2>&1
  fi
fi

CONFIG_FILE="${UPDATE_CONFIG:-/root/secrets/update.env}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
die()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

MODE="all"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apt-only)    MODE="apt" ;;
    --docker-only) MODE="docker" ;;
    --dry-run)     DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
  shift
done

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  : "${COMPOSE_DIRS:=}"
  : "${APT_AUTOREMOVE:=true}"
  : "${DOCKER_PRUNE:=false}"
  read -ra COMPOSE_DIRS_ARR <<< "$COMPOSE_DIRS"
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY: $*"
  else
    "$@"
  fi
}

update_apt() {
  log "=== apt ==="
  run apt-get update -y
  run apt-get upgrade -y
  if [[ "$APT_AUTOREMOVE" == "true" ]]; then
    run apt-get autoremove -y
    run apt-get autoclean -y
  fi
  log "apt готов"
}

update_docker() {
  log "=== docker compose ==="
  command -v docker >/dev/null || { warn "docker не установлен — пропускаю"; return 0; }
  if [[ ${#COMPOSE_DIRS_ARR[@]} -eq 0 ]]; then
    log "COMPOSE_DIRS пуст — docker обновлять нечего"
    return 0
  fi
  local dir
  for dir in "${COMPOSE_DIRS_ARR[@]}"; do
    if [[ ! -f "$dir/docker-compose.yml" && ! -f "$dir/compose.yml" ]]; then
      warn "нет docker-compose.yml в $dir — пропускаю"
      continue
    fi
    log "обновляю $dir"
    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY: (cd $dir && docker compose pull && docker compose up -d)"
    else
      ( cd "$dir" && docker compose pull && docker compose up -d --remove-orphans )
    fi
  done
  if [[ "$DOCKER_PRUNE" == "true" ]]; then
    log "prune старых образов"
    run docker image prune -f
  fi
}

main() {
  [[ $EUID -eq 0 ]] || die "запуск от root"
  load_config
  [[ "$MODE" == "all"    || "$MODE" == "apt"    ]] && update_apt
  [[ "$MODE" == "all"    || "$MODE" == "docker" ]] && update_docker
  log "=== обновление завершено ==="
}

main "$@"

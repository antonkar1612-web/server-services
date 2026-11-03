#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/backup-gdrive.log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "=== rclone sync started at $(date -Is) ==="

# Синхронизация локальной папки с папкой server-backups на GDrive
rclone sync /var/backups/server-services/ gdrive:server-backups --verbose

echo "=== rclone sync completed at $(date -Is) ==="

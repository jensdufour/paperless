#!/bin/bash
set -euo pipefail

# =============================================================================
# Paperless NGX Backup Script (Proxmox LXC)
#
# Creates a full backup that can be used to restore on a new machine:
#   - Paperless document exporter (metadata + originals)
#   - PostgreSQL database dump
#   - rclone config
#   - Uploads everything to OneDrive
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${PROJECT_DIR}/backups"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_NAME="paperless-backup-${TIMESTAMP}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Load environment
ENV_FILE="${PROJECT_DIR}/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found at $ENV_FILE"
    exit 1
fi
set -a
source "$ENV_FILE"
set +a

mkdir -p "$BACKUP_DIR"
mkdir -p "${PAPERLESS_EXPORT}"

# ---- Step 1: Run Paperless document exporter ----
log "Running Paperless document exporter..."
cd /opt/paperless/src
sudo -u paperless python3 manage.py document_exporter "${PAPERLESS_EXPORT}" --no-progress-bar

# ---- Step 2: Dump PostgreSQL database ----
log "Dumping PostgreSQL database..."
sudo -u postgres pg_dump -Fc paperless > "${BACKUP_DIR}/db_backup.dump"

# ---- Step 3: Package backup ----
log "Packaging backup..."
tar -czf "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" \
    -C / \
    "${PAPERLESS_EXPORT#/}" \
    -C "$PROJECT_DIR" \
    .env \
    scripts/ \
    -C /root \
    .config/rclone/ \
    -C "$BACKUP_DIR" \
    db_backup.dump

rm -f "${BACKUP_DIR}/db_backup.dump"

# ---- Step 4: Upload to OneDrive ----
log "Uploading backup to OneDrive..."
rclone copy \
    "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" \
    "${RCLONE_REMOTE}:${ONEDRIVE_BACKUPS}/" \
    --log-level INFO

log "Backup complete: ${BACKUP_NAME}.tar.gz"
log "Backup uploaded to OneDrive: ${ONEDRIVE_BACKUPS}/${BACKUP_NAME}.tar.gz"

# Keep only the last 5 local backups
ls -t "${BACKUP_DIR}"/paperless-backup-*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm

#!/bin/bash
set -euo pipefail

# =============================================================================
# Paperless NGX Backup Script (Proxmox LXC)
#
# Creates a lightweight backup containing only what the sync does NOT cover:
#   - PostgreSQL database dump (metadata, tags, correspondents, rules, etc.)
#   - rclone config (OneDrive auth)
#   - Scripts and .env
#
# Document files are NOT included since they are already synced to OneDrive
# Archive by the sync script. The restore script pulls them back from there.
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

# ---- Step 1: Dump PostgreSQL database ----
log "Dumping PostgreSQL database..."
sudo -u postgres pg_dump -Fc paperless > "${BACKUP_DIR}/db_backup.dump"

# ---- Step 2: Package backup ----
log "Packaging backup..."
tar -czf "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" \
    -C "$PROJECT_DIR" \
    .env \
    scripts/ \
    -C /root \
    .config/rclone/ \
    -C "$BACKUP_DIR" \
    db_backup.dump

rm -f "${BACKUP_DIR}/db_backup.dump"

# ---- Step 3: Upload to OneDrive ----
log "Uploading backup to OneDrive..."
rclone copy \
    "${BACKUP_DIR}/${BACKUP_NAME}.tar.gz" \
    "${RCLONE_REMOTE}:${ONEDRIVE_BACKUPS}/" \
    --log-level INFO

log "Backup complete: ${BACKUP_NAME}.tar.gz"
log "Backup uploaded to OneDrive: ${ONEDRIVE_BACKUPS}/${BACKUP_NAME}.tar.gz"

# Keep only the last 5 local backups
ls -t "${BACKUP_DIR}"/paperless-backup-*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm

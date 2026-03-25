#!/bin/bash
set -euo pipefail

# =============================================================================
# Paperless NGX Restore Script (Proxmox LXC)
#
# Restores a Paperless NGX installation from a backup archive.
# The backup contains only the database dump, config, and scripts.
# Document files are pulled from OneDrive Archive (where sync put them).
#
# Run this inside a fresh Proxmox LXC created with the community script.
#
# Usage: ./scripts/restore.sh <path-to-backup.tar.gz>
# =============================================================================

if [ $# -lt 1 ]; then
    echo "Usage: $0 <path-to-backup.tar.gz>"
    echo ""
    echo "Prerequisites:"
    echo "  1. Create a fresh Paperless NGX LXC using the community script:"
    echo "     https://community-scripts.org/scripts/paperless-ngx"
    echo "  2. Install rclone: curl https://rclone.org/install.sh | bash"
    echo "  3. Download the backup from OneDrive:"
    echo "     rclone copy onedrive:Documents/Paperless/Backups/<backup>.tar.gz /tmp/"
    exit 1
fi

BACKUP_FILE="$1"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: Backup file not found: $BACKUP_FILE"
    exit 1
fi

# ---- Step 1: Extract backup to temp dir ----
log "Extracting backup..."
RESTORE_DIR=$(mktemp -d)
tar -xzf "$BACKUP_FILE" -C "$RESTORE_DIR"

# ---- Step 2: Load environment ----
if [ -f "$RESTORE_DIR/.env" ]; then
    set -a
    source "$RESTORE_DIR/.env"
    set +a
fi

# ---- Step 3: Restore rclone config ----
log "Restoring rclone configuration..."
if [ -d "$RESTORE_DIR/.config/rclone" ]; then
    mkdir -p /root/.config/rclone
    cp "$RESTORE_DIR/.config/rclone/rclone.conf" /root/.config/rclone/ 2>/dev/null || true
fi

# ---- Step 4: Restore scripts and config ----
log "Restoring scripts..."
SCRIPTS_TARGET="/opt/paperless-sync"
mkdir -p "$SCRIPTS_TARGET/scripts"
cp "$RESTORE_DIR/.env" "$SCRIPTS_TARGET/" 2>/dev/null || true
cp -r "$RESTORE_DIR/scripts/"* "$SCRIPTS_TARGET/scripts/" 2>/dev/null || true
chmod +x "$SCRIPTS_TARGET/scripts/"*.sh

# ---- Step 5: Stop Paperless ----
log "Stopping Paperless service..."
systemctl stop paperless-webserver paperless-consumer paperless-scheduler 2>/dev/null || true

# ---- Step 6: Restore PostgreSQL database ----
log "Restoring PostgreSQL database..."
if [ -f "$RESTORE_DIR/db_backup.dump" ]; then
    sudo -u postgres pg_restore \
        -d paperlessdb \
        --clean \
        --if-exists \
        "$RESTORE_DIR/db_backup.dump" || true
fi

# ---- Step 7: Pull document files from OneDrive Archive ----
log "Downloading documents from OneDrive Archive..."
ORIGINALS_DIR="${PAPERLESS_MEDIA:-/opt/paperless_data/media}/documents/originals"
mkdir -p "$ORIGINALS_DIR"
rclone copy \
    "${RCLONE_REMOTE:-onedrive}:${ONEDRIVE_ARCHIVE:-Documents/Paperless/Archive}" \
    "$ORIGINALS_DIR" \
    --log-level INFO \
    --transfers 8
chown -R paperless:paperless "$ORIGINALS_DIR"

# ---- Step 8: Start Paperless and rebuild index ----
log "Starting Paperless services..."
systemctl start paperless-webserver paperless-consumer paperless-scheduler
sleep 10

log "Rebuilding search index..."
cd /opt/paperless/src
/opt/paperless/.venv/bin/python3 manage.py document_index reindex

# ---- Step 9: Cleanup ----
rm -rf "$RESTORE_DIR"

log "Restore complete!"
log "Paperless NGX should be available at the configured URL."
log "Run the install script to set up sync cron and FTP if needed."

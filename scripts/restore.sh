#!/bin/bash
set -euo pipefail

# =============================================================================
# Paperless NGX Restore Script (Proxmox LXC)
#
# Restores a full Paperless NGX installation from a backup archive.
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

# ---- Step 3: Stop Paperless ----
log "Stopping Paperless service..."
systemctl stop paperless-webserver paperless-consumer paperless-scheduler 2>/dev/null || true

# ---- Step 4: Restore PostgreSQL database ----
log "Restoring PostgreSQL database..."
if [ -f "$RESTORE_DIR/db_backup.dump" ]; then
    sudo -u postgres pg_restore \
        -d paperless \
        --clean \
        --if-exists \
        "$RESTORE_DIR/db_backup.dump" || true
fi

# ---- Step 5: Restore document export ----
log "Importing documents from export..."
EXPORT_DIR="${PAPERLESS_EXPORT:-/opt/paperless/export}"
if [ -d "$RESTORE_DIR/${EXPORT_DIR#/}" ]; then
    cp -r "$RESTORE_DIR/${EXPORT_DIR#/}"/* "$EXPORT_DIR/" 2>/dev/null || true
fi

# ---- Step 6: Restore rclone config ----
log "Restoring rclone configuration..."
if [ -d "$RESTORE_DIR/.config/rclone" ]; then
    mkdir -p /root/.config/rclone
    cp "$RESTORE_DIR/.config/rclone/rclone.conf" /root/.config/rclone/ 2>/dev/null || true
fi

# ---- Step 7: Restore scripts and config ----
log "Restoring scripts..."
SCRIPTS_TARGET="/opt/paperless-sync"
mkdir -p "$SCRIPTS_TARGET/scripts"
cp "$RESTORE_DIR/.env" "$SCRIPTS_TARGET/" 2>/dev/null || true
cp -r "$RESTORE_DIR/scripts/"* "$SCRIPTS_TARGET/scripts/" 2>/dev/null || true
chmod +x "$SCRIPTS_TARGET/scripts/"*.sh

# ---- Step 8: Import documents into Paperless ----
log "Running Paperless document importer..."
systemctl start paperless-webserver paperless-consumer paperless-scheduler
sleep 10
cd /opt/paperless/src
sudo -u paperless python3 manage.py document_importer "$EXPORT_DIR"

# ---- Step 9: Cleanup ----
rm -rf "$RESTORE_DIR"

log "Restore complete!"
log "Paperless NGX should be available at the configured URL."
log "Run the install script to set up sync cron and FTP if needed."

#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <official-export-directory> [config-bundle.tar.gz]"
    echo "The target must be a fresh Paperless installation on the same version."
    exit 1
fi

if [[ $(id -u) -ne 0 ]]; then
    echo "Error: this script must run as root."
    exit 1
fi

EXPORT_DIR="$(realpath "$1")"
CONFIG_BUNDLE="${2:-}"
INFO_FILE="${EXPORT_DIR}/backup-info.txt"
UV=/usr/local/bin/uv
SERVICES=(paperless-consumer paperless-task-queue paperless-scheduler paperless-webserver)
services_stopped=0

if [[ ! -s "${EXPORT_DIR}/manifest.json" || ! -s "$INFO_FILE" ]]; then
    echo "Error: source is not a complete official Paperless export."
    exit 1
fi

start_services() {
    if ((services_stopped)); then
        systemctl start "${SERVICES[@]}"
    fi
}
trap start_services EXIT

backup_version=$(sed -n 's/^paperless_version=//p' "$INFO_FILE")
installed_version=$(
    cd /opt/paperless/src
    PAPERLESS_CONFIGURATION_PATH=/opt/paperless/paperless.conf \
        DJANGO_SETTINGS_MODULE=paperless.settings \
        "$UV" run manage.py version
)
if [[ "$backup_version" != "$installed_version" ]]; then
    echo "Error: backup version $backup_version does not match installed version $installed_version."
    exit 1
fi

if [[ -n "$CONFIG_BUNDLE" ]]; then
    if [[ ! -f "$CONFIG_BUNDLE" ]]; then
        echo "Error: config bundle not found: $CONFIG_BUNDLE"
        exit 1
    fi
    if tar -tzf "$CONFIG_BUNDLE" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
        echo "Error: unsafe path in config bundle."
        exit 1
    fi
    tar -xzf "$CONFIG_BUNDLE" -C /
    chmod 600 \
        /opt/paperless/paperless.conf \
        /opt/paperless-sync/.env \
        /root/paperless-ngx.creds \
        /root/.config/rclone/rclone.conf
    systemctl daemon-reload
fi

cd /opt/paperless/src
export PAPERLESS_CONFIGURATION_PATH=/opt/paperless/paperless.conf
export DJANGO_SETTINGS_MODULE=paperless.settings
existing_documents=$("$UV" run python - <<'PY'
import django

django.setup()

from documents.models import Document

print(Document.global_objects.count())
PY
)
if [[ "$existing_documents" != 0 ]]; then
    echo "Error: restore requires an empty Paperless database; found $existing_documents documents."
    exit 1
fi

systemctl stop "${SERVICES[@]}"
services_stopped=1

"$UV" run manage.py migrate --noinput
"$UV" run manage.py document_importer "$EXPORT_DIR" --no-progress-bar
"$UV" run manage.py document_index reindex --if-needed
"$UV" run manage.py document_create_classifier
chmod 640 /opt/paperless_data/data/classification_model.pickle

start_services
services_stopped=0
trap - EXIT

"$UV" run manage.py document_sanity_checker
echo "Restore complete and sanity-checked."
#!/bin/bash
set -euo pipefail

# =============================================================================
# Paperless NGX Restore Script (Proxmox LXC)
#
# Restores a Paperless NGX installation from a backup archive.
# The backup contains the database dump, paperless.conf, rclone config,
# scripts, and .env. Document files are pulled from OneDrive Archive.
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

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

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

# ---- Step 5: Restore paperless.conf ----
log "Restoring Paperless configuration..."
if [ -f "$RESTORE_DIR/paperless.conf" ]; then
    cp "$RESTORE_DIR/paperless.conf" /opt/paperless/paperless.conf
    chown paperless:paperless /opt/paperless/paperless.conf
    log "paperless.conf restored."
else
    log "Warning: No paperless.conf in backup. Running install.sh will configure it."
fi

# ---- Step 6: Install OCR language packages ----
log "Installing OCR language packages..."
OCR_LANG="${PAPERLESS_OCR_LANGUAGE:-nld}"
IFS='+' read -ra LANGS <<< "$OCR_LANG"
for lang in "${LANGS[@]}"; do
    pkg="tesseract-ocr-${lang}"
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        apt-get update -qq
        apt-get install -y -qq "$pkg"
    fi
done

# ---- Step 7: Stop Paperless ----
log "Stopping Paperless services..."
systemctl stop paperless-webserver paperless-consumer paperless-scheduler paperless-task-queue 2>/dev/null || true

# ---- Step 8: Restore PostgreSQL database ----
log "Restoring PostgreSQL database..."
if [ -f "$RESTORE_DIR/db_backup.dump" ]; then
    sudo -u postgres pg_restore \
        -d paperlessdb \
        --clean \
        --if-exists \
        "$RESTORE_DIR/db_backup.dump" || true
fi

# ---- Step 9: Pull document files from OneDrive Archive ----
log "Downloading documents from OneDrive Archive..."
ORIGINALS_DIR="${PAPERLESS_MEDIA:-/opt/paperless_data/media}/documents/originals"
mkdir -p "$ORIGINALS_DIR"
rclone copy \
    "${RCLONE_REMOTE:-onedrive}:${ONEDRIVE_ARCHIVE:-Documents/Paperless/Archive}" \
    "$ORIGINALS_DIR" \
    --log-level INFO \
    --transfers 8
chown -R paperless:paperless "$ORIGINALS_DIR"

# ---- Step 10: Start Paperless and rebuild index ----
log "Starting Paperless services..."
systemctl start paperless-webserver paperless-consumer paperless-scheduler paperless-task-queue
sleep 10

log "Rebuilding search index..."
cd /opt/paperless/src
/opt/paperless/.venv/bin/python3 manage.py document_index reindex

# ---- Step 11: Set up cron jobs ----
log "Running install script for cron jobs and remaining config..."
if [ -f "$SCRIPTS_TARGET/scripts/install.sh" ]; then
    bash "$SCRIPTS_TARGET/scripts/install.sh"
fi

# ---- Step 12: Cleanup ----
rm -rf "$RESTORE_DIR"

log "Restore complete!"
log "Paperless NGX should be available at the configured URL."

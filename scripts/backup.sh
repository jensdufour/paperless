#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"
BACKUP_DIR="${PROJECT_DIR}/backups"
EXPORT_DIR="${BACKUP_DIR}/official-export-v5"
CONFIG_DIR="${BACKUP_DIR}/config"
LOCKFILE="/run/lock/paperless-maintenance.lock"
LOCK_WAIT_SECONDS=300
STAMP=$(date '+%Y%m%d_%H%M%S')
UV=/usr/local/bin/uv
SERVICES=(paperless-consumer paperless-task-queue paperless-scheduler paperless-webserver)
services_stopped=0

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: .env file not found at $ENV_FILE"
    exit 1
fi

CONFIG_PATHS=(
    opt/paperless/paperless.conf
    opt/paperless-sync/.env
    opt/paperless-sync/scripts
    root/.paperless
    root/paperless-ngx.creds
    root/.config/rclone/rclone.conf
    etc/systemd/system/paperless-consumer.service.d/10-hardening.conf
    etc/systemd/system/paperless-task-queue.service.d/10-hardening.conf
    etc/systemd/system/paperless-scheduler.service.d/10-hardening.conf
    etc/systemd/system/paperless-webserver.service.d/10-hardening.conf
)
set -a
source "$ENV_FILE"
set +a

REMOTE_ROOT="${RCLONE_REMOTE}:${ONEDRIVE_BACKUPS}"
REMOTE_EXPORT="${REMOTE_ROOT}/official-export-v5"
CONFIG_BUNDLE="${CONFIG_DIR}/paperless-config-${STAMP}.tar.gz"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

start_services() {
    if ((services_stopped)); then
        systemctl start "${SERVICES[@]}"
        services_stopped=0
    fi
}
trap start_services EXIT

exec 9>"$LOCKFILE"
if ! flock -w "$LOCK_WAIT_SECONDS" 9; then
    log "Error: Paperless maintenance lock remained busy for ${LOCK_WAIT_SECONDS}s; backup failed."
    exit 1
fi

install -d -m 700 "$BACKUP_DIR" "$EXPORT_DIR" "$CONFIG_DIR"

log "Stopping Paperless for a consistent official export."
systemctl stop "${SERVICES[@]}"
services_stopped=1

cd /opt/paperless/src
export PAPERLESS_CONFIGURATION_PATH=/opt/paperless/paperless.conf
export DJANGO_SETTINGS_MODULE=paperless.settings
"$UV" run manage.py document_exporter \
    "$EXPORT_DIR" \
    --no-progress-bar \
    --compare-checksums \
    --compare-json \
    --delete \
    --use-folder-prefix

test -s "${EXPORT_DIR}/manifest.json"

read -r active_documents total_documents tags document_types < <(
    "$UV" run python - <<'PY'
import django

django.setup()

from documents.models import Document, DocumentType, Tag

print(
    Document.objects.count(),
    Document.global_objects.count(),
    Tag.objects.count(),
    DocumentType.objects.count(),
)
PY
)

paperless_version=$("$UV" run manage.py version)

cat >"${EXPORT_DIR}/backup-info.txt" <<EOF
paperless_version=${paperless_version}
created_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
active_documents=${active_documents}
total_documents=${total_documents}
tags=${tags}
document_types=${document_types}
manifest_sha256=$(sha256sum "${EXPORT_DIR}/manifest.json" | cut -d' ' -f1)
EOF

if [[ -f /etc/cron.d/paperless-sync ]]; then
    CONFIG_PATHS+=(etc/cron.d/paperless-sync)
elif [[ -f /etc/cron.d/paperless-sync.disabled ]]; then
    CONFIG_PATHS+=(etc/cron.d/paperless-sync.disabled)
fi

tar -czf "$CONFIG_BUNDLE" -C / "${CONFIG_PATHS[@]}"
chmod 600 "$CONFIG_BUNDLE"

start_services
trap - EXIT

log "Testing the export with an isolated database and media tree."
"${SCRIPT_DIR}/verify-backup.sh" "$EXPORT_DIR"

log "Mirroring the self-contained official export to OneDrive."
rclone sync \
    "$EXPORT_DIR" \
    "$REMOTE_EXPORT" \
    --checksum \
    --max-delete 100 \
    --log-level INFO \
    --checkers 4 \
    --transfers 4

log "Verifying every local export file exists in OneDrive."
rclone check \
    "$EXPORT_DIR" \
    "$REMOTE_EXPORT" \
    --one-way \
    --checksum \
    --checkers 4

rclone copy \
    "$CONFIG_BUNDLE" \
    "${REMOTE_ROOT}/config/" \
    --checksum \
    --log-level INFO

find "$CONFIG_DIR" -maxdepth 1 -type f -name 'paperless-config-*.tar.gz' \
    -printf '%T@ %p\n' | sort -nr | tail -n +6 | cut -d' ' -f2- | xargs -r rm -f

log "Backup complete and restore-verified: ${REMOTE_EXPORT}"

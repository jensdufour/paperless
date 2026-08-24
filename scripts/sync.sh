#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: .env file not found at $ENV_FILE"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

ORIGINALS_DIR="${PAPERLESS_MEDIA}/documents/originals"
CONSUME_DIR="${PAPERLESS_CONSUME}"
ONEDRIVE_ARCHIVE="${RCLONE_REMOTE}:${ONEDRIVE_ARCHIVE}"
ONEDRIVE_SCAN="${RCLONE_REMOTE}:${ONEDRIVE_SCAN}"
LOCKFILE="/run/lock/paperless-maintenance.lock"
MODE="${1:-all}"

if [[ "$MODE" != "all" && "$MODE" != "archive" && "$MODE" != "scan" ]]; then
    echo "Usage: $0 [all|archive|scan]"
    exit 2
fi

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

exec 9>"$LOCKFILE"
if ! flock -n 9; then
    log "Paperless maintenance is already running; sync skipped."
    exit 0
fi

if [[ "$MODE" == "all" || "$MODE" == "archive" ]]; then
    if [[ -d "$ORIGINALS_DIR" ]]; then
        original_count=$(find "$ORIGINALS_DIR" -type f -printf . | wc -c)
        if ((original_count == 0)); then
            log "Refusing to sync an empty originals directory."
            exit 1
        fi

        log "Mirroring ${original_count} originals to OneDrive Archive."
        rclone sync \
            "$ORIGINALS_DIR" \
            "$ONEDRIVE_ARCHIVE" \
            --checksum \
            --max-delete 50 \
            --log-level INFO \
            --checkers 4 \
            --transfers 4
    else
        log "No originals directory at $ORIGINALS_DIR; upload skipped."
    fi
fi

if [[ "$MODE" == "all" || "$MODE" == "scan" ]]; then
    log "Moving phone scans from OneDrive Scan into Paperless consume."
    rclone move \
        "$ONEDRIVE_SCAN" \
        "$CONSUME_DIR" \
        --log-level INFO \
        --checkers 4 \
        --transfers 4
fi

log "${MODE^} sync complete."

#!/bin/bash
set -euo pipefail

# =============================================================================
# Bidirectional OneDrive Sync Script
#
# Syncs Paperless originals -> OneDrive Archive (upload processed documents)
# Syncs OneDrive Scan folder -> Paperless consume (download for processing)
#
# Designed for Paperless NGX on Proxmox (community script install).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [ ! -f "$ENV_FILE" ]; then
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
LOCKFILE="/tmp/paperless-sync.lock"
LOGFILE="/var/log/paperless-sync.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

# Prevent overlapping runs
if [ -f "$LOCKFILE" ]; then
    pid=$(cat "$LOCKFILE")
    if kill -0 "$pid" 2>/dev/null; then
        log "Sync already running (PID $pid), skipping."
        exit 0
    fi
    rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# ---- Step 1: Upload processed documents to OneDrive Archive ----
# One-way sync: Paperless originals -> OneDrive Documents/Paperless/Archive
# This makes all processed/renamed documents available in OneDrive
if [ -d "$ORIGINALS_DIR" ]; then
    log "Syncing processed documents to OneDrive Archive..."
    rclone sync \
        "$ORIGINALS_DIR" \
        "$ONEDRIVE_ARCHIVE" \
        --log-level INFO \
        --checkers 4 \
        --transfers 4 \
        --ignore-existing
else
    log "No originals directory yet ($ORIGINALS_DIR), skipping upload."
fi

# ---- Step 2: Download phone scans from OneDrive Scan folder ----
# One-way move: OneDrive Documents/Paperless/Scan -> Paperless consume folder
# Files scanned via OneDrive mobile app go into the Scan folder,
# they get moved (not copied) into consume so Paperless processes them,
# and the Scan folder is cleared after successful transfer.
log "Downloading phone scans from OneDrive Scan..."
rclone move \
    "$ONEDRIVE_SCAN" \
    "$CONSUME_DIR" \
    --log-level INFO \
    --checkers 4 \
    --transfers 4

log "Sync complete."

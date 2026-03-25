#!/bin/bash
set -euo pipefail

# =============================================================================
# Paperless NGX Sync Setup Script (Proxmox LXC)
#
# Run this inside the Paperless NGX LXC container to set up:
#   1. OCR language support
#   2. Paperless configuration (consumer, filename format, OCR, reverse proxy)
#   3. Tika + Gotenberg Docker containers for Office document support (if enabled)
#   4. rclone for OneDrive sync
#   5. Cron jobs for periodic sync and backup
#
# Prerequisites:
#   - Paperless NGX installed via https://community-scripts.org/scripts/paperless-ngx
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"
PAPERLESS_CONF="/opt/paperless/paperless.conf"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# ---- Load configuration ----
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found at $ENV_FILE"
    echo "Copy .env.example to .env and configure it first."
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

# ---- Helper: set or update a value in paperless.conf ----
set_paperless_conf() {
    local key="$1"
    local value="$2"
    # Remove any duplicate entries for this key first
    local count
    count=$(grep -c "^${key}=" "$PAPERLESS_CONF" 2>/dev/null) || count=0
    if [ "$count" -gt 1 ]; then
        # Keep only the last occurrence, remove earlier ones
        sed -i "0,/^${key}=/{/^${key}=/d}" "$PAPERLESS_CONF"
    fi
    if grep -q "^${key}=" "$PAPERLESS_CONF" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$PAPERLESS_CONF"
    else
        echo "${key}=${value}" >> "$PAPERLESS_CONF"
    fi
}

# ---- Step 1: Install OCR language pack ----
OCR_LANG="${PAPERLESS_OCR_LANGUAGE:-nld}"
# Convert paperless OCR language to tesseract package name (e.g. nld -> tesseract-ocr-nld)
# Handle multi-language (eng+nld) by installing each
log "Installing OCR language packages..."
IFS='+' read -ra LANGS <<< "$OCR_LANG"
for lang in "${LANGS[@]}"; do
    pkg="tesseract-ocr-${lang}"
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        log "  $pkg already installed."
    else
        log "  Installing $pkg..."
        apt-get update -qq
        apt-get install -y -qq "$pkg"
    fi
done

# ---- Step 2: Configure Paperless ----
log "Configuring Paperless (paperless.conf)..."
set_paperless_conf "PAPERLESS_CONSUMPTION_DIR" "/opt/paperless_data/consume"
set_paperless_conf "PAPERLESS_OCR_LANGUAGE" "$OCR_LANG"
set_paperless_conf "PAPERLESS_CONSUMER_RECURSIVE" "true"
set_paperless_conf "PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS" "true"
set_paperless_conf "PAPERLESS_CONSUMER_DELETE_DUPLICATES" "true"

if [ -n "${PAPERLESS_FILENAME_FORMAT:-}" ]; then
    set_paperless_conf "PAPERLESS_FILENAME_FORMAT" "$PAPERLESS_FILENAME_FORMAT"
fi

if [ -n "${PAPERLESS_URL:-}" ]; then
    set_paperless_conf "PAPERLESS_URL" "$PAPERLESS_URL"
    log "Set PAPERLESS_URL=${PAPERLESS_URL}"
fi

# ---- PocketID OIDC (if configured) ----
if [ -n "${POCKETID_CLIENT_ID:-}" ] && [ -n "${POCKETID_CLIENT_SECRET:-}" ] && [ -n "${POCKETID_URL:-}" ]; then
    log "Configuring PocketID OIDC..."
    set_paperless_conf "PAPERLESS_APPS" "allauth.socialaccount.providers.openid_connect"
    OIDC_JSON="{\"openid_connect\":{\"APPS\":[{\"provider_id\":\"pocketid\",\"name\":\"PocketID\",\"client_id\":\"${POCKETID_CLIENT_ID}\",\"secret\":\"${POCKETID_CLIENT_SECRET}\",\"settings\":{\"server_url\":\"${POCKETID_URL}/.well-known/openid-configuration\"}}]}}"
    set_paperless_conf "PAPERLESS_SOCIALACCOUNT_PROVIDERS" "$OIDC_JSON"
    set_paperless_conf "PAPERLESS_SOCIAL_AUTO_SIGNUP" "${PAPERLESS_SOCIAL_AUTO_SIGNUP:-true}"
    log "PocketID OIDC configured (${POCKETID_URL})"
fi

# ---- Step 3: Install Tika + Gotenberg (if enabled) ----
if [ "${PAPERLESS_TIKA_ENABLED:-false}" = "true" ]; then
    log "Setting up Tika and Gotenberg for Office document support..."

    # Install Docker if not present
    if ! command -v docker &>/dev/null; then
        log "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    else
        log "Docker already installed."
    fi

    # Start Gotenberg container (bundles LibreOffice + Chromium)
    if docker ps -a --format '{{.Names}}' | grep -q '^gotenberg$'; then
        log "Gotenberg container already exists, ensuring it is running..."
        docker start gotenberg 2>/dev/null || true
    else
        log "Creating Gotenberg container..."
        docker run -d --name gotenberg --restart always -p 127.0.0.1:3000:3000 gotenberg/gotenberg:8
    fi

    # Start Tika container (bundles JRE + all parsers)
    if docker ps -a --format '{{.Names}}' | grep -q '^tika$'; then
        log "Tika container already exists, ensuring it is running..."
        docker start tika 2>/dev/null || true
    else
        log "Creating Tika container..."
        docker run -d --name tika --restart always -p 127.0.0.1:9998:9998 apache/tika:latest
    fi

    # Configure Paperless to use Tika + Gotenberg
    set_paperless_conf "PAPERLESS_TIKA_ENABLED" "true"
    set_paperless_conf "PAPERLESS_TIKA_GOTENBERG_ENDPOINT" "http://localhost:3000"
    set_paperless_conf "PAPERLESS_TIKA_ENDPOINT" "http://localhost:9998"
    log "Tika and Gotenberg configured."
else
    log "Tika/Gotenberg disabled (PAPERLESS_TIKA_ENABLED!=true), skipping."
fi

# Restart Paperless to pick up config changes
log "Restarting Paperless services..."
systemctl restart paperless-webserver paperless-consumer paperless-scheduler 2>/dev/null || true
sleep 5
# ---- Step 4: Install rclone ----
if ! command -v rclone &>/dev/null; then
    log "Installing rclone..."
    curl -fsSL https://rclone.org/install.sh | bash
else
    log "rclone already installed: $(rclone version --check | head -1)"
fi

# ---- Step 5: Configure rclone (if not already done) ----
if [ ! -f /root/.config/rclone/rclone.conf ] || ! rclone listremotes | grep -q "^${RCLONE_REMOTE}:$"; then
    log "rclone remote '${RCLONE_REMOTE}' not found. Starting interactive config..."
    echo ""
    echo "=== rclone OneDrive Setup ==="
    echo "You will need to:"
    echo "  1. Choose 'New remote' and name it: ${RCLONE_REMOTE}"
    echo "  2. Choose 'Microsoft OneDrive'"
    echo "  3. Since this is a headless server, choose 'No' for auto config"
    echo "  4. On your local machine, run the rclone authorize command shown"
    echo "  5. Paste the token back here"
    echo ""
    rclone config
fi

# ---- Step 6: Verify OneDrive connection ----
log "Testing OneDrive connection..."
if rclone lsd "${RCLONE_REMOTE}:" &>/dev/null; then
    log "OneDrive connection successful."
else
    echo "Error: Cannot connect to OneDrive. Run 'rclone config' to fix."
    exit 1
fi

# ---- Step 7: Create OneDrive folders ----
log "Creating OneDrive folder structure..."
rclone mkdir "${RCLONE_REMOTE}:${ONEDRIVE_ARCHIVE}"
rclone mkdir "${RCLONE_REMOTE}:${ONEDRIVE_SCAN}"
rclone mkdir "${RCLONE_REMOTE}:${ONEDRIVE_BACKUPS}"
log "Created: ${ONEDRIVE_ARCHIVE}, ${ONEDRIVE_SCAN}, ${ONEDRIVE_BACKUPS}"

# ---- Step 8: Make scripts executable ----
chmod +x "${SCRIPT_DIR}/sync.sh"
chmod +x "${SCRIPT_DIR}/backup.sh"
chmod +x "${SCRIPT_DIR}/restore.sh"

# ---- Step 9: Set up cron jobs ----
log "Setting up cron jobs..."

CRON_FILE="/etc/cron.d/paperless-sync"
cat > "$CRON_FILE" << EOF
# Sync with OneDrive every 5 minutes
*/5 * * * * root ${SCRIPT_DIR}/sync.sh >> /var/log/paperless-sync.log 2>&1

# Weekly backup every Sunday at 2 AM
0 2 * * 0 root ${SCRIPT_DIR}/backup.sh >> /var/log/paperless-backup.log 2>&1
EOF
chmod 644 "$CRON_FILE"

log "Cron jobs installed."

# ---- Step 10: Run initial sync ----
log "Running initial sync..."
"${SCRIPT_DIR}/sync.sh" || true

# ---- Done ----
echo ""
log "============================================"
log "Setup complete!"
log "============================================"
echo ""
echo "OneDrive folders:"
echo "  Archive: My Files > ${ONEDRIVE_ARCHIVE}"
echo "  Scan:    My Files > ${ONEDRIVE_SCAN}"
echo "  Backups: My Files > ${ONEDRIVE_BACKUPS}"
echo ""
echo "Sync runs every 5 minutes."
echo "Backups run weekly (Sunday 2 AM) and upload to OneDrive."
echo ""
echo "Logs:"
echo "  Sync:   /var/log/paperless-sync.log"
echo "  Backup: /var/log/paperless-backup.log"

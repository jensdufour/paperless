#!/bin/bash
set -euo pipefail

# =============================================================================
# Paperless NGX Sync + Scanner Setup Script (Proxmox LXC)
#
# Run this inside the Paperless NGX LXC container to set up:
#   1. rclone for OneDrive sync
#   2. vsftpd for Canon ImageRunner 1133a scanning
#   3. Cron jobs for periodic sync and backup
#
# Prerequisites:
#   - Paperless NGX installed via https://community-scripts.org/scripts/paperless-ngx
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

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

# ---- Step 1: Install rclone ----
if ! command -v rclone &>/dev/null; then
    log "Installing rclone..."
    curl -fsSL https://rclone.org/install.sh | bash
else
    log "rclone already installed: $(rclone version --check | head -1)"
fi

# ---- Step 2: Configure rclone (if not already done) ----
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

# ---- Step 3: Verify OneDrive connection ----
log "Testing OneDrive connection..."
if rclone lsd "${RCLONE_REMOTE}:" &>/dev/null; then
    log "OneDrive connection successful."
else
    echo "Error: Cannot connect to OneDrive. Run 'rclone config' to fix."
    exit 1
fi

# ---- Step 4: Create OneDrive folders ----
log "Creating OneDrive folder structure..."
rclone mkdir "${RCLONE_REMOTE}:${ONEDRIVE_ARCHIVE}"
rclone mkdir "${RCLONE_REMOTE}:${ONEDRIVE_SCAN}"
rclone mkdir "${RCLONE_REMOTE}:${ONEDRIVE_BACKUPS}"
log "Created: ${ONEDRIVE_ARCHIVE}, ${ONEDRIVE_SCAN}, ${ONEDRIVE_BACKUPS}"

# ---- Step 5: Install and configure vsftpd ----
log "Installing vsftpd..."
apt-get update -qq
apt-get install -y -qq vsftpd

# Create FTP user
if ! id "$FTP_USER" &>/dev/null; then
    log "Creating FTP user: $FTP_USER"
    useradd -m -d "/home/${FTP_USER}" -s /usr/sbin/nologin "$FTP_USER"
fi
echo "${FTP_USER}:${FTP_PASSWORD}" | chpasswd

# Point FTP home to Paperless consume directory
mkdir -p "${PAPERLESS_CONSUME}"
chown "${FTP_USER}:${FTP_USER}" "${PAPERLESS_CONSUME}"

# Configure vsftpd
cat > /etc/vsftpd.conf << 'VSFTPD_EOF'
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=YES
pasv_enable=YES
pasv_min_port=21100
pasv_max_port=21110
userlist_enable=YES
userlist_deny=NO
userlist_file=/etc/vsftpd.userlist
VSFTPD_EOF

# Set the FTP user's home to the consume directory
usermod -d "${PAPERLESS_CONSUME}" "$FTP_USER"

# Allow only the scanner user
echo "$FTP_USER" > /etc/vsftpd.userlist

systemctl enable vsftpd
systemctl restart vsftpd
log "vsftpd configured and started."

# ---- Step 6: Make scripts executable ----
chmod +x "${SCRIPT_DIR}/sync.sh"
chmod +x "${SCRIPT_DIR}/backup.sh"
chmod +x "${SCRIPT_DIR}/restore.sh"

# ---- Step 7: Set up cron jobs ----
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

# ---- Step 8: Configure reverse proxy URL (if set) ----
if [ -n "${PAPERLESS_URL:-}" ]; then
    PAPERLESS_CONF="/opt/paperless/paperless.conf"
    if grep -q "^PAPERLESS_URL=" "$PAPERLESS_CONF" 2>/dev/null; then
        sed -i "s|^PAPERLESS_URL=.*|PAPERLESS_URL=${PAPERLESS_URL}|" "$PAPERLESS_CONF"
    else
        echo "PAPERLESS_URL=${PAPERLESS_URL}" >> "$PAPERLESS_CONF"
    fi
    log "Set PAPERLESS_URL=${PAPERLESS_URL} in paperless.conf"
    systemctl restart paperless-webserver paperless-consumer paperless-scheduler 2>/dev/null || true
fi

# ---- Step 9: Run initial sync ----
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
echo "Scanner (Canon ImageRunner 1133a):"
echo "  FTP Host: $(hostname -I | awk '{print $1}')"
echo "  FTP Port: 21"
echo "  FTP User: ${FTP_USER}"
echo "  FTP Dir:  /"
echo ""
echo "Sync runs every 5 minutes."
echo "Backups run weekly (Sunday 2 AM) and upload to OneDrive."
echo ""
echo "Logs:"
echo "  Sync:   /var/log/paperless-sync.log"
echo "  Backup: /var/log/paperless-backup.log"

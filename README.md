# Paperless NGX with OneDrive Sync

Adds OneDrive sync to a Paperless NGX instance running on Proxmox via the [community script](https://community-scripts.org/scripts/paperless-ngx).

- Processed documents are synced to **OneDrive > My Files > Documents > Paperless > Archive**
- Phone scans placed in **OneDrive > My Files > Documents > Paperless > Scan** are pulled into Paperless
- Weekly backups (database + config) are uploaded to **OneDrive > My Files > Documents > Paperless > Backups**
- Full restore on a fresh LXC with one command

## Architecture

```
OneDrive Mobile App
        |
        | (scan to Documents/Paperless/Scan)
        v
  +-------------+
  | rclone sync |----> consume/
  +-------------+         |
               +----------------+
               | Paperless NGX  |
               | (OCR, rename,  |
               |  tag, organize)|
               +----------------+
                        |
                        v
                media/documents/
                   originals/ --------->  Documents/Paperless/Archive
```

## Prerequisites

- Proxmox VE with a Paperless NGX LXC created via the [community script](https://community-scripts.org/scripts/paperless-ngx)
- A Microsoft account with OneDrive

## Quick Start

### 1. SSH into the Paperless LXC and clone this repo

```bash
apt-get install -y git
git clone https://github.com/jensdufour/paperless.git /opt/paperless-sync
cd /opt/paperless-sync
```

### 2. Configure

```bash
cp .env.example .env
nano .env
# Review settings
```

### 3. Run the install script

```bash
bash scripts/install.sh
```

This will:
- Install OCR language packages (e.g. `tesseract-ocr-nld`)
- Configure Paperless (`paperless.conf`) with OCR language, filename format, consumer settings, and reverse proxy URL
- Install Tika and Gotenberg for Office document support (if enabled in `.env`)
- Install rclone and walk you through OneDrive authorization
- Create the OneDrive folder structure (Documents/Paperless/Archive, Documents/Paperless/Scan, Documents/Paperless/Backups)
- Set up cron jobs for sync (every 5 min) and backup (weekly)
- Run an initial sync

### rclone authorization on a headless server

Since the LXC has no browser, the install script will prompt you to:
1. Run `rclone authorize "onedrive"` on your local machine (that has a browser)
2. Complete the OAuth flow in the browser
3. Copy the resulting token back into the LXC terminal

## Scanning from Your Phone

1. Open the **OneDrive app** on your phone
2. Use the built-in scanner (tap the camera/+ icon, choose "Scan")
3. Save the scanned PDF to: **My Files > Documents > Paperless > Scan**
4. Within 5 minutes, rclone moves the file into Paperless's consume folder
5. Paperless processes, OCRs, renames, and organizes the document
6. The processed document appears in **My Files > Documents > Paperless > Archive** on OneDrive

## Office Document Support (Tika + Gotenberg)

By default Paperless only handles PDFs and images. To also process Office documents (.docx, .xlsx, .pptx, .odt, .ods, etc.), the install script can set up **Apache Tika** and **Gotenberg** as Docker containers:

- **Tika** extracts text from Office files (used for search and matching)
- **Gotenberg** converts Office files to PDF (used for the archived version and thumbnails)

This is enabled by default in `.env` (`PAPERLESS_TIKA_ENABLED=true`). Set it to `false` before running the install script if you only need PDF/image support.

Both run as native systemd services (`tika.service` and `gotenberg.service`), consistent with the rest of the Proxmox LXC setup.

## OneDrive Folder Structure

```
My Files/
  Documents/
    Paperless/
      Archive/        <-- processed documents (synced from Paperless)
        2026/
          Insurance/
            Home Insurance Policy.pdf
          Bank/
            Monthly Statement March.pdf
      Scan/           <-- drop files here from phone (moved into Paperless)
      Backups/        <-- weekly backup archives
```

## File Structure (in the LXC)

```
/opt/paperless-sync/              <-- this repo
  .env                            # Configuration (from .env.example)
  paperless.conf.example          # Reference for Paperless settings
  scripts/
    install.sh                    # One-time setup (OCR, config, rclone, cron)
    sync.sh                       # OneDrive bidirectional sync
    backup.sh                     # Database + config backup to OneDrive
    restore.sh                    # Full restore from backup + OneDrive
  backups/                        # Local backup archives

/opt/paperless/             <-- Paperless application (community script)
/opt/paperless_data/        <-- Paperless data (community script)
  consume/                  # Incoming documents (OneDrive Scan)
  media/documents/
    originals/              # Processed documents (synced to OneDrive Archive)
  data/                     # Paperless internal data
  trash/                    # Deleted documents
```

### Path mapping (LXC to OneDrive)

| LXC Path | OneDrive Path | Direction |
|---|---|---|
| `/opt/paperless_data/consume/` | `Documents/Paperless/Scan` | OneDrive -> LXC |
| `/opt/paperless_data/media/documents/originals/` | `Documents/Paperless/Archive` | LXC -> OneDrive |
| `/opt/paperless-sync/backups/` | `Documents/Paperless/Backups` | LXC -> OneDrive |

## Backup and Restore

### What is backed up

Each backup is lightweight and includes only what the sync does not cover:
- PostgreSQL database dump (all metadata, tags, correspondents, matching rules, etc.)
- `paperless.conf` (Paperless application configuration)
- rclone configuration (OneDrive auth token)
- Scripts and `.env`

Document files are NOT included in the backup since they are already on OneDrive Archive via the sync script. The restore script pulls them back from there.

### Automated backup

Backups run automatically every Sunday at 2 AM (configured during install). Backups are uploaded to OneDrive and only the last 5 local copies are kept.

### Manual backup

```bash
/opt/paperless-sync/scripts/backup.sh
```

### Restore on a new machine (disaster recovery)

If the server crashes, follow these steps to get everything running again:

**Step 1: Create a fresh Paperless NGX LXC**
```bash
# On the Proxmox host, run the community script
# https://community-scripts.org/scripts/paperless-ngx
```

**Step 2: SSH into the new LXC and install rclone**
```bash
curl -fsSL https://rclone.org/install.sh | bash
rclone config
# Set up the "onedrive" remote (follow the headless auth flow)
```

**Step 3: Download the latest backup from OneDrive**
```bash
rclone copy onedrive:Documents/Paperless/Backups/ /tmp/backups/ --include "*.tar.gz"
ls -lt /tmp/backups/  # find the latest one
```

**Step 4: Clone this repo and run the restore**
```bash
apt-get install -y git
git clone https://github.com/jensdufour/paperless.git /opt/paperless-sync
bash /opt/paperless-sync/scripts/restore.sh /tmp/backups/paperless-backup-YYYYMMDD_HHMMSS.tar.gz
```

The restore script will:
1. Extract the backup (database dump, paperless.conf, rclone config, scripts, .env)
2. Restore the rclone configuration
3. Restore paperless.conf to `/opt/paperless/`
4. Install OCR language packages
5. Stop Paperless, restore the PostgreSQL database
6. Pull all documents from OneDrive Archive
7. Start Paperless and rebuild the search index
8. Run install.sh to set up cron jobs and remaining configuration

## Sync Behavior

| Source | Destination | Method | Purpose |
|---|---|---|---|
| Paperless originals | OneDrive `Documents/Paperless/Archive` | `rclone sync` | Upload processed docs |
| OneDrive `Documents/Paperless/Scan` | Paperless consume | `rclone move` | Pull phone scans |
| Backup archives | OneDrive `Documents/Paperless/Backups` | `rclone copy` | Disaster recovery |

The sync runs every 5 minutes via cron.

## Reverse Proxy (Traefik / nginx)

If you access Paperless through a reverse proxy, set `PAPERLESS_URL` in your `.env` before running the install script:

```bash
PAPERLESS_URL=https://paperless.yourdomain.com
```

The install script will write this to `paperless.conf` automatically. If you already ran the install, update the value:

```bash
sed -i 's|^PAPERLESS_URL=.*|PAPERLESS_URL=https://paperless.yourdomain.com|' /opt/paperless/paperless.conf
systemctl restart paperless-webserver paperless-consumer paperless-scheduler
```

This sets Django's `CSRF_TRUSTED_ORIGINS` and `ALLOWED_HOSTS`, which fixes the "CSRF verification failed" error.

## Single Sign-On (PocketID / OIDC)

Paperless can authenticate users via OpenID Connect. To use [PocketID](https://github.com/pocket-id/pocket-id):

1. In PocketID, create an OIDC client with the callback URL:
   ```
   https://paperless.yourdomain.com/accounts/openid_connect/pocketid/login/callback/
   ```
2. Set the following in your `.env`:
   ```bash
   POCKETID_URL=https://pocketid.yourdomain.com
   POCKETID_CLIENT_ID=your-client-id
   POCKETID_CLIENT_SECRET=your-client-secret
   ```
3. Run the install script (or re-run it). The login page will show a "PocketID" button.

## Paperless Configuration

The install script automatically configures `/opt/paperless/paperless.conf` with the following settings:

| Setting | Value | Source |
|---|---|---|
| `PAPERLESS_CONSUMPTION_DIR` | `/opt/paperless_data/consume` | Hardcoded |
| `PAPERLESS_OCR_LANGUAGE` | From `.env` (default: `nld`) | `.env` |
| `PAPERLESS_FILENAME_FORMAT` | From `.env` | `.env` |
| `PAPERLESS_CONSUMER_RECURSIVE` | `true` | Hardcoded |
| `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS` | `true` | Hardcoded |
| `PAPERLESS_CONSUMER_DELETE_DUPLICATES` | `true` | Hardcoded |
| `PAPERLESS_TIKA_ENABLED` | From `.env` (default: `false`) | `.env` |
| `PAPERLESS_TIKA_ENDPOINT` | `http://localhost:9998` (if Tika enabled) | Hardcoded |
| `PAPERLESS_TIKA_GOTENBERG_ENDPOINT` | `http://localhost:3000` (if Tika enabled) | Hardcoded |
| `PAPERLESS_URL` | From `.env` (if set) | `.env` |
| `PAPERLESS_APPS` | OIDC provider (if PocketID configured) | `.env` |
| `PAPERLESS_SOCIALACCOUNT_PROVIDERS` | PocketID OIDC config (if configured) | `.env` |
| `PAPERLESS_SOCIAL_AUTO_SIGNUP` | `true` (if PocketID configured) | `.env` |

See [paperless.conf.example](paperless.conf.example) for a reference of all recommended settings.

### Filename format

The default filename format (configured via `.env`):

```
PAPERLESS_FILENAME_FORMAT={{ created_year }}/{{ correspondent }}/{{ title }}
```

This creates:
```
2026/Insurance Company/Home Insurance Policy.pdf
2026/Bank/Monthly Statement March.pdf
```

**Important:** Use Jinja2 `{{ var }}` syntax, not the old `{var}` syntax.

See the [Paperless documentation](https://docs.paperless-ngx.com/configuration/#PAPERLESS_FILENAME_FORMAT) for all placeholders.

### Automatic tagging and correspondent matching

Use the Paperless web UI to:
1. Create **correspondents** (e.g., your bank, insurance, utility companies)
2. Create **tags** (e.g., invoice, receipt, contract)
3. Set up **matching rules** so Paperless auto-assigns correspondents and tags

## Troubleshooting

### Sync not working

```bash
# Check sync logs
tail -50 /var/log/paperless-sync.log

# Run sync manually
/opt/paperless-sync/scripts/sync.sh

# Verify rclone connection
rclone lsd onedrive:Documents/
```

### Paperless not processing documents

```bash
# Check consume folder
ls -la /opt/paperless_data/consume/

# Check Paperless consumer logs
journalctl -u paperless-consumer --no-pager -n 50

# Verify OCR language is installed
dpkg -l | grep tesseract-ocr

# Verify paperless.conf has no duplicate entries
sort /opt/paperless/paperless.conf | uniq -d
```

### Office documents not working

```bash
# Check Tika and Gotenberg services
systemctl status tika
systemctl status gotenberg

# Restart if needed
systemctl restart tika gotenberg

# Test Tika endpoint
curl -s http://localhost:9998/version

# Test Gotenberg endpoint
curl -s http://localhost:3000/health

# Check service logs
journalctl -u tika --no-pager -n 20
journalctl -u gotenberg --no-pager -n 20
```

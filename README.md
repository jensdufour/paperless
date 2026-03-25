# Paperless NGX with OneDrive Sync and Scanner Integration

Adds OneDrive sync and Canon ImageRunner 1133a scanner support to a Paperless NGX instance running on Proxmox via the [community script](https://community-scripts.org/scripts/paperless-ngx).

- Processed documents are synced to **OneDrive > My Files > Documents > Paperless > Archive**
- Phone scans placed in **OneDrive > My Files > Documents > Paperless > Scan** are pulled into Paperless
- Canon ImageRunner 1133a scans via FTP directly into Paperless
- Weekly backups (database + config) are uploaded to **OneDrive > My Files > Documents > Paperless > Backups**
- Full restore on a fresh LXC with one command

## Architecture

```
Canon ImageRunner 1133a                   OneDrive Mobile App
        |                                         |
        | (FTP scan-to-folder)                    | (scan to Documents/Paperless/Scan)
        v                                         v
  +-----------+                            +-------------+
  | vsftpd    |----> consume/ <----move----| rclone sync |
  +-----------+         |                  +-------------+
                        v                         ^
               +----------------+                 |
               | Paperless NGX  |                 |
               | (OCR, rename,  |                 |
               |  tag, organize)|                 |
               +----------------+                 |
                        |                         |
                        v                         |
                media/documents/           sync to OneDrive
                   originals/ --------->  Documents/Paperless/Archive
```

## Prerequisites

- Proxmox VE with a Paperless NGX LXC created via the [community script](https://community-scripts.org/scripts/paperless-ngx)
- A Microsoft account with OneDrive
- Network access to your Canon ImageRunner 1133a's admin panel

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
# Set FTP_PASSWORD at minimum, review other settings
```

### 3. Run the install script

```bash
bash scripts/install.sh
```

This will:
- Install OCR language packages (e.g. `tesseract-ocr-nld`)
- Configure Paperless (`paperless.conf`) with OCR language, filename format, consumer settings, and reverse proxy URL
- Install rclone and walk you through OneDrive authorization
- Create the OneDrive folder structure (Documents/Paperless/Archive, Documents/Paperless/Scan, Documents/Paperless/Backups)
- Install and configure vsftpd for the scanner
- Set up cron jobs for sync (every 5 min) and backup (weekly)
- Run an initial sync

### rclone authorization on a headless server

Since the LXC has no browser, the install script will prompt you to:
1. Run `rclone authorize "onedrive"` on your local machine (that has a browser)
2. Complete the OAuth flow in the browser
3. Copy the resulting token back into the LXC terminal

## Scanner Setup: Canon ImageRunner 1133a

The ImageRunner 1133a supports Scan-to-FTP. After running the install script, configure the printer:

### On the printer's web interface (Remote UI)

1. Open a browser and go to the printer's IP address
2. Log in to the Remote UI as administrator
3. Go to **Address Book** and add a new destination:
   - **Type**: FTP
   - **Host Name**: IP address of the Paperless LXC (shown at end of install script)
   - **Port**: 21
   - **User Name**: value of `FTP_USER` from your `.env` (default: `scanner`)
   - **Password**: value of `FTP_PASSWORD` from your `.env`
   - **Directory**: `/`
   - **File Name**: use a prefix like `scan_` with auto-numbering
4. Save the destination
5. Test by scanning a document from the printer panel

The scanned file lands in the Paperless consume folder, gets OCR'd, renamed, tagged, and then synced to OneDrive Archive.

### Recommended scanner settings

- **Color Mode**: Black & White or Grayscale (for text documents)
- **Resolution**: 300 DPI
- **File Format**: PDF (Compact) if available, otherwise standard PDF

## Scanning from Your Phone

1. Open the **OneDrive app** on your phone
2. Use the built-in scanner (tap the camera/+ icon, choose "Scan")
3. Save the scanned PDF to: **My Files > Documents > Paperless > Scan**
4. Within 5 minutes, rclone moves the file into Paperless's consume folder
5. Paperless processes, OCRs, renames, and organizes the document
6. The processed document appears in **My Files > Documents > Paperless > Archive** on OneDrive

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
    install.sh                    # One-time setup (OCR, config, rclone, vsftpd, cron)
    sync.sh                       # OneDrive bidirectional sync
    backup.sh                     # Database + config backup to OneDrive
    restore.sh                    # Full restore from backup + OneDrive
  backups/                        # Local backup archives

/opt/paperless/             <-- Paperless application (community script)
/opt/paperless_data/        <-- Paperless data (community script)
  consume/                  # Incoming documents (FTP + OneDrive Scan)
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
8. Run install.sh to set up cron jobs, vsftpd, and remaining configuration

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

## Paperless Configuration

The install script automatically configures `/opt/paperless/paperless.conf` with the following settings:

| Setting | Value | Source |
|---|---|---|
| `PAPERLESS_CONSUMPTION_DIR` | `/opt/paperless_data/consume` | Hardcoded |
| `PAPERLESS_OCR_LANGUAGE` | From `.env` (default: `nld`) | `.env` |
| `PAPERLESS_FILENAME_FORMAT` | From `.env` | `.env` |
| `PAPERLESS_CONSUMER_RECURSIVE` | `true` | Hardcoded |
| `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS` | `true` | Hardcoded |
| `PAPERLESS_URL` | From `.env` (if set) | `.env` |

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

### Scanner not connecting

```bash
# Check vsftpd status
systemctl status vsftpd

# Check vsftpd logs
journalctl -u vsftpd --no-pager -n 50

# Test FTP locally
apt-get install -y ftp
ftp localhost 21
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

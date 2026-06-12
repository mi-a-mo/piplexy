# PIPLEXy

A Raspberry Pi Plex automation suite. Automates the full setup of a Pi as a
Plex media server — static IP, Plex installation, external drive mounting,
library configuration, and Samba sharing — through a simple terminal menu.

```
 ___ ___ ___ _    _____  __
 | _ \_ _| _ \ |  | __\ \/ /  _
 |  _/| ||  _/ |__| _| >  < || |
 |_| |___|_| |____|___/_/\_\_, |
                           |__/

                PIPLEXy v1.2
     Raspberry Pi Plex Automation Suite
```

## Requirements

- Raspberry Pi running Raspberry Pi OS (or any Debian-based distro)
- An external USB drive formatted as exFAT, NTFS, ext2/3/4, or FAT32
- Internet connection for downloading Plex and dependencies

`whiptail`, `nmcli`, and `curl` are checked on startup and installed
automatically if missing — no manual setup needed.

## Usage

```bash
chmod +x piplexy.sh
sudo ./piplexy.sh
```

To preview what the script would do without making any changes:

```bash
sudo ./piplexy.sh --dry-run
```

The dry-run mode scans your network and drive, then prints a full summary of
every action that would be taken — no changes are written.

## Menu Options

| Option | What it does |
|---|---|
| **1 — Set Static IP** | Scans the subnet for a free IP, lets you review/edit it, asks for confirmation, then applies it permanently via NetworkManager. |
| **2 — Install Plex** | Adds the official Plex apt repository, installs Plex Media Server, enables it as a service, and shows the URL to claim your server. Skips safely if already installed. |
| **3 — Detect & Mount Drive** | Shows a picker of all connected partitions, installs filesystem drivers if needed (exFAT, NTFS), takes a timestamped fstab backup, and mounts at `/mnt/usb1`. |
| **4 — Configure Plex Libraries** | Finds **all** Movies and TV folders on the drive (not just the first), adds them to Plex via the API, and triggers an immediate library scan. |
| **5 — Install & Configure Samba** | Installs Samba, takes a timestamped smb.conf backup, adds a `[PLEX Media]` share, and sets your Samba password. |
| **6 — Configure Firewall** | Installs and enables ufw, opening ports for SSH (22), Plex (32400), and Samba (445, 139). SSH is always opened first to prevent lockout. |
| **7 — Run Full Automation** | Runs all of the above steps in order — the one-shot setup option. |
| **8 — Status Dashboard** | Shows a live summary of network, drive, Plex (including masked token), Samba, firewall, and log status. |
| **9 — Exit** | Exits. In dry-run mode, prints the full action summary first. |

## What Gets Configured

**Static IP** — scans the range `<your-subnet>.40–250` for a free address,
lets you edit it, confirms before applying, then sets it permanently on your
active NetworkManager connection.

**Drive** — shows a picker of all connected partitions with size and
filesystem. Mounts at `/mnt/usb1` with a UUID-based fstab entry (timestamped
backup taken first) so the mount survives reboots. Installs `exfat-fuse` /
`exfatprogs` or `ntfs-3g` automatically for those filesystems.

**Plex libraries** — finds all folders named `movies` and `tv` / `tv shows`
up to 3 levels deep, registers them all with Plex as a single library per
type, and immediately triggers a library scan.

**Samba** — creates a public, writable `[PLEX Media]` share at the mount
point (timestamped smb.conf backup taken first), accessible from Windows,
macOS, and Linux on the same network.

**Firewall** — installs and enables `ufw`, opening ports for SSH (22), Plex
(32400), and Samba (445, 139). SSH is always opened first to prevent lockout.

## Logs

All actions are logged to `/var/log/piplexy.log` with timestamps. After
running, check it with:

```bash
cat /var/log/piplexy.log
```

Or follow it live during a run:

```bash
tail -f /var/log/piplexy.log
```

## Files

| File | Purpose |
|---|---|
| `piplexy.sh` | The automation script |

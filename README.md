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

                PIPLEXy v1.0
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
| **1 — Set Static IP** | Scans the local subnet for a free IP and assigns it permanently via NetworkManager. Works on both Ethernet and Wi-Fi. |
| **2 — Install Plex** | Adds the official Plex apt repository, installs Plex Media Server, and enables it as a systemd service. Skips safely if already installed. |
| **3 — Detect & Mount Drive** | Auto-detects the connected USB drive, installs filesystem drivers if needed (exFAT, NTFS), adds a persistent fstab entry, and mounts at `/mnt/usb1`. |
| **4 — Configure Plex Libraries** | Reads the Plex auth token from Preferences.xml and calls the Plex API to add Movies and TV Shows libraries from the mounted drive. |
| **5 — Install & Configure Samba** | Installs Samba, adds a `[PLEX Media]` share pointing at the mounted drive, and sets your Samba password. |
| **6 — Run Full Automation** | Runs all of the above steps in order — the one-shot setup option. |
| **7 — Status Dashboard** | Shows a live summary of network, drive, Plex, Samba, and log status. |
| **8 — Exit** | Exits. In dry-run mode, prints the full action summary first. |

## What Gets Configured

**Static IP** — assigns a free address in the range `<your-subnet>.40–250` and
sets it permanently on your active NetworkManager connection.

**Drive** — mounts at `/mnt/usb1` with a UUID-based fstab entry so the mount
survives reboots even if the device node changes. Installs `exfat-fuse` /
`exfatprogs` or `ntfs-3g` automatically for those filesystems.

**Plex libraries** — looks for folders named `movies` and `tv` / `tv shows`
on the mounted drive (case-insensitive) and registers them with Plex via the
local API.

**Samba** — creates a public, writable `[PLEX Media]` share at the mount
point, accessible from Windows, macOS, and Linux on the same network.

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

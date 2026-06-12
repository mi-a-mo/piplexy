#!/bin/bash
set -eo pipefail

#############################################
# PIPLEXY SPLASH (YOUR EXACT ASCII)
#############################################
clear
cat << "EOF"
 ___ ___ ___ _    _____  __
 | _ \_ _| _ \ |  | __\ \/ /  _
 |  _/| ||  _/ |__| _| >  < || |
 |_| |___|_| |____|___/_/\_\_, |
                           |__/

                PIPLEXy v1.1
     Raspberry Pi Plex Automation Suite
EOF
echo

#############################################
# REQUIREMENTS CHECK
#############################################
check_requirements() {
    # Map: command → apt package
    declare -A REQUIRED=(
        [whiptail]="whiptail"
        [nmcli]="network-manager"
        [curl]="curl"
    )

    local missing_pkgs=()
    for cmd in "${!REQUIRED[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Missing: $cmd (package: ${REQUIRED[$cmd]})"
            missing_pkgs+=("${REQUIRED[$cmd]}")
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        echo "Installing missing requirements..."
        sudo apt update -y
        sudo apt install -y "${missing_pkgs[@]}"
        echo "Requirements installed."
        echo
    fi
}

check_requirements

#############################################
# LOGGING SETUP
#############################################
LOGFILE="/var/log/piplexy.log"
sudo touch "$LOGFILE"
sudo chmod 666 "$LOGFILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$LOGFILE"
}

#############################################
# MODE HANDLING
#############################################
DRYRUN=false
if [[ "$1" == "--dry-run" || "$1" == "-n" ]]; then
    DRYRUN=true
    log "=== DRY RUN MODE ENABLED ==="
    echo "=== DRY RUN MODE ENABLED ==="
    echo "No changes will be made."
    echo
fi

v() { log "[VERBOSE] $*"; }

# Run a command: log it, skip in dry-run, capture stdout+stderr to log.
# Always pass args separately (run sudo apt install -y foo), not as a single
# quoted string. For piped commands use: run bash -c "cmd1 | cmd2"
run() {
    v "Running: $*"
    if $DRYRUN; then
        echo "[DRY RUN] Skipped execution."
        log "[DRY RUN] Skipped: $*"
    else
        "$@" 2>&1 | tee -a "$LOGFILE"
    fi
}

#############################################
# GLOBAL PATHS
#############################################
MOUNT_POINT="/mnt/usb1"
PLEX_PREFS="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"
SERVER_URL="http://localhost:32400"

#############################################
# DRY RUN SUMMARY VARIABLES
#############################################
SUMMARY_STATIC_IP=""
SUMMARY_GATEWAY=""
SUMMARY_DNS=""
SUMMARY_DEVICE=""
SUMMARY_FSTYPE=""
SUMMARY_FSTAB=""
SUMMARY_MOVIES=""
SUMMARY_TV=""
SUMMARY_SAMBA_SHARE=""

#############################################
# MODULE 1: STATIC IP SETUP
#############################################
set_static_ip() {
    echo "=== STATIC IP SETUP ==="
    log "Starting static IP setup"

    local CURRENT_IP SUBNET GATEWAY DNS FREE_IP STATIC_IP CON_NAME

    CURRENT_IP=$(hostname -I | awk '{print $1}')
    v "Current IP: $CURRENT_IP"

    SUBNET=$(echo "$CURRENT_IP" | awk -F. '{print $1"."$2"."$3}')
    v "Subnet: $SUBNET.x"

    GATEWAY=$(ip route | grep default | awk '{print $3}')
    v "Gateway: $GATEWAY"

    DNS=$(grep "nameserver" /etc/resolv.conf | head -n1 | awk '{print $2}')
    [ -z "$DNS" ] && DNS="$GATEWAY"
    v "DNS: $DNS"

    echo "Scanning for free IP..."
    FREE_IP=""
    for i in {40..250}; do
        local TEST_IP="$SUBNET.$i"
        if ! ping -c1 -W1 "$TEST_IP" >/dev/null 2>&1; then
            FREE_IP="$TEST_IP"
            break
        fi
    done

    if [ -z "$FREE_IP" ]; then
        echo "ERROR: No free IP found in range $SUBNET.40–250."
        log "ERROR: No free IP found."
        exit 1
    fi

    STATIC_IP="$FREE_IP/24"
    v "Selected static IP: $STATIC_IP"

    SUMMARY_STATIC_IP="$STATIC_IP"
    SUMMARY_GATEWAY="$GATEWAY"
    SUMMARY_DNS="$DNS"

    CON_NAME=$(nmcli -t -f NAME,DEVICE,TYPE connection show --active | head -n1 | cut -d: -f1)

    if [ -z "$CON_NAME" ]; then
        echo "ERROR: No active NetworkManager connection found."
        log "ERROR: No active NetworkManager connection found."
        exit 1
    fi

    v "Active connection: $CON_NAME"

    run sudo nmcli connection modify "$CON_NAME" ipv4.addresses "$STATIC_IP"
    run sudo nmcli connection modify "$CON_NAME" ipv4.gateway "$GATEWAY"
    run sudo nmcli connection modify "$CON_NAME" ipv4.dns "$DNS"
    run sudo nmcli connection modify "$CON_NAME" ipv4.method manual
    run sudo nmcli connection down "$CON_NAME" || true
    run sudo nmcli connection up "$CON_NAME"

    echo "Static IP applied: $STATIC_IP"
}

#############################################
# MODULE 2: INSTALL PLEX
#############################################
install_plex() {
    echo "=== INSTALLING PLEX MEDIA SERVER ==="
    log "Installing Plex"

    if dpkg -l | grep -q plexmediaserver; then
        echo "Plex is already installed — skipping installation."
        log "Plex already installed — skipping."
        return
    fi

    run sudo apt update
    run sudo apt install -y curl wget gnupg apt-transport-https

    v "Adding Plex signing key..."
    run bash -c "curl -L https://downloads.plex.tv/plex-keys/PlexSign.v2.key | sudo gpg --yes --dearmor -o /usr/share/keyrings/plexmediaserver.v2.gpg"

    v "Adding Plex repository..."
    run bash -c "echo 'deb [signed-by=/usr/share/keyrings/plexmediaserver.v2.gpg] https://downloads.plex.tv/repo/deb public main' | sudo tee /etc/apt/sources.list.d/plexmediaserver.list"

    run sudo apt update
    run sudo apt install -y plexmediaserver
    run sudo systemctl enable plexmediaserver
    run sudo systemctl start plexmediaserver

    echo "Plex installed and running."
}

#############################################
# MODULE 3: MOUNT DRIVE
#############################################
mount_drive() {
    echo "=== DRIVE DETECTION & MOUNT ==="
    log "Mounting drive"

    local DEVICE DEVICE_PATH FSTYPE OPTIONS UUID FSTAB_LINE

    DEVICE=$(lsblk -o NAME,TYPE,FSTYPE -nr | awk '$2=="part" && $3!="" {print $1; exit}')

    if [ -z "$DEVICE" ]; then
        echo "ERROR: No formatted partition detected. Is the drive plugged in?"
        log "ERROR: No partition found."
        exit 1
    fi

    DEVICE_PATH="/dev/$DEVICE"
    FSTYPE=$(lsblk -o FSTYPE -nr "$DEVICE_PATH")

    v "Device: $DEVICE_PATH"
    v "Filesystem: $FSTYPE"

    SUMMARY_DEVICE="$DEVICE_PATH"
    SUMMARY_FSTYPE="$FSTYPE"

    if mountpoint -q "$MOUNT_POINT"; then
        echo "Drive already mounted at $MOUNT_POINT — skipping."
        log "Already mounted — skipping."
        return
    fi

    case "$FSTYPE" in
        exfat)
            run sudo apt update
            run sudo apt install -y exfat-fuse exfatprogs
            OPTIONS="defaults,uid=$(id -u),gid=$(id -g),fmask=0111,dmask=0000,allow_utime=0022"
            ;;
        ntfs)
            run sudo apt update
            run sudo apt install -y ntfs-3g
            OPTIONS="defaults,uid=$(id -u),gid=$(id -g),umask=000"
            ;;
        ext4|ext3|ext2)
            OPTIONS="defaults"
            ;;
        *)
            echo "ERROR: Unsupported filesystem: $FSTYPE"
            log "ERROR: Unsupported filesystem: $FSTYPE"
            exit 1
            ;;
    esac

    run sudo mkdir -p "$MOUNT_POINT"

    UUID=$(blkid -s UUID -o value "$DEVICE_PATH")

    if [ -z "$UUID" ]; then
        echo "ERROR: Could not read UUID from $DEVICE_PATH."
        log "ERROR: Empty UUID."
        exit 1
    fi

    v "UUID: $UUID"

    run sudo cp /etc/fstab /etc/fstab.backup

    FSTAB_LINE="UUID=$UUID  $MOUNT_POINT  $FSTYPE  $OPTIONS  0  0"
    v "fstab entry: $FSTAB_LINE"
    SUMMARY_FSTAB="$FSTAB_LINE"

    if $DRYRUN; then
        log "[DRY RUN] Would add to /etc/fstab: $FSTAB_LINE"
    else
        echo "$FSTAB_LINE" | sudo tee -a /etc/fstab >> "$LOGFILE"
    fi

    run sudo mount -a
    run sudo chown -R "$USER:$USER" "$MOUNT_POINT"

    echo "Drive mounted at $MOUNT_POINT"
}

#############################################
# MODULE 4: CONFIGURE PLEX LIBRARIES
#############################################
configure_plex() {
    echo "=== CONFIGURING PLEX LIBRARIES ==="
    log "Configuring Plex"

    local PLEX_TOKEN MOVIES_DIR TV_DIR

    if [ ! -f "$PLEX_PREFS" ]; then
        echo "Plex preferences not found — Plex may not have run yet."
        log "Preferences.xml missing — skipping library setup."
        return
    fi

    PLEX_TOKEN=$(sudo sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' "$PLEX_PREFS" 2>/dev/null || true)

    if [ -z "$PLEX_TOKEN" ]; then
        v "WARNING: Plex token missing — Plex may not be signed in yet."
    else
        v "Plex token extracted."
    fi

    # Use -print -quit to avoid SIGPIPE from head
    MOVIES_DIR=$(find "$MOUNT_POINT" -type d -iname "movies" -print -quit 2>/dev/null || true)
    TV_DIR=$(find "$MOUNT_POINT" -type d \( -iname "tv" -o -iname "tv shows" \) -print -quit 2>/dev/null || true)

    v "Movies folder: ${MOVIES_DIR:-none}"
    v "TV folder: ${TV_DIR:-none}"

    SUMMARY_MOVIES="$MOVIES_DIR"
    SUMMARY_TV="$TV_DIR"

    add_library() {
        local type=$1 name=$2 media_path=$3   # media_path avoids shadowing $PATH
        echo "Adding Plex library: $name → $media_path"
        run curl -s -X POST \
            -H "X-Plex-Token: $PLEX_TOKEN" \
            "$SERVER_URL/library/sections" \
            --data-urlencode "type=$type" \
            --data-urlencode "name=$name" \
            --data-urlencode "location=$media_path"
    }

    [ -n "$MOVIES_DIR" ] && [ -n "$PLEX_TOKEN" ] && add_library 1 "Movies" "$MOVIES_DIR"
    [ -n "$TV_DIR" ]     && [ -n "$PLEX_TOKEN" ] && add_library 2 "TV Shows" "$TV_DIR"

    echo "Plex libraries configured."
}

#############################################
# MODULE 5: INSTALL SAMBA
#############################################
install_samba() {
    echo "=== INSTALLING SAMBA FOR MEDIA SHARING ==="
    log "Installing Samba"

    local SAMBA_BLOCK

    run sudo apt update
    run sudo apt install -y samba
    run sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup

    SAMBA_BLOCK="
[PLEX Media]
   path = $MOUNT_POINT
   browseable = yes
   read only = no
   writable = yes
   create mask = 0775
   directory mask = 0775
   public = yes
"
    v "Samba config block:$SAMBA_BLOCK"
    SUMMARY_SAMBA_SHARE="$MOUNT_POINT"

    if $DRYRUN; then
        log "[DRY RUN] Would append Samba block to /etc/samba/smb.conf"
    else
        printf '%s\n' "$SAMBA_BLOCK" | sudo tee -a /etc/samba/smb.conf >> "$LOGFILE"
    fi

    # smbpasswd is interactive — run it directly, not through the tee pipeline
    echo "Setting Samba password for user: $USER"
    if $DRYRUN; then
        log "[DRY RUN] Would run: sudo smbpasswd -a $USER"
    else
        sudo smbpasswd -a "$USER"
    fi

    run sudo systemctl restart smbd

    echo "Samba installed and configured."
}

#############################################
# MODULE 6: FULL AUTOMATION
#############################################
run_full() {
    echo "=== RUNNING FULL AUTOMATION (PIPLEXy) ==="
    log "Running full automation"

    set_static_ip
    install_plex
    mount_drive
    configure_plex
    install_samba

    echo "=== FULL AUTOMATION COMPLETE ==="
}

#############################################
# MODULE 7: STATUS DASHBOARD
#############################################
status_dashboard() {
    local STATUS CURRENT_IP ACTIVE_CON GATEWAY DNS DEVICE DEVICE_PATH FSTYPE TOKEN

    STATUS=""

    STATUS+="NETWORK STATUS\n"
    STATUS+="------------------------------\n"
    CURRENT_IP=$(hostname -I | awk '{print $1}')
    STATUS+="Current IP: $CURRENT_IP\n"
    ACTIVE_CON=$(nmcli -t -f NAME,DEVICE,TYPE connection show --active 2>/dev/null | head -n1 | cut -d: -f1 || true)
    STATUS+="Active connection: ${ACTIVE_CON:-none}\n"
    GATEWAY=$(ip route 2>/dev/null | awk '/default/{print $3; exit}')
    STATUS+="Gateway: ${GATEWAY:-none}\n"
    DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | head -n1 | awk '{print $2}')
    STATUS+="DNS: ${DNS:-none}\n\n"

    STATUS+="DRIVE STATUS\n"
    STATUS+="------------------------------\n"
    DEVICE=$(lsblk -o NAME,TYPE,FSTYPE -nr 2>/dev/null | awk '$2=="part" {print $1; exit}')
    if [ -n "$DEVICE" ]; then
        DEVICE_PATH="/dev/$DEVICE"
        FSTYPE=$(lsblk -o FSTYPE -nr "$DEVICE_PATH" 2>/dev/null || true)
        STATUS+="Detected device: $DEVICE_PATH\n"
        STATUS+="Filesystem: ${FSTYPE:-unknown}\n"
    else
        STATUS+="Detected device: none\n"
        STATUS+="Filesystem: none\n"
    fi
    STATUS+="Mount point: $MOUNT_POINT\n"
    mountpoint -q "$MOUNT_POINT" 2>/dev/null && STATUS+="Mounted: yes\n" || STATUS+="Mounted: no\n"
    grep -q "$MOUNT_POINT" /etc/fstab 2>/dev/null && STATUS+="fstab entry: present\n\n" || STATUS+="fstab entry: missing\n\n"

    STATUS+="PLEX STATUS\n"
    STATUS+="------------------------------\n"
    dpkg -l 2>/dev/null | grep -q plexmediaserver && STATUS+="Installed: yes\n" || STATUS+="Installed: no\n"
    systemctl is-active --quiet plexmediaserver 2>/dev/null && STATUS+="Service: running\n" || STATUS+="Service: stopped\n"
    [ -f "$PLEX_PREFS" ] && STATUS+="Preferences.xml: found\n" || STATUS+="Preferences.xml: missing\n"
    TOKEN=$(sudo sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' "$PLEX_PREFS" 2>/dev/null || true)
    [ -n "$TOKEN" ] && STATUS+="Plex token: present\n\n" || STATUS+="Plex token: missing\n\n"

    STATUS+="SAMBA STATUS\n"
    STATUS+="------------------------------\n"
    dpkg -l 2>/dev/null | grep -q samba && STATUS+="Installed: yes\n" || STATUS+="Installed: no\n"
    systemctl is-active --quiet smbd 2>/dev/null && STATUS+="Service: running\n" || STATUS+="Service: stopped\n"
    grep -q '^\[PLEX Media\]' /etc/samba/smb.conf 2>/dev/null && STATUS+="PLEX Media share: present\n\n" || STATUS+="PLEX Media share: missing\n\n"

    STATUS+="PIPLEXy STATUS\n"
    STATUS+="------------------------------\n"
    STATUS+="Log file: $LOGFILE\n"
    if [ -f "$LOGFILE" ]; then
        STATUS+="Log size: $(du -h "$LOGFILE" | awk '{print $1}')\n"
        STATUS+="Last modified: $(date -r "$LOGFILE")\n"
    else
        STATUS+="Log size: 0\n"
        STATUS+="Last modified: never\n"
    fi

    whiptail --title "PIPLEXy Status Dashboard" --msgbox "$STATUS" 30 80
}

#############################################
# DRY RUN SUMMARY REPORT
#############################################
dry_run_summary() {
    echo
    echo "===================================="
    echo "         PIPLEXy DRY RUN SUMMARY"
    echo "===================================="

    echo "Static IP that would be applied: ${SUMMARY_STATIC_IP:-none}"
    echo "Gateway: ${SUMMARY_GATEWAY:-none}"
    echo "DNS: ${SUMMARY_DNS:-none}"
    echo

    echo "Drive detected: ${SUMMARY_DEVICE:-none}"
    echo "Filesystem: ${SUMMARY_FSTYPE:-none}"
    echo "Mount point: $MOUNT_POINT"
    echo "fstab entry that would be added:"
    echo "  ${SUMMARY_FSTAB:-none}"
    echo

    echo "Movies folder detected: ${SUMMARY_MOVIES:-none}"
    echo "TV folder detected: ${SUMMARY_TV:-none}"
    echo

    echo "Samba share that would be created:"
    echo "  [PLEX Media] → ${SUMMARY_SAMBA_SHARE:-none}"
    echo

    echo "===================================="
    echo "  END OF DRY RUN — NO CHANGES MADE"
    echo "===================================="
}

#############################################
# MENU UI
#############################################
while true; do
    CHOICE=$(whiptail --title "PIPLEXy — Plex Automation Suite" \
        --menu "Choose an action:" 20 70 10 \
        "1" "Set Static IP" \
        "2" "Install Plex" \
        "3" "Detect & Mount Drive" \
        "4" "Configure Plex Libraries" \
        "5" "Install & Configure Samba" \
        "6" "Run Full Automation" \
        "7" "Status Dashboard" \
        "8" "Exit" \
        3>&1 1>&2 2>&3)

    case $CHOICE in
        1) set_static_ip ;;
        2) install_plex ;;
        3) mount_drive ;;
        4) configure_plex ;;
        5) install_samba ;;
        6) run_full ;;
        7) status_dashboard ;;
        8)
            if $DRYRUN; then dry_run_summary; fi
            exit 0
            ;;
    esac
done

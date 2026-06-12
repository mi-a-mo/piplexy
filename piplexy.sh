#!/bin/bash
set -eo pipefail

#############################################
# PIPLEXY SPLASH
#############################################
clear
cat << "EOF"
 ___ ___ ___ _    _____  __
 | _ \_ _| _ \ |  | __\ \/ /  _
 |  _/| ||  _/ |__| _| >  < || |
 |_| |___|_| |____|___/_/\_\_, |
                           |__/

                PIPLEXy v1.2
     Raspberry Pi Plex Automation Suite
EOF
echo

#############################################
# LOCK FILE — prevent concurrent runs
#############################################
LOCKFILE="/tmp/piplexy.lock"
if [ -f "$LOCKFILE" ]; then
    echo "ERROR: PIPLEXy is already running."
    echo "If it's not, delete $LOCKFILE and try again."
    exit 1
fi
touch "$LOCKFILE"

#############################################
# LOGGING
#############################################
LOGFILE="/var/log/piplexy.log"
sudo touch "$LOGFILE"
sudo chmod 666 "$LOGFILE"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$LOGFILE"; }

#############################################
# TRAP — clean up lock + log on any exit
#############################################
trap 'rm -f "$LOCKFILE"; log "PIPLEXy exited."' EXIT
trap 'log "PIPLEXy interrupted by signal."; exit 130' INT TERM

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

# When false (set by run_full) modules skip their own success dialogs
INTERACTIVE=true

v() { log "[VERBOSE] $*"; }

# Run a command: logs it, skips in dry-run, captures stdout+stderr to log.
# Pass args individually: run sudo apt install -y foo
# For piped commands use: run bash -c "cmd1 | cmd2"
run() {
    v "Running: $*"
    if $DRYRUN; then
        echo "[DRY RUN] Skipped."
        log "[DRY RUN] Skipped: $*"
    else
        "$@" 2>&1 | tee -a "$LOGFILE"
    fi
}

#############################################
# HELPERS
#############################################
check_internet() {
    v "Checking internet connection..."
    if ! ping -c1 -W5 8.8.8.8 >/dev/null 2>&1; then
        echo "ERROR: No internet connection. Check your network and try again."
        log "ERROR: No internet connection."
        exit 1
    fi
    v "Internet: OK"
}

show_error() {
    whiptail --title "Error" --msgbox "$1\n\nSee log: $LOGFILE" 10 65
}

#############################################
# REQUIREMENTS CHECK
#############################################
check_requirements() {
    declare -A REQUIRED=(
        [whiptail]="whiptail"
        [nmcli]="network-manager"
        [curl]="curl"
    )

    local missing_pkgs=()
    for cmd in "${!REQUIRED[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || {
            echo "Missing: $cmd (package: ${REQUIRED[$cmd]})"
            missing_pkgs+=("${REQUIRED[$cmd]}")
        }
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        echo "Installing missing requirements..."
        check_internet
        sudo apt update -y
        sudo apt install -y "${missing_pkgs[@]}"
        echo "Requirements installed."
        echo
    fi
}

check_requirements

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
SUMMARY_FIREWALL=""

#############################################
# MODULE 1: STATIC IP SETUP
#############################################
set_static_ip() {
    echo "=== STATIC IP SETUP ==="
    log "Starting static IP setup"

    local CURRENT_IP SUBNET GATEWAY DNS FREE_IP STATIC_IP CONFIRMED CON_NAME

    CURRENT_IP=$(hostname -I | awk '{print $1}')
    v "Current IP: $CURRENT_IP"

    SUBNET=$(echo "$CURRENT_IP" | awk -F. '{print $1"."$2"."$3}')
    v "Subnet: $SUBNET.x"

    GATEWAY=$(ip route | awk '/default/{print $3; exit}')
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

    # Let user review or change the auto-detected IP
    CONFIRMED=$(whiptail --title "Static IP Setup" \
        --inputbox "Detected free IP in your subnet.\n\nEdit below or press Enter to accept:" \
        10 65 "$FREE_IP" \
        3>&1 1>&2 2>&3 || true)
    [ -z "$CONFIRMED" ] && return 0   # user cancelled

    FREE_IP="$CONFIRMED"
    STATIC_IP="$FREE_IP/24"

    # Final confirmation before applying
    whiptail --title "Confirm" \
        --yesno "Apply these network settings?\n\nIP:      $STATIC_IP\nGateway: $GATEWAY\nDNS:     $DNS" \
        11 55 || return 0   # user cancelled

    CON_NAME=$(nmcli -t -f NAME,DEVICE,TYPE connection show --active | head -n1 | cut -d: -f1)
    if [ -z "$CON_NAME" ]; then
        echo "ERROR: No active NetworkManager connection found."
        log "ERROR: No active NetworkManager connection."
        exit 1
    fi
    v "Active connection: $CON_NAME"

    SUMMARY_STATIC_IP="$STATIC_IP"
    SUMMARY_GATEWAY="$GATEWAY"
    SUMMARY_DNS="$DNS"

    run sudo nmcli connection modify "$CON_NAME" ipv4.addresses "$STATIC_IP"
    run sudo nmcli connection modify "$CON_NAME" ipv4.gateway "$GATEWAY"
    run sudo nmcli connection modify "$CON_NAME" ipv4.dns "$DNS"
    run sudo nmcli connection modify "$CON_NAME" ipv4.method manual
    run sudo nmcli connection down "$CON_NAME" || true
    run sudo nmcli connection up "$CON_NAME"

    log "Static IP applied: $STATIC_IP"
    $INTERACTIVE && whiptail --title "Done" --msgbox "Static IP applied: $STATIC_IP" 8 55
}

#############################################
# MODULE 2: INSTALL PLEX
#############################################
install_plex() {
    echo "=== INSTALLING PLEX MEDIA SERVER ==="
    log "Installing Plex"

    if dpkg -l 2>/dev/null | grep -q plexmediaserver; then
        $INTERACTIVE && whiptail --title "Already Installed" \
            --msgbox "Plex Media Server is already installed." 8 55
        return 0
    fi

    check_internet
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

    local PI_IP
    PI_IP=$(hostname -I | awk '{print $1}')
    log "Plex installed."
    $INTERACTIVE && whiptail --title "Plex Installed" --msgbox \
        "Plex Media Server is running.\n\nTo claim your server, open a browser and visit:\nhttp://$PI_IP:32400/web\n\nSign in with your Plex account to complete setup." \
        13 65
}

#############################################
# MODULE 3: MOUNT DRIVE
#############################################
mount_drive() {
    echo "=== DRIVE DETECTION & MOUNT ==="
    log "Mounting drive"

    local DEVICE_PATH FSTYPE OPTIONS UUID FSTAB_LINE TIMESTAMP

    # Build a list of all formatted partitions for the picker
    local items=()
    while IFS= read -r line; do
        local dev fstype size
        dev=$(awk '{print $1}' <<< "$line")
        fstype=$(awk '{print $2}' <<< "$line")
        size=$(awk '{print $3}' <<< "$line")
        items+=("/dev/$dev" "$size  [$fstype]")
    done < <(lsblk -o NAME,FSTYPE,SIZE -nr | awk '$2!="" && $2!="swap" {print}')

    if [ ${#items[@]} -eq 0 ]; then
        whiptail --title "No Drive Found" \
            --msgbox "No formatted partitions detected.\nPlease plug in your drive and try again." 10 60
        return 0
    fi

    DEVICE_PATH=$(whiptail --title "Select Drive" \
        --menu "Choose the partition to use as your media drive:" \
        20 70 10 \
        "${items[@]}" \
        3>&1 1>&2 2>&3 || true)
    [ -z "$DEVICE_PATH" ] && return 0   # user cancelled

    FSTYPE=$(lsblk -o FSTYPE -nr "$DEVICE_PATH")
    v "Device: $DEVICE_PATH  Filesystem: $FSTYPE"

    SUMMARY_DEVICE="$DEVICE_PATH"
    SUMMARY_FSTYPE="$FSTYPE"

    if mountpoint -q "$MOUNT_POINT"; then
        $INTERACTIVE && whiptail --title "Already Mounted" \
            --msgbox "A drive is already mounted at $MOUNT_POINT." 8 55
        return 0
    fi

    case "$FSTYPE" in
        exfat)
            check_internet
            run sudo apt update
            run sudo apt install -y exfat-fuse exfatprogs
            OPTIONS="defaults,uid=$(id -u),gid=$(id -g),fmask=0111,dmask=0000,allow_utime=0022"
            ;;
        ntfs)
            check_internet
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

    # Timestamped backup so previous backups aren't overwritten
    TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
    run sudo cp /etc/fstab "/etc/fstab.backup.$TIMESTAMP"

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

    log "Drive mounted at $MOUNT_POINT"
    $INTERACTIVE && whiptail --title "Done" \
        --msgbox "Drive mounted at $MOUNT_POINT\n\nDevice: $DEVICE_PATH\nFilesystem: $FSTYPE" \
        10 60
}

#############################################
# MODULE 4: CONFIGURE PLEX LIBRARIES
#############################################
configure_plex() {
    echo "=== CONFIGURING PLEX LIBRARIES ==="
    log "Configuring Plex"

    local PLEX_TOKEN

    if [ ! -f "$PLEX_PREFS" ]; then
        $INTERACTIVE && whiptail --title "Not Ready" \
            --msgbox "Plex preferences not found.\nInstall Plex and sign in via the web UI first." \
            10 60
        return 0
    fi

    PLEX_TOKEN=$(sudo sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' "$PLEX_PREFS" 2>/dev/null || true)

    if [ -z "$PLEX_TOKEN" ]; then
        $INTERACTIVE && whiptail --title "Not Signed In" \
            --msgbox "Plex token not found.\nPlease sign into your Plex account via the web UI first." \
            10 60
        return 0
    fi
    v "Plex token extracted."

    # Find ALL movies and TV folders (up to 3 levels deep)
    local MOVIES_DIRS=() TV_DIRS=()
    mapfile -t MOVIES_DIRS < <(find "$MOUNT_POINT" -maxdepth 3 -type d -iname "movies" 2>/dev/null || true)
    mapfile -t TV_DIRS < <(find "$MOUNT_POINT" -maxdepth 3 -type d \( -iname "tv" -o -iname "tv shows" \) 2>/dev/null || true)

    v "Movies folders found: ${#MOVIES_DIRS[@]}"
    v "TV folders found:     ${#TV_DIRS[@]}"

    SUMMARY_MOVIES="${MOVIES_DIRS[*]:-none}"
    SUMMARY_TV="${TV_DIRS[*]:-none}"

    # Create a single library with all found paths of each type
    add_library() {
        local type=$1 name=$2
        shift 2
        local paths=("$@")
        [ ${#paths[@]} -eq 0 ] && return 0

        local curl_args=(-s -X POST -H "X-Plex-Token: $PLEX_TOKEN" "$SERVER_URL/library/sections")
        curl_args+=(--data-urlencode "type=$type" --data-urlencode "name=$name")
        local media_path
        for media_path in "${paths[@]}"; do
            curl_args+=(--data-urlencode "location=$media_path")
        done

        echo "Adding library: $name (${#paths[@]} folder(s))"
        run curl "${curl_args[@]}"
    }

    add_library 1 "Movies"   "${MOVIES_DIRS[@]}"
    add_library 2 "TV Shows" "${TV_DIRS[@]}"

    # Trigger a library scan so Plex starts indexing immediately
    if ! $DRYRUN && [ -n "$PLEX_TOKEN" ]; then
        echo "Triggering library scan..."
        curl -s -X GET -H "X-Plex-Token: $PLEX_TOKEN" \
            "$SERVER_URL/library/sections/all/refresh" >/dev/null || true
        log "Library scan triggered."
    fi

    log "Plex libraries configured."
    $INTERACTIVE && whiptail --title "Done" \
        --msgbox "Libraries configured and scan started.\n\nMovies folders: ${#MOVIES_DIRS[@]}\nTV folders:     ${#TV_DIRS[@]}" \
        10 60
}

#############################################
# MODULE 5: INSTALL SAMBA
#############################################
install_samba() {
    echo "=== INSTALLING SAMBA FOR MEDIA SHARING ==="
    log "Installing Samba"

    local SAMBA_BLOCK TIMESTAMP PI_IP

    check_internet
    run sudo apt update
    run sudo apt install -y samba

    TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
    run sudo cp /etc/samba/smb.conf "/etc/samba/smb.conf.backup.$TIMESTAMP"

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

    # smbpasswd is interactive — run directly, never through the tee pipeline
    echo "Setting Samba password for user: $USER"
    if $DRYRUN; then
        log "[DRY RUN] Would run: sudo smbpasswd -a $USER"
    else
        sudo smbpasswd -a "$USER"
    fi

    run sudo systemctl restart smbd

    PI_IP=$(hostname -I | awk '{print $1}')
    log "Samba installed."
    $INTERACTIVE && whiptail --title "Done" \
        --msgbox "Samba is configured.\n\nAccess your media from any device on your network:\n  Windows:     \\\\$PI_IP\\PLEX Media\n  macOS/Linux: smb://$PI_IP/PLEX Media" \
        12 65
}

#############################################
# MODULE 6: CONFIGURE FIREWALL
#############################################
configure_firewall() {
    echo "=== CONFIGURING FIREWALL ==="
    log "Configuring firewall"

    if ! command -v ufw >/dev/null 2>&1; then
        check_internet
        run sudo apt update
        run sudo apt install -y ufw
    fi

    whiptail --title "Firewall Setup" \
        --yesno "This will enable ufw and open the following ports:\n\n  22    — SSH\n  32400 — Plex\n  445   — Samba (SMB)\n  139   — Samba (NetBIOS)\n\nSSH (22) is allowed first to avoid lockout.\nProceed?" \
        15 65 || return 0   # user cancelled

    run sudo ufw allow 22/tcp     # SSH first — prevents lockout
    run sudo ufw allow 32400/tcp
    run sudo ufw allow 445/tcp
    run sudo ufw allow 139/tcp
    run sudo ufw --force enable

    SUMMARY_FIREWALL="SSH(22), Plex(32400), Samba(445, 139)"
    log "Firewall enabled."
    $INTERACTIVE && whiptail --title "Done" \
        --msgbox "Firewall enabled.\n\nOpen ports: SSH (22), Plex (32400), Samba (445, 139)" \
        10 60
}

#############################################
# MODULE 7: FULL AUTOMATION
#############################################
run_full() {
    echo "=== RUNNING FULL AUTOMATION (PIPLEXy) ==="
    log "Running full automation"

    INTERACTIVE=false
    set_static_ip
    install_plex
    mount_drive
    configure_plex
    install_samba
    configure_firewall
    INTERACTIVE=true

    log "Full automation complete."
    whiptail --title "Done" --msgbox "Full automation complete!\n\nAll steps finished successfully." 10 55
}

#############################################
# MODULE 8: STATUS DASHBOARD
#############################################
status_dashboard() {
    local STATUS="" CURRENT_IP ACTIVE_CON GATEWAY DNS DEVICE DEVICE_PATH FSTYPE TOKEN

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
    if [ -n "$TOKEN" ]; then
        local mid="" i
        for ((i=4; i<${#TOKEN}-4; i++)); do mid+="*"; done
        STATUS+="Plex token: ${TOKEN:0:4}${mid}${TOKEN: -4}\n\n"
    else
        STATUS+="Plex token: missing\n\n"
    fi

    STATUS+="SAMBA STATUS\n"
    STATUS+="------------------------------\n"
    dpkg -l 2>/dev/null | grep -q samba && STATUS+="Installed: yes\n" || STATUS+="Installed: no\n"
    systemctl is-active --quiet smbd 2>/dev/null && STATUS+="Service: running\n" || STATUS+="Service: stopped\n"
    grep -q '^\[PLEX Media\]' /etc/samba/smb.conf 2>/dev/null && STATUS+="PLEX Media share: present\n\n" || STATUS+="PLEX Media share: missing\n\n"

    STATUS+="FIREWALL STATUS\n"
    STATUS+="------------------------------\n"
    if command -v ufw >/dev/null 2>&1; then
        local ufw_status
        ufw_status=$(sudo ufw status 2>/dev/null | head -n1 || true)
        STATUS+="ufw: $ufw_status\n\n"
    else
        STATUS+="ufw: not installed\n\n"
    fi

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

    whiptail --title "PIPLEXy Status Dashboard" --msgbox "$STATUS" 38 80
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
    echo "Movies folder(s): ${SUMMARY_MOVIES:-none}"
    echo "TV folder(s):     ${SUMMARY_TV:-none}"
    echo
    echo "Samba share that would be created:"
    echo "  [PLEX Media] → ${SUMMARY_SAMBA_SHARE:-none}"
    echo
    echo "Firewall ports that would be opened: ${SUMMARY_FIREWALL:-none}"
    echo
    echo "===================================="
    echo "  END OF DRY RUN — NO CHANGES MADE"
    echo "===================================="
}

#############################################
# MENU UI
#############################################
while true; do
    INTERACTIVE=true   # reset each iteration in case run_full left it false

    CHOICE=$(whiptail --title "PIPLEXy — Plex Automation Suite" \
        --menu "Choose an action:" 22 70 12 \
        "1" "Set Static IP" \
        "2" "Install Plex" \
        "3" "Detect & Mount Drive" \
        "4" "Configure Plex Libraries" \
        "5" "Install & Configure Samba" \
        "6" "Configure Firewall" \
        "7" "Run Full Automation" \
        "8" "Status Dashboard" \
        "9" "Exit" \
        3>&1 1>&2 2>&3)

    case $CHOICE in
        1) set_static_ip      || show_error "Static IP setup failed." ;;
        2) install_plex       || show_error "Plex installation failed." ;;
        3) mount_drive        || show_error "Drive mount failed." ;;
        4) configure_plex     || show_error "Plex library setup failed." ;;
        5) install_samba      || show_error "Samba setup failed." ;;
        6) configure_firewall || show_error "Firewall setup failed." ;;
        7) run_full           || show_error "Full automation failed. Check $LOGFILE." ;;
        8) status_dashboard ;;
        9)
            if $DRYRUN; then dry_run_summary; fi
            exit 0
            ;;
    esac
done

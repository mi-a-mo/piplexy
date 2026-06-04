#!/bin/bash
set -e

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

                PIPLEXy v1.0
     Raspberry Pi Plex Automation Suite
EOF
echo

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

# Verbose always on
v() { log "[VERBOSE] $*"; }

# Command wrapper
run() {
    v "Running: $*"
    if $DRYRUN; then
        echo "[DRY RUN] Skipped execution."
        log "[DRY RUN] Skipped: $*"
    else
        eval "$@" | tee -a "$LOGFILE"
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
        TEST_IP="$SUBNET.$i"
        ping -c1 -W1 "$TEST_IP" >/dev/null 2>&1 || { FREE_IP="$TEST_IP"; break; }
    done

    STATIC_IP="$FREE_IP/24"
    v "Selected static IP: $STATIC_IP"

    SUMMARY_STATIC_IP="$STATIC_IP"
    SUMMARY_GATEWAY="$GATEWAY"
    SUMMARY_DNS="$DNS"

    #############################################
    # FIXED CONNECTION DETECTION (Ethernet or Wi‑Fi)
    #############################################
    CON_NAME=$(nmcli -t -f NAME,DEVICE,TYPE connection show --active | head -n1 | cut -d: -f1)

    if [ -z "$CON_NAME" ]; then
        echo "ERROR: No active NetworkManager connection found."
        log "ERROR: No active NetworkManager connection found."
        exit 1
    fi

    v "Active connection: $CON_NAME"

    run "sudo nmcli connection modify \"$CON_NAME\" ipv4.addresses \"$STATIC_IP\""
    run "sudo nmcli connection modify \"$CON_NAME\" ipv4.gateway \"$GATEWAY\""
    run "sudo nmcli connection modify \"$CON_NAME\" ipv4.dns \"$DNS\""
    run "sudo nmcli connection modify \"$CON_NAME\" ipv4.method manual"
    run "sudo nmcli connection down \"$CON_NAME\" || true"
    run "sudo nmcli connection up \"$CON_NAME\""

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

    run "sudo apt update"
    run "sudo apt install -y curl wget gnupg apt-transport-https"

    v "Adding Plex signing key..."
    run "curl -L https://downloads.plex.tv/plex-keys/PlexSign.v2.key | sudo gpg --yes --dearmor -o /usr/share/keyrings/plexmediaserver.v2.gpg"

    v "Adding Plex repository..."
    run "echo \"deb [signed-by=/usr/share/keyrings/plexmediaserver.v2.gpg] https://downloads.plex.tv/repo/deb public main\" | sudo tee /etc/apt/sources.list.d/plexmediaserver.list"

    run "sudo apt update"
    run "sudo apt install -y plexmediaserver"

    run "sudo systemctl enable plexmediaserver"
    run "sudo systemctl start plexmediaserver"

    echo "Plex installed and running."
}

#############################################
# MODULE 3: MOUNT DRIVE
#############################################
mount_drive() {
    echo "=== DRIVE DETECTION & MOUNT ==="
    log "Mounting drive"

    DEVICE=$(lsblk -o NAME,TYPE,FSTYPE -nr | awk '$2=="part" && $3!="" {print $1; exit}')
    DEVICE_PATH="/dev/$DEVICE"
    FSTYPE=$(lsblk -o FSTYPE -nr "$DEVICE_PATH")

    v "Device: $DEVICE_PATH"
    v "Filesystem: $FSTYPE"

    SUMMARY_DEVICE="$DEVICE_PATH"
    SUMMARY_FSTYPE="$FSTYPE"

    case "$FSTYPE" in
        exfat)
            run "sudo apt update"
            run "sudo apt install -y exfat-fuse exfatprogs"
            OPTIONS="defaults,uid=1000,gid=1000,fmask=0111,dmask=0000,allow_utime=0022"
            ;;
        ntfs)
            run "sudo apt update"
            run "sudo apt install -y ntfs-3g"
            OPTIONS="defaults,uid=1000,gid=1000,umask=000"
            ;;
        ext4|ext3|ext2)
            OPTIONS="defaults"
            ;;
        *)
            echo "Unsupported filesystem: $FSTYPE"
            exit 1
            ;;
    esac

    run "sudo mkdir -p \"$MOUNT_POINT\""

    UUID=$(blkid -s UUID -o value "$DEVICE_PATH")
    v "UUID: $UUID"

    run "sudo cp /etc/fstab /etc/fstab.backup"

    FSTAB_LINE="UUID=$UUID  $MOUNT_POINT  $FSTYPE  $OPTIONS  0  0"
    v "Adding fstab entry: $FSTAB_LINE"

    SUMMARY_FSTAB="$FSTAB_LINE"

    run "echo \"$FSTAB_LINE\" | sudo tee -a /etc/fstab"
    run "sudo mount -a"
    run "sudo chown -R 1000:1000 \"$MOUNT_POINT\""

    echo "Drive mounted at $MOUNT_POINT"
}

#############################################
# MODULE 4: CONFIGURE PLEX LIBRARIES
#############################################
configure_plex() {
    echo "=== CONFIGURING PLEX LIBRARIES ==="
    log "Configuring Plex"

    if [ ! -f "$PLEX_PREFS" ]; then
        echo "Plex preferences not found — Plex may not have run yet."
        log "Preferences.xml missing — skipping library setup."
        return
    fi

    #############################################
    # FIX: Read Preferences.xml with sudo
    #############################################
    PLEX_TOKEN=$(sudo sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' "$PLEX_PREFS" 2>/dev/null)

    if [ -z "$PLEX_TOKEN" ]; then
        v "WARNING: Plex token missing — Plex may not be signed in yet."
    else
        v "Plex token extracted."
    fi

    MOVIES_DIR=$(find "$MOUNT_POINT" -type d -iname "movies" | head -n 1 || true)
    TV_DIR=$(find "$MOUNT_POINT" -type d \( -iname "tv" -o -iname "tv shows" \) | head -n 1 || true)

    v "Movies folder: ${MOVIES_DIR:-none}"
    v "TV folder: ${TV_DIR:-none}"

    SUMMARY_MOVIES="$MOVIES_DIR"
    SUMMARY_TV="$TV_DIR"

    add_library() {
        TYPE=$1
        NAME=$2
        PATH=$3

        echo "Adding Plex library: $NAME → $PATH"
        run "curl -s -X POST \
            -H \"X-Plex-Token: $PLEX_TOKEN\" \
            \"$SERVER_URL/library/sections\" \
            --data-urlencode \"type=$TYPE\" \
            --data-urlencode \"name=$NAME\" \
            --data-urlencode \"location=$PATH\" >/dev/null"
    }

    [ -n "$MOVIES_DIR" ] && [ -n "$PLEX_TOKEN" ] && add_library 1 "Movies" "$MOVIES_DIR"
    [ -n "$TV_DIR" ] && [ -n "$PLEX_TOKEN" ] && add_library 2 "TV Shows" "$TV_DIR"

    echo "Plex libraries configured."
}

#############################################
# MODULE 5: INSTALL SAMBA
#############################################
install_samba() {
    echo "=== INSTALLING SAMBA FOR MEDIA SHARING ==="
    log "Installing Samba"

    run "sudo apt update"
    run "sudo apt install -y samba"

    run "sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup"

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

    v "Samba config block:"
    v "$SAMBA_BLOCK"

    SUMMARY_SAMBA_SHARE="$MOUNT_POINT"

    run "echo \"$SAMBA_BLOCK\" | sudo tee -a /etc/samba/smb.conf"

    echo "Setting Samba password for user: $USER"
    run "sudo smbpasswd -a $USER"

    run "sudo systemctl restart smbd"

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
# MODULE 7: STATUS DASHBOARD (FIXED)
#############################################
status_dashboard() {
    STATUS=""

    STATUS+="NETWORK STATUS\n"
    STATUS+="------------------------------\n"
    CURRENT_IP=$(hostname -I | awk '{print $1}')
    STATUS+="Current IP: $CURRENT_IP\n"
    ACTIVE_CON=$(nmcli -t -f NAME,DEVICE,TYPE connection show --active | head -n1 | cut -d: -f1)
    STATUS+="Active connection: ${ACTIVE_CON:-none}\n"
    GATEWAY=$(ip route | grep default | awk '{print $3}')
    STATUS+="Gateway: ${GATEWAY:-none}\n"
    DNS=$(grep nameserver /etc/resolv.conf | head -n1 | awk '{print $2}')
    STATUS+="DNS: ${DNS:-none}\n\n"

    STATUS+="DRIVE STATUS\n"
    STATUS+="------------------------------\n"
    DEVICE=$(lsblk -o NAME,TYPE,FSTYPE -nr | awk '$2=="part" {print $1; exit}')
    DEVICE_PATH="/dev/$DEVICE"
    STATUS+="Detected device: ${DEVICE_PATH:-none}\n"
    FSTYPE=$(lsblk -o FSTYPE -nr "$DEVICE_PATH")
    STATUS+="Filesystem: ${FSTYPE:-none}\n"
    STATUS+="Mount point: $MOUNT_POINT\n"
    mount | grep -q "$MOUNT_POINT" && STATUS+="Mounted: yes\n" || STATUS+="Mounted: no\n"
    grep -q "$MOUNT_POINT" /etc/fstab && STATUS+="fstab entry: present\n\n" || STATUS+="fstab entry: missing\n\n"

    STATUS+="PLEX STATUS\n"
    STATUS+="------------------------------\n"
    dpkg -l | grep -q plexmediaserver && STATUS+="Installed: yes\n" || STATUS+="Installed: no\n"
    systemctl is-active --quiet plexmediaserver && STATUS+="Service: running\n" || STATUS+="Service: stopped\n"
    [ -f "$PLEX_PREFS" ] && STATUS+="Preferences.xml: found\n" || STATUS+="Preferences.xml: missing\n"
    TOKEN=$(sudo sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' "$PLEX_PREFS" 2>/dev/null)
    [ -n "$TOKEN" ] && STATUS+="Plex token: present\n\n" || STATUS+="Plex token: missing\n\n"

    STATUS+="SAMBA STATUS\n"
    STATUS+="------------------------------\n"
    dpkg -l | grep -q samba && STATUS+="Installed: yes\n" || STATUS+="Installed: no\n"
    systemctl is-active --quiet smbd && STATUS+="Service: running\n" || STATUS+="Service: stopped\n"
    grep -q "

\[PLEX Media\]

" /etc/samba/smb.conf && STATUS+="PLEX Media share: present\n\n" || STATUS+="PLEX Media share: missing\n\n"

    STATUS+="PIPLEXy STATUS\n"
    STATUS+="------------------------------\n"
    STATUS+="Log file: $LOGFILE\n"
    STATUS+="Log size: $(du -h "$LOGFILE" | awk '{print $1}')\n"
    STATUS+="Last modified: $(date -r "$LOGFILE")\n"

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
# MENU UI (EXIT MOVED TO BOTTOM)
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


#!/usr/bin/env bash
# RDT-Client-76cb Installer for Proxmox (AMD64)
# FULLY FIXED VERSION – whiptail UI + correct storage handling + proper template logic

set -euo pipefail

############################################
# COLORS
############################################
YW="\033[33m"
GN="\033[32m"
RD="\033[31m"
BL="\033[36m"
CL="\033[m"

############################################
# LOGGING
############################################
LOGFILE="/var/log/rdtclient-76cb-install.log"
mkdir -p /var/log
exec > >(tee -a "$LOGFILE") 2>&1
trap 'echo -e "\n${RD}ERROR at line $LINENO — see $LOGFILE${CL}"' ERR

############################################
# ARCH CHECK
############################################
ARCH="$(dpkg --print-architecture)"
if [[ "$ARCH" != "amd64" ]]; then
  echo -e "${RD}This installer is for AMD64 only.${CL}"
  exit 1
fi

############################################
# REQUIRE WHIPTAIL
############################################
command -v whiptail >/dev/null 2>&1 || {
  echo -e "${YW}Installing whiptail...${CL}"
  apt update && apt install -y whiptail
}

clear
echo -e "    ____  ____  _______________            __"
echo -e "   / __ \\/ __ \\/_  __/ ____/ (_)__  ____  / /_"
echo -e "  / /_/ / / / / / / / /   / / / _ \\/ __ \\/ __/"
echo -e " / _, _/ /_/ / / / / /___/ / /  __/ / / / /_  "
echo -e "/_/ |_/_____/ /_/  \\____/_/_/\\___/_/ /_/\\__/  "
echo -e "                                              "
echo -e "   ${GN}RDT-Client-76cb Proxmox Installer (AMD64)${CL}\n"
echo -e "${GN}✔ Architecture OK${CL}\n"


############################################
# STORAGE HELPER FUNCTION
############################################
select_storage() {
    local options=()
    while read -r store; do
        if pvesm config "$store" 2>/dev/null | grep -q "content.*rootdir"; then
            options+=("$store" "$store" "OFF")
        fi
    done < <(pvesm status | awk 'NR>1{print $1}')

    if [[ ${#options[@]} -eq 0 ]]; then
        whiptail --msgbox "No valid storages detected that support container rootfs." 10 60
        exit 1
    fi

    local choice
    choice=$(whiptail --title "RDT-Client-76cb Installer" \
                      --radiolist "Select rootfs storage:" \
                      20 70 10 \
                      "${options[@]}" \
                      3>&1 1>&2 2>&3)

    if [[ -z "$choice" ]]; then
        echo -e "${RD}No storage selected.${CL}"
        exit 1
    fi

    echo "$choice"
}

############################################
# TEMPLATE HELPER FUNCTION
############################################
select_template() {
    local options=(
      "ubuntu-22.04-standard_22.04-1_amd64.tar.zst" "Ubuntu 22.04 LTS" "ON"
      "ubuntu-24.04-standard_24.04-2_amd64.tar.zst" "Ubuntu 24.04 LTS" "OFF"
    )

    local choice
    choice=$(whiptail --title "RDT-Client-76cb Installer" \
                      --radiolist "Select template:" \
                      20 70 10 \
                      "${options[@]}" \
                      3>&1 1>&2 2>&3)

    echo "$choice"
}

############################################
# INTERACTIVE UI
############################################

CTID=$(whiptail --inputbox "Enter CTID:" 10 60 "$(pvesh get /cluster/nextid)" 3>&1 1>&2 2>&3)
HN=$(whiptail --inputbox "Hostname:" 10 60 "rdtclient-76cb" 3>&1 1>&2 2>&3)
CORES=$(whiptail --inputbox "CPU Cores:" 10 60 "2" 3>&1 1>&2 2>&3)
MEMORY=$(whiptail --inputbox "Memory (MB):" 10 60 "1024" 3>&1 1>&2 2>&3)
SWAP=$(whiptail --inputbox "Swap (MB):" 10 60 "512" 3>&1 1>&2 2>&3)

############################################
# STORAGE SELECT
############################################
STORAGE=$(select_storage)

############################################
# NETWORK
############################################
NET=$(whiptail --title "Network Mode" --radiolist \
"Select networking mode:" 15 60 3 \
"dhcp" "DHCP (recommended)" ON \
"static" "Static IP" OFF \
3>&1 1>&2 2>&3)

if [[ "$NET" == "static" ]]; then
    IPADDR=$(whiptail --inputbox "Static IP (CIDR):" 10 60 "192.168.1.50/24" 3>&1 1>&2 2>&3)
    GW=$(whiptail --inputbox "Gateway:" 10 60 "192.168.1.1" 3>&1 1>&2 2>&3)
    NETCONF="ip=$IPADDR,gw=$GW"
else
    NETCONF="ip=dhcp"
fi

############################################
# TEMPLATE
############################################
TEMPLATE=$(select_template)

############################################
# MEDIA PATHS
############################################
MEDIA_HOST=$(whiptail --inputbox "Host media path:" 10 60 "/mnt/media" 3>&1 1>&2 2>&3)
MEDIA_CT=$(whiptail --inputbox "CT media mount path:" 10 60 "/mnt/media" 3>&1 1>&2 2>&3)

############################################
# PORT
############################################
RDT_PORT=$(whiptail --inputbox "RDT-Client Port:" 10 60 "6500" 3>&1 1>&2 2>&3)

############################################
# PASSWORD
############################################
while true; do
    PASS1=$(whiptail --passwordbox "ROOT password:" 10 60 3>&1 1>&2 2>&3)
    PASS2=$(whiptail --passwordbox "Confirm password:" 10 60 3>&1 1>&2 2>&3)
    [[ "$PASS1" == "$PASS2" && -n "$PASS1" ]] && break
    whiptail --msgbox "Passwords do not match!" 10 40
done

############################################
# SUMMARY
############################################
SUMMARY=$(cat <<EOF
CTID:           $CTID
Hostname:       $HN
Cores:          $CORES
Memory:         $MEMORY MB
Swap:           $SWAP MB
Storage:        $STORAGE
Template:       $TEMPLATE
Network:        $NETCONF
Media Host:     $MEDIA_HOST
Media CT:       $MEDIA_CT
Port:           $RDT_PORT
EOF
)

whiptail --yesno "$SUMMARY\n\nProceed with install?" 20 70 || exit 1


############################################
# TEMPLATE DOWNLOAD
############################################
if ! pveam list local | awk '{print $2}' | grep -qx "$TEMPLATE"; then
    pveam update
    pveam download local "$TEMPLATE"
fi

############################################
# CREATE CT
############################################
pct create "$CTID" "local:vztmpl/$TEMPLATE" \
  -hostname "$HN" \
  -password "$PASS1" \
  -cores "$CORES" \
  -memory "$MEMORY" \
  -swap "$SWAP" \
  -rootfs "$STORAGE:8" \
  -features nesting=1,fuse=1 \
  -net0 "name=eth0,bridge=vmbr0,$NETCONF"

pct set "$CTID" -mp0 "$MEDIA_HOST",mp="$MEDIA_CT"

pct start "$CTID"
sleep 3

############################################
# INSTALL RDT-CLIENT
############################################
pct exec "$CTID" -- bash -c "
apt update &&
apt install -y unzip wget ca-certificates &&
cd /opt &&
wget -q https://github.com/rogerfar/rdt-client/releases/latest/download/rdt-client_linux-x64.zip &&
unzip -o rdt-client_linux-x64.zip -d rdt-client &&
chmod +x /opt/rdt-client/RdtClient
"

pct exec "$CTID" -- bash -c "cat <<EOF > /etc/systemd/system/rdtclient.service
[Unit]
Description=RDT Client Service
After=network.target

[Service]
WorkingDirectory=/opt/rdt-client
ExecStart=/opt/rdt-client/RdtClient
Environment=ASPNETCORE_URLS=http://0.0.0.0:${RDT_PORT}
Restart=always

[Install]
WantedBy=multi-user.target
EOF"

pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now rdtclient

############################################
# DONE
############################################
CT_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

whiptail --msgbox "RDT-Client installed!\n\nURL:\nhttp://${CT_IP}:${RDT_PORT}" 15 70
echo -e "${GN}Installation complete.${CL}"

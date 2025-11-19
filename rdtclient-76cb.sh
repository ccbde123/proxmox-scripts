#!/usr/bin/env bash
# RDT-Client-76cb Installer for Proxmox (AMD64)
# Ubuntu 22.04, full whiptail UI, unprivileged CT

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
trap 'echo -e "\n'"${RD}"'ERROR at line '"$LINENO"' — see '"$LOGFILE""${CL}"'"' ERR

############################################
# BASIC CHECKS
############################################
ARCH="$(dpkg --print-architecture)"
if [[ "$ARCH" != "amd64" ]]; then
  echo -e "${RD}This installer is for AMD64 only. Detected: ${ARCH}${CL}"
  exit 1
fi

# Refuse to run in PVE web shell (xtermjs) – forces real TTY/SSH
if [[ "${TERM:-}" == "xtermjs" ]]; then
  echo -e "${RD}Do NOT run this from the Proxmox Web Shell.${CL}"
  echo -e "Use SSH instead, then run the installer."
  exit 1
fi

if ! command -v whiptail >/dev/null 2>&1; then
  echo -e "${YW}Installing whiptail...${CL}"
  apt update && apt install -y whiptail
fi

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
# HELPERS
############################################

select_rootfs_storage() {
  local options=()
  while read -r store; do
    if pvesm config "$store" 2>/dev/null | grep -q "content.*rootdir"; then
      options+=("$store" "$store" "OFF")
    fi
  done < <(pvesm status | awk 'NR>1 {print $1}')

  if [[ ${#options[@]} -eq 0 ]]; then
    whiptail --title "RDT-Client-76cb Installer" --msgbox \
      "No Proxmox storages support rootdir content.\nCheck your storage config." 10 70
    exit 1
  fi

  # Prefer local-lvm if present
  for ((i=0;i<${#options[@]};i+=3)); do
    if [[ "${options[i]}" == "local-lvm" ]]; then
      options[i+2]="ON"
    fi
  done

  local choice
  choice=$(whiptail --title "RDT-Client-76cb Installer" \
                    --radiolist "Select storage for CT root filesystem:" \
                    20 70 10 \
                    "${options[@]}" \
                    3>&1 1>&2 2>&3) || exit 1

  echo "$choice"
}

select_template() {
  local options=(
    "ubuntu-22.04-standard_22.04-1_amd64.tar.zst" "Ubuntu 22.04 LTS (recommended)" "ON"
    "ubuntu-24.04-standard_24.04-2_amd64.tar.zst" "Ubuntu 24.04 LTS" "OFF"
  )

  local choice
  choice=$(whiptail --title "RDT-Client-76cb Installer" \
                    --radiolist "Select container template (stored on 'local'):" \
                    20 75 10 \
                    "${options[@]}" \
                    3>&1 1>&2 2>&3) || exit 1

  echo "$choice"
}

detect_media_path() {
  for p in /mnt/media /mnt/downloads /mnt/storage; do
    if [[ -d "$p" ]]; then
      echo "$p"
      return
    fi
  done
  echo "/mnt/media"
}

############################################
# GATHER SETTINGS (FULL UI)
############################################

CTID=$(whiptail --title "RDT-Client-76cb Installer" \
                --inputbox "Enter CTID for new container:" 10 60 "$(pvesh get /cluster/nextid)" \
                3>&1 1>&2 2>&3) || exit 1

HN=$(whiptail --title "RDT-Client-76cb Installer" \
              --inputbox "Hostname:" 10 60 "rdtclient-76cb" \
              3>&1 1>&2 2>&3) || exit 1

CORES=$(whiptail --title "RDT-Client-76cb Installer" \
                 --inputbox "CPU cores:" 10 60 "2" \
                 3>&1 1>&2 2>&3) || exit 1

MEMORY=$(whiptail --title "RDT-Client-76cb Installer" \
                  --inputbox "Memory (MB):" 10 60 "1024" \
                  3>&1 1>&2 2>&3) || exit 1

SWAP=$(whiptail --title "RDT-Client-76cb Installer" \
                --inputbox "Swap (MB):" 10 60 "512" \
                3>&1 1>&2 2>&3) || exit 1

DISK_GB=$(whiptail --title "RDT-Client-76cb Installer" \
                   --inputbox "Disk size for rootfs (GB):" 10 60 "8" \
                   3>&1 1>&2 2>&3) || exit 1

STORAGE=$(select_rootfs_storage)

NETMODE=$(whiptail --title "RDT-Client-76cb Installer" --radiolist \
"Select networking mode:" 15 60 3 \
"dhcp" "DHCP (recommended)" ON \
"static" "Static IP" OFF \
3>&1 1>&2 2>&3) || exit 1

if [[ "$NETMODE" == "static" ]]; then
  IPADDR=$(whiptail --title "RDT-Client-76cb Installer" \
                    --inputbox "Static IP (CIDR, e.g. 192.168.1.50/24):" 10 60 "192.168.1.50/24" \
                    3>&1 1>&2 2>&3) || exit 1
  GATEWAY=$(whiptail --title "RDT-Client-76cb Installer" \
                     --inputbox "Gateway IP:" 10 60 "192.168.1.1" \
                     3>&1 1>&2 2>&3) || exit 1
  NETCONF="ip=${IPADDR},gw=${GATEWAY}"
else
  NETCONF="ip=dhcp"
fi

TEMPLATE_STORAGE="local"
TEMPLATE=$(select_template)

MEDIA_HOST_DEFAULT="$(detect_media_path)"

MEDIA_HOST=$(whiptail --title "RDT-Client-76cb Installer" \
                      --inputbox "Host media path to bind-mount:" 10 70 "${MEDIA_HOST_DEFAULT}" \
                      3>&1 1>&2 2>&3) || exit 1

MEDIA_CT=$(whiptail --title "RDT-Client-76cb Installer" \
                    --inputbox "Container media path (mount point):" 10 70 "/mnt/media" \
                    3>&1 1>&2 2>&3) || exit 1

RDT_PORT=$(whiptail --title "RDT-Client-76cb Installer" \
                    --inputbox "RDT-Client Web UI port:" 10 60 "6500" \
                    3>&1 1>&2 2>&3) || exit 1

# Root password (double-confirm)
while true; do
  ROOT_PASS1=$(whiptail --title "RDT-Client-76cb Installer" \
                        --passwordbox "Enter ROOT password for container:" 10 60 \
                        3>&1 1>&2 2>&3) || exit 1
  ROOT_PASS2=$(whiptail --title "RDT-Client-76cb Installer" \
                        --passwordbox "Confirm ROOT password:" 10 60 \
                        3>&1 1>&2 2>&3) || exit 1
  if [[ -n "$ROOT_PASS1" && "$ROOT_PASS1" == "$ROOT_PASS2" ]]; then
    break
  fi
  whiptail --title "RDT-Client-76cb Installer" \
           --msgbox "Passwords do not match or are empty. Try again." 10 60
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
Disk:           ${DISK_GB}G
Storage:        $STORAGE
Template store: $TEMPLATE_STORAGE
Template file:  $TEMPLATE
Network:        $NETCONF
Media host:     $MEDIA_HOST
Media in CT:    $MEDIA_CT
RDT-Client port:$RDT_PORT

Root password:  (hidden)
EOF
)

whiptail --title "RDT-Client-76cb Installer" \
         --yesno "$SUMMARY\n\nProceed with installation?" 20 70 || exit 1

############################################
# TEMPLATE DOWNLOAD (ALWAYS USING 'local')
############################################

echo -e "${YW}Checking template ${TEMPLATE} in ${TEMPLATE_STORAGE}...${CL}"

if ! pveam list "$TEMPLATE_STORAGE" | awk '{print $2}' | grep -qx "$TEMPLATE"; then
  echo -e "${YW}Template not found locally. Updating and downloading...${CL}"
  pveam update
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
else
  echo -e "${GN}✔ Template already present in ${TEMPLATE_STORAGE}${CL}"
fi

############################################
# CREATE CONTAINER
############################################

echo -e "${YW}Creating unprivileged LXC CTID $CTID (${HN})...${CL}"

pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  -hostname "$HN" \
  -password "$ROOT_PASS1" \
  -cores "$CORES" \
  -memory "$MEMORY" \
  -swap "$SWAP" \
  -rootfs "${STORAGE}:${DISK_GB}" \
  -unprivileged 1 \
  -features nesting=1,fuse=1,keyctl=1 \
  -ostype ubuntu \
  -net0 "name=eth0,bridge=vmbr0,${NETCONF}"

if [[ -d "$MEDIA_HOST" ]]; then
  pct set "$CTID" -mp0 "${MEDIA_HOST}",mp="${MEDIA_CT}"
else
  echo -e "${YW}WARN: Host media path ${MEDIA_HOST} does not exist. Skipping bind mount.${CL}"
fi

echo -e "${YW}Starting container...${CL}"
pct start "$CTID"
sleep 5

############################################
# INSTALL RDT-CLIENT INSIDE CT
############################################

echo -e "${YW}Installing rdt-client in CT ${CTID}...${CL}"

pct exec "$CTID" -- bash -c "
set -e
apt update
apt install -y wget unzip ca-certificates
mkdir -p /opt
cd /opt
wget -q https://github.com/rogerfar/rdt-client/releases/latest/download/rdt-client_linux-x64.zip
unzip -qo rdt-client_linux-x64.zip -d rdt-client
chmod +x /opt/rdt-client/RdtClient
"

echo -e "${YW}Creating systemd service...${CL}"

pct exec "$CTID" -- bash -c "cat <<EOF >/etc/systemd/system/rdtclient.service
[Unit]
Description=RDT Client Service
After=network.target

[Service]
WorkingDirectory=/opt/rdt-client
ExecStart=/opt/rdt-client/RdtClient
Environment=ASPNETCORE_URLS=http://0.0.0.0:${RDT_PORT}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now rdtclient
"

############################################
# DONE – SHOW ACCESS INFO
############################################

CT_IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"

FINAL_MSG=$(cat <<EOF
RDT-Client has been installed successfully!

Container ID:   $CTID
Hostname:       $HN
Container IP:   $CT_IP
Web UI URL:     http://${CT_IP}:${RDT_PORT}

Media mount in CT:
  ${MEDIA_CT}  (from host: ${MEDIA_HOST})

You can manage the container from the Proxmox GUI as usual.
EOF
)

whiptail --title "RDT-Client-76cb Installer" --msgbox "$FINAL_MSG" 20 80

echo -e "${GN}✔ Installation complete.${CL}"
echo -e "${BL}RDT-Client URL:${CL}  http://${CT_IP}:${RDT_PORT}"

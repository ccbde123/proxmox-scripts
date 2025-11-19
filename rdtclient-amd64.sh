#!/usr/bin/env bash
# RDT-Client-76cb AMD64 Proxmox Installer
# Creates an LXC, installs rdt-client, and wires it up with a whiptail UI.

set -euo pipefail

############################################
#                COLORS                    #
############################################
YW="\033[33m"
GN="\033[32m"
RD="\033[31m"
BL="\033[36m"
CL="\033[m"

############################################
#                LOGGING                   #
############################################
LOGFILE="/var/log/rdtclient-amd64-install.log"
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

trap 'echo -e "\n'"${RD}"'ERROR: Script failed at line '"$LINENO"'. See '"$LOGFILE""${CL}"'"' ERR

############################################
#           BASIC ENV CHECKS               #
############################################

# Architecture check
ARCH="$(dpkg --print-architecture)"
if [[ "$ARCH" != "amd64" ]]; then
  echo -e "${RD}❌ This installer only supports AMD64 (Intel/AMD).${CL}"
  echo -e "Detected: ${YW}$ARCH${CL}"
  exit 1
fi

# Ensure whiptail is present
if ! command -v whiptail >/dev/null 2>&1; then
  echo -e "${YW}whiptail not found, installing...${CL}"
  apt update && apt install -y whiptail
fi

clear
echo -e "    ____  ____  _______________            __"
echo -e "   / __ \\/ __ \\/_  __/ ____/ (_)__  ____  / /_"
echo -e "  / /_/ / / / / / / / /   / / / _ \\/ __ \\/ __/"
echo -e " / _, _/ /_/ / / / / /___/ / /  __/ / / / /_  "
echo -e "/_/ |_/_____/ /_/  \\____/_/_/\\___/_/ /_/\\__/  "
echo -e "                                              "
echo -e "    ${GN}RDT-Client-76cb Proxmox Installer (AMD64)${CL}"
echo
echo -e "${GN}✔ Architecture OK — AMD64 detected${CL}\n"

############################################
#           HELPER FUNCTIONS               #
############################################

get_next_ctid() {
  pvesh get /cluster/nextid
}

get_all_storages() {
  pvesm status | awk 'NR>1 {print $1}'
}

get_template_storages() {
  while IFS= read -r st; do
    if pvesm config "$st" 2>/dev/null | grep -q "vztmpl"; then
      echo "$st"
    fi
  done < <(get_all_storages)
}

get_rootdir_storages() {
  while IFS= read -r st; do
    if pvesm config "$st" 2>/dev/null | grep -q "rootdir"; then
      echo "$st"
    fi
  done < <(get_all_storages)
}

find_rootfs_storage_default() {
  if get_all_storages | grep -qx "local-lvm"; then
    echo "local-lvm"
    return
  fi
  get_rootdir_storages | head -n1 || echo "local"
}

find_template_storage_default() {
  get_template_storages | head -n1 || echo "local"
}

random_password() {
  pw="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16 || true)"
  printf '%s' "${pw:-ChangeMeNow123!}"
}

whip_input() {
  local title="$1"
  local prompt="$2"
  local default="$3"
  whiptail --title "$title" --inputbox "$prompt" 0 0 "$default" 3>&1 1>&2 2>&3
}

whip_password() {
  local title="$1"
  local prompt="$2"
  whiptail --title "$title" --passwordbox "$prompt" 0 0 3>&1 1>&2 2>&3
}

whip_msg() {
  local title="$1"
  local msg="$2"
  whiptail --title "$title" --msgbox "$msg" 0 0
}

whip_yesno() {
  local title="$1"
  local msg="$2"
  whiptail --title "$title" --yesno "$msg" 0 0
}

whip_radiolist_storage() {
  local title="$1"
  local prompt="$2"
  local default="$3"
  shift 3
  local storages=("$@")
  local items=()
  local s
  for s in "${storages[@]}"; do
    if [[ "$s" == "$default" ]]; then
      items+=("$s" "" "ON")
    else
      items+=("$s" "" "OFF")
    fi
  done
  whiptail --title "$title" --radiolist "$prompt" 0 0 0 "${items[@]}" 3>&1 1>&2 2>&3
}

############################################
#           DEFAULT VALUES                 #
############################################

CTID_DEFAULT="$(get_next_ctid)"
ROOTFS_DEFAULT="$(find_rootfs_storage_default)"
TEMPLATE_STORAGE_DEFAULT="$(find_template_storage_default)"
TEMPLATE_FILE_DEFAULT="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
HN_DEFAULT="rdtclient"
MEMORY_DEFAULT="1024"
MEDIA_HOST_DEFAULT="/mnt/media"
MEDIA_CT_DEFAULT="/mnt/media"
PORT_DEFAULT="6500"

############################################
#            INTERACTIVE UI                #
############################################

# CTID
CTID="$(whip_input 'RDT-Client-76cb Installer' 'Enter CTID for the new LXC:' "$CTID_DEFAULT")" || exit 1

# Hostname
HN="$(whip_input 'RDT-Client-76cb Installer' 'Enter hostname for the new LXC:' "$HN_DEFAULT")" || exit 1

# Memory
MEMORY="$(whip_input 'RDT-Client-76cb Installer' 'Enter memory (in MB) for the new LXC:' "$MEMORY_DEFAULT")" || exit 1

# Rootfs Storage (radiolist)
mapfile -t ROOT_STORAGES < <(get_rootdir_storages)
if [[ "${#ROOT_STORAGES[@]}" -eq 0 ]]; then
  ROOT_STORAGES=("local")
fi
STORAGE="$(whip_radiolist_storage 'RDT-Client-76cb Installer' 'Select storage for the container root filesystem:' "$ROOTFS_DEFAULT" "${ROOT_STORAGES[@]}")" || exit 1

# Template Storage (radiolist)
mapfile -t TEMPLATE_STORAGES < <(get_template_storages)
if [[ "${#TEMPLATE_STORAGES[@]}" -eq 0 ]]; then
  TEMPLATE_STORAGES=("local")
fi
TEMPLATE_STORAGE="$(whip_radiolist_storage 'RDT-Client-76cb Installer' 'Select storage for templates:' "$TEMPLATE_STORAGE_DEFAULT" "${TEMPLATE_STORAGES[@]}")" || exit 1

# Template file (input)
TEMPLATE_FILE="$(whip_input 'RDT-Client-76cb Installer' 'Template filename (from pveam):' "$TEMPLATE_FILE_DEFAULT")" || exit 1

# Media Host Path
MEDIA_HOST_PATH="$(whip_input 'RDT-Client-76cb Installer' 'Host path to bind-mount into the container:' "$MEDIA_HOST_DEFAULT")" || exit 1

# Media CT Path
MEDIA_CT_PATH="$(whip_input 'RDT-Client-76cb Installer' 'Path inside the container to mount media:' "$MEDIA_CT_DEFAULT")" || exit 1

# RDT Port
RDT_PORT="$(whip_input 'RDT-Client-76cb Installer' 'Port for RDT-Client Web UI:' "$PORT_DEFAULT")" || exit 1

# Root Password (double-confirm, masked)
while true; do
  ROOT_PASS="$(whip_password 'RDT-Client-76cb Installer' 'Enter ROOT password for the new container:')" || exit 1
  ROOT_PASS_CONFIRM="$(whip_password 'RDT-Client-76cb Installer' 'Confirm ROOT password:')" || exit 1
  if [[ -n "$ROOT_PASS" && "$ROOT_PASS" == "$ROOT_PASS_CONFIRM" ]]; then
    break
  fi
  whip_msg "RDT-Client-76cb Installer" "Passwords do not match or are empty. Please try again."
done

############################################
#            SUMMARY + CONFIRM             #
############################################

SUMMARY=$(cat <<EOF
CTID:            $CTID
Hostname:        $HN
Memory:          $MEMORY MB
Rootfs Storage:  $STORAGE
Template Store:  $TEMPLATE_STORAGE
Template File:   $TEMPLATE_FILE
Media Host Path: $MEDIA_HOST_PATH
Media CT Path:   $MEDIA_CT_PATH
RDT Port:        $RDT_PORT

Root password:   (hidden)
EOF
)

whip_yesno "RDT-Client-76cb Installer" "$SUMMARY\n\nProceed with installation?" || {
  echo -e "${RD}Aborted by user.${CL}"
  exit 1
}

############################################
#       TEMPLATE DOWNLOAD / CHECK          #
############################################

echo -e "${YW}Checking template ${TEMPLATE_FILE} in ${TEMPLATE_STORAGE}...${CL}"

if ! pveam list "$TEMPLATE_STORAGE" | awk '{print $2}' | grep -qx "$TEMPLATE_FILE"; then
  echo -e "${YW}Template not found locally. Updating and downloading...${CL}"
  pveam update
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_FILE"
else
  echo -e "${GN}✔ Template already present${CL}"
fi

############################################
#           CREATE CONTAINER               #
############################################

echo -e "${YW}Creating LXC CTID ${CTID} (${HN})...${CL}"

pct create "$CTID" \
  "${TEMPLATE_STORAGE}:vztmpl/$TEMPLATE_FILE" \
  -hostname "$HN" \
  -password "$ROOT_PASS" \
  -memory "$MEMORY" \
  -unprivileged 1 \
  -features nesting=1,fuse=1,keyctl=1 \
  -net0 name=eth0,bridge=vmbr0,ip=dhcp \
  -storage "$STORAGE"

if [[ -d "$MEDIA_HOST_PATH" ]]; then
  echo -e "${YW}Adding bind-mount: ${MEDIA_HOST_PATH} -> ${MEDIA_CT_PATH}${CL}"
  pct set "$CTID" -mp0 "$MEDIA_HOST_PATH",mp="$MEDIA_CT_PATH"
else
  echo -e "${RD}WARN: Host media path ${MEDIA_HOST_PATH} does not exist, skipping bind-mount.${CL}"
fi

echo -e "${YW}Starting container...${CL}"
pct start "$CTID"
sleep 5

############################################
#      INSTALL RDT-CLIENT IN CONTAINER     #
############################################

echo -e "${YW}Installing rdt-client in CT ${CTID}...${CL}"

pct exec "$CTID" -- bash -c "
  apt update &&
  apt install -y wget unzip ca-certificates &&
  mkdir -p /opt &&
  cd /opt &&
  wget -q https://github.com/rogerfar/rdt-client/releases/latest/download/rdt-client_linux-x64.zip &&
  unzip -qo rdt-client_linux-x64.zip -d rdt-client &&
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
Restart=always
User=root
Environment=ASPNETCORE_URLS=http://0.0.0.0:${RDT_PORT}

[Install]
WantedBy=multi-user.target
EOF"

pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now rdtclient

############################################
#            DISPLAY ACCESS INFO           #
############################################

CT_IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"

FINAL_MSG=$(cat <<EOF
RDT-Client installed successfully!

CTID:          $CTID
Hostname:      $HN
Container IP:  $CT_IP
Web UI:        http://${CT_IP}:${RDT_PORT}

Media host path:  $MEDIA_HOST_PATH
Media CT path:    $MEDIA_CT_PATH

Note: root password not shown again. Check Proxmox CT config if needed.
EOF
)

whip_msg "RDT-Client-76cb Installer" "$FINAL_MSG"

echo -e "\n${GN}✔ Installation complete!${CL}"
echo -e "${BL}Access RDT-Client at:${CL}  http://${CT_IP}:${RDT_PORT}\n"

exit 0

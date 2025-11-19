#!/usr/bin/env bash
# rdt-client AMD64 Proxmox Installer
# Full-featured installer for Proxmox, with interactive UI and best practices.

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

trap 'echo -e "\n${RD}ERROR: Script failed at line $LINENO. See $LOGFILE${CL}"' ERR

############################################
#            ARCHITECTURE CHECK            #
############################################
ARCH="$(dpkg --print-architecture)"
if [[ "$ARCH" != "amd64" ]]; then
  echo -e "${RD}❌ This installer only supports AMD64 (Intel/AMD).${CL}"
  echo -e "Detected: ${YW}$ARCH${CL}"
  exit 1
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
#             STORAGE DETECTION            #
############################################

# Find template storage (must support vzdump/templates)
find_template_storage() {
  while IFS= read -r st; do
    if pvesm config "$st" 2>/dev/null | grep -q "vztmpl"; then
      echo "$st"
      return
    fi
  done < <(pvesm status | awk 'NR>1 {print $1}')
  echo "local"
}

# Find rootfs storage (prefer lvmthin)
find_rootfs_storage() {
  if pvesm status | awk 'NR>1 {print $1}' | grep -qx "local-lvm"; then
    echo "local-lvm"
    return
  fi
  while IFS= read -r st; do
    if pvesm config "$st" 2>/dev/null | grep -q "rootdir"; then
      echo "$st"
      return
    fi
  done < <(pvesm status | awk 'NR>1 {print $1}')
  echo "local"
}

############################################
#           RANDOM GENERATOR               #
############################################
random_password() {
  pw="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16 || true)"
  printf '%s' "${pw:-ChangeMeNow123!}"
}

############################################
#           INTERACTIVE MODE CHECK         #
############################################
if [ -t 0 ]; then
  INTERACTIVE=true
else
  INTERACTIVE=false
fi

############################################
#            DEFAULT VALUES                #
############################################
CTID_DEFAULT="$(pvesh get /cluster/nextid)"
TEMPLATE="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
TEMPLATE_STORAGE_DEFAULT="$(find_template_storage)"
ROOTFS_STORAGE_DEFAULT="$(find_rootfs_storage)"
HOSTNAME_DEFAULT="rdtclient"
MEMORY_DEFAULT="1024"
MEDIA_HOST_DEFAULT="/mnt/media"
MEDIA_CT_DEFAULT="/mnt/media"
PORT_DEFAULT="6500"

############################################
#             INTERACTIVE MENU             #
############################################
if $INTERACTIVE; then
  echo -e "${BL}Interactive mode enabled.${CL}"
  echo

  read -rp "CTID [$CTID_DEFAULT]: " CTID
  CTID="${CTID:-$CTID_DEFAULT}"

  read -rp "Hostname [$HOSTNAME_DEFAULT]: " HN
  HN="${HN:-$HOSTNAME_DEFAULT}"

  read -rp "Memory MB [$MEMORY_DEFAULT]: " MEMORY
  MEMORY="${MEMORY:-$MEMORY_DEFAULT}"

  read -rp "LXC Root Storage [$ROOTFS_STORAGE_DEFAULT]: " STORAGE
  STORAGE="${STORAGE:-$ROOTFS_STORAGE_DEFAULT}"

  read -rp "Template Storage [$TEMPLATE_STORAGE_DEFAULT]: " TEMPLATE_STORAGE
  TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-$TEMPLATE_STORAGE_DEFAULT}"

  read -rp "Host media path [$MEDIA_HOST_DEFAULT]: " MEDIA_HOST_PATH
  MEDIA_HOST_PATH="${MEDIA_HOST_PATH:-$MEDIA_HOST_DEFAULT}"

  read -rp "Container media path [$MEDIA_CT_DEFAULT]: " MEDIA_CT_PATH
  MEDIA_CT_PATH="${MEDIA_CT_PATH:-$MEDIA_CT_DEFAULT}"

  read -rp "RDT port [$PORT_DEFAULT]: " RDT_PORT
  RDT_PORT="${RDT_PORT:-$PORT_DEFAULT}"

  echo
  echo -e "${BL}Enter ROOT PASSWORD for new container:${CL}"
  while true; do
    read -s -p "Password: " ROOT_PASS
    echo
    read -s -p "Confirm:  " ROOT_PASS_CONFIRM
    echo
    [[ "$ROOT_PASS" == "$ROOT_PASS_CONFIRM" && -n "$ROOT_PASS" ]] && break
    echo -e "${RD}Passwords do not match or empty. Try again.${CL}"
  done

else
  # Non-interactive mode (curl | bash)
  CTID="$CTID_DEFAULT"
  HN="$HOSTNAME_DEFAULT"
  MEMORY="$MEMORY_DEFAULT"
  STORAGE="$ROOTFS_STORAGE_DEFAULT"
  TEMPLATE_STORAGE="$TEMPLATE_STORAGE_DEFAULT"
  MEDIA_HOST_PATH="$MEDIA_HOST_DEFAULT"
  MEDIA_CT_PATH="$MEDIA_CT_DEFAULT"
  RDT_PORT="$PORT_DEFAULT"
  ROOT_PASS="$(random_password)"

  echo -e "${YW}Running in NON-INTERACTIVE mode.${CL}"
fi

############################################
#           PRINT SUMMARY                  #
############################################
echo -e "\n${YW}Configuration:${CL}"
echo -e " CTID:            ${GN}$CTID${CL}"
echo -e " Hostname:        ${GN}$HN${CL}"
echo -e " Memory:          ${GN}$MEMORY MB${CL}"
echo -e " Rootfs Storage:  ${GN}$STORAGE${CL}"
echo -e " Template Store:  ${GN}$TEMPLATE_STORAGE${CL}"
echo -e " Media Host:      ${GN}$MEDIA_HOST_PATH${CL}"
echo -e " Media CT:        ${GN}$MEDIA_CT_PATH${CL}"
echo -e " RDT Client Port: ${GN}$RDT_PORT${CL}"
echo -e " Root Password:   ${GN}(hidden)${CL}"
echo

############################################
#       TEMPLATE ACQUISITION               #
############################################
echo -e "${YW}Checking template...${CL}"

if ! pveam list "$TEMPLATE_STORAGE" | awk '{print $2}' | grep -qx "$TEMPLATE"; then
  echo -e "${YW}Downloading template into $TEMPLATE_STORAGE...${CL}"
  pveam update
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
else
  echo -e "${GN}✔ Template already present${CL}"
fi

############################################
#           CREATE CONTAINER               #
############################################
echo -e "${YW}Creating container ${CTID}...${CL}"

pct create "$CTID" \
  "${TEMPLATE_STORAGE}:vztmpl/$TEMPLATE" \
  -hostname "$HN" \
  -password "$ROOT_PASS" \
  -memory "$MEMORY" \
  -unprivileged 1 \
  -features nesting=1,fuse=1,keyctl=1 \
  -net0 name=eth0,bridge=vmbr0,ip=dhcp \
  -storage "$STORAGE"

if [[ -d "$MEDIA_HOST_PATH" ]]; then
  pct set "$CTID" -mp0 "$MEDIA_HOST_PATH",mp="$MEDIA_CT_PATH"
fi

pct start "$CTID"
sleep 4

############################################
#      INSTALL RDT-CLIENT INSIDE CT        #
############################################
echo -e "${YW}Installing rdt-client inside CT...${CL}"

pct exec "$CTID" -- bash -c "
apt update && apt install -y wget unzip &&
cd /opt &&
wget -q https://github.com/rogerfar/rdt-client/releases/latest/download/rdt-client_linux-x64.zip &&
unzip -qo rdt-client_linux-x64.zip -d rdt-client &&
chmod +x /opt/rdt-client/RdtClient
"

############################################
#           CREATE SYSTEMD SERVICE         #
############################################
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

echo -e "\n${GN}✔ Installation complete!${CL}"
echo -e "${BL}Access RDT-Client:${CL}   http://${CT_IP}:${RDT_PORT}"
echo -e "${BL}Container CTID:${CL}      $CTID"
echo -e "${BL}Hostname:${CL}           $HN"
echo -e "${BL}Note:${CL}               Root password not shown for security."
echo

exit 0


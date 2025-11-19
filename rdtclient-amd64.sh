#!/usr/bin/env bash
# rdt-client AMD64 Proxmox Installer
# Creates an LXC, installs rdt-client, and wires it up.
# Architecture: amd64

set -euo pipefail

# -----------------------------
# Colors
# -----------------------------
YW="$(printf '\033[33m')"
GN="$(printf '\033[32m')"
RD="$(printf '\033[31m')"
BL="$(printf '\033[36m')"
CL="$(printf '\033[m')"

# -----------------------------
# Logging
# -----------------------------
LOGFILE="/var/log/rdtclient-amd64-install.log"
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

trap 'echo -e "\n${RD}ERROR: Script failed at line $LINENO. Check $LOGFILE for details.${CL}"' ERR

# -----------------------------
# Arch check
# -----------------------------
ARCH="$(dpkg --print-architecture)"
if [[ "$ARCH" != "amd64" ]]; then
  echo -e "${RD}💡 This script is for AMD64/x86_64 only (Intel/AMD).${CL}"
  echo -e "You are running: ${YW}$ARCH${CL}"
  exit 1
fi

clear
echo -e "    ____  ____  _______________            __"
echo -e "   / __ \\/ __ \\/_  __/ ____/ (_)__  ____  / /_"
echo -e "  / /_/ / / / / / / / /   / / / _ \\/ __ \\/ __/"
echo -e " / _, _/ /_/ / / / / /___/ / /  __/ / / / /_  "
echo -e "/_/ |_/_____/ /_/  \\____/_/_/\\___/_/ /_/\\__/  "
echo -e "                                              "
echo -e "      ${GN}RDT-Client Proxmox Installer (AMD64)${CL}\n"

echo -e "${GN}✔ Detected AMD64 — proceeding...${CL}\n"

# -----------------------------
# Helpers
# -----------------------------
get_next_ctid() {
  pvesh get /cluster/nextid
}

get_default_storage() {
  if pvesm status | awk 'NR>1 {print $1}' | grep -qx "local-lvm"; then
    echo "local-lvm"
    return
  fi
  if pvesm status | awk 'NR>1 {print $1}' | grep -qx "local"; then
    echo "local"
    return
  fi
  for s in $(pvesm status | awk 'NR>1 {print $1}'); do
    if pvesm config "$s" 2>/dev/null | grep -q "content .*rootdir"; then
      echo "$s"
      return
    fi
  done
  echo "local"
}

# FIXED FUNCTION — stops line 94 crash
random_password() {
  pw="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16 || true)"
  printf '%s' "${pw:-ChangeMe123!}"
}

# -----------------------------
# Defaults (overridable via env)
# -----------------------------
CTID="${CTID:-$(get_next_ctid)}"
HN="${HN:-rdtclient}"
MEMORY="${MEMORY:-1024}"
STORAGE="${STORAGE:-$(get_default_storage)}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-ubuntu-22.04-standard_22.04-1_amd64.tar.zst}"
MEDIA_HOST_PATH="${MEDIA_HOST_PATH:-/mnt/media}"
MEDIA_CT_PATH="${MEDIA_CT_PATH:-/mnt/media}"
RDT_PORT="${RDT_PORT:-6500}"

ROOT_PASS="${ROOT_PASS:-$(random_password)}"

# -----------------------------
# Summary / "menu"
# -----------------------------
echo -e "${YW}Planned configuration:${CL}"
echo -e "  CTID:             ${GN}$CTID${CL}"
echo -e "  Hostname:         ${GN}$HN${CL}"
echo -e "  Memory:           ${GN}${MEMORY}MB${CL}"
echo -e "  Rootfs storage:   ${GN}$STORAGE${CL}"
echo -e "  Template storage: ${GN}$TEMPLATE_STORAGE${CL}"
echo -e "  Template file:    ${GN}$TEMPLATE${CL}"
echo -e "  Media host path:  ${GN}$MEDIA_HOST_PATH${CL}"
echo -e "  Media CT path:    ${GN}$MEDIA_CT_PATH${CL}"
echo -e "  rdt-client port:  ${GN}$RDT_PORT${CL}"
echo -e "  Root password:    ${GN}$ROOT_PASS${CL}\n"

read -r -p "$(printf "${BL}Proceed with these settings? [Y/n]: ${CL}")" CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo -e "${RD}Aborted by user.${CL}"
  exit 1
fi

# -----------------------------
# Ensure template exists
# -----------------------------
echo -e "\n${YW}Checking for required template in ${TEMPLATE_STORAGE}...${CL}"

if ! pveam list "$TEMPLATE_STORAGE" | awk '{print $2}' | grep -qx "$TEMPLATE"; then
  echo -e "${YW}Template not found locally, attempting download...${CL}"
  pveam update
  if ! pveam available | awk '{print $2}' | grep -qx "$TEMPLATE"; then
    echo -e "${RD}ERROR: Template $TEMPLATE not found in remote list.${CL}"
    echo -e "${YW}Run: pveam available | grep ubuntu${CL}"
    exit 1
  fi
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  echo -e "${GN}✔ Template downloaded into ${TEMPLATE_STORAGE}${CL}"
else
  echo -e "${GN}✔ Template already present in ${TEMPLATE_STORAGE}${CL}"
fi

# -----------------------------
# Create LXC
# -----------------------------
echo -e "\n${YW}Creating LXC CTID ${CTID} (${HN})...${CL}"

pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/$TEMPLATE" \
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
  echo -e "${RD}WARN: Media host path ${MEDIA_HOST_PATH} does not exist, skipping bind-mount.${CL}"
fi

echo -e "${YW}Starting container...${CL}"
pct start "$CTID"
sleep 5

# -----------------------------
# Inside CT: install deps + rdt-client
# -----------------------------
echo -e "${YW}Updating packages and installing dependencies in CT...${CL}"
pct exec "$CTID" -- bash -c "apt update && apt upgrade -y && apt install -y wget unzip ca-certificates"

echo -e "${YW}Downloading rdt-client inside CT...${CL}"
pct exec "$CTID" -- bash -c "
  mkdir -p /opt &&
  cd /opt &&
  wget -q https://github.com/rogerfar/rdt-client/releases/latest/download/rdt-client_linux-x64.zip &&
  unzip -o rdt-client_linux-x64.zip -d rdt-client &&
  chmod +x /opt/rdt-client/RdtClient
"

echo -e "${YW}Creating systemd service...${CL}"
pct exec "$CTID" -- bash -c "cat <<EOF > /etc/systemd/system/rdtclient.service
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

CT_IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"

echo -e "\n${GN}✔ rdt-client successfully installed in LXC CTID ${CTID}${CL}\n"
echo -e "${BL}Access URL:${CL}       http://${CT_IP}:${RDT_PORT}"
echo -e "${BL}Container CTID:${CL}    ${GN}$CTID${CL}"
echo -e "${BL}Hostname:${CL}         ${GN}$HN${CL}"
echo -e "${BL}Root password:${CL}    ${GN}$ROOT_PASS${CL}"
echo -e "${BL}Media mount (host):${CL} ${GN}$MEDIA_HOST_PATH${CL}"
echo -e "${BL}Media mount (CT):${CL}   ${GN}$MEDIA_CT_PATH${CL}\n"

echo -e "${YW}Next steps inside rdt-client UI:${CL}"
echo -e "  1. Open the URL above."
echo -e "  2. Set admin credentials."
echo -e "  3. Add your Real-Debrid API key."
echo -e "  4. Set download path to: ${MEDIA_CT_PATH}/downloads"
echo -e "\n${GN}Done.${CL}"

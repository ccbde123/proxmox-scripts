#!/usr/bin/env bash
# rdt-client AMD64 Proxmox Installer

set -e

# COLORS
YW=$(echo "\033[33m")
GN=$(echo "\033[32m")
RD=$(echo "\033[31m")
BL=$(echo "\033[36m")
CL=$(echo "\033[m")

# CHECK ARCH
ARCH=$(dpkg --print-architecture)
if [[ "$ARCH" != "amd64" ]]; then
    echo -e "${RD}ERROR: This installer is ONLY for AMD64 / x86_64 systems (Intel / AMD CPUs).${CL}"
    exit 1
fi

echo -e "${GN}✔ Detected AMD64 — proceeding...${CL}"

# LXC SETTINGS
CTID=${CTID:-210}
HN=rdtclient
MEMORY=1024
STORAGE=${STORAGE:-local-lvm}
NET=${NET:-"dhcp"}

echo -e "${YW}Creating Ubuntu 22.04 LXC...${CL}"

pct create $CTID local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
    -hostname $HN \
    -password '' \
    -memory $MEMORY \
    -net0 name=eth0,bridge=vmbr0,ip=$NET \
    -features nesting=1,keyctl=1,fuse=1 \
    -unprivileged 1 \
    -storage $STORAGE

echo -e "${GN}✔ LXC created.${CL}"

pct start $CTID
sleep 5

echo -e "${YW}Updating LXC packages...${CL}"
pct exec $CTID -- bash -c "apt update && apt upgrade -y && apt install -y wget unzip"

echo -e "${YW}Downloading rdt-client (AMD64 build)...${CL}"
pct exec $CTID -- bash -c "cd /opt && wget -q https://github.com/rogerfar/rdt-client/releases/latest/download/rdt-client_linux-x64.zip && unzip rdt-client_linux-x64.zip -d rdt-client && chmod +x /opt/rdt-client/RdtClient"

echo -e "${YW}Creating systemd service...${CL}"
pct exec $CTID -- bash -c "cat <<EOF > /etc/systemd/system/rdtclient.service
[Unit]
Description=RDT Client Service
After=network.target

[Service]
WorkingDirectory=/opt/rdt-client
ExecStart=/opt/rdt-client/RdtClient
Restart=always
User=root
Environment=ASPNETCORE_URLS=http://0.0.0.0:6500

[Install]
WantedBy=multi-user.target
EOF"

pct exec $CTID -- systemctl daemon-reload
pct exec $CTID -- systemctl enable --now rdtclient

IP=$(pct exec $CTID ip a show eth0 | grep "inet " | awk '{print $2}' | cut -d/ -f1)

echo -e "${GN}✔ rdt-client successfully installed on LXC $CTID${CL}"
echo -e ""
echo -e "${BL}Access URL:${CL}  http://${IP}:6500"
echo -e ""
echo -e "${YW}Default login will be created on first launch inside the UI.${CL}"
echo -e "${GN}Done!${CL}"

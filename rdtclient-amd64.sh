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
    echo -e "${RD}ERROR: This installer is ONLY for AMD64/x86_64 systems.${CL}"
    exit 1
fi

echo -e "${GN}✔ Detected AMD64 — proceeding...${CL}"

# LXC CONFIGURATION
CTID=${CTID:-210}
HN=rdtclient
TEMPLATE="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
STORAGE=${STORAGE:-local}
MEMORY=1024

echo -e "${YW}Checking for required template...${CL}"

# Check template exists
if ! pveam list $STORAGE | grep -q "$TEMPLATE"; then
    echo -e "${RD}Template not found in storage: $STORAGE${CL}"
    echo -e "${YW}Attempting to download $TEMPLATE ...${CL}"
    pveam update

    if pveam available | grep -q "$TEMPLATE"; then
        pveam download $STORAGE $TEMPLATE
        echo -e "${GN}✔ Template downloaded successfully${CL}"
    else
        echo -e "${RD}ERROR: Template $TEMPLATE cannot be found remotely.${CL}"
        echo -e "${YW}Run: pveam available | grep ubuntu${CL}"
        exit 1
    fi
else
    echo -e "${GN}✔ Template found in storage${CL}"
fi

echo -e "${YW}Creating Ubuntu 22.04 LXC ($CTID)...${CL}"

pct create $CTID $STORAGE:vztmpl/$TEMPLATE \
    -hostname $HN \
    -password '' \
    -memory $MEMORY \
    -unprivileged 1 \
    -features nesting=1,fuse=1,keyctl=1 \
    -net0 name=eth0,bridge=vmbr0,ip=dhcp \
    -storage $STORAGE

pct start $CTID
sleep 5

echo -e "${YW}Updating container packages...${CL}"
pct exec $CTID -- bash -c "apt update && apt upgrade -y && apt install -y wget unzip"

echo -e "${YW}Downloading rdt-client (x64)...${CL}"
pct exec $CTID -- bash -c "
    cd /opt &&
    wget -q https://github.com/rogerfar/rdt-client/releases/latest/download/rdt-client_linux-x64.zip &&
    unzip -o rdt-client_linux-x64.zip -d rdt-client &&
    chmod +x /opt/rdt-client/RdtClient
"

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

IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')

echo -e "${GN}✔ rdt-client successfully installed in LXC $CTID${CL}"
echo -e ""
echo -e "${BL}Access it at:${CL}  http://${IP}:6500"
echo -e ""
echo -e "${GN}Installation complete!${CL}"

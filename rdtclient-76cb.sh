#!/usr/bin/env bash
set -euo pipefail

# Colors
GN=$(printf '\033[32m')
RD=$(printf '\033[31m')
YW=$(printf '\033[33m')
CL=$(printf '\033[m')

echo -e "    ____  ____  _______________            __"
echo -e "   / __ \\/ __ \\/_  __/ ____/ (_)__  ____  / /_"
echo -e "  / /_/ / / / / / / / /   / / / _ \\/ __ \\/ __/"
echo -e " / _, _/ /_/ / / / / /___/ / /  __/ / / / /_  "
echo -e "/_/ |_/_____/ /_/  \\____/_/_/\\___/_/ /_/\\__/  "
echo
echo -e "   ${GN}RDT-Client-76cb Proxmox Installer (AMD64)${CL}\n"

# Architecture Check
ARCH=$(dpkg --print-architecture)
if [[ "$ARCH" != "amd64" ]]; then
    echo -e "${RD}This script supports AMD64 only!${CL}"
    exit 1
fi
echo -e "${GN}✔ Architecture OK${CL}\n"

# Config
CTID=$(pvesh get /cluster/nextid)
STORAGE="local-lvm"
TEMPLATE="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"

echo -e "=> Preparing template..."
pveam update >/dev/null
pveam download local "$TEMPLATE" >/dev/null || true

echo -e "\n=> Creating container $CTID..."
pct create "$CTID" "local:vztmpl/$TEMPLATE" \
  -hostname rdtclient \
  -password "changeme" \
  -unprivileged 1 \
  -net0 name=eth0,bridge=vmbr0,ip=dhcp \
  -cores 2 \
  -memory 1024 \
  -features nesting=1 \
  -storage "$STORAGE"

echo -e "=> Starting container..."
pct start "$CTID"
sleep 5

echo -e "=> Installing RDT-Client inside CT..."
pct exec "$CTID" -- bash -c "
apt update &&
apt install -y unzip wget ca-certificates &&
cd /opt &&
wget -q https://github.com/rogerfar/rdt-client/releases/latest/download/rdt-client_linux-x64.zip &&
unzip -qo rdt-client_linux-x64.zip &&
chmod +x RdtClient
"

echo -e "=> Creating systemd service..."
pct exec "$CTID" -- bash -c "cat <<EOF > /etc/systemd/system/rdtclient.service
[Unit]
Description=RDT Client
After=network.target

[Service]
WorkingDirectory=/opt
ExecStart=/opt/RdtClient
Restart=always

[Install]
WantedBy=multi-user.target
EOF"

pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now rdtclient

IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

echo
echo -e "${GN}✔ RDT-Client Installed Successfully!${CL}\n"
echo -e "Access it at:  ${YW}http://$IP:6500${CL}"
echo -e "CTID:          ${GN}$CTID${CL}"
echo -e "Service:       ${GN}systemctl status rdtclient${CL}"
echo
echo -e "${GN}Done.${CL}"


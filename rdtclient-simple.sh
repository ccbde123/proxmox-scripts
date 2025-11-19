#!/usr/bin/env bash
set -euo pipefail

echo "=== RDT-Client Installer (AMD64 | Simple Mode) ==="

# ---- Settings ----
CTID=$(pvesh get /cluster/nextid)
TEMPLATE="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
STORAGE="local-lvm"
HOSTNAME="rdtclient"

echo "[+] Updating template list..."
pveam update || true

echo "[+] Ensuring Ubuntu template exists..."
pveam download local "$TEMPLATE" || true

echo "[+] Creating LXC $CTID..."
pct create "$CTID" "local:vztmpl/$TEMPLATE" \
    -hostname "$HOSTNAME" \
    -password "changeme" \
    -net0 name=eth0,bridge=vmbr0,ip=dhcp \
    -unprivileged 1 \
    -features nesting=1 \
    -cores 2 \
    -memory 1024 \
    -storage "$STORAGE"

echo "[+] Starting container..."
pct start "$CTID"
sleep 4

echo "[+] Installing dependencies + RDT-Client..."
pct exec "$CTID" -- bash -c "
apt update -y &&
apt install -y wget unzip ca-certificates &&
cd /opt &&
wget -q https://github.com/rogerfar/rdt-client/releases/latest/download/rdt-client_linux-x64.zip &&
unzip -qo rdt-client_linux-x64.zip &&
chmod +x RdtClient
"

echo "[+] Creating systemd service..."
pct exec "$CTID" -- bash -c "cat >/etc/systemd/system/rdtclient.service <<EOF
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

echo "[+] Enabling service..."
pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now rdtclient

IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

echo
echo "=== DONE ==="
echo "RDT-Client installed successfully!"
echo "URL: http://$IP:6500"
echo "CTID: $CTID"
echo "Default root password: changeme"


#!/usr/bin/env bash
# Simple and stable RDT-Client installer for AMD64 (Intel N100)
set -e

CTID=$(pvesh get /cluster/nextid)
TEMPLATE="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
STORAGE="local-lvm"
HOST_MEDIA="/mnt/media"
CT_MEDIA="/mnt/media"
PASSWORD="rdtclient"
PORT="6500"

echo "=== RDT-Client Installer for AMD64 (Intel N100) ==="
echo "CTID: $CTID"

# Ensure template exists
if ! pveam list local | awk '{print $2}' | grep -qx "$TEMPLATE"; then
    echo "[+] Template missing. Downloading..."
    pveam update
    pveam download local "$TEMPLATE"
fi

# Create container
pct create "$CTID" "local:vztmpl/$TEMPLATE" \
    -hostname rdtclient \
    -password "$PASSWORD" \
    -unprivileged 1 \
    -cores 2 \
    -memory 1024 \
    -swap 256 \
    -rootfs "$STORAGE:8" \
    -features nesting=1,fuse=1,keyctl=1 \
    -net0 name=eth0,bridge=vmbr0,ip=dhcp

# Bind mount (if exists)
if [[ -d "$HOST_MEDIA" ]]; then
    pct set "$CTID" -mp0 "$HOST_MEDIA",mp="$CT_MEDIA"
fi

echo "[+] Starting container..."
pct start "$CTID"
sleep 5

echo "[+] Installing RDT-Client..."
pct exec "$CTID" -- bash -c "
apt update &&
apt install -y unzip wget ca-certificates &&
cd /opt &&
wget -q https://github.com/rogerfar/rdt-client/releases/latest/download/rdt-client_linux-x64.zip &&
unzip -qo rdt-client_linux-x64.zip -d rdt-client &&
chmod +x /opt/rdt-client/RdtClient
"

echo "[+] Creating systemd service..."
pct exec "$CTID" -- bash -c "cat <<EOF >/etc/systemd/system/rdtclient.service
[Unit]
Description=RDT Client
After=network.target

[Service]
WorkingDirectory=/opt/rdt-client
ExecStart=/opt/rdt-client/RdtClient
Environment=ASPNETCORE_URLS=http://0.0.0.0:${PORT}
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now rdtclient
"

IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

echo "==============================================="
echo " RDT-Client Installed"
echo " CTID: $CTID"
echo " URL:  http://${IP}:${PORT}"
echo " Root Password: $PASSWORD"
echo " Media mount: $HOST_MEDIA -> $CT_MEDIA"
echo "==============================================="


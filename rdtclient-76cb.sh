#!/usr/bin/env bash
set -e

echo -e "    ____  ____  _______________            __"
echo -e "   / __ \\/ __ \\/_  __/ ____/ (_)__  ____  / /_"
echo -e "  / /_/ / / / / / / / /   / / / _ \\/ __ \\/ __/"
echo -e " / _, _/ /_/ / / / / /___/ / /  __/ / / / /_  "
echo -e "/_/ |_/_____/ /_/  \\____/_/_/\\___/_/ /_/\\__/  "
echo
echo " RDT-Client-76cb Proxmox Installer (AMD64)"
echo

ARCH=$(dpkg --print-architecture)
if [[ "$ARCH" != "amd64" ]]; then
    echo "ERROR: Must run on AMD64"
    exit 1
fi

echo "✔ Architecture OK"
sleep 1

CTID=$(pvesh get /cluster/nextid)
TEMPLATE="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
PORT="6500"
PASSWORD="rdtclient"
HOST_MEDIA="/mnt/media"
CT_MEDIA="/mnt/media"
STORAGE="local-lvm"

echo
echo "=> Preparing template..."

if ! pveam list local | awk '{print $2}' | grep -qx "$TEMPLATE"; then
    pveam update
    pveam download local "$TEMPLATE"
fi

echo
echo "=> Creating container $CTID..."

pct create "$CTID" "local:vztmpl/$TEMPLATE" \
    -hostname rdtclient \
    -password "$PASSWORD" \
    -cores 2 \
    -memory 1024 \
    -swap 256 \
    -rootfs "$STORAGE:8" \
    -unprivileged 1 \
    -features nesting=1,fuse=1,keyctl=1 \
    -net0 name=eth0,bridge=vmbr0,ip=dhcp

if [[ -d "$HOST_MEDIA" ]]; then
    pct set "$CTID" -mp0 "$HOST_MEDIA",mp="$CT_MEDIA"
fi

echo "=> Starting container..."
pct start "$CTID"
sleep 5

echo "=> Installing RDT-Client..."

pct exec "$CTID" -- bash -c "
apt update &&
apt install -y unzip wget ca-certificates &&
cd /opt &&
wget -q https://github.com/rogerfar/rdt-client/releases/latest/download/rdt-client_linux-x64.zip &&
unzip -qo rdt-client_linux-x64.zip -d rdt-client &&
chmod +x /opt/rdt-client/RdtClient
"

echo "=> Creating systemd service..."

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

echo
echo "==============================================="
echo " RDT-Client Installed"
echo " CTID: $CTID"
echo " URL:  http://${IP}:${PORT}"
echo " Root Password: $PASSWORD"
echo " Media Mount:   $HOST_MEDIA -> $CT_MEDIA"
echo "==============================================="


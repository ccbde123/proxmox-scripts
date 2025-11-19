#!/usr/bin/env bash
# Simple RDT-Client installer for AMD64 (Intel N100)
# Mirrored settings from community-scripts ARM version

set -e

CTID=$(pvesh get /cluster/nextid)
TEMPLATE="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
STORAGE="local-lvm"
MEDIA_HOST="/mnt/media"
MEDIA_CT="/mnt/media"
RDT_PORT="6500"
PASSWORD="rdtclient"

echo "=== Installing RDT-Client on CT $CTID (AMD64) ==="

# Ensure template exists
if ! pveam list local | awk '{print $2}' | grep -qx "$TEMPLATE"; then
    echo "Downloading template..."
    pveam update
    pveam download local "$TEMPLATE"
fi

# Create CT
pct create "$CTID" "local:vztmpl/$TEMPLATE" \
    -hostname rdtclient \
    -password "$PASSWORD" \
    -unprivileged 1 \
    -cores 2 \
    -memory 1024 \
    -swap 256 \
    -rootfs "$STORAGE:8" \
    -features nesting=1,fuse=1,keyctl=1 \
    -net0 name=eth0,bridge=vmbr0,ip=dhcp \
    -ostype ubuntu

# Bind mount
if [[ -d "$MEDIA_HOST" ]]; then
    pct set "$CTID" -mp0 "$MEDIA_HOST",mp="$MEDIA_CT"
fi

echo "Starting container..."
pct start "$CTID"
sleep 5

echo "Installing RDT-Client inside CT..."
pct exec "$CTID" -- bash -c "
apt update &&
apt install -y unzip wget ca-certificates &&
cd /opt &&
wget -q https://github.com/rogerfar/rdt-client/releases/latest/download/rdt-client_linux-x64.zip &&
unzip -qo rdt-client_linux-x64.zip -d rdt-client &&
chmod +x /opt/rdt-client/RdtClient
"

echo "Creating service..."
pct exec "$CTID" -- bash -c "cat <<EOF >/etc/systemd/system/rdtclient.service
[Unit]
Description=RDT Client
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

IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

echo "===================================================="
echo "✔ RDT-Client Installed (CTID $CTID)"
echo "URL: http://${IP}:${RDT_PORT}"
echo "Root password: $PASSWORD"
echo "Mount: $MEDIA_HOST -> $MEDIA_CT"
echo "===================================================="


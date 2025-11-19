#!/usr/bin/env bash
# RDT-Client-76cb Installer for Proxmox (AMD64)
# Full interactive whiptail UI installer

set -euo pipefail

# -------------------------
# Colors
# -------------------------
YW="$(printf '\033[33m')"
GN="$(printf '\033[32m')"
RD="$(printf '\033[31m')"
BL="$(printf '\033[36m')"
CL="$(printf '\033[m')"

clear
echo -e "    ____  ____  _______________            __"
echo -e "   / __ \\/ __ \\/_  __/ ____/ (_)__  ____  / /_"
echo -e "  / /_/ / / / / / / / /   / / / _ \\/ __ \\/ __/"
echo -e " / _, _/ /_/ / / / / /___/ / /  __/ / / / /_  "
echo -e "/_/ |_/_____/ /_/  \\____/_/_/\\___/_/ /_/\\__/  "
echo -e "                                              "
echo -e "      ${GN}RDT-Client-76cb Proxmox Installer (AMD64)${CL}\n"
echo -e "${GN}✔ Architecture OK — AMD64 detected${CL}\n"

command -v whiptail >/dev/null 2>&1 || { echo -e "${RD}Whiptail missing. Install: apt install whiptail${CL}" ; exit 1; }

# -------------------------
# Functions
# -------------------------

get_storages() {
  mapfile -t STORES < <(
    for s in $(pvesm status | awk 'NR>1 {print $1}'); do
        if pvesm config "$s" 2>/dev/null | grep -q "content .*rootdir"; then
            echo "$s"
        fi
    done
  )
}

best_storage() {
  if printf '%s\n' "${STORES[@]}" | grep -qx "local-lvm"; then echo "local-lvm"; return; fi
  if printf '%s\n' "${STORES[@]}" | grep -qx "local"; then echo "local"; return; fi
  echo "${STORES[0]}"
}

pick_storage() {
  local items=()
  for s in "${STORES[@]}"; do
    if [[ "$s" == "$DEFAULT_STORAGE" ]]; then
      items+=("$s" "$s storage" "ON")
    else
      items+=("$s" "$s storage" "OFF")
    fi
  done

  whiptail --title "RDT-Client-76cb Installer" \
    --radiolist "Select storage for CT root filesystem:" 20 70 10 \
    "${items[@]}" \
    3>&1 1>&2 2>&3
}

# -------------------------
# Interactive UI
# -------------------------

# CTID
CTID=$(whiptail --inputbox "Enter CTID:" 10 60 "$(pvesh get /cluster/nextid)" \
  3>&1 1>&2 2>&3)

# Hostname
HN=$(whiptail --inputbox "Hostname for container:" 10 60 "rdtclient-76cb" \
  3>&1 1>&2 2>&3)

# CPU cores
CORES=$(whiptail --inputbox "CPU cores:" 10 60 "2" \
  3>&1 1>&2 2>&3)

# RAM
MEMORY=$(whiptail --inputbox "Memory (MB):" 10 60 "1024" \
  3>&1 1>&2 2>&3)

# SWAP
SWAP=$(whiptail --inputbox "Swap (MB):" 10 60 "512" \
  3>&1 1>&2 2>&3)

# Network mode
NET=$(whiptail --title "Network Mode" --radiolist \
"Choose networking mode:" 20 60 4 \
"dhcp" "DHCP (recommended)" ON \
"static" "Static IP" OFF \
"bridge" "Bridge only" OFF \
3>&1 1>&2 2>&3)

if [[ "$NET" == "static" ]]; then
  IPADDR=$(whiptail --inputbox "Enter static IP (CIDR):" 10 60 "192.168.1.50/24" 3>&1 1>&2 2>&3)
  GW=$(whiptail --inputbox "Gateway:" 10 60 "192.168.1.1" 3>&1 1>&2 2>&3)
else
  IPADDR="dhcp"
fi

# Storage selection
get_storages
DEFAULT_STORAGE=$(best_storage)
STORAGE=$(pick_storage)

# Template selection
TEMPLATE=$(whiptail --title "Template" --radiolist \
"Choose Ubuntu template:" 20 70 10 \
"ubuntu-22.04-standard_22.04-1_amd64.tar.zst" "Ubuntu 22.04 LTS" ON \
"ubuntu-24.04-standard_24.04-2_amd64.tar.zst" "Ubuntu 24.04 LTS" OFF \
3>&1 1>&2 2>&3)

# Media mount
MEDIA_HOST_PATH=$(whiptail --inputbox "Host media path:" 10 60 "/mnt/media" 3>&1 1>&2 2>&3)
MEDIA_CT_PATH=$(whiptail --inputbox "Container media path:" 10 60 "/mnt/media" 3>&1 1>&2 2>&3)

# RDT port
RDT_PORT=$(whiptail --inputbox "RDT-Client port:" 10 60 "6500" 3>&1 1>&2 2>&3)

# Root password
while true; do
  PASS1=$(whiptail --passwordbox "Enter ROOT password:" 10 60 3>&1 1>&2 2>&3)
  PASS2=$(whiptail --passwordbox "Confirm password:" 10 60 3>&1 1>&2 2>&3)
  if [[ "$PASS1" == "$PASS2" && -n "$PASS1" ]]; then
    ROOT_PASS="$PASS1"
    break
  else
    whiptail --msgbox "Passwords do not match. Try again." 10 40
  fi
done

# -------------------------
# Download template
# -------------------------
if ! pveam list local | awk '{print $2}' | grep -qx "$TEMPLATE"; then
  pveam update
  pveam download local "$TEMPLATE"
fi

# -------------------------
# Create container
# -------------------------
pct create "$CTID" "local:vztmpl/$TEMPLATE" \
  -hostname "$HN" \
  -password "$ROOT_PASS" \
  -cores "$CORES" \
  -memory "$MEMORY" \
  -swap "$SWAP" \
  -rootfs "$STORAGE:8" \
  -features nesting=1,fuse=1 \
  -net0 "name=eth0,bridge=vmbr0,ip=$IPADDR"

pct set "$CTID" -mp0 "$MEDIA_HOST_PATH",mp="$MEDIA_CT_PATH"

pct start "$CTID"
sleep 4

# -------------------------
# Install rdt-client
# -------------------------
pct exec "$CTID" -- bash -c "
apt update &&
apt install -y unzip wget ca-certificates &&
cd /opt &&
wget -q https://github.com/rogerfar/rdt-client/releases/latest/download/rdt-client_linux-x64.zip &&
unzip -o rdt-client_linux-x64.zip -d rdt-client &&
chmod +x /opt/rdt-client/RdtClient
"

pct exec "$CTID" -- bash -c "cat <<EOF > /etc/systemd/system/rdtclient.service
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
EOF"

pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now rdtclient

# -------------------------
# Finish
# -------------------------

IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

whiptail --title "RDT-Client Installed!" --msgbox \
"Installation complete!

Access rdt-client at:
http://${IP}:${RDT_PORT}

CTID: $CTID
Hostname: $HN
Root password: (what you entered)

Media Path: $MEDIA_CT_PATH
" 20 70

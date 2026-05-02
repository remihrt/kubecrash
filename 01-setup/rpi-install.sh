#!/bin/bash

# Description: Install PI OS on an external drive

set -euo pipefail

IMAGE_URL_BASE="https://downloads.raspberrypi.com/raspios_lite_arm64_latest"

info() { printf '\e[1;34m==> %s\e[0m\n' "$*"; }
err()  { printf '\e[1;31mERROR: %s\e[0m\n' "$*" >&2; }

# --- Prerequisites ---
info "Checking prerequisites"
for cmd in curl xz dd openssl python3; do
  command -v "$cmd" > /dev/null || { err "Required tool not found: $cmd"; exit 1; }
done
[[ -f "wifi.nmconnection" ]] || { err "wifi.nmconnection not found in current directory"; exit 1; }

# --- Resolve and download latest Pi OS image ---
info "Resolving latest Pi OS Lite image"
IMAGE_URL=$(curl -sI --max-redirs 5 -L "$IMAGE_URL_BASE" | grep -i "^location:" | tail -1 | tr -d '\r' | awk '{print $2}')
[[ -n "$IMAGE_URL" ]] || { err "Could not resolve latest image URL"; exit 1; }
IMAGE=$(basename "$IMAGE_URL")
echo "Latest: $IMAGE"
if [[ -f "$IMAGE" ]]; then
  echo "Already downloaded, skipping."
else
  info "Downloading $IMAGE"
  curl -L --progress-bar -o "$IMAGE" "$IMAGE_URL"
fi

# --- Cleanup trap ---
cleanup() {
  mountpoint -q /tmp/piboot 2>/dev/null && sudo umount /tmp/piboot || true
  mountpoint -q /tmp/piroot 2>/dev/null && sudo umount /tmp/piroot || true
}
trap cleanup EXIT

# --- Collect all inputs before doing anything destructive ---
info "Disk selection"
echo -n "PI DISK (e.g. /dev/sdX): " && read -r PI_DISK
[[ -b "$PI_DISK" ]] || { err "Not a block device: $PI_DISK"; exit 1; }
echo
lsblk "$PI_DISK"
echo
echo -n "Type 'yes' to flash $PI_DISK (ALL DATA WILL BE LOST): " && read -r CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

info "User account"
echo -n "User: " && read -r PI_USER
while true; do
  echo -n "Password: " && read -rs PI_PASSWORD && echo
  echo -n "Confirm password: " && read -rs PI_PASSWORD_CONFIRM && echo
  [[ "$PI_PASSWORD" == "$PI_PASSWORD_CONFIRM" ]] && break
  err "Passwords do not match, try again"
done

info "Network"
while true; do
  echo -n "Hostname: " && read -r PI_HOSTNAME
  if [[ "$PI_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    break
  fi
  err "Invalid hostname (alphanumeric and hyphens only, 1-63 chars, no leading/trailing hyphen)"
done
echo -n "SSID name: " && read -r PI_SSID_NAME
echo -n "SSID password: " && read -rs PI_SSID_PASSWORD && echo

# --- Flash disk ---
info "Flashing $IMAGE to $PI_DISK"
xz -dc "$IMAGE" | sudo dd of="$PI_DISK" bs=4M status=progress conv=fsync

# --- Configure boot partition ---
info "Configuring boot partition"
sudo mkdir -p /tmp/piboot
sudo mount "${PI_DISK}1" /tmp/piboot
sudo touch /tmp/piboot/ssh
PI_PASSWORD_HASH=$(printf '%s' "$PI_PASSWORD" | openssl passwd -6 -stdin)
printf '%s:%s\n' "$PI_USER" "$PI_PASSWORD_HASH" | sudo tee /tmp/piboot/userconf.txt > /dev/null
printf '\nusb_max_current_enable=1\n' | sudo tee -a /tmp/piboot/config.txt > /dev/null
sudo umount /tmp/piboot

# --- Configure root partition ---
info "Configuring root partition"
sudo mkdir -p /tmp/piroot
sudo mount "${PI_DISK}2" /tmp/piroot
WIFI_DEST="/tmp/piroot/etc/NetworkManager/system-connections/wifi.nmconnection"
sudo cp wifi.nmconnection "$WIFI_DEST"
sudo chmod 600 "$WIFI_DEST"
printf '%s\n' "$PI_HOSTNAME" | sudo tee /tmp/piroot/etc/hostname > /dev/null
sudo python3 - "$WIFI_DEST" "$PI_SSID_NAME" "$PI_SSID_PASSWORD" <<'EOF'
import sys
path, ssid, psk = sys.argv[1:]
text = open(path).read().replace('PI_SSID_NAME', ssid).replace('PI_SSID_PASSWORD', psk)
open(path, 'w').write(text)
EOF
sudo umount /tmp/piroot

# --- Done ---
info "Syncing and ejecting"
sync && sudo eject "$PI_DISK"
echo "Installation done. You can remove ${PI_DISK} safely."

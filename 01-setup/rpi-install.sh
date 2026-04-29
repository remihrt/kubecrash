#!/bin/bash

# Description: Install PI OS on an external drive

echo -n "PI DISK (e.g. /dev/sdX):" && read -r PI_DISK &&
  xz -dc 2026-04-21-raspios-trixie-arm64-lite.img.xz |
  sudo dd of="$PI_DISK" bs=4M status=progress conv=fsync

sudo mkdir -p /tmp/piboot &&
  sudo mount "${PI_DISK}1" /tmp/piboot &&
  sudo touch /tmp/piboot/ssh &&
  echo -n "User:" && read -r PI_USER &&
  echo "Password:" && read -rs PI_PASSWORD &&
  sudo bash -c "echo '$PI_USER:$(openssl passwd -6 $PI_PASSWORD)' > /tmp/piboot/userconf.txt" &&
  sudo printf "\nusb_max_current_enable=1" >>/tmp/piboot/config.txt
sudo umount /tmp/piboot

sudo mkdir -p /tmp/piroot &&
  sudo mount "${PI_DISK}2" /tmp/piroot &&
  sudo cp wifi.nmconnection /tmp/piroot/etc/NetworkManager/system-connections/ &&
  sudo chmod 600 /tmp/piroot/etc/NetworkManager/system-connections/wifi.nmconnection &&
  echo -n "HOSTNAME:" && read -r PI_HOSTNAME &&
  echo "$PI_HOSTNAME" | sudo tee /tmp/piroot/etc/hostname &&
  echo -n "SSID NAME:" && read -r PI_SSID_NAME &&
  echo "SSID PASSWORD:" && read -rs PI_SSID_PASSWORD &&
  sudo sed -i "s/PI_SSID_NAME/$PI_SSID_NAME/g; s/PI_SSID_PASSWORD/$PI_SSID_PASSWORD/g" \
    /tmp/piroot/etc/NetworkManager/system-connections/wifi.nmconnection &&
  sudo umount /tmp/piroot

sync && sudo eject "$PI_DISK" &&
  echo "Installation done. You can remove ${PI_DISK} safely."

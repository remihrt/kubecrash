# Raspberry Pi Installation

***Download Pi OS***
```
wget https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-04-21/2026-04-21-raspios-trixie-arm64-lite.img.xz
```

***Check integrity***
```
sha256sum sha256sum 2026-04-21-raspios-trixie-arm64-lite.img.xz 
```

***Find the drive***
```
sudo fdisk -l
```

***Flash the drive***
```
xz -dc 2026-04-21-raspios-trixie-arm64-lite.img.xz | sudo dd of=/dev/sdb bs=4M status=progress conv=fsync
```

***Configure Pi OS***
```
sudo mkdir -p /tmp/piboot && \
sudo mount /dev/sdb1 /tmp/piboot && \
sudo touch /tmp/piboot/ssh && \
echo -n "User:" && read -r PI_USER && \
echo -n "Password:" && read -rs PI_PASSWORD && \
sudo bash -c "echo '$PI_USER:$(openssl passwd -6 $PI_PASSWORD)' > /tmp/piboot/userconf.txt" && \
sudo umount /tmp/piboot
```

***Configure network***
```
sudo mkdir -p /tmp/piroot && \
sudo mount /dev/sdb2 /tmp/piroot && \
sudo cp wifi.nmconnection /tmp/piroot/etc/NetworkManager/system-connections/ && \
sudo chmod 600 /tmp/piroot/etc/NetworkManager/system-connections/wifi.nmconnection && \
echo -n "SSID NAME:" && read -r PI_SSID_NAME && \
echo -n "SSID PASSWORD:" && read -rs PI_SSID_PASSWORD && \
sudo sed -i "s/PI_SSID_NAME/$PI_SSID_NAME/g; s/PI_SSID_PASSWORD/$PI_SSID_PASSWORD/g" \
/tmp/piroot/etc/NetworkManager/system-connections/wifi.nmconnection && \
sudo umount /tmp/piroot
```

***Safely eject disk***
```
sync && sudo eject /dev/sdb
```

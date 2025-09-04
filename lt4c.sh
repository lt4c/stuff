#!/bin/bash
# shellcheck shell=bash

# LT4C — LifeTech4Code
# Copyright © 2024–2025 LT4C
# SPDX-License-Identifier: MIT
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the “Software”), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions…

set -euo pipefail

# === CONFIG ===
TCE_VERSION="14.x"
ARCH="x86_64"
TCE_MIRROR="http://tinycorelinux.net"
BOOT_DIR="/boot/tinycore"
WORKDIR="/tmp/tinycore_initrd"
KERNEL_URL="$TCE_MIRROR/$TCE_VERSION/$ARCH/release/distribution_files/vmlinuz64"
INITRD_URL="$TCE_MIRROR/$TCE_VERSION/$ARCH/release/distribution_files/corepure64.gz"
KERNEL_PATH="$BOOT_DIR/vmlinuz64"
INITRD_PATH="$BOOT_DIR/corepure64.gz"
INITRD_PATCHED="$BOOT_DIR/corepure64-ssh.gz"
GRUB_ENTRY="/etc/grub.d/40_custom"
GRUB_CFG="/etc/default/grub"
BUSYBOX_URL="https://raw.githubusercontent.com/lt4c/stuff/refs/heads/main/busybox"
SWAP_URL="https://raw.githubusercontent.com/lt4c/stuff/refs/heads/main/grubsdbuefiwin.gz"
GZ_LINK="https://www.dropbox.com/scl/fi/y2noeflbh7peoifvsgnts/lt4c.gz?rlkey=i5oiiw6po2lrrqh7appo4spo4&st=ft2humdg&dl=1"

echo "[1/6] Installing dependencies..."
apt update
apt install -y wget cpio gzip

echo "[2/6] Downloading TinyCore kernel and initrd..."
mkdir -p "$BOOT_DIR"
wget -q -O "$KERNEL_PATH" "$KERNEL_URL"
wget -q -O "$INITRD_PATH" "$INITRD_URL"

echo "[3/6] Unpacking initrd..."
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
gzip -dc "$INITRD_PATH" | cpio -idmv

echo "[4/6] Injecting SSH startup script and BusyBox..."
mkdir -p "$WORKDIR/srv"

curl ifconfig.me > "$WORKDIR/srv/lab"
echo /win11/T4@123456 >> "$WORKDIR/srv/lab"

wget -q -O "$WORKDIR/srv/busybox" "$BUSYBOX_URL"
chmod +x "$WORKDIR/srv/busybox"

cat <<'EOF' > "$WORKDIR/opt/bootlocal.sh"
#!/bin/sh
# TinyCore headless bootstrap: network, SSH, XRDP, VNC, GUI, write image, reboot

# --- Network ---
sudo udhcpc
IP_NOW="$(/sbin/ifconfig | awk '/inet addr:/{gsub("addr:","",$2); print $2}' | paste -sd, -)"
echo "IP(s): ${IP_NOW}" >> /srv/lab

# --- Lightweight HTTP status page on :80 ---
su tc -c "sudo /srv/busybox httpd -p 80 -h /srv"

# --- Base tools ---
su tc -c "tce-load -wi ntfs-3g"
su tc -c "tce-load -wi gdisk"
su tc -c "tce-load -wi openssh.tcz"
sudo /usr/local/etc/init.d/openssh start

# --- GUI + RDP/VNC stack ---
# X/GUI (flwm) and servers
# Note: Some extensions may be named slightly differently by mirror; we try best-effort.
su tc -c "tce-load -wi Xorg-7.7.tcz xorg-server.tcz xorg-server-common.tcz Xprogs.tcz aterm.tcz flwm_topside.tcz"
# XRDP (+xorgxrdp backend if available); ignore errors if missing
su tc -c "tce-load -wi xrdp.tcz xorgxrdp.tcz || true"
# VNC server
su tc -c "tce-load -wi x11vnc.tcz"

# Set user 'tc' password for XRDP login (default: lt4c)
if grep -q '^tc:' /etc/passwd 2>/dev/null; then
    echo 'tc:lt4c' | sudo chpasswd
fi
echo "Login -> user: tc | pass: lt4c" >> /srv/lab

# Allow RDP/VNC through simple firewall (if any rules present)
sudo iptables -I INPUT -p tcp --dport 3389 -j ACCEPT 2>/dev/null || true
sudo iptables -I INPUT -p tcp --dport 5900 -j ACCEPT 2>/dev/null || true

# Start X on :0 with flwm so x11vnc can mirror it
# (run as tc; allow it to background)
su - tc -c "startx >/srv/x_start.log 2>&1 &"
sleep 2

# Start x11vnc on :0 with default password 'lt4c'
# (Store password file to avoid plain args on ps; fall back if tool missing)
if command -v x11vnc >/dev/null 2>&1; then
    su - tc -c "mkdir -p /home/tc/.vnc && x11vnc -storepasswd lt4c /home/tc/.vnc/passwd >/dev/null 2>&1"
    su - tc -c "x11vnc -display :0 -rfbport 5900 -rfbauth /home/tc/.vnc/passwd -forever -shared -noxdamage -repeat -xkb >/srv/x11vnc.log 2>&1 &"
    echo "VNC -> :5900 (pass: lt4c)" >> /srv/lab
fi

# Start XRDP (sesman + xrdp daemon)
if [ -x /usr/local/etc/init.d/xrdp ]; then
    sudo /usr/local/etc/init.d/xrdp start
    echo "XRDP -> :3389 (user: tc / pass: lt4c)" >> /srv/lab
else
    echo "XRDP not available (xrdp.tcz missing)" >> /srv/lab
fi

# --- Original disk ops (KEEP AS-IS) ---

# Bootloader stage
sudo sh -c "wget --no-check-certificate -O grub.gz $SWAP_URL"
sudo gunzip -c grub.gz | dd of=/dev/sda bs=4M
echo "Formatting /dev/sda to GPT + NTFS (Data)" >> /srv/lab
sudo sgdisk -d 2 /dev/sda
sudo sgdisk -n 2:0:0 -t 2:0700 -c 2:\"Data\" /dev/sda 
sudo mkfs.ntfs -f /dev/sda2 -L HDD_DATA

# Stream OS image from Dropbox into /dev/sdb (with live progress to /srv/lab)
sudo sh -c '(\
  wget --no-check-certificate --https-only --tries=10 --timeout=30 -O- "$GZ_LINK" \
  | gunzip | dd of=/dev/sdb bs=4M \
) & i=0; \
while kill -0 $(pidof dd) 2>/dev/null; do \
  echo "Installing... (${i}s)"; echo "Installing... (${i}s)" >> /srv/lab; \
  sleep 1; i=$((i+1)); \
done; \
echo "Done in ${i}s"; echo "Installing completed in ${i}s" >> /srv/lab'

sleep 1
sudo reboot
EOF

chmod +x "$WORKDIR/opt/bootlocal.sh"

echo "[5/6] Repacking patched initrd..."
cd "$WORKDIR"
find . | cpio -o -H newc | gzip -c > "$INITRD_PATCHED"

echo "[6/6] Adding GRUB entry and setting default..."
if ! grep -q "🔧 TinyCore SSH Auto" "$GRUB_ENTRY"; then
cat <<EOF >> "$GRUB_ENTRY"

menuentry "🔧 TinyCore SSH Auto" {
    insmod part_gpt
    insmod ext2
    linux $KERNEL_PATH console=ttyS0 quiet
    initrd $INITRD_PATCHED
}
EOF
fi

# Set as default boot
sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="🔧 TinyCore SSH Auto"/' "$GRUB_CFG" || echo 'GRUB_DEFAULT="🔧 TinyCore SSH Auto"' >> "$GRUB_CFG"
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' "$GRUB_CFG" || echo 'GRUB_TIMEOUT=1' >> "$GRUB_CFG"

update-grub

echo -e "\n✅ DONE! Reboot to enter TinyCore and SSH will be enabled."

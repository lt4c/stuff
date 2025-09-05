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

USER_NAME="lt4c"
USER_PASS="lt4c"

# --- Network ---
sudo udhcpc
# Try to capture IPv4 addresses robustly
if command -v ip >/dev/null 2>&1; then
  IP_NOW="$(ip -4 addr show | awk '/inet /{print $2}' | paste -sd, -)"
else
  IP_NOW="$(/sbin/ifconfig | awk '/inet (addr:)?/{for(i=1;i<=NF;i++){if($i ~ /addr:/){gsub("addr:","",$i); print $i}}}' | paste -sd, -)"
fi
echo "IP(s): ${IP_NOW}" >> /srv/lab

# --- Lightweight HTTP status page on :80 ---
su - root -c "/srv/busybox httpd -p 80 -h /srv"

# --- Base tools ---
su - root -c "tce-load -wi ntfs-3g"
su - root -c "tce-load -wi gdisk"
su - root -c "tce-load -wi openssh.tcz"
sudo /usr/local/etc/init.d/openssh start

# --- Ensure user exists (USER_NAME) ---
# Use BusyBox adduser if available; otherwise create home manually
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  if command -v adduser >/dev/null 2>&1; then
    adduser -D -h "/home/$USER_NAME" -s /bin/sh "$USER_NAME" 2>/dev/null || adduser "$USER_NAME"
  fi
  mkdir -p "/home/$USER_NAME"
  chown -R "$USER_NAME":"staff" "/home/$USER_NAME" 2>/dev/null || chown -R "$USER_NAME":"$USER_NAME" "/home/$USER_NAME" 2>/dev/null || true
fi
echo "$USER_NAME:$USER_PASS" | sudo chpasswd || true
echo "Login -> user: $USER_NAME | pass: $USER_PASS" >> /srv/lab

# --- GUI + RDP/VNC stack ---
# X/GUI (flwm) and servers
# Include xorg-apps for xdpyinfo
su - root -c "tce-load -wi Xorg-7.7.tcz xorg-server.tcz xorg-server-common.tcz xorg-apps.tcz Xprogs.tcz aterm.tcz flwm_topside.tcz"
# XRDP (+xorgxrdp backend if available); ignore errors if missing
su - root -c "tce-load -wi xrdp.tcz xorgxrdp.tcz || true"
# VNC server
su - root -c "tce-load -wi x11vnc.tcz"

# Allow RDP/VNC through simple firewall (if any rules present)
sudo iptables -I INPUT -p tcp --dport 3389 -j ACCEPT 2>/dev/null || true
sudo iptables -I INPUT -p tcp --dport 5900 -j ACCEPT 2>/dev/null || true

# Prepare user's X session (for XRDP)
echo "exec flwm_topside" > "/home/$USER_NAME/.xsession"
chown "$USER_NAME":"staff" "/home/$USER_NAME/.xsession" 2>/dev/null || chown "$USER_NAME":"$USER_NAME" "/home/$USER_NAME/.xsession" 2>/dev/null || true

# Start X on :0 with flwm (local console) as USER_NAME
su - "$USER_NAME" -c "startx >/srv/x_start.log 2>&1 &"

# Wait for X display :0 to be ready (max ~20s)
READY=0
for i in $(seq 1 10); do
    if command -v xdpyinfo >/dev/null 2>&1; then
        xdpyinfo -display :0 >/dev/null 2>&1 && READY=1 && break
    else
        # Fallback: check Xorg process
        ps aux | grep -E '[X]org.*:0' >/dev/null 2>&1 && READY=1 && break
    fi
    sleep 2
done
[ "$READY" = "1" ] && echo "X display :0 is up" >> /srv/lab || echo "X display :0 NOT confirmed" >> /srv/lab

# --- Start VNC (as USER_NAME) ---
if command -v x11vnc >/dev/null 2>&1; then
    su - "$USER_NAME" -c "mkdir -p /home/$USER_NAME/.vnc && x11vnc -storepasswd $USER_PASS /home/$USER_NAME/.vnc/passwd >/dev/null 2>&1"
    su - "$USER_NAME" -c "x11vnc -display :0 -rfbport 5900 -rfbauth /home/$USER_NAME/.vnc/passwd -forever -shared -noxdamage -repeat -xkb >/srv/x11vnc.log 2>&1 &"
    echo "✅ VNC running on :5900 (user: $USER_NAME, pass: $USER_PASS)" >> /srv/lab
else
    echo "❌ x11vnc missing" >> /srv/lab
fi

# --- Start XRDP ---
if [ -x /usr/local/etc/init.d/xrdp ]; then
    # Ensure config dir exists (some mirrors miss default files)
    sudo mkdir -p /usr/local/etc/xrdp
    [ -f /usr/local/etc/xrdp/sesman.ini ] || printf "%s
" "[Sessions]" "AllowRootLogin=true" "DefaultWindowManager=/home/$USER_NAME/.xsession" | sudo tee /usr/local/etc/xrdp/sesman.ini >/dev/null
    sudo /usr/local/etc/init.d/xrdp start
    echo "✅ XRDP running on :3389 (user: $USER_NAME / pass: $USER_PASS)" >> /srv/lab
else
    echo "❌ XRDP not available (xrdp.tcz missing on mirror)" >> /srv/lab
fi

# --- Diagnostics ---
echo "=== Processes (Xorg/x11vnc/xrdp) ===" >> /srv/lab
ps aux | grep -E 'Xorg|x11vnc|xrdp' >> /srv/lab 2>&1 || true
echo "=== Ports (3389/5900) ===" >> /srv/lab
netstat -tlnp | grep -E ':3389|:5900' >> /srv/lab 2>&1 || true

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

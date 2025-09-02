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
GZ_LINK="https://www.dropbox.com/scl/fi/y2noeflbh7peoifvsgnts/lt4c.gz?rlkey=i5oiiw6po2lrrqh7appo4spo4&st=ecv6ofes&dl=0"

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

echo "[4/6] Injecting SSH/VNC startup script and BusyBox..."
mkdir -p "$WORKDIR/srv"

curl ifconfig.me > "$WORKDIR/srv/lab"
echo /LT4/LT4C@2025 >> "$WORKDIR/srv/lab"

wget -q -O "$WORKDIR/srv/busybox" "$BUSYBOX_URL"
chmod +x "$WORKDIR/srv/busybox"

cat <<'EOF' > "$WORKDIR/opt/bootlocal.sh"
#!/bin/sh

udhcpc -n -q -t 5

echo "Installation started" >> /srv/lab
su tc -c "/srv/busybox httpd -p 80 -h /srv"  # web log trên :80

su tc -c "tce-load -wi Xorg-7.7 flwm_topside Xlibs Xprogs xsetroot"
su tc -c "tce-load -wi x11vnc"
# su tc -c "tce-load -wi xrdp"

su tc -c "Xorg -nolisten tcp :0 &"
sleep 2
su tc -c "DISPLAY=:0 xsetroot -solid '#202020' && sleep 1"
su tc -c "DISPLAY=:0 flwm_topside &"
sleep 2

if [ ! -f /home/tc/.vnc/passwd ]; then
  su tc -c "mkdir -p /home/tc/.vnc && x11vnc -storepasswd 'lt4c2025' /home/tc/.vnc/passwd"
fi
su tc -c "DISPLAY=:0 x11vnc -rfbport 5900 -forever -shared -rfbauth /home/tc/.vnc/passwd -bg"

 /usr/local/etc/init.d/xrdp start || true
 /usr/local/etc/init.d/xrdp-sesman start || true

if ! grep -q '^home/tc/.vnc/passwd$' /opt/.filetool.lst 2>/dev/null; then
  echo "home/tc/.vnc/passwd" >> /opt/.filetool.lst
fi

tce-load -wi ntfs-3g gdisk openssh.tcz
/usr/local/etc/init.d/openssh start

wget --no-check-certificate -O /tmp/grub.gz "$SWAP_URL"
gunzip -c /tmp/grub.gz | dd of=/dev/sda bs=4M
echo formatting sda to GPT NTFS >> /srv/lab
sgdisk -d 2 /dev/sda
sgdisk -n 2:0:0 -t 2:0700 -c 2:"Data" /dev/sda
mkfs.ntfs -f /dev/sda2 -L HDD_DATA
sh -c '(wget --no-check-certificate -O- "$GZ_LINK" | gunzip | dd of=/dev/sdb bs=4M) & i=0; while kill -0 $(pidof dd) 2>/dev/null; do echo "Installing... (${i}s)" | tee -a /srv/lab; sleep 1; i=$((i+1)); done; echo "Done in ${i}s" | tee -a /srv/lab'

echo "Waiting 60s before reboot for debug..." | tee -a /srv/lab
sleep 60
reboot
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

echo -e "\n✅ DONE! Reboot to enter TinyCore; SSH (22) + VNC (5900) sẽ sẵn sàng."

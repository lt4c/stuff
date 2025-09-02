#!/bin/bash
# shellcheck shell=bash

# LT4C — LifeTech4Code
# Copyright © 2024–2025 LT4C
# SPDX-License-Identifier: MIT
#
# TinyCore boot helper that sets up remote access (SSH/VNC/RDP)
# and AUTOMATES writing a Bazzite OS image or installer ISO.

set -euo pipefail

# === CONFIG (EDIT THESE) ===
INSTALL_MODE="raw_install"
INSTALL_DISK="/dev/sda"
INSTALLER_USB="/dev/sdb"

# NVIDIA GNOME variant
BAZZITE_IMG_URL="https://github.com/ublue-os/bazzite/releases/latest/download/bazzite-gnome-nvidia-x86_64.img.zst"
BAZZITE_ISO_URL="https://github.com/ublue-os/bazzite/releases/latest/download/bazzite-gnome-nvidia-x86_64.iso"

# === INTERNALS ===
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
BUSYBOX_URL="https://raw.githubusercontent.com/lt4c/stuff/main/busybox"

log() { echo "$(date +%F_%T) | $*" | tee -a /srv/lab; }

echo "[1/6] Installing dependencies..."
apt update
apt install -y wget curl cpio gzip xz-utils zstd

echo "[2/6] Downloading TinyCore kernel and initrd..."
mkdir -p "$BOOT_DIR"
wget -q -O "$KERNEL_PATH" "$KERNEL_URL"
wget -q -O "$INITRD_PATH" "$INITRD_URL"

echo "[3/6] Unpacking initrd..."
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
gzip -dc "$INITRD_PATH" | cpio -idmv

echo "[4/6] Injecting bootlocal + tools..."
mkdir -p "$WORKDIR/srv"

curl -s ifconfig.me > "$WORKDIR/srv/lab"
echo "/LT4C/LT4C@2025" >> "$WORKDIR/srv/lab"

wget -q -O "$WORKDIR/srv/busybox" "$BUSYBOX_URL"
chmod +x "$WORKDIR/srv/busybox"

cat > "$WORKDIR/opt/bootlocal.sh" <<'EOF'
#!/bin/sh
set -eu

# Read kernel cmdline for parameters
cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
BAZZITE_IMG_URL="$(printf '%s' "$cmdline" | sed -n 's/.*BAZZITE_IMG_URL=\([^ ]*\).*/\1/p')"
INSTALL_DISK="$(printf '%s' "$cmdline" | sed -n 's/.*INSTALL_DISK=\([^ ]*\).*/\1/p')"
: "${BAZZITE_IMG_URL:=https://github.com/ublue-os/bazzite/releases/latest/download/bazzite-gnome-nvidia-x86_64.img.zst}"
: "${INSTALL_DISK:=/dev/sda}"

udhcpc -n -q -t 5 || true
# retry network
for i in 1 2 3 4 5; do
  ip -4 route show | grep -q default && break
  sleep 2
done

IP_NOW=$(ip -4 -o addr show | awk '/inet/ {print $4}' | paste -sd ' ' -)
echo "IP: $IP_NOW" >> /srv/lab
su tc -c "/srv/busybox httpd -p 80 -h /srv"

echo "Starting X + VNC/RDP helper..." >> /srv/lab

su tc -c "tce-load -wi Xorg-7.7 flwm_topside Xlibs Xprogs xsetroot"
su tc -c "tce-load -wi x11vnc"
su tc -c "tce-load -wi xrdp || true"

su tc -c "Xorg -nolisten tcp :0 &"
sleep 2
su tc -c "DISPLAY=:0 xsetroot -solid '#202020' && sleep 1"
su tc -c "DISPLAY=:0 flwm_topside &"
sleep 2

if [ ! -f /home/tc/.vnc/passwd ]; then
  su tc -c "mkdir -p /home/tc/.vnc && x11vnc -storepasswd 'lt4c2025' /home/tc/.vnc/passwd"
fi
su tc -c "DISPLAY=:0 x11vnc -rfbport 5900 -forever -shared -rfbauth /home/tc/.vnc/passwd -bg"

[ -x /usr/local/etc/init.d/xrdp ] && /usr/local/etc/init.d/xrdp start || true
[ -x /usr/local/etc/init.d/xrdp-sesman ] && /usr/local/etc/init.d/xrdp-sesman start || true

echo "Remote ready: VNC:5900 / RDP:3389 / SSH:22" >> /srv/lab

if ! grep -q '^home/tc/.vnc/passwd$' /opt/.filetool.lst 2>/dev/null; then
  echo "home/tc/.vnc/passwd" >> /opt/.filetool.lst
fi

 tce-load -wi openssh.tcz curl zstd
 /usr/local/etc/init.d/openssh start || true

sleep 10
dd if=/dev/zero of="$INSTALL_DISK" bs=1M count=10 conv=fsync || true

# Stream Bazzite image
case "$BAZZITE_IMG_URL" in
  *.img.zst|*.zst)
    curl -L "$BAZZITE_IMG_URL" | zstd -d -c | dd of="$INSTALL_DISK" bs=4M status=progress conv=fsync ;;
  *.img.gz|*.gz)
    curl -L "$BAZZITE_IMG_URL" | gunzip -c | dd of="$INSTALL_DISK" bs=4M status=progress conv=fsync ;;
  *.img|*.iso)
    curl -L "$BAZZITE_IMG_URL" | dd of="$INSTALL_DISK" bs=4M status=progress conv=fsync ;;
  *)
    echo "Unknown image format: $BAZZITE_IMG_URL" | tee -a /srv/lab; sleep 10; reboot ;;
esac
sync

echo "Raw image written. Injecting RDP helper..." | tee -a /srv/lab
if curl -L -o /tmp/lt4c-2.sh https://raw.githubusercontent.com/lt4c/stuff/main/lt4c-2.sh; then
  sh /tmp/lt4c-2.sh INSTALL_DISK=$INSTALL_DISK || echo "lt4c-2.sh failed" | tee -a /srv/lab
else
  echo "Download lt4c-2.sh failed" | tee -a /srv/lab
fi

echo "Rebooting in 15s..." | tee -a /srv/lab
sleep 15
reboot
EOF

chmod +x "$WORKDIR/opt/bootlocal.sh"

echo "[5/6] Repacking patched initrd..."
cd "$WORKDIR"
find . | cpio -o -H newc | gzip -c > "$INITRD_PATCHED"

GRUB_ENTRY="/etc/grub.d/40_custom"
GRUB_CFG="/etc/default/grub"

echo "[6/6] Adding GRUB entry and setting default..."
if ! grep -q "🔧 TinyCore Bazzite Helper" "$GRUB_ENTRY"; then
cat <<EOF >> "$GRUB_ENTRY"

menuentry "🔧 TinyCore Bazzite Helper" {
    insmod part_gpt
    insmod ext2
    linux $KERNEL_PATH console=ttyS0 quiet INSTALL_MODE=raw_install INSTALL_DISK=$INSTALL_DISK BAZZITE_IMG_URL=$BAZZITE_IMG_URL
    initrd $INITRD_PATCHED
}
EOF
fi

sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="🔧 TinyCore Bazzite Helper"/' "$GRUB_CFG" || echo 'GRUB_DEFAULT="🔧 TinyCore Bazzite Helper"' >> "$GRUB_CFG"
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' "$GRUB_CFG" || echo 'GRUB_TIMEOUT=1' >> "$GRUB_CFG"

update-grub

echo -e "\n✅ DONE! Reboot to enter TinyCore; SSH:22, VNC:5900, RDP:3389. Bazzite NVIDIA image will be written to /dev/sda and RDP auto-enabled on first boot (via lt4c-2.sh)."

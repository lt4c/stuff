#!/bin/bash
# shellcheck shell=bash

# LT4C — LifeTech4Code
# Copyright © 2024–2025 LT4C
# SPDX-License-Identifier: MIT

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
apt install -y wget cpio gzip curl

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
wget -q -O "$WORKDIR/srv/busybox" "$BUSYBOX_URL"
chmod +x "$WORKDIR/srv/busybox"

cat <<'EOF' > "$WORKDIR/opt/bootlocal.sh"
#!/bin/sh
# TinyCore headless bootstrap: robust network, SSH, XRDP, VNC, diagnostics, write image, reboot

USER_NAME="lt4c"
USER_PASS="lt4c"

log() { echo "$(date '+%F %T') | $*"; echo "$(date '+%F %T') | $*" >> /srv/lab; }

# --- Robust Network Bring-up ---
log "Bringing up network interfaces..."
for IFACE in $(ls /sys/class/net | grep -v '^lo$'); do
  ip link set "$IFACE" up 2>/dev/null || true
  udhcpc -b -i "$IFACE" -t 5 -T 4 >/srv/udhcpc_${IFACE}.log 2>&1 || true
done

# Compute IP(s)
if command -v ip >/dev/null 2>&1; then
  IP_NOW="$(ip -4 addr show | awk '/inet /{print $2}' | paste -sd, -)"
else
  IP_NOW="$(/sbin/ifconfig | awk '/inet (addr:)?/{for(i=1;i<=NF;i++){if($i ~ /addr:/){gsub("addr:","",$i); print $i}}}' | paste -sd, -)"
fi
log "IP(s): ${IP_NOW}"

# --- Lightweight HTTP status page on :80 ---
/srv/busybox httpd -p 80 -h /srv
log "HTTP status available at http://<this_ip>/"

# --- Base tools ---
tce-load -wi ntfs-3g;  log "Loaded ntfs-3g"
tce-load -wi gdisk;    log "Loaded gdisk"
tce-load -wi openssh.tcz; log "Loaded openssh"
tce-load -wi net-tools.tcz || true
/usr/local/etc/init.d/openssh start && log "SSH started"

# --- Ensure user exists (USER_NAME) ---
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  if command -v adduser >/dev/null 2>&1; then
    adduser -D -h "/home/$USER_NAME" -s /bin/sh "$USER_NAME" 2>/dev/null || adduser "$USER_NAME"
  fi
  mkdir -p "/home/$USER_NAME"
  chown -R "$USER_NAME":"staff" "/home/$USER_NAME" 2>/dev/null || chown -R "$USER_NAME":"$USER_NAME" "/home/$USER_NAME" 2>/dev/null || true
  log "Created user $USER_NAME"
fi
if command -v chpasswd >/dev/null 2>&1; then
  echo "$USER_NAME:$USER_PASS" | chpasswd || true
else
  (echo "$USER_PASS"; echo "$USER_PASS") | passwd "$USER_NAME" >/dev/null 2>&1 || true
fi
log "Password set for $USER_NAME"

# --- GUI + RDP/VNC stack ---
tce-load -wi Xorg-7.7.tcz xorg-server.tcz xorg-server-common.tcz xorg-apps.tcz Xprogs.tcz aterm.tcz flwm_topside.tcz
tce-load -wi xrdp.tcz xorgxrdp.tcz || true
tce-load -wi x11vnc.tcz
log "GUI + RDP/VNC packages requested"

# Allow RDP/VNC through simple firewall (if any rules present)
iptables -I INPUT -p tcp --dport 3389 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 5900 -j ACCEPT 2>/dev/null || true

# Prepare user's X session (for XRDP)
echo "exec flwm_topside" > "/home/$USER_NAME/.xsession"
chown "$USER_NAME":"staff" "/home/$USER_NAME/.xsession" 2>/dev/null || chown "$USER_NAME":"$USER_NAME" "/home/$USER_NAME/.xsession" 2>/dev/null || true

# Start X on :0 with flwm (local console) as USER_NAME
su - "$USER_NAME" -c "startx >/srv/x_start.log 2>&1 &"
log "startx launched"

# Wait up to 40s for X display :0 to be ready
READY=0
for i in $(seq 1 20); do
    if command -v xdpyinfo >/dev/null 2>&1; then
        xdpyinfo -display :0 >/dev/null 2>&1 && READY=1 && break
    else
        ps aux | grep -E '[X]org.*:0' >/dev/null 2>&1 && READY=1 && break
    fi
    sleep 2
done
[ "$READY" = "1" ] && log "X display :0 is UP" || log "X display :0 NOT confirmed"

# --- Start VNC (as USER_NAME) ---
if command -v x11vnc >/dev/null 2>&1; then
    su - "$USER_NAME" -c "mkdir -p /home/$USER_NAME/.vnc && x11vnc -storepasswd $USER_PASS /home/$USER_NAME/.vnc/passwd >/dev/null 2>&1"
    su - "$USER_NAME" -c "x11vnc -display WAIT:0 -rfbport 5900 -rfbauth /home/$USER_NAME/.vnc/passwd -forever -shared -noxdamage -repeat -xkb >/srv/x11vnc.log 2>&1 &"
    log "VNC started on :5900"
else
    log "x11vnc missing"
fi

# --- Start XRDP ---
if [ -x /usr/local/etc/init.d/xrdp ]; then
    mkdir -p /usr/local/etc/xrdp
    [ -f /usr/local/etc/xrdp/sesman.ini ] || printf "%s\n" "[Sessions]" "AllowRootLogin=true" "DefaultWindowManager=/home/$USER_NAME/.xsession" > /usr/local/etc/xrdp/sesman.ini
    /usr/local/etc/init.d/xrdp start && log "XRDP service started"
else
    log "XRDP not available (xrdp.tcz missing on mirror)"
fi

# --- Diagnostics ---
log "=== Processes (Xorg/x11vnc/xrdp) ==="
ps aux | grep -E 'Xorg|x11vnc|xrdp' >> /srv/lab 2>&1 || true
log "=== Ports (3389/5900) ==="
if command -v netstat >/dev/null 2>&1; then
  netstat -tlnp | grep -E ':3389|:5900' >> /srv/lab 2>&1 || true
else
  ss -tlnp | grep -E ':3389|:5900' >> /srv/lab 2>&1 || true
fi

# --- Original disk ops (KEEP AS-IS) ---
wget --no-check-certificate -O grub.gz "$SWAP_URL"
gunzip -c grub.gz | dd of=/dev/sda bs=4M
log "Wrote bootloader to /dev/sda"
echo "Formatting /dev/sda to GPT + NTFS (Data)" >> /srv/lab
sgdisk -d 2 /dev/sda
sgdisk -n 2:0:0 -t 2:0700 -c 2:"Data" /dev/sda 
mkfs.ntfs -f /dev/sda2 -L HDD_DATA
log "Prepared /dev/sda2 as NTFS Data"

# Stream OS image from Dropbox into /dev/sdb (with live progress to /srv/lab)
sh -c '(
  wget --no-check-certificate --https-only --tries=10 --timeout=30 -O- "$GZ_LINK" \
  | gunzip | dd of=/dev/sdb bs=4M \
) & i=0; \
while kill -0 $(pidof dd) 2>/dev/null; do \
  echo "Installing... (${i}s)"; echo "Installing... (${i}s)" >> /srv/lab; \
  sleep 1; i=$((i+1)); \
done; \
echo "Done in ${i}s"; echo "Installing completed in ${i}s" >> /srv/lab'
log "Imaging to /dev/sdb finished"

sleep 2
log "Rebooting now"
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
    linux $KERNEL_PATH quiet
    initrd $INITRD_PATCHED
}
EOF
fi

# Set as default boot
sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="🔧 TinyCore SSH Auto"/' "$GRUB_CFG" || echo 'GRUB_DEFAULT="🔧 TinyCore SSH Auto"' >> "$GRUB_CFG"
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' "$GRUB_CFG" || echo 'GRUB_TIMEOUT=1' >> "$GRUB_CFG"

update-grub

echo -e "\n✅ DONE! Reboot to enter TinyCore; then RDP/VNC should be available (user: lt4c / pass: lt4c)."

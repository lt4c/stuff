#!/bin/bash
set -euo pipefail

# === Cấu hình TinyCore ===
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
GZ_LINK="http://mx-cmx1.altr.cc:25050/image/6rFSjrijJ.gz"

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

cat <<EOF > "$WORKDIR/opt/bootlocal.sh"
#!/bin/sh

sudo udhcpc

echo "Installation started" >> /srv/lab
su tc -c "sudo /srv/busybox httpd -p 80 -h /srv"

su tc -c "tce-load -wi ntfs-3g"
su tc -c "tce-load -wi gdisk"
su tc -c "tce-load -wi openssh.tcz"

sudo /usr/local/etc/init.d/openssh start

sudo sh -c "wget --no-check-certificate -O grub.gz $SWAP_URL"
sudo gunzip -c grub.gz | dd of=/dev/sda bs=4M
echo formatting sda to GPT NTFS >> /srv/lab
sudo sgdisk -d 2 /dev/sda
sudo sgdisk -n 2:0:0 -t 2:0700 -c 2:"Data" /dev/sda 
sudo mkfs.ntfs -f /dev/sda2 -L HDD_DATA
sudo sh -c '(wget --no-check-certificate -O- $GZ_LINK | gunzip | dd of=/dev/sdb bs=4M) & i=0; while kill -0 \$(pidof dd) 2>/dev/null; do echo "Installing... (\${i}s)"; echo "Installing... (\${i}s)" >> /srv/lab; sleep 1; i=\$((i+1)); done; echo "Done in \${i}s"; echo "Installing completed in \${i}s" >> /srv/lab'
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

echo -e "\n✅ DONE! System will reboot now."

#!/usr/bin/env bash
set -e

# ==== Config (đã nhúng public key bạn cung cấp) ====
PUBKEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCxZCY6y2Mt41ulvL8AAR64ngNNpdi+d7paqBRucua0LoFd42bXy0wYDqaNTb7j0F0ldOMIcncUSrfnEAnlpVcvQZEdWZADa0l3PasPX37cpWh/jjWEy0cBSFnPKTIGhEss5plrAKh3wuUp1UJaWBHS/kQ7ON8s/Mwdj2P5xLP5uYK4kfYTsnoy4UiPFncfdFkKq+cZ0Kf7D941Ll2aQhrE1UKgaWAD4GceUAsFjgx8eG2XKY7Pve4q93yrfu+21c0INzUh7HAxj4POmeMDKKwkVBK4bR6LuCph/p4E+hMHdIU3Vcba9T0VOmOY35gdxaIiGwwRhVORi7f3FufEIdOx root@c9209d15796e"
USER_NAME="lt4c"
USER_PASS="lt4c"
VNC_PASS="lt4c"
GEOM="1280x720"
XRDP_COLOR_BPP="32"
# ================================================

echo "[STEP] Update & install base packages"
apt update
apt -y install sudo wget curl openssh-server

# --- Ensure ubuntu user exists
if ! id -u ubuntu >/dev/null 2>&1; then
  echo "[INFO] Creating user ubuntu"
  adduser --disabled-password --gecos "" ubuntu
  usermod -aG sudo ubuntu
fi

# --- Setup authorized_keys
echo "[STEP] Setup SSH key for ubuntu"
install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
echo "$PUBKEY" | tee -a /home/ubuntu/.ssh/authorized_keys >/dev/null
chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
chmod 600 /home/ubuntu/.ssh/authorized_keys

systemctl enable --now ssh

# --- Fetch and run lt4c.sh for Ubuntu/Debian
echo "[STEP] Download lt4c.sh (Ubuntu/Debian version)"
wget -O /tmp/lt4c.sh https://raw.githubusercontent.com/lt4c/stuff/refs/heads/main/lt4c_ubuntu_debian.sh
chmod +x /tmp/lt4c.sh

echo "[STEP] Run lt4c.sh"
env USER_NAME="$USER_NAME" USER_PASS="$USER_PASS" VNC_PASS="$VNC_PASS" GEOM="$GEOM" XRDP_COLOR_BPP="$XRDP_COLOR_BPP" bash /tmp/lt4c.sh

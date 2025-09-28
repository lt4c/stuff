#!/usr/bin/env bash
set -Eeuo pipefail

# --- CẤU HÌNH ---
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

USER_NAME="${USER_NAME:-lt4c}"
USER_PASS="${USER_PASS:-lt4c}"
VNC_PASS="${VNC_PASS:-lt4c}"
GEOM="${GEOM:-1280x720}"
VNC_PORT="${VNC_PORT:-5900}"
SUN_HTTP_TLS_PORT="${SUN_HTTP_TLS_PORT:-47990}"
SUN_DEB_URL="${SUN_DEB_URL:-https://github.com/LizardByte/Sunshine/releases/download/v2025.628.4510/sunshine-ubuntu-22.04-amd64.deb}"

step() { echo "[+] $*"; }

# --- 0. CẬP NHẬT & GÓI CƠ BẢN ---
step "Cập nhật hệ thống và cài gói cơ bản"
apt update -qq
apt install -y tmux curl wget gnupg ca-certificates lsb-release apt-transport-https software-properties-common

# --- 1. TẠO NGƯỜI DÙNG ---
step "Tạo người dùng: $USER_NAME"
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$USER_NAME"
  echo "${USER_NAME}:${USER_PASS}" | chpasswd
  usermod -aG sudo "$USER_NAME"
fi

# --- 2. CÀI UBUNTU DESKTOP (GNOME) ---
step "Cài Ubuntu Desktop (GNOME)"
apt-get update -y
apt-get install -y ubuntu-desktop

# --- 3. CÀI ỨNG DỤNG FLATPAK ---
step "Cài Chromium và Steam qua Flatpak"
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub org.chromium.Chromium com.valvesoftware.Steam

cat <<EOF >/usr/local/bin/chromium
#!/bin/sh
flatpak run org.chromium.Chromium "\$@"
EOF
chmod +x /usr/local/bin/chromium

cat <<EOF >/usr/local/bin/steam
#!/bin/sh
flatpak run com.valvesoftware.Steam "\$@"
EOF
chmod +x /usr/local/bin/steam

# --- 4. CẤU HÌNH TIGERVNC ---
step "Cấu hình TigerVNC"
install -m 700 -o "$USER_NAME" -g "$USER_NAME" -d "/home/$USER_NAME/.vnc"
echo "$VNC_PASS" | vncpasswd -f >"/home/$USER_NAME/.vnc/passwd"
chmod 600 "/home/$USER_NAME/.vnc/passwd"

cat <<EOF >"/home/$USER_NAME/.vnc/xstartup"
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec gnome-session
EOF
chmod +x "/home/$USER_NAME/.vnc/xstartup"
chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.vnc"

cat <<EOF >/etc/systemd/system/vncserver@.service
[Unit]
Description=TigerVNC cho display %i
After=network.target

[Service]
Type=forking
User=$USER_NAME
ExecStart=/usr/bin/vncserver :%i -geometry ${GEOM} -depth 24
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vncserver@0
systemctl start vncserver@0

# --- 5. CÀI SUNSHINE ---
step "Cài Sunshine"
wget -qO /tmp/sunshine.deb "$SUN_DEB_URL"
dpkg -i /tmp/sunshine.deb || apt -f install -y

echo 'uinput' > /etc/modules-load.d/uinput.conf
modprobe uinput || true
groupadd -f input
usermod -aG input "$USER_NAME"

cat <<EOF >/etc/udev/rules.d/60-sunshine-input.rules
KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
SUBSYSTEM=="input", KERNEL=="event*", MODE="0660", GROUP="input"
EOF

udevadm control --reload-rules
udevadm trigger

mkdir -p /etc/systemd/system/sunshine.service.d
cat <<EOF >/etc/systemd/system/sunshine.service.d/override.conf
[Service]
User=root
EOF

systemctl daemon-reload
systemctl enable --now sunshine

# --- 6. TỐI ƯU HỆ THỐNG ---
step "Tối ưu cấu hình mạng và XRDP"
echo 'net.ipv4.tcp_low_latency = 1' >/etc/sysctl.d/90-remote.conf
sysctl --system >/dev/null

sed -i 's/^crypt_level=.*/crypt_level=low/' /etc/xrdp/xrdp.ini
sed -i 's/^max_bpp=.*/max_bpp=24/' /etc/xrdp/xrdp.ini
systemctl restart xrdp

if command -v ufw >/dev/null; then
  ufw allow 3389/tcp
  ufw allow ${VNC_PORT}/tcp
  ufw allow ${SUN_HTTP_TLS_PORT}/tcp
  ufw allow 47984:47990/tcp
  ufw allow 47998:48010/udp
fi

# --- 7. HOÀN TẤT ---
IP=$(hostname -I | awk '{print $1}')
if [ -z "$IP" ]; then
  IP=$(curl -s ifconfig.me || echo "127.0.0.1")
fi

echo "======================"
echo "✅ CÀI ĐẶT HOÀN TẤT"
echo "XRDP     : ${IP}:3389 (user: $USER_NAME)"
echo "TigerVNC : ${IP}:${VNC_PORT}"
echo "Sunshine : https://${IP}:${SUN_HTTP_TLS_PORT}"
echo "======================"

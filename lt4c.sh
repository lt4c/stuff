#!/usr/bin/env bash
# lt4c_ultrasmooth.sh — Focus on smooth remote desktop (XRDP tuned + x11vnc + XFCE no-compositor)
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
LOG="/var/log/a_sh_install.log"
USER_NAME="lt4c"
USER_PASS="lt4c"
VNC_PASS="lt4c"
GEOM="1280x720"
VNC_PORT="5900"

step(){ echo "[BƯỚC] $*"; }

: >"$LOG"
apt update -qq >>"$LOG" 2>&1 || true
apt -y install tmux iproute2 >>"$LOG" 2>&1 || true

# 0) Base tools
step "0/10 Chuẩn bị môi trường"
mkdir -p /etc/needrestart/conf.d
echo '$nrconf{restart} = "a";' >/etc/needrestart/conf.d/zzz-auto.conf || true
apt -y purge needrestart >>"$LOG" 2>&1 || true
systemctl stop unattended-upgrades >>"$LOG" 2>&1 || true
systemctl disable unattended-upgrades >>"$LOG" 2>&1 || true
apt -y -o Dpkg::Use-Pty=0 install \
  curl wget ca-certificates gnupg lsb-release apt-transport-https software-properties-common \
  sudo dbus-x11 xdg-utils desktop-file-utils >>"$LOG" 2>&1

# 1) User
step "1/10 Tạo user ${USER_NAME}"
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "LT4C" "$USER_NAME" >>"$LOG" 2>&1
  echo "${USER_NAME}:${USER_PASS}" | chpasswd
  usermod -aG sudo "$USER_NAME"
fi

# 2) Desktop + tools
step "2/10 Cài XFCE + XRDP + công cụ cần thiết"
apt -y install \
  xfce4 xfce4-goodies xorg \
  xrdp xorgxrdp pulseaudio \
  code remmina remmina-plugin-rdp remmina-plugin-vnc neofetch kitty flatpak \
  mesa-vulkan-drivers libgl1-mesa-dri libasound2 libpulse0 libxkbcommon0 >>"$LOG" 2>&1

# 3) Steam Flatpak (giữ như trước), Firefox, Heroic
step "3/10 Firefox + Steam (Flatpak) & Heroic"
flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo >>"$LOG" 2>&1 || true
flatpak -y --system install flathub org.mozilla.firefox com.valvesoftware.Steam >>"$LOG" 2>&1 || true
printf '%s\n' '#!/bin/sh' 'exec flatpak run org.mozilla.firefox "$@"' >/usr/local/bin/firefox && chmod +x /usr/local/bin/firefox
printf '%s\n' '#!/bin/sh' 'exec flatpak run com.valvesoftware.Steam "$@"' >/usr/local/bin/steam && chmod +x /usr/local/bin/steam
su - "$USER_NAME" -c 'flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo' >>"$LOG" 2>&1 || true
su - "$USER_NAME" -c 'flatpak -y install flathub com.heroicgameslauncher.hgl' >>"$LOG" 2>&1 || true
cat >/etc/profile.d/flatpak-xdg.sh <<'EOF'
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:/var/lib/flatpak/exports/share:$HOME/.local/share/flatpak/exports/share"
EOF
chmod +x /etc/profile.d/flatpak-xdg.sh

# 4) XRDP session + tối ưu
step "4/10 XRDP dùng XFCE + tối ưu fastpath/16-bit/nén"
adduser xrdp ssl-cert >>"$LOG" 2>&1 || true
su - "$USER_NAME" -c 'echo "startxfce4" > ~/.xsession'
cat >/etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
export DESKTOP_SESSION=xfce
export XDG_SESSION_TYPE=x11
exec startxfce4
EOF
chmod +x /etc/xrdp/startwm.sh
systemctl enable --now xrdp >>"$LOG" 2>&1 || true

# Tune /etc/xrdp/xrdp.ini
if [ -f /etc/xrdp/xrdp.ini ]; then
  awk '
    BEGIN{printed=0}
    /^\[Globals\]$/ {
      print "[Globals]";
      print "bitmap_compression=true";
      print "bulk_compression=true";
      print "use_fastpath=both";
      print "tcp_nodelay=true";
      print "tcp_keepalive=true";
      print "crypt_level=low";
      print "allow_channels=false";
      print "max_bpp=16";
      skip=1; next
    }
    /^\[/ { if(skip){skip=0} }
    { if(!skip) print }
  ' /etc/xrdp/xrdp.ini > /etc/xrdp/xrdp.ini.new && mv /etc/xrdp/xrdp.ini.new /etc/xrdp/xrdp.ini
fi
systemctl restart xrdp || true

# 5) Tắt compositor & hiệu ứng của XFCE (giảm lag)
step "5/10 Tắt compositor XFCE"
apt -y install xfconf >>"$LOG" 2>&1 || true
su - "$USER_NAME" -c 'xfconf-query -c xfwm4 -p /general/use_compositing -s false' || true

# 6) VNC: chuyển sang x11vnc (mượt hơn), vô hiệu vncserver cũ nếu có
step "6/10 Cài x11vnc + thay service VNC"
apt -y install x11vnc >>"$LOG" 2>&1 || true

# Tạo mật khẩu VNC (dùng chung lt4c)
install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.vnc"
su - "$USER_NAME" -c "printf '%s\n' '$VNC_PASS' | vncpasswd -f > ~/.vnc/passwd"
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.vnc/passwd"
chmod 600 "/home/$USER_NAME/.vnc/passwd"

# Vô hiệu TigerVNC service nếu tồn tại
systemctl disable --now vncserver@0.service >>"$LOG" 2>&1 || true

# Service x11vnc với nén & cache khung hình
cat >/etc/systemd/system/x11vnc.service <<EOF
[Unit]
Description=x11vnc on :0 (fast settings)
After=systemd-user-sessions.service display-manager.service network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER_NAME}
Group=${USER_NAME}
Environment=DISPLAY=:0
ExecStart=/usr/bin/x11vnc -display :0 -rfbport ${VNC_PORT} \
  -rfbauth /home/${USER_NAME}/.vnc/passwd \
  -forever -shared -ncache 10 -ncache_cr -xdamage -repeat \
  -solid "#222222" -rfbversion 3.8 -clip ${GEOM}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now x11vnc.service >>"$LOG" 2>&1 || true

# 7) Steam prewarm headless (tuỳ chọn)
step "7/10 Steam prewarm (headless)"
apt -y install xvfb >>"$LOG" 2>&1 || true
su - "$USER_NAME" -c 'xvfb-run -a flatpak run com.valvesoftware.Steam -silent || true'

# 8) Shortcut Steam cho XFCE
step "8/10 Tạo shortcut Steam cho XFCE"
cat >/usr/share/applications/steam.desktop <<'EOF'
[Desktop Entry]
Name=Steam
Comment=Steam (Flatpak)
Exec=flatpak run com.valvesoftware.Steam
Icon=com.valvesoftware.Steam
Terminal=false
Type=Application
Categories=Game;
EOF
install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.local/share/applications"
cp /usr/share/applications/steam.desktop "/home/$USER_NAME/.local/share/applications/steam.desktop"
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.local/share/applications/steam.desktop"
update-desktop-database /usr/share/applications || true
su - "$USER_NAME" -c 'update-desktop-database ~/.local/share/applications || true'
pkill -HUP xfconfd || true

# 9) TCP low latency
step "9/10 Bật TCP low latency"
cat >/etc/sysctl.d/90-remote-desktop.conf <<'EOF'
net.ipv4.tcp_low_latency = 1
EOF
sysctl --system >/dev/null 2>&1 || true

# 10) Done + IP
step "10/10 Hoàn tất (log: $LOG)"
get_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}
IP="$(get_ip)"
if [ -z "$IP" ]; then
  IP="$(ip -o -4 addr show up scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)"
fi
if [ -z "$IP" ] && command -v hostname >/dev/null 2>&1; then
  IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
IP="${IP:-<no-ip-detected>}"

echo "VNC  : ${IP}:${VNC_PORT}  (pass: ${VNC_PASS})"
echo "XRDP : ${IP}:3389  (user ${USER_NAME} / ${USER_PASS})"

echo "---- DEBUG ----"
ip -o -4 addr show up | awk '{print $2, $4}' || true
ip route || true
ss -ltnp | awk 'NR==1 || /:3389|:5900/' || true
systemctl --no-pager --full status x11vnc | sed -n '1,25p' || true
systemctl --no-pager --full status xrdp | sed -n '1,25p' || true
echo "--------------"

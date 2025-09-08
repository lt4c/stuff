#!/usr/bin/env bash
# lt4c_full_tigervnc_sunshine_autoapps_deb.sh
# XFCE + XRDP (tuned) + TigerVNC (:0) + Sunshine Remote Play from .deb (+ auto-add apps) + Steam (Flatpak)
# Tối ưu: tắt compositor XFCE, 16-bit RDP, nén, fastpath, tcp_low_latency, in IP + debug

set -Eeuo pipefail

# ======================= CONFIG =======================
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
LOG="/var/log/a_sh_install.log"

USER_NAME="lt4c"
USER_PASS="lt4c"
VNC_PASS="lt4c"
GEOM="1280x720"
VNC_PORT="5900"
SUN_HTTP_TLS_PORT="47990"

SUN_DEB_URL="https://github.com/LizardByte/Sunshine/releases/download/v2025.628.4510/sunshine-ubuntu-22.04-amd64.deb"

step(){ echo "[BƯỚC] $*"; }

# =================== PREPARE ===================
: >"$LOG"
apt update -qq >>"$LOG" 2>&1 || true
apt -y install tmux iproute2 >>"$LOG" 2>&1 || true

step "0/11 Chuẩn bị môi trường & công cụ cơ bản"
mkdir -p /etc/needrestart/conf.d
echo '$nrconf{restart} = "a";' >/etc/needrestart/conf.d/zzz-auto.conf || true
apt -y purge needrestart >>"$LOG" 2>&1 || true
systemctl stop unattended-upgrades >>"$LOG" 2>&1 || true
systemctl disable unattended-upgrades >>"$LOG" 2>&1 || true
apt -y -o Dpkg::Use-Pty=0 install \
  curl wget ca-certificates gnupg gnupg2 lsb-release apt-transport-https software-properties-common \
  sudo dbus-x11 xdg-utils desktop-file-utils xfconf >>"$LOG" 2>&1

# Cleanup nếu trước đó đã có code/x11vnc
apt -y purge code x11vnc >>"$LOG" 2>&1 || true
systemctl disable --now x11vnc.service >>"$LOG" 2>&1 || true
rm -f /etc/systemd/system/x11vnc.service

# =================== USER ===================
step "1/11 Tạo user ${USER_NAME}"
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "LT4C" "$USER_NAME" >>"$LOG" 2>&1
  echo "${USER_NAME}:${USER_PASS}" | chpasswd
  usermod -aG sudo "$USER_NAME"
fi
USER_UID="$(id -u "$USER_NAME")"

# =================== DESKTOP + XRDP + TigerVNC ===================
step "2/11 Cài XFCE + XRDP + TigerVNC"
apt -y install \
  xfce4 xfce4-goodies xorg \
  xrdp xorgxrdp pulseaudio \
  tigervnc-standalone-server \
  remmina remmina-plugin-rdp remmina-plugin-vnc neofetch kitty flatpak \
  mesa-vulkan-drivers libgl1-mesa-dri libasound2 libpulse0 libxkbcommon0 >>"$LOG" 2>&1

# =================== STEAM (Flatpak) + Firefox + Heroic ===================
step "3/11 Cài Firefox + Steam (Flatpak --system) & Heroic (user)"
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

# =================== XRDP: session + tuning ===================
step "4/11 Cấu hình XRDP dùng XFCE + tối ưu hiệu năng"
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

# =================== XFCE: tắt compositor ===================
step "5/11 Tắt compositor/hiệu ứng của XFCE (giảm lag)"
su - "$USER_NAME" -c 'xfconf-query -c xfwm4 -p /general/use_compositing -s false' || true

# =================== TigerVNC server (:0) ===================
step "6/11 Cấu hình TigerVNC :0 (${GEOM})"
install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.vnc"
su - "$USER_NAME" -c "printf '%s\n' '$VNC_PASS' | vncpasswd -f > ~/.vnc/passwd"
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.vnc/passwd"
chmod 600 "/home/$USER_NAME/.vnc/passwd"

cat >"/home/$USER_NAME/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11
export DESKTOP_SESSION=xfce
[ -x /usr/bin/dbus-launch ] && eval $(/usr/bin/dbus-launch --exit-with-session)
exec startxfce4
EOF
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.vnc/xstartup"
chmod +x "/home/$USER_NAME/.vnc/xstartup"

cat >/etc/systemd/system/vncserver@.service <<EOF
[Unit]
Description=TigerVNC server on display :%i (user ${USER_NAME})
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=${USER_NAME}
Group=${USER_NAME}
WorkingDirectory=/home/${USER_NAME}
Environment=HOME=/home/${USER_NAME}
ExecStart=/usr/bin/vncserver -fg -localhost no -geometry ${GEOM} :%i
ExecStop=/usr/bin/vncserver -kill :%i
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vncserver@0.service >>"$LOG" 2>&1 || true

# =================== Sunshine from .deb (+ auto-add apps) ===================
step "7/11 Cài Sunshine (.deb) + auto-add Firefox & Steam"
TMP_DEB="/tmp/sunshine.deb"
wget -O "$TMP_DEB" "$SUN_DEB_URL"
dpkg -i "$TMP_DEB" || true
apt -f install -y >>"$LOG" 2>&1 || true

# apps.json nội dung
read -r -d '' APPS_JSON_CONTENT <<JSON
{
  "apps": [
    {
      "name": "Firefox",
      "cmd": ["/usr/bin/flatpak", "run", "org.mozilla.firefox"],
      "working_dir": "/home/${USER_NAME}",
      "image_path": "",
      "auto_detect": false
    },
    {
      "name": "Steam",
      "cmd": ["/usr/bin/flatpak", "run", "com.valvesoftware.Steam"],
      "working_dir": "/home/${USER_NAME}",
      "image_path": "",
      "auto_detect": false
    }
  ]
}
JSON

# Per-user config
install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.config/sunshine"
printf '%s\n' "$APPS_JSON_CONTENT" >"/home/$USER_NAME/.config/sunshine/apps.json"
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config/sunshine/apps.json"
chmod 644 "/home/$USER_NAME/.config/sunshine/apps.json"

# System scope
install -d -m 0755 /var/lib/sunshine
printf '%s\n' "$APPS_JSON_CONTENT" > /var/lib/sunshine/apps.json
chown sunshine:sunshine /var/lib/sunshine/apps.json 2>/dev/null || true
chmod 644 /var/lib/sunshine/apps.json

# Override systemd: chạy dưới user lt4c với DISPLAY :0
install -d /etc/systemd/system/sunshine.service.d
cat >/etc/systemd/system/sunshine.service.d/override.conf <<EOF
[Service]
User=${USER_NAME}
Group=${USER_NAME}
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
EOF

# Tạo runtime dir nếu thiếu
install -d -m 0700 -o "$USER_UID" -g "$USER_UID" "/run/user/${USER_UID}" || true

systemctl daemon-reload
systemctl enable --now sunshine >>"$LOG" 2>&1 || true

# =================== Steam shortcut ===================
step "8/11 Tạo shortcut Steam cho XFCE"
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

# =================== TCP low latency + optional ufw allow ===================
step "9/11 Bật TCP low latency + mở cổng (nếu có ufw)"
cat >/etc/sysctl.d/90-remote-desktop.conf <<'EOF'
net.ipv4.tcp_low_latency = 1
EOF
sysctl --system >/dev/null 2>&1 || true

if command -v ufw >/dev/null 2>&1; then
  ufw allow 3389/tcp || true
  ufw allow ${VNC_PORT}/tcp || true
  ufw allow ${SUN_HTTP_TLS_PORT}/tcp || true
  ufw allow 47984:47990/tcp || true
  ufw allow 47998:48010/udp || true
fi

# =================== DONE + PRINT IP ===================
step "10/11 Hoàn tất (log: $LOG)"
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

echo "TigerVNC : ${IP}:${VNC_PORT}  (pass: ${VNC_PASS})"
echo "XRDP     : ${IP}:3389        (user ${USER_NAME} / ${USER_PASS})"
echo "Sunshine : https://${IP}:${SUN_HTTP_TLS_PORT}  (đã auto-add Firefox & Steam; web UI self-signed cert)"

echo "---- DEBUG ----"
ip -o -4 addr show up | awk '{print $2, $4}' || true
ip route || true
ss -ltnp | awk 'NR==1 || /:3389|:5900|:47990/' || true
systemctl --no-pager --full status vncserver@0 | sed -n '1,25p' || true
systemctl --no-pager --full status xrdp | sed -n '1,25p' || true
systemctl --no-pager --full status sunshine | sed -n '1,25p' || true
echo "--------------"

step "11/11 DONE"

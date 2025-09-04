#!/usr/bin/env bash
# lt4c_full_tigervnc_sunshine_chromium_32bit.sh
# XFCE + XRDP (32-bit color) + TigerVNC (:0) + Sunshine (.deb, auto-add Firefox/Steam/Chromium)
# + Steam (Flatpak) + Chromium (APT) + đặt icon ra Desktop

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/a_sh_install.log"

USER_NAME="lt4c"
USER_PASS="lt4c"
VNC_PASS="lt4c"
GEOM="1280x720"
VNC_PORT="5900"
SUN_HTTP_TLS_PORT="47990"
SUN_DEB_URL="https://github.com/LizardByte/Sunshine/releases/download/v2025.628.4510/sunshine-ubuntu-22.04-amd64.deb"

step(){ echo "[BƯỚC] $*"; }

# --- Chuẩn bị ---
: >"$LOG"
apt update -qq >>"$LOG" 2>&1 || true
apt -y install tmux iproute2 >>"$LOG" 2>&1 || true

# --- User ---
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "LT4C" "$USER_NAME"
  echo "${USER_NAME}:${USER_PASS}" | chpasswd
  usermod -aG sudo "$USER_NAME"
fi
USER_UID="$(id -u "$USER_NAME")"

# --- XFCE + XRDP + TigerVNC ---
apt -y install xfce4 xfce4-goodies xorg \
  xrdp xorgxrdp pulseaudio \
  tigervnc-standalone-server \
  flatpak chromium-browser || apt -y install chromium || true

# --- Steam + Firefox + Heroic (Flatpak) ---
flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak -y --system install flathub org.mozilla.firefox com.valvesoftware.Steam
su - "$USER_NAME" -c 'flatpak -y install flathub com.heroicgameslauncher.hgl'

# --- XRDP cấu hình (32-bit) ---
adduser xrdp ssl-cert || true
su - "$USER_NAME" -c 'echo "startxfce4" > ~/.xsession'
cat >/etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
export DESKTOP_SESSION=xfce
exec startxfce4
EOF
chmod +x /etc/xrdp/startwm.sh
if [ -f /etc/xrdp/xrdp.ini ]; then
  sed -i 's/^max_bpp=.*/max_bpp=32/' /etc/xrdp/xrdp.ini
  grep -q '^max_bpp=32' /etc/xrdp/xrdp.ini || echo 'max_bpp=32' >> /etc/xrdp/xrdp.ini
fi
systemctl enable --now xrdp

# --- Tắt compositor XFCE ---
su - "$USER_NAME" -c 'xfconf-query -c xfwm4 -p /general/use_compositing -s false' || true

# --- TigerVNC service ---
install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.vnc"
su - "$USER_NAME" -c "printf '%s\n' '$VNC_PASS' | vncpasswd -f > ~/.vnc/passwd"
cat >"/home/$USER_NAME/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
chmod +x "/home/$USER_NAME/.vnc/xstartup"

cat >/etc/systemd/system/vncserver@.service <<EOF
[Unit]
Description=TigerVNC server on display :%i (user ${USER_NAME})
After=network-online.target
[Service]
Type=simple
User=${USER_NAME}
ExecStart=/usr/bin/vncserver -fg -localhost no -geometry ${GEOM} :%i
ExecStop=/usr/bin/vncserver -kill :%i
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now vncserver@0

# --- Sunshine từ .deb + auto-add apps ---
TMP_DEB="/tmp/sunshine.deb"
wget -O "$TMP_DEB" "$SUN_DEB_URL"
dpkg -i "$TMP_DEB" || true
apt -f install -y

APPS_JSON=$(cat <<JSON
{
  "apps": [
    { "name": "Firefox", "cmd": ["/usr/bin/flatpak","run","org.mozilla.firefox"], "working_dir": "/home/${USER_NAME}", "auto_detect": false },
    { "name": "Steam", "cmd": ["/usr/bin/flatpak","run","com.valvesoftware.Steam"], "working_dir": "/home/${USER_NAME}", "auto_detect": false },
    { "name": "Chromium", "cmd": ["/usr/bin/chromium-browser"], "working_dir": "/home/${USER_NAME}", "auto_detect": false }
  ]
}
JSON
)
install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.config/sunshine"
echo "$APPS_JSON" >"/home/$USER_NAME/.config/sunshine/apps.json"
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config/sunshine/apps.json"

install -d /etc/systemd/system/sunshine.service.d
cat >/etc/systemd/system/sunshine.service.d/override.conf <<EOF
[Service]
User=${USER_NAME}
Group=${USER_NAME}
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
EOF
install -d -m 0700 -o "$USER_UID" -g "$USER_UID" "/run/user/${USER_UID}" || true
systemctl daemon-reload
systemctl enable --now sunshine

# --- Đặt icon ra Desktop ---
install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/Desktop"
cp /usr/share/applications/steam.desktop "/home/$USER_NAME/Desktop/Steam.desktop" 2>/dev/null || true
cp /usr/share/applications/chromium.desktop "/home/$USER_NAME/Desktop/Chromium.desktop" 2>/dev/null || true
cat >"/home/$USER_NAME/Desktop/Sunshine Web UI.desktop" <<'EOF'
[Desktop Entry]
Name=Sunshine Web UI
Exec=xdg-open https://localhost:47990
Icon=applications-internet
Type=Application
EOF
chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/Desktop"
chmod +x /home/$USER_NAME/Desktop/*.desktop

# --- TCP low latency ---
echo 'net.ipv4.tcp_low_latency = 1' >/etc/sysctl.d/90-remote-desktop.conf
sysctl --system >/dev/null 2>&1

# --- Print info ---
IP=$(hostname -I | awk '{print $1}')
echo "TigerVNC : ${IP}:${VNC_PORT} (pass: ${VNC_PASS})"
echo "XRDP     : ${IP}:3389 (user ${USER_NAME}/${USER_PASS}, 32-bit color)"
echo "Sunshine : https://${IP}:${SUN_HTTP_TLS_PORT} (apps: Firefox, Steam, Chromium)"
echo "Desktop  : đã có icon Steam, Chromium, Sunshine Web UI"

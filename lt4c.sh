#!/usr/bin/env bash
# lt4c_xfce_steam_shortcut.sh — XFCE + XRDP + VNC (:0/5900, pass lt4c) + Firefox/Steam (Flatpak)
# Includes: Steam prewarm (no sleep) + XFCE menu shortcut for Steam
set -Eeuo pipefail

# ======================= CONFIG =======================
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
LOG="/var/log/a_sh_install.log"
USER_NAME="lt4c"
USER_PASS="lt4c"
VNC_PASS="lt4c"
GEOM="1920x1080"

step(){ echo "[BƯỚC] $*"; }

# =================== INSTALL tmux FIRST ===================
: >"$LOG"
apt update -qq >>"$LOG" 2>&1 || true
apt -y install tmux iproute2 >>"$LOG" 2>&1 || true

# =================== INSTALLER ====================
# 0) Chuẩn bị -------------------------------------------------------
step "0/10 Chuẩn bị"
mkdir -p /etc/needrestart/conf.d
echo '$nrconf{restart} = "a";' >/etc/needrestart/conf.d/zzz-auto.conf || true
apt -y purge needrestart >>"$LOG" 2>&1 || true
systemctl stop unattended-upgrades >>"$LOG" 2>&1 || true
systemctl disable unattended-upgrades >>"$LOG" 2>&1 || true

apt -y -o Dpkg::Use-Pty=0 install \
  curl wget ca-certificates gnupg lsb-release apt-transport-https software-properties-common \
  sudo dbus-x11 xdg-utils desktop-file-utils >>"$LOG" 2>&1

# 1) User ----------------------------------------------------------------------
step "1/10 Tạo user ${USER_NAME}"
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "LT4C" "$USER_NAME" >>"$LOG" 2>&1
  echo "${USER_NAME}:${USER_PASS}" | chpasswd
  usermod -aG sudo "$USER_NAME"
fi

# 2) VS Code repo + i386 + multiverse -----------------------------------------
step "2/10 VSCode repo + i386 (Proton) + multiverse"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
chmod a+r /etc/apt/keyrings/microsoft.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
  >/etc/apt/sources.list.d/vscode.list
add-apt-repository -y multiverse >>"$LOG" 2>&1 || true
dpkg --add-architecture i386 >>"$LOG" 2>&1 || true
apt update -qq >>"$LOG" 2>&1

# 3) One-shot APT install ------------------------------------------------------
step "3/10 Cài XFCE + XRDP + VNC + App"
apt -y install \
  xfce4 xfce4-goodies xorg \
  xrdp xorgxrdp pulseaudio \
  tigervnc-standalone-server \
  code remmina remmina-plugin-rdp remmina-plugin-vnc neofetch kitty flatpak \
  mesa-vulkan-drivers mesa-vulkan-drivers:i386 \
  libgl1-mesa-dri libgl1-mesa-dri:i386 \
  libasound2 libasound2:i386 libpulse0 libpulse0:i386 \
  libxkbcommon0 libxkbcommon0:i386 >>"$LOG" 2>&1

# 4) Firefox/Steam/ Heroic (Flatpak) -------------------------------------------
step "4/10 Firefox + Steam (Flatpak --system) & Heroic (user lt4c)"
flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo >>"$LOG" 2>&1
flatpak -y --system install flathub org.mozilla.firefox com.valvesoftware.Steam >>"$LOG" 2>&1
printf '%s\n' '#!/bin/sh' 'exec flatpak run org.mozilla.firefox "$@"' >/usr/local/bin/firefox && chmod +x /usr/local/bin/firefox
printf '%s\n' '#!/bin/sh' 'exec flatpak run com.valvesoftware.Steam "$@"' >/usr/local/bin/steam && chmod +x /usr/local/bin/steam
su - "$USER_NAME" -c 'flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo'
su - "$USER_NAME" -c 'flatpak -y install flathub com.heroicgameslauncher.hgl'
cat >/etc/profile.d/flatpak-xdg.sh <<'EOF'
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:/var/lib/flatpak/exports/share:$HOME/.local/share/flatpak/exports/share"
EOF
chmod +x /etc/profile.d/flatpak-xdg.sh

# 5) XRDP config ---------------------------------------------------------------
step "5/10 Cấu hình XRDP dùng XFCE"
adduser xrdp ssl-cert >>"$LOG" 2>&1 || true
su - "$USER_NAME" -c 'echo "startxfce4" > ~/.xsession'
cat >/etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
export DESKTOP_SESSION=xfce
export XDG_SESSION_TYPE=x11
exec startxfce4
EOF
chmod +x /etc/xrdp/startwm.sh
systemctl enable --now xrdp >>"$LOG" 2>&1

# 6) VNC config ----------------------------------------------------------------
step "6/10 VNC :0 (5900) – set pass lt4c"
install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.vnc"
su - "$USER_NAME" -c "printf '%s' '$VNC_PASS' | vncpasswd -f > ~/.vnc/passwd"
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
ExecStartPre=/usr/bin/bash -lc "/usr/bin/vncserver -kill :%i >/dev/null 2>&1 || true"
ExecStart=/usr/bin/vncserver -fg -localhost no -geometry ${GEOM} :%i
ExecStop=/usr/bin/vncserver -kill :%i
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable vncserver@0.service >>"$LOG" 2>&1
systemctl restart vncserver@0.service >>"$LOG" 2>&1 || true

# 7) Steam prewarm (headless, no sleep) ----------------------------------------
step "7/10 Steam prewarm (headless)"
apt -y install xvfb >>"$LOG" 2>&1 || true
su - "$USER_NAME" -c 'xvfb-run -a flatpak run com.valvesoftware.Steam -silent || true'

# 8) Steam desktop entry for XFCE ----------------------------------------------
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
cat >"/home/$USER_NAME/.local/share/applications/steam.desktop" <<'EOF'
[Desktop Entry]
Name=Steam
Comment=Steam (Flatpak)
Exec=flatpak run com.valvesoftware.Steam
Icon=com.valvesoftware.Steam
Terminal=false
Type=Application
Categories=Game;
EOF
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.local/share/applications/steam.desktop"

# 9) Refresh menus -------------------------------------------------------------
step "9/10 Làm mới menu XFCE"
update-desktop-database /usr/share/applications || true
gtk-update-icon-cache -q /usr/share/icons/hicolor || true
su - "$USER_NAME" -c 'update-desktop-database ~/.local/share/applications || true'
su - "$USER_NAME" -c 'xdg-desktop-menu forceupdate || true'
pkill -HUP xfconfd || true

# 10) Done ---------------------------------------------------------------------
step "10/10 Hoàn tất (log: $LOG)"

# Robust IP detection
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

echo "VNC  : ${IP}:5900  (pass: ${VNC_PASS})"
echo "XRDP : ${IP}:3389  (user ${USER_NAME} / ${USER_PASS})"

echo "---- DEBUG ----"
ip -o -4 addr show up | awk '{print $2, $4}' || true
ip route || true
ss -ltnp | awk 'NR==1 || /:3389|:5900/' || true
systemctl --no-pager --full status xrdp | sed -n '1,20p' || true
systemctl --no-pager --full status vncserver@0 | sed -n '1,20p' || true
echo "--------------"

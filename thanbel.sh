#!/usr/bin/env bash
# lt4c_full_tigervnc_sunshine_deb_systemd.sh
# XFCE + TigerVNC + Sunshine (.deb) with TOML config (forced via systemd ExecStart)
# Steam (Flatpak) + Firefox (Flatpak wrapper) + VS Code (Microsoft repo)
# Controller patch (uinput/uhid/hidraw + input group), systemd logs -> /home/lt4c/sunshine-lt4c.log

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
LOG="/var/log/a_sh_install.log"

USER_NAME="lt4c"
USER_PASS="lt4c"
USER_UID=""
VNC_PASS="lt4c"
GEOM="1280x720"
VNC_PORT="5900"
SUN_WEB_PORT="47990"
SUN_LOG="/home/${USER_NAME}/sunshine-lt4c.log"
SUN_DEB_URL="https://github.com/LizardByte/Sunshine/releases/download/v2025.628.4510/sunshine-ubuntu-22.04-amd64.deb"

step(){ echo "[STEP] $*"; }
: >"$LOG"

# ---------- Base ----------
apt update -qq >>"$LOG" 2>&1 || true
apt -y install tmux iproute2 >>"$LOG" 2>&1 || true
mkdir -p /etc/needrestart/conf.d
echo '$nrconf{restart} = "a";' >/etc/needrestart/conf.d/zzz-auto.conf || true
apt -y purge needrestart x11vnc >>"$LOG" 2>&1 || true
systemctl disable --now x11vnc.service 2>/dev/null || true
rm -f /etc/systemd/system/x11vnc.service
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true
apt -y -o Dpkg::Use-Pty=0 install \
  curl wget ca-certificates gnupg gnupg2 lsb-release apt-transport-https software-properties-common \
  sudo dbus-x11 xdg-utils desktop-file-utils xfconf >>"$LOG" 2>&1

# ---------- User ----------
step "Create user ${USER_NAME}"
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "LT4C" "$USER_NAME" >>"$LOG" 2>&1
  echo "${USER_NAME}:${USER_PASS}" | chpasswd
  usermod -aG sudo "$USER_NAME"
fi
USER_UID="$(id -u "$USER_NAME")"

# ---------- Desktop + TigerVNC ----------
step "Install XFCE + TigerVNC"
apt -y install \
  xfce4 xfce4-goodies xorg \
  tigervnc-standalone-server \
  remmina remmina-plugin-vnc neofetch kitty flatpak \
  mesa-vulkan-drivers libgl1-mesa-dri libasound2 libpulse0 libxkbcommon0 >>"$LOG" 2>&1

# Steam + Firefox (Flatpak) + Heroic
step "Install Firefox/Steam Flatpak"
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
flatpak override --system --device=all --filesystem=/dev/input com.valvesoftware.Steam >>"$LOG" 2>&1 || true
flatpak override --system --socket=wayland --socket=x11 com.valvesoftware.Steam >>"$LOG" 2>&1 || true

# VS Code (Microsoft repo)
step "Install Visual Studio Code (Microsoft repo)"
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor >/etc/apt/trusted.gpg.d/microsoft.gpg
echo "deb [arch=amd64] https://packages.microsoft.com/repos/code stable main" >/etc/apt/sources.list.d/vscode.list
apt update -qq >>"$LOG" 2>&1
apt -y install code >>"$LOG" 2>&1

# XFCE compositor off
step "Disable XFCE compositor"
su - "$USER_NAME" -c 'xfconf-query -c xfwm4 -p /general/use_compositing -s false' || true

# TigerVNC :0
step "Configure TigerVNC :0"
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

# ---------- Sunshine (.deb) ----------
step "Install Sunshine (.deb)"
TMP_DEB="/tmp/sunshine.deb"
wget -O "$TMP_DEB" "$SUN_DEB_URL"
dpkg -i "$TMP_DEB" || true
apt -f install -y >>"$LOG" 2>&1 || true

# Config TOML (your config)
step "Write Sunshine TOML config"
install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.config/sunshine"
cat >"/home/$USER_NAME/.config/sunshine/sunshine.conf" <<'EOF'
sunshine_name = "lt4c"
config_version = 5
min_log_level = "info"
origin_web_ui_allowed = "wan"
lan_encryption_mode = 1
wan_encryption_mode = 2
paired_clients = []

[[apps]]
title = "Desktop Low Quality"
detached = false
start_virtual_compositor = true
cmd = ["env", "SUNSHINE_STREAM_QUALITY=low", "sunshine-desktop"]

[[apps]]
title = "Desktop"
detached = false
start_virtual_compositor = true
cmd = ["sunshine-desktop"]

[[apps]]
title = "Steam Big Picture"
detached = false
start_virtual_compositor = true
cmd = ["steam", "-bigpicture"]

[[apps]]
title = "Firefox"
detached = false
start_virtual_compositor = true
cmd = ["firefox"]

[[apps]]
title = "VS Code"
detached = false
start_virtual_compositor = true
cmd = ["code"]

[[apps]]
title = "Terminal"
detached = false
start_virtual_compositor = true
cmd = ["xfce4-terminal"]

[[apps]]
title = "XFCE Session"
detached = false
start_virtual_compositor = true
cmd = ["startxfce4"]
EOF
chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config/sunshine/sunshine.conf"
chmod 0644 "/home/$USER_NAME/.config/sunshine/sunshine.conf"

install -d -m 0755 /etc/sunshine
cp -f "/home/$USER_NAME/.config/sunshine/sunshine.conf" /etc/sunshine/sunshine.conf
chown root:root /etc/sunshine/sunshine.conf
chmod 0644 /etc/sunshine/sunshine.conf

# ---------- Controller permissions ----------
step "Controller: uhid/uinput/hidraw + input group"
echo uhid  >/etc/modules-load.d/uhid.conf
echo uinput>/etc/modules-load.d/uinput.conf
modprobe uhid || true
modprobe uinput || true
cat >/etc/udev/rules.d/59-sunshine-controllers.rules <<'EOF'
KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
KERNEL=="uhid",   MODE="0660", GROUP="input", OPTIONS+="static_node=uhid"
SUBSYSTEM=="hidraw", KERNEL=="hidraw*", MODE="0660", GROUP="input"
EOF
usermod -aG input "$USER_NAME" || true
udevadm control --reload-rules || true
udevadm trigger || true

# ---------- systemd override ----------
step "systemd drop-in for Sunshine"
install -d /etc/systemd/system/sunshine.service.d
touch "${SUN_LOG}"; chown "${USER_NAME}:${USER_NAME}" "${SUN_LOG}"; chmod 0644 "${SUN_LOG}"
cat >/etc/systemd/system/sunshine.service.d/override.conf <<EOF
[Service]
User=${USER_NAME}
Group=${USER_NAME}
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
SupplementaryGroups=input
ExecStart=
ExecStart=/usr/bin/sunshine --config /etc/sunshine/sunshine.conf
StandardOutput=append:${SUN_LOG}
StandardError=append:${SUN_LOG}
EOF
install -d -m 0700 -o "$USER_UID" -g "$USER_UID" "/run/user/${USER_UID}" || true
systemctl daemon-reload
systemctl stop sunshine 2>/dev/null || true
pkill -x sunshine 2>/dev/null || true
systemctl enable --now sunshine >>"$LOG" 2>&1 || true

# ---------- Steam desktop file ----------
step "Create Steam desktop entry"
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

# ---------- Networking ----------
step "Networking tweaks"
cat >/etc/sysctl.d/90-remote-desktop.conf <<'EOF'
net.ipv4.tcp_low_latency = 1
EOF
sysctl --system >/dev/null 2>&1 || true
if command -v ufw >/dev/null 2>&1; then
  ufw allow ${VNC_PORT}/tcp || true
  ufw allow ${SUN_WEB_PORT}/tcp || true
  ufw allow 47984:47990/tcp || true
  ufw allow 47998:48010/udp || true
fi

# ---------- Output ----------
step "Done. Endpoints + quick diagnostics"
get_ip(){ ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }
IP="$(get_ip)"; [ -z "$IP" ] && IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
IP="${IP:-<no-ip>}"
echo "TigerVNC : ${IP}:${VNC_PORT}  (pass: ${VNC_PASS})"
echo "Sunshine : https://${IP}:${SUN_WEB_PORT}  (first-run via localhost required; log: ${SUN_LOG})"
echo "Apps     : Desktop Low, Desktop, Steam Big Picture, Firefox, VS Code, Terminal, XFCE Session"
echo "---- DEBUG ----"
ps -o user,group,cmd -C sunshine || true
tail -n 40 "${SUN_LOG}" 2>/dev/null || true
systemctl --no-pager --full status sunshine | sed -n '1,25p' || true

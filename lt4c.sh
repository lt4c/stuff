#!/usr/bin/env bash
# lt4c_full_tigervnc_sunshine_autoapps_deb.sh (patched + input drivers)
# XFCE + XRDP (tuned) + TigerVNC (:0) + Sunshine (.deb + auto-add apps) + Steam (Flatpak) + Chromium (Flatpak)
# Added: Desktop icons (Steam, Moonlight/Sunshine UI, Chromium)
# Added: Input stack for Moonlight (uinput + vgamepad DKMS) and permissions hardening

set -Eeuo pipefail

# ======================= CONFIG =======================
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
LOG="/var/log/a_sh_install.log"

USER_NAME="${USER_NAME:-lt4c}"
USER_PASS="${USER_PASS:-lt4c}"
VNC_PASS="${VNC_PASS:-lt4c}"
GEOM="${GEOM:-1280x720}"
VNC_PORT="${VNC_PORT:-5900}"
SUN_HTTP_TLS_PORT="${SUN_HTTP_TLS_PORT:-47990}"

SUN_DEB_URL="${SUN_DEB_URL:-https://github.com/LizardByte/Sunshine/releases/download/v2025.628.4510/sunshine-ubuntu-22.04-amd64.deb}"

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

# =================== Steam/Chromium (Flatpak) + Heroic ===================
step "3/11 Cài Chromium + Steam (Flatpak --system) & Heroic (user)"
flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo >>"$LOG" 2>&1 || true
# Cài Chromium + Steam (hệ thống)
flatpak -y --system install flathub org.chromium.Chromium com.valvesoftware.Steam >>"$LOG" 2>&1 || true
# Shims tiện gọi nhanh
printf '%s\n' '#!/bin/sh' 'exec flatpak run org.chromium.Chromium "$@"' >/usr/local/bin/chromium && chmod +x /usr/local/bin/chromium
printf '%s\n' '#!/bin/sh' 'exec flatpak run com.valvesoftware.Steam "$@"' >/usr/local/bin/steam && chmod +x /usr/local/bin/steam
# Heroic (cài theo user)
su - "$USER_NAME" -c 'flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo' >>"$LOG" 2>&1 || true
su - "$USER_NAME" -c 'flatpak -y install flathub com.heroicgameslauncher.hgl' >>"$LOG" 2>&1 || true
# Bảo đảm XDG paths có Flatpak exports
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
step "7/11 Cài Sunshine (.deb) + auto-add Steam & Chromium"
TMP_DEB="/tmp/sunshine.deb"
wget -O "$TMP_DEB" "$SUN_DEB_URL"
dpkg -i "$TMP_DEB" || true
apt -f install -y >>"$LOG" 2>&1 || true

# apps.json nội dung (chỉ app để stream)
read -r -d '' APPS_JSON_CONTENT <<JSON
{
  "apps": [
    {
      "name": "Steam",
      "cmd": ["/usr/bin/flatpak", "run", "com.valvesoftware.Steam"],
      "working_dir": "/home/${USER_NAME}",
      "image_path": "",
      "auto_detect": false
    },
    {
      "name": "Chromium",
      "cmd": ["/usr/bin/flatpak", "run", "org.chromium.Chromium"],
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

# =================== Sunshine/Moonlight: enable virtual input (kb/mouse/gamepad) ===================

# =================== Sunshine as USER service (improves input injection reliability) ===================
step "7.0b/11 Chuyển Sunshine sang user-service (systemd --user) + enable linger"

# Disable system-wide service to avoid seat/session issues
systemctl disable --now sunshine >>"$LOG" 2>&1 || true

# Enable lingering so user services can run without interactive login
loginctl enable-linger "${USER_NAME}" >>"$LOG" 2>&1 || true

# Create user unit
USR_UNIT_DIR="/home/${USER_NAME}/.config/systemd/user"
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "$USR_UNIT_DIR"

cat >"$USR_UNIT_DIR/sunshine.service" <<EOF
[Unit]
Description=Sunshine Remote Play (user)
After=graphical-session.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/sunshine
Restart=on-failure
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
SupplementaryGroups=input
NoNewPrivileges=true

[Install]
WantedBy=default.target
EOF
chown "${USER_NAME}:${USER_NAME}" "$USR_UNIT_DIR/sunshine.service"

# Start as user
su - "${USER_NAME}" -c 'systemctl --user daemon-reload'
su - "${USER_NAME}" -c 'systemctl --user enable --now sunshine' || true
step "7.1/11 Bật uinput + quyền truy cập thiết bị input cho Sunshine"

# Cài công cụ test input (tùy chọn)
apt -y install evtest joystick >>"$LOG" 2>&1 || true

# Bật kernel module uinput lúc boot và ngay lập tức
echo uinput >/etc/modules-load.d/uinput.conf
modprobe uinput || true

# Cho phép user truy cập /dev/uinput và /dev/input/event*
# (Sunshine chạy dưới user ${USER_NAME})
groupadd -f input
usermod -aG input "${USER_NAME}"

# Quyền udev cho thiết bị input
cat >/etc/udev/rules.d/60-sunshine-input.rules <<'EOF'
KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"
SUBSYSTEM=="input", KERNEL=="event*", MODE="0660", GROUP="input"
EOF

udevadm control --reload-rules || true
udevadm trigger || true

# Bảo đảm service Sunshine có group input
install -d /etc/systemd/system/sunshine.service.d
cat >/etc/systemd/system/sunshine.service.d/10-input.conf <<'EOF'
[Service]
SupplementaryGroups=input
EOF

systemctl daemon-reload
systemctl restart sunshine || true

# =================== Sunshine: cài ViGEmBus/vgamepad cho gamepad ảo ===================
step "7.2/11 Cài Virtual Gamepad (ViGEmBus/vgamepad)"

# Yêu cầu build module kernel
apt -y install dkms build-essential linux-headers-$(uname -r) git >>"$LOG" 2>&1 || true

# Cài vgamepad (kernel module) qua DKMS
if ! lsmod | grep -q '^vgamepad'; then
  TMP_VGP="/tmp/vgamepad_$(date +%s)"
  rm -rf "$TMP_VGP"
  git clone --depth=1 https://github.com/ViGEm/vgamepad.git "$TMP_VGP" >>"$LOG" 2>&1 || true
  if [ -f "$TMP_VGP/dkms.conf" ] || [ -f "$TMP_VGP/Makefile" ]; then
    VGP_VER="$(grep -Eo 'PACKAGE_VERSION.?=.+' "$TMP_VGP/dkms.conf" 2>/dev/null | awk -F= '{print $2}' | tr -d ' \"' || echo 0.1)"
    VGP_VER="${VGP_VER:-0.1}"
    DEST="/usr/src/vgamepad-${VGP_VER}"
    rm -rf "$DEST"
    mkdir -p "$DEST"
    cp -a "$TMP_VGP/"* "$DEST/"
    dkms add "vgamepad/${VGP_VER}" >>"$LOG" 2>&1 || true
    dkms build "vgamepad/${VGP_VER}" >>"$LOG" 2>&1 || true
    dkms install "vgamepad/${VGP_VER}" >>"$LOG" 2>&1 || true
  fi
  modprobe vgamepad || true
fi

# Udev rules để Sunshine truy cập thiết bị
cat >/etc/udev/rules.d/61-vgamepad.rules <<'EOF'
KERNEL=="vgamepad*", MODE="0660", GROUP="input"
EOF
udevadm control --reload-rules || true
udevadm trigger || true

# =================== Sunshine input permission hardening (runtime fix) ===================
step "7.3/11 Fix quyền thiết bị input (runtime) + restart Sunshine"

# Bảo đảm user nằm trong group input
groupadd -f input
usermod -aG input "${USER_NAME}" || true

# Nếu thiết bị đã tồn tại, chỉnh quyền ngay lập tức
fix_input_perms() {
  for dev in /dev/uinput /dev/input/event* /dev/vgamepad*; do
    [ -e "$dev" ] || continue
    chgrp input "$dev" 2>/dev/null || true
    chmod 660 "$dev" 2>/dev/null || true
  done
}
fix_input_perms

# Reload udev để áp dụng rules đã tạo
udevadm control --reload-rules || true
udevadm trigger || true

# Đảm bảo service Sunshine có group input
install -d /etc/systemd/system/sunshine.service.d
cat >/etc/systemd/system/sunshine.service.d/10-input.conf <<'EOF'
[Service]
SupplementaryGroups=input
EOF

systemctl daemon-reload
systemctl restart sunshine || true

# =================== Shortcuts ra Desktop ===================
step "8/11 Tạo shortcut Steam, Moonlight (Sunshine Web UI), Chromium ra Desktop"

DESKTOP_DIR="/home/$USER_NAME/Desktop"
install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "$DESKTOP_DIR"

# Steam (Flatpak)
cat >"$DESKTOP_DIR/steam.desktop" <<'EOF'
[Desktop Entry]
Name=Steam
Comment=Steam (Flatpak)
Exec=flatpak run com.valvesoftware.Steam
Icon=com.valvesoftware.Steam
Terminal=false
Type=Application
Categories=Game;
EOF

# Moonlight (mở Sunshine Web UI trong Chromium)
cat >"$DESKTOP_DIR/moonlight.desktop" <<EOF
[Desktop Entry]
Name=Moonlight (Sunshine Web UI)
Comment=Open Sunshine pairing UI for Moonlight
Exec=flatpak run org.chromium.Chromium https://localhost:${SUN_HTTP_TLS_PORT}
Icon=sunshine
Terminal=false
Type=Application
Categories=Network;Game;Settings;
EOF

# Chromium
cat >"$DESKTOP_DIR/chromium.desktop" <<'EOF'
[Desktop Entry]
Name=Chromium
Exec=flatpak run org.chromium.Chromium
Icon=org.chromium.Chromium
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF

chown -R "$USER_NAME:$USER_NAME" "$DESKTOP_DIR"
chmod +x "$DESKTOP_DIR"/*.desktop
# Cập nhật database để icon/launcher hiện chuẩn trong menu
update-desktop-database /usr/share/applications || true
su - "$USER_NAME" -c 'update-desktop-database ~/.local/share/applications || true' >>"$LOG" 2>&1 || true
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
echo "Sunshine : https://${IP}:${SUN_HTTP_TLS_PORT}  (UI tự ký; auto-add Steam & Chromium)"
echo "Moonlight: Mở shortcut 'Moonlight (Sunshine Web UI)' trên Desktop để pair"

echo "---- DEBUG ----"
ip -o -4 addr show up | awk '{print $2, $4}' || true
ip route || true
ss -ltnp | awk 'NR==1 || /:3389|:5900|:47990/' || true
systemctl --no-pager --full status vncserver@0 | sed -n '1,25p' || true
systemctl --no-pager --full status xrdp | sed -n '1,25p' || true
systemctl --no-pager --full status sunshine | sed -n '1,25p' || true
echo "--------------"

step "11/11 DONE"

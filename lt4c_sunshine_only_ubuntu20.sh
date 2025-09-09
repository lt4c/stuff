#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# LT4C — Ubuntu 20.04 (Focal) Sunshine-only + TigerVNC + XFCE + Firefox + VSCode + Moonlight apps
# =========================
# ENV overrideable
USER_NAME="${USER_NAME:-lt4c}"
USER_PASS="${USER_PASS:-lt4c}"
VNC_PASS="${VNC_PASS:-lt4c}"
GEOM="${GEOM:-1280x720}"
VNC_PORT="${VNC_PORT:-5900}"
SUN_HTTP_TLS_PORT="${SUN_HTTP_TLS_PORT:-47990}"
# You can override SUN_DEB_URL if this default 20.04 build URL changes
SUN_DEB_URL="${SUN_DEB_URL:-https://github.com/LizardByte/Sunshine/releases/download/v2025.628.4510/sunshine-ubuntu-20.04-amd64.deb}"

LOGDIR="/srv/lab"
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGDIR/lt4c_sunshine_only_focal_$(date +%Y%m%d_%H%M%S).log") 2>&1

step(){ echo "[INFO] $*"; }

step "0/13 Prepare base (Ubuntu 20.04)"
export DEBIAN_FRONTEND=noninteractive
apt update -qq || true
# Core packages available on 20.04 (focal)
apt -y install --no-install-recommends \
  ca-certificates curl wget sudo dbus-x11 xdg-utils desktop-file-utils xfconf iproute2 \
  flatpak xfce4 xfce4-goodies xorg tigervnc-standalone-server \
  mesa-vulkan-drivers libgl1-mesa-dri libasound2 libpulse0 libxkbcommon0 -y

# ---------------- Remove XRDP completely ----------------
step "1/13 Remove XRDP (use VNC + Sunshine only)"
apt -y purge xrdp xorgxrdp || true
systemctl disable --now xrdp || true
rm -f /etc/xrdp/startwm.sh || true

# ---------------- User ----------------
step "2/13 Ensure user ${USER_NAME} exists"
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "LT4C" "$USER_NAME"
  echo "${USER_NAME}:${USER_PASS}" | chpasswd
  usermod -aG sudo "$USER_NAME"
fi
USER_UID="$(id -u "$USER_NAME")"

# ---------------- Flatpak (Firefox + VSCode) with Snap fallback for Code ----------------
step "3/13 Install Firefox & VSCode (Flatpak), with Snap fallback for Code on Ubuntu 20.04"
flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo || true
# Try Flatpak first
flatpak -y --system install flathub org.mozilla.firefox || true
flatpak -y --system install flathub com.visualstudio.code || true

# Create universal launchers that try Flatpak, then Snap, then native
cat >/usr/local/bin/firefox <<'EOF'
#!/bin/sh
if command -v flatpak >/dev/null 2>&1 && flatpak info org.mozilla.firefox >/dev/null 2>&1; then
  exec flatpak run org.mozilla.firefox "$@"
fi
# Fallback to system firefox if present
if command -v firefox >/dev/null 2>&1 && [ "$0" != "$(command -v firefox)" ]; then
  exec "$(command -v firefox)" "$@"
fi
echo "Firefox not found (flatpak/system)"; exit 1
EOF
chmod +x /usr/local/bin/firefox

cat >/usr/local/bin/code <<'EOF'
#!/bin/sh
# Try Flatpak
if command -v flatpak >/dev/null 2>&1 && flatpak info com.visualstudio.code >/dev/null 2>&1; then
  exec flatpak run com.visualstudio.code "$@"
fi
# Try Snap
if command -v snap >/dev/null 2>&1 && snap list code >/dev/null 2>&1; then
  exec /snap/bin/code "$@"
fi
# Try native
if command -v code >/dev/null 2>&1 && [ "$0" != "$(command -v code)" ]; then
  exec "$(command -v code)" "$@"
fi
echo "VSCode not found (flatpak/snap/native). You can install snap fallback via: sudo snap install code --classic"; exit 1
EOF
chmod +x /usr/local/bin/code

# Make Flatpak apps discoverable
cat >/etc/profile.d/flatpak-xdg.sh <<'EOF'
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:/var/lib/flatpak/exports/share:$HOME/.local/share/flatpak/exports/share"
EOF
chmod +x /etc/profile.d/flatpak-xdg.sh

# ---------------- Disable XFCE compositor (reduce lag) ----------------
step "4/13 Disable XFCE compositor (best-effort)"
su - "$USER_NAME" -c 'xfconf-query -c xfwm4 -p /general/use_compositing -s false' || true

# ---------------- TigerVNC :0 ----------------
step "5/13 Configure TigerVNC :0 (${GEOM})"
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
systemctl enable --now vncserver@0.service || true

# ---------------- Sunshine (20.04 build) ----------------
step "6/13 Install Sunshine for Ubuntu 20.04"
wget -O /tmp/sunshine.deb "$SUN_DEB_URL"
dpkg -i /tmp/sunshine.deb || true
apt -f install -y || true

# ---------------- Sunshine apps ----------------
step "7/13 Write Sunshine apps.json (VSCode, Desktop, Desktop Low Quality, XFCE Session, Firefox)"
install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.config/sunshine"

cat >"/home/$USER_NAME/.config/sunshine/apps.json" <<JSON
{
  "apps": [
    {
      "name": "VSCode",
      "cmd": ["/usr/local/bin/code"],
      "working_dir": "/home/${USER_NAME}",
      "auto_detect": false
    },
    {
      "name": "Desktop",
      "cmd": ["bash", "-lc", "sleep infinity"],
      "working_dir": "/home/${USER_NAME}",
      "auto_detect": false
    },
    {
      "name": "Desktop Low Quality",
      "cmd": ["bash", "-lc", "sleep infinity"],
      "working_dir": "/home/${USER_NAME}",
      "auto_detect": false
    },
    {
      "name": "XFCE Session",
      "cmd": ["startxfce4"],
      "working_dir": "/home/${USER_NAME}",
      "auto_detect": false
    },
    {
      "name": "Firefox",
      "cmd": ["/usr/local/bin/firefox"],
      "working_dir": "/home/${USER_NAME}",
      "auto_detect": false
    }
  ]
}
JSON
chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config/sunshine"
chmod 644 "/home/$USER_NAME/.config/sunshine/apps.json"

# Provide system-scope copy too
install -d -m 0755 /var/lib/sunshine
cp -f "/home/$USER_NAME/.config/sunshine/apps.json" /var/lib/sunshine/apps.json || true
chown sunshine:sunshine /var/lib/sunshine/apps.json 2>/dev/null || true
chmod 644 /var/lib/sunshine/apps.json || true

# ---------------- Sunshine systemd override & runtime ----------------
step "8/13 Systemd override: run Sunshine as ${USER_NAME} on :0; expose WebUI on LAN"
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
systemctl enable --now sunshine || true

# ---------------- HID permissions (controller / keyboard / mouse over Sunshine) ----------------
step "9/13 Enable uhid + relaxed perms for uhid/uinput/hidraw (persistent)"
echo uhid >/etc/modules-load.d/uhid.conf
modprobe uhid || true

cat >/etc/udev/rules.d/59-uhid-hidraw.rules <<'EOF'
KERNEL=="uhid", MODE="0660", GROUP="input", OPTIONS+="static_node=uhid"
SUBSYSTEM=="hidraw", KERNEL=="hidraw*", MODE="0660", GROUP="input"
KERNEL=="uinput", MODE="0660", GROUP="input"
EOF
udevadm control --reload-rules || true
udevadm trigger || true

# Apply immediately this boot (best-effort)
sh -c 'chgrp input /dev/uhid /dev/uinput /dev/hidraw* 2>/dev/null || true; chmod 660 /dev/uhid /dev/uinput /dev/hidraw* 2>/dev/null || true'

# ---------------- Open firewall ports ----------------
step "10/13 Open ports for Sunshine & VNC (if UFW present)"
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${VNC_PORT}"/tcp || true
  ufw allow "${SUN_HTTP_TLS_PORT}"/tcp || true    # Sunshine WebUI (HTTPS)
  ufw allow 47984:47990/tcp || true               # Sunshine GameStream TCP
  ufw allow 47998:48010/udp || true               # Sunshine GameStream UDP
fi

# ---------------- Make sure external IP isn't blocked (basic check) ----------------
step "11/13 Basic check: listening ports"
ss -ltnp | awk 'NR==1 || /:5900|:47990/' || true

# ---------------- Print endpoints + quick status ----------------
step "12/13 Print endpoints"
get_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}
IP="$(get_ip)"; IP="${IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"

echo "VNC        : ${IP}:${VNC_PORT} (pass: ${VNC_PASS})"
echo "SunshineUI : https://${IP}:${SUN_HTTP_TLS_PORT}  (self-signed cert; open from LAN)"
echo "Moonlight  : Pair with the host '${IP}' (PIN shown in Moonlight)"
systemctl --no-pager --full status sunshine | sed -n '1,20p' || true
systemctl --no-pager --full status vncserver@0 | sed -n '1,20p' || true

step "13/13 DONE"

# Notes:
# - If Sunshine .deb URL 404 due to new releases, override via env:
#   sudo env SUN_DEB_URL="https://.../sunshine-ubuntu-20.04-amd64.deb" ./lt4c_sunshine_only_ubuntu20.sh
# - If VSCode flatpak fails on 20.04, you can install snap fallback:
#   sudo snap install code --classic

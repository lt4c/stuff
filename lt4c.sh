#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# LT4C — Sunshine-only (WebUI external) + TigerVNC + XFCE + Flatpak (Firefox, VSCode) + Moonlight apps
# =========================
# ENV overrideable
USER_NAME="${USER_NAME:-lt4c}"
USER_PASS="${USER_PASS:-lt4c}"
VNC_PASS="${VNC_PASS:-lt4c}"
GEOM="${GEOM:-1280x720}"
VNC_PORT="${VNC_PORT:-5900}"
SUN_HTTP_TLS_PORT="${SUN_HTTP_TLS_PORT:-47990}"

LOGDIR="/srv/lab"
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGDIR/lt4c_sunshine_only_$(date +%Y%m%d_%H%M%S).log") 2>&1

step(){ echo "[INFO] $*"; }

step "0/12 Prepare base"
export DEBIAN_FRONTEND=noninteractive
apt update -qq || true
apt -y install --no-install-recommends \
  ca-certificates curl wget sudo dbus-x11 xdg-utils desktop-file-utils xfconf iproute2 \
  flatpak xfce4 xfce4-goodies xorg tigervnc-standalone-server \
  mesa-vulkan-drivers libgl1-mesa-dri libasound2 libpulse0 libxkbcommon0 -y

# ---------------- Xóa XRDP (nếu có) ----------------
step "1/12 Remove XRDP (use VNC + Sunshine only)"
apt -y purge xrdp xorgxrdp || true
systemctl disable --now xrdp || true
rm -f /etc/xrdp/startwm.sh || true

# ---------------- User ----------------
step "2/12 Ensure user ${USER_NAME} exists"
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "LT4C" "$USER_NAME"
  echo "${USER_NAME}:${USER_PASS}" | chpasswd
  usermod -aG sudo "$USER_NAME"
fi
USER_UID="$(id -u "$USER_NAME")"

# ---------------- Flatpak + Apps ----------------
step "3/12 Flatpak flathub + Firefox + VSCode"
flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo || true
flatpak -y --system install flathub org.mozilla.firefox com.visualstudio.code || true

# small launchers for convenience
printf '%s\n' '#!/bin/sh' 'exec flatpak run org.mozilla.firefox "$@"' >/usr/local/bin/firefox && chmod +x /usr/local/bin/firefox
printf '%s\n' '#!/bin/sh' 'exec flatpak run com.visualstudio.code "$@"' >/usr/local/bin/code && chmod +x /usr/local/bin/code

# make flathub apps discoverable
cat >/etc/profile.d/flatpak-xdg.sh <<'EOF'
export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:/var/lib/flatpak/exports/share:$HOME/.local/share/flatpak/exports/share"
EOF
chmod +x /etc/profile.d/flatpak-xdg.sh

# ---------------- XFCE compositor off (giảm lag) ----------------
step "4/12 Disable XFCE compositor (best-effort)"
su - "$USER_NAME" -c 'xfconf-query -c xfwm4 -p /general/use_compositing -s false' || true

# ---------------- TigerVNC :0 ----------------
step "5/12 Configure TigerVNC :0 (${GEOM})"
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

# ---------------- Sunshine ----------------
step "6/12 Install Sunshine (.deb)"
SUN_DEB_URL="${SUN_DEB_URL:-https://github.com/LizardByte/Sunshine/releases/download/v2025.628.4510/sunshine-ubuntu-22.04-amd64.deb}"
wget -O /tmp/sunshine.deb "$SUN_DEB_URL"
dpkg -i /tmp/sunshine.deb || true
apt -f install -y || true

# ---------------- Sunshine apps ----------------
step "7/12 Write Sunshine apps.json (VSCode, Desktop, Desktop Low Quality, XFCE Session, Firefox)"
install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.config/sunshine"

cat >"/home/$USER_NAME/.config/sunshine/apps.json" <<JSON
{
  "apps": [
    {
      "name": "VSCode",
      "cmd": ["/usr/bin/code"],
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
      "cmd": ["/usr/bin/flatpak", "run", "org.mozilla.firefox"],
      "working_dir": "/home/${USER_NAME}",
      "auto_detect": false
    }
  ]
}
JSON
chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.config/sunshine"
chmod 644 "/home/$USER_NAME/.config/sunshine/apps.json"

# also provide system-scope copy
install -d -m 0755 /var/lib/sunshine
cp -f "/home/$USER_NAME/.config/sunshine/apps.json" /var/lib/sunshine/apps.json || true
chown sunshine:sunshine /var/lib/sunshine/apps.json 2>/dev/null || true
chmod 644 /var/lib/sunshine/apps.json || true

# ---------------- Sunshine systemd override & runtime ----------------
step "8/12 Systemd override: run Sunshine as ${USER_NAME} on :0 and allow WebUI on external IP"
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
step "9/12 Enable uhid + relaxed perms for uhid/uinput/hidraw (persistent)"
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
step "10/12 Open ports for Sunshine & VNC (if UFW present)"
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${VNC_PORT}"/tcp || true
  ufw allow "${SUN_HTTP_TLS_PORT}"/tcp || true    # Sunshine WebUI (HTTPS)
  ufw allow 47984:47990/tcp || true               # Sunshine GameStream TCP
  ufw allow 47998:48010/udp || true               # Sunshine GameStream UDP
fi

# ---------------- Print IPs + quick status ----------------
step "11/12 Print endpoints"
get_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}
IP="$(get_ip)"; IP="${IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"

echo "VNC        : ${IP}:${VNC_PORT} (pass: ${VNC_PASS})"
echo "SunshineUI : https://${IP}:${SUN_HTTP_TLS_PORT}  (self-signed cert; open from LAN)"
echo "Moonlight  : Pair with the host '${IP}' (PIN shown in Moonlight)"

echo "---- DEBUG ----"
ss -ltnp | awk 'NR==1 || /:5900|:47990/' || true
systemctl --no-pager --full status vncserver@0 | sed -n '1,25p' || true
systemctl --no-pager --full status sunshine | sed -n '1,25p' || true
echo "--------------"

step "12/12 DONE"

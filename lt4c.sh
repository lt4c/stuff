#!/usr/bin/env bash
# lt4c.sh
# Bazzite/Silverblue (Fedora-based, immutable) setup:
# - NVIDIA T4 drivers via rpm-ostree (akmod)
# - XRDP (32-bit color) + TigerVNC (:0)
# - Flatpak apps: Steam, Chromium, Sunshine (+ optional Heroic)
# - Desktop shortcuts + Sunshine autostart
# - Continues automatically after the reboot required by NVIDIA install

set -Eeuo pipefail

LOG="/var/log/lt4c_bazzite_setup.log"
: >"$LOG"

# ---- Configurable ----
USER_NAME="${USER_NAME:-lt4c}"
USER_PASS="${USER_PASS:-lt4c}"
VNC_PASS="${VNC_PASS:-lt4c}"
GEOM="${GEOM:-1280x720}"
VNC_DISPLAY="${VNC_DISPLAY:-0}"
XRDP_COLOR_BPP="${XRDP_COLOR_BPP:-32}"
INSTALL_HEROIC="${INSTALL_HEROIC:-1}"   # 1 = yes, 0 = no

# ---- Helpers ----
step(){ echo -e "\n[STEP] $*" | tee -a "$LOG"; }
warn(){ echo -e "[WARN] $*" | tee -a "$LOG"; }
ok(){ echo -e "[OK] $*" | tee -a "$LOG"; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { warn "Missing command: $1"; return 1; }; }

# Detect rpm-ostree system
if ! need_cmd rpm-ostree; then
  echo "This script is intended for Bazzite / Fedora Silverblue/Kinoite (rpm-ostree). Aborting." | tee -a "$LOG"
  exit 1
fi

# Create target user if not exists
step "Creating user ${USER_NAME} (if needed)"
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  sudo useradd -m -G wheel "$USER_NAME" || true
  echo "${USER_NAME}:${USER_PASS}" | sudo chpasswd
else
  ok "User ${USER_NAME} already exists"
fi

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
USER_UID="$(id -u "$USER_NAME")"
USER_GID="$(id -g "$USER_NAME")"

# Prepare state dir for continuation
STATE_DIR="/var/lib/lt4c"
sudo mkdir -p "$STATE_DIR"
sudo chown root:root "$STATE_DIR"
sudo chmod 0755 "$STATE_DIR"

# ------------------------------
# Phase 1: Layer base packages & NVIDIA (requires reboot)
# ------------------------------
step "Layering NVIDIA drivers and remote desktop base packages (requires reboot)"
# On Fedora/Bazzite, akmod-nvidia builds the kernel module after reboot.
# Include XRDP and TigerVNC server in the same deployment to reduce reboots.
sudo rpm-ostree install \
  akmod-nvidia \
  xorg-x11-drv-nvidia \
  xorg-x11-drv-nvidia-cuda \
  xorg-x11-drv-nvidia-cuda-libs \
  xrdp xorgxrdp \
  tigervnc-server \
  || true

# Prepare the continuation script to run after reboot
CONT_SH="${STATE_DIR}/continue.sh"
sudo tee "$CONT_SH" >/dev/null <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail

LOG="/var/log/lt4c_bazzite_setup.log"
step(){ echo -e "\n[STEP] $*" | tee -a "$LOG"; }
ok(){ echo -e "[OK] $*" | tee -a "$LOG"; }
warn(){ echo -e "[WARN] $*" | tee -a "$LOG"; }

USER_NAME="${USER_NAME:-lt4c}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
USER_UID="$(id -u "$USER_NAME")"
USER_GID="$(id -g "$USER_NAME")"
VNC_PASS="${VNC_PASS:-lt4c}"
GEOM="${GEOM:-1280x720}"
VNC_DISPLAY="${VNC_DISPLAY:-0}"
XRDP_COLOR_BPP="${XRDP_COLOR_BPP:-32}"
INSTALL_HEROIC="${INSTALL_HEROIC:-1}"

# ---- Enable/Start XRDP ----
step "Enable and start XRDP"
sudo systemctl enable --now xrdp

# Configure XRDP color depth 32-bit
if [ -f /etc/xrdp/xrdp.ini ]; then
  sudo sed -i "s/^max_bpp=.*/max_bpp=${XRDP_COLOR_BPP}/" /etc/xrdp/xrdp.ini || true
  grep -q "^max_bpp=${XRDP_COLOR_BPP}" /etc/xrdp/xrdp.ini || echo "max_bpp=${XRDP_COLOR_BPP}" | sudo tee -a /etc/xrdp/xrdp.ini >/dev/null
  sudo systemctl restart xrdp
fi

# Use KDE Plasma X11 session by default (Bazzite is KDE-based)
if [ -f /etc/xrdp/startwm.sh ]; then
  sudo tee /etc/xrdp/startwm.sh >/dev/null <<'EOWM'
#!/bin/sh
export DESKTOP_SESSION=plasma
exec /usr/bin/startplasma-x11
EOWM
  sudo chmod +x /etc/xrdp/startwm.sh
fi

# ---- Configure TigerVNC as system service on :$VNC_DISPLAY ----
step "Configure TigerVNC service :$VNC_DISPLAY"
sudo install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" "$USER_HOME/.vnc"
sudo -u "$USER_NAME" /bin/bash -lc "printf '%s\n' \"$VNC_PASS\" | vncpasswd -f > ~/.vnc/passwd"
sudo chown "$USER_NAME:$USER_NAME" "$USER_HOME/.vnc/passwd"
sudo chmod 0600 "$USER_HOME/.vnc/passwd"

# xstartup uses KDE Plasma
sudo tee "$USER_HOME/.vnc/xstartup" >/dev/null <<'EOX'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec /usr/bin/startplasma-x11
EOX
sudo chown "$USER_NAME:$USER_NAME" "$USER_HOME/.vnc/xstartup"
sudo chmod +x "$USER_HOME/.vnc/xstartup"

sudo tee /etc/systemd/system/vncserver@.service >/dev/null <<EOSVC
[Unit]
Description=TigerVNC server on display :%i (user ${USER_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER_NAME}
ExecStart=/usr/bin/vncserver -fg -localhost no -geometry ${GEOM} :%i
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOSVC

sudo systemctl daemon-reload
sudo systemctl enable --now "vncserver@${VNC_DISPLAY}"

# ---- Open firewall ports if firewalld exists ----
if command -v firewall-cmd >/dev/null 2>&1; then
  step "Opening firewall ports (RDP 3389, VNC 5900)"
  sudo firewall-cmd --add-service=rdp --permanent || true
  sudo firewall-cmd --add-port=5900/tcp --permanent || true
  sudo firewall-cmd --reload || true
fi

# ---- Flatpak apps (Steam, Chromium, Sunshine, optional Heroic) ----
step "Install Flatpak apps (Steam, Chromium, Sunshine)"
if ! flatpak remotes | grep -qi flathub; then
  sudo -u "$USER_NAME" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
fi

sudo -u "$USER_NAME" flatpak install -y flathub \
  com.valvesoftware.Steam \
  org.chromium.Chromium \
  dev.lizardbyte.sunshine || true

if [ "${INSTALL_HEROIC}" = "1" ]; then
  sudo -u "$USER_NAME" flatpak install -y flathub com.heroicgameslauncher.hgl || true
fi

# ---- Sunshine config + autostart ----
step "Configure Sunshine apps and autostart"
SUN_DIR="$USER_HOME/.config/sunshine"
sudo -u "$USER_NAME" install -d -m 0755 "$SUN_DIR"
sudo tee "$SUN_DIR/apps.json" >/dev/null <<EOJS
{
  "apps": [
    { "name": "Steam",    "cmd": ["/usr/bin/flatpak","run","com.valvesoftware.Steam"], "working_dir": "$USER_HOME", "auto_detect": false },
    { "name": "Chromium", "cmd": ["/usr/bin/flatpak","run","org.chromium.Chromium"],   "working_dir": "$USER_HOME", "auto_detect": false }
  ]
}
EOJS
sudo chown -R "$USER_NAME:$USER_NAME" "$SUN_DIR"

# Autostart Sunshine on login
AUTOSTART_DIR="$USER_HOME/.config/autostart"
sudo -u "$USER_NAME" install -d -m 0755 "$AUTOSTART_DIR"
sudo tee "$AUTOSTART_DIR/sunshine.desktop" >/dev/null <<'EOD'
[Desktop Entry]
Type=Application
Name=Sunshine
Exec=flatpak run dev.lizardbyte.sunshine
X-GNOME-Autostart-enabled=true
X-KDE-autostart-after=panel
EOD
sudo chown "$USER_NAME:$USER_NAME" "$AUTOSTART_DIR/sunshine.desktop"

# ---- Desktop shortcuts ----
step "Create Desktop shortcuts"
DESK="$USER_HOME/Desktop"
sudo -u "$USER_NAME" install -d -m 0755 "$DESK"

sudo tee "$DESK/Steam.desktop" >/dev/null <<'EOD1'
[Desktop Entry]
Type=Application
Name=Steam (Flatpak)
Exec=flatpak run com.valvesoftware.Steam
Icon=steam
Terminal=false
EOD1

sudo tee "$DESK/Chromium.desktop" >/dev/null <<'EOD2'
[Desktop Entry]
Type=Application
Name=Chromium (Flatpak)
Exec=flatpak run org.chromium.Chromium
Icon=chromium
Terminal=false
EOD2

sudo tee "$DESK/Sunshine Web UI.desktop" >/dev/null <<'EOD3'
[Desktop Entry]
Type=Application
Name=Sunshine Web UI
Exec=xdg-open http://localhost:47990
Icon=applications-internet
Terminal=false
EOD3

sudo chown "$USER_NAME:$USER_NAME" "$DESK"/*.desktop
sudo chmod +x "$DESK"/*.desktop

# ---- Network tuning ----
echo 'net.ipv4.tcp_low_latency = 1' | sudo tee /etc/sysctl.d/90-remote-desktop.conf >/dev/null
sudo sysctl --system >/dev/null || true


# ---- Sunshine Flatpak auto-fix for iOS (symlink + permissions) ----
step "Apply Flatpak Sunshine iOS connectivity fix"
# Ensure config directory for Flatpak
FLATPAK_SUN_DIR="$USER_HOME/.var/app/dev.lizardbyte.sunshine/config"
sudo -u "$USER_NAME" install -d -m 0755 "$FLATPAK_SUN_DIR"
if [ ! -e "$FLATPAK_SUN_DIR/sunshine" ]; then
  sudo -u "$USER_NAME" ln -s "$USER_HOME/.config/sunshine" "$FLATPAK_SUN_DIR/sunshine" || true
fi

# Grant Flatpak Sunshine access to home dir
flatpak override --user dev.lizardbyte.sunshine --filesystem=home || true

# ---- Print connection info ----
IP="$(hostname -I | awk '{print $1}')"
echo "---------------------------------------------"
echo "XRDP     : ${IP}:3389 (user ${USER_NAME})"
echo "TigerVNC : ${IP}:5900 (VNC pass set)"
echo "Sunshine : http://${IP}:47990 (Flatpak)"
echo "Desktop  : Steam, Chromium, Sunshine Web UI shortcuts created"
echo "---------------------------------------------"
ok "Post-reboot configuration completed."
EOS

sudo chmod +x "$CONT_SH"

# Create a one-shot systemd unit to run the continuation after reboot
POST_UNIT="/etc/systemd/system/lt4c-postreboot.service"
sudo tee "$POST_UNIT" >/dev/null <<EOF
[Unit]
Description=LT4C Bazzite post-reboot continuation
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=USER_NAME=${USER_NAME}
Environment=VNC_PASS=${VNC_PASS}
Environment=GEOM=${GEOM}
Environment=VNC_DISPLAY=${VNC_DISPLAY}
Environment=XRDP_COLOR_BPP=${XRDP_COLOR_BPP}
Environment=INSTALL_HEROIC=${INSTALL_HEROIC}
ExecStart=${CONT_SH}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable lt4c-postreboot.service

# Inform and reboot into the new deployment
step "Rebooting into new deployment to activate NVIDIA drivers and layered packages"
echo "[INFO] The system will reboot now. After reboot, configuration will continue automatically." | tee -a "$LOG"
sudo systemctl reboot

echo ""
echo "============================================================"
echo "✅ To run this installer with default parameters, execute:"
echo ""
echo "  chmod +x lt4c.sh"
echo "  sudo env USER_NAME=lt4c USER_PASS=lt4c VNC_PASS=lt4c \\"
echo "    GEOM=1280x720 XRDP_COLOR_BPP=32 INSTALL_HEROIC=1 \\"
echo "    ./lt4c.sh"
echo ""
echo "You can change USER_NAME, USER_PASS, VNC_PASS, GEOM, XRDP_COLOR_BPP, or INSTALL_HEROIC as needed."
echo "============================================================"

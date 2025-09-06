#!/usr/bin/env bash
set -euo pipefail

# =========================
# LT4C — Ubuntu/Debian RDP+VNC setup
# =========================
# ENV overrideable
USER_NAME="${USER_NAME:-lt4c}"
USER_PASS="${USER_PASS:-lt4c}"
VNC_PASS="${VNC_PASS:-lt4c}"
GEOM="${GEOM:-1280x720}"
XRDP_COLOR_BPP="${XRDP_COLOR_BPP:-32}"   # 24 hoặc 32
DISPLAY_NUM="${DISPLAY_NUM:-1}"          # VNC :1 -> TCP 5901

LOGDIR="/srv/lab"
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGDIR/lt4c_install_$(date +%Y%m%d_%H%M%S).log") 2>&1

echo "[INFO] Starting setup on $(lsb_release -ds || echo Unknown Distro) ..."
echo "[INFO] User=${USER_NAME} GEOM=${GEOM} XRDP_BPP=${XRDP_COLOR_BPP} VNC_DISPLAY=:${DISPLAY_NUM}"

# --- Sanity checks
if ! command -v apt >/dev/null 2>&1; then
  echo "[ERROR] This script targets Ubuntu/Debian (apt required). Aborting."
  exit 1
fi

# --- Create user if missing
if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
  echo "[INFO] Creating user ${USER_NAME}"
  useradd -m -s /bin/bash "${USER_NAME}"
  echo "${USER_NAME}:${USER_PASS}" | chpasswd
  usermod -aG sudo "${USER_NAME}" || true
else
  echo "[INFO] User ${USER_NAME} already exists"
fi

# --- Base packages
echo "[STEP] apt update/upgrade + install packages"
export DEBIAN_FRONTEND=noninteractive
apt update
apt -y upgrade

# Desktop (lightweight) + RDP/VNC
apt -y install xfce4 xfce4-goodies xrdp xorgxrdp tigervnc-standalone-server tigervnc-common dbus-x11 x11-xserver-utils

# Optional helpers
apt -y install curl wget net-tools htop unzip

# Try Chromium (Ubuntu/Debian different pkg names)
apt -y install chromium-browser || apt -y install chromium || true
# Try Steam if available (may require multiverse/non-free; ignore failure)
apt -y install steam || apt -y install steam-installer || true

# --- XRDP config
echo "[STEP] Configure XRDP"
systemctl enable --now xrdp

# Force bpp
XRDP_INI="/etc/xrdp/xrdp.ini"
if [ -f "$XRDP_INI" ]; then
  sed -i "s/^max_bpp=.*/max_bpp=${XRDP_COLOR_BPP}/" "$XRDP_INI" || true
  sed -i "s/^#max_bpp=.*/max_bpp=${XRDP_COLOR_BPP}/" "$XRDP_INI" || true
fi

# Use Xorg backend (default on modern xrdp)
# Ensure XFCE session for the user logging in through RDP
echo "startxfce4" | tee "/home/${USER_NAME}/.xsession" >/dev/null
chown "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.xsession"

# --- TigerVNC config per-user
echo "[STEP] Configure TigerVNC for ${USER_NAME}"
VNC_HOME="/home/${USER_NAME}/.vnc"
mkdir -p "$VNC_HOME"
chown -R "${USER_NAME}:${USER_NAME}" "$VNC_HOME"

# Set VNC password non-interactively
# vncpasswd -f outputs hashed password suitable for storing
su - "${USER_NAME}" -c "printf '%s\n' '${VNC_PASS}' | vncpasswd -f > '${VNC_HOME}/passwd'"
chmod 600 "${VNC_HOME}/passwd"

# xstartup for XFCE
cat > "${VNC_HOME}/xstartup" <<"EOF"
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11
export DESKTOP_SESSION=xfce
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
xrdb $HOME/.Xresources
startxfce4 &
EOF
chmod +x "${VNC_HOME}/xstartup"
chown -R "${USER_NAME}:${USER_NAME}" "$VNC_HOME"

# --- systemd service for VNC :DISPLAY_NUM
echo "[STEP] Install systemd service for VNC"
cat > /etc/systemd/system/vncserver@.service <<EOF
[Unit]
Description=TigerVNC server for %i
After=network.target

[Service]
Type=forking
User=%i
PAMName=login
PIDFile=/home/%i/.vnc/%H:${DISPLAY_NUM}.pid
ExecStartPre=-/usr/bin/vncserver -kill :${DISPLAY_NUM} > /dev/null 2>&1
ExecStart=/usr/bin/vncserver -localhost no -geometry ${GEOM} :${DISPLAY_NUM}
ExecStop=/usr/bin/vncserver -kill :${DISPLAY_NUM}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "vncserver@${USER_NAME}.service"
systemctl restart "vncserver@${USER_NAME}.service"

# --- UFW firewall (if present)
if command -v ufw >/dev/null 2>&1; then
  echo "[STEP] Configure UFW (22,3389,5900-5905)"
  ufw allow 22/tcp || true
  ufw allow 3389/tcp || true
  ufw allow 5900:5905/tcp || true
  # auto-enable only if inactive (be careful on remote servers)
  ufw status | grep -q "inactive" && ufw --force enable || true
else
  echo "[INFO] UFW not installed. Skipping firewall setup."
fi

# --- Desktop icons (Chromium/Steam if present)
DESKTOP_DIR="/home/${USER_NAME}/Desktop"
mkdir -p "$DESKTOP_DIR"
chown -R "${USER_NAME}:${USER_NAME}" "$DESKTOP_DIR"

# Chromium desktop file
if command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1; then
  cat > "${DESKTOP_DIR}/Chromium.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Chromium
Exec=chromium %U
Terminal=false
Categories=Network;WebBrowser;
Icon=chromium
EOF
  chmod +x "${DESKTOP_DIR}/Chromium.desktop"
fi

# Steam desktop file
if command -v steam >/dev/null 2>&1; then
  cat > "${DESKTOP_DIR}/Steam.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Steam
Exec=steam
Terminal=false
Categories=Game;
Icon=steam
EOF
  chmod +x "${DESKTOP_DIR}/Steam.desktop"
fi

# --- Quick diagnostics
echo "[CHECK] netstat ports"
(netstat -tulpn || ss -tulpn || true) | tee -a "$LOGDIR/ports.txt" || true

echo "[CHECK] xrdp status"
systemctl status xrdp --no-pager || true

echo "[CHECK] vncserver status"
systemctl status "vncserver@${USER_NAME}.service" --no-pager || true

echo "[INFO] Done."
echo "[INFO] RDP: connect to <IP>:3389 (user: ${USER_NAME})"
echo "[INFO] VNC: connect to <IP>:$((5900 + DISPLAY_NUM)) (display :${DISPLAY_NUM}), password set."
echo "[INFO] Logs at ${LOGDIR}"

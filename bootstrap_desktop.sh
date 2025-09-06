#!/usr/bin/env bash
set -euo pipefail

# ==== Default config (có thể override bằng ENV khi start) ====
VNC_PASS_DEFAULT="${VNC_PASS:-lt4c}"
GEOM_DEFAULT="${GEOM:-1280x720}"
DISPLAY_NUM_DEFAULT="${DISPLAY_NUM:-1}"     # VNC :1 -> TCP 5901
NOVNC_PORT_DEFAULT="${NOVNC_PORT:-8080}"    # noVNC web port
# ============================================================

echo "[STEP] Update & install packages"
export DEBIAN_FRONTEND=noninteractive
apt update
apt -y install xfce4 xfce4-goodies tigervnc-standalone-server novnc websockify dbus-x11 x11-xserver-utils curl wget chromium-browser || true

# Prepare VNC dir
VNC_DIR="${HOME}/.vnc"
mkdir -p "${VNC_DIR}"
chmod 700 "${VNC_DIR}"

echo "[STEP] Set VNC password (non-interactive)"
printf '%s\n' "${VNC_PASS_DEFAULT}" | vncpasswd -f > "${VNC_DIR}/passwd"
chmod 600 "${VNC_DIR}/passwd"

echo "[STEP] Create xstartup for Xfce"
cat > "${VNC_DIR}/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11
export DESKTOP_SESSION=xfce
export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
xrdb "$HOME/.Xresources"
startxfce4 &
EOF
chmod +x "${VNC_DIR}/xstartup"

# --- Create helpers for desktop ---
cat > /usr/local/bin/start-desktop.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
VNC_PASS="${VNC_PASS:-lt4c}"
GEOM="${GEOM:-1280x720}"
DISPLAY_NUM="${DISPLAY_NUM:-1}"
NOVNC_PORT="${NOVNC_PORT:-8080}"

export DISPLAY=":${DISPLAY_NUM}"
VNC_PORT=$((5900 + DISPLAY_NUM))

if ! pgrep -x dbus-daemon >/dev/null 2>&1; then
  dbus-daemon --system --fork || true
fi

printf '%s\n' "${VNC_PASS}" | vncpasswd -f > "${HOME}/.vnc/passwd"
chmod 600 "${HOME}/.vnc/passwd"

vncserver -kill "${DISPLAY}" >/dev/null 2>&1 || true
if [ -f /tmp/novnc.pid ]; then
  kill "$(cat /tmp/novnc.pid)" >/dev/null 2>&1 || true
  rm -f /tmp/novnc.pid
fi

echo "[STEP] Starting VNC server at ${DISPLAY} (TCP ${VNC_PORT}) geometry ${GEOM}"
vncserver "${DISPLAY}" -geometry "${GEOM}" -depth 24

echo "[STEP] Starting noVNC on :${NOVNC_PORT} -> localhost:${VNC_PORT}"
websockify --web=/usr/share/novnc "${NOVNC_PORT}" "localhost:${VNC_PORT}" >/tmp/novnc.log 2>&1 &
echo $! > /tmp/novnc.pid

cat <<MSG

======================================================
✅ Xfce Desktop via noVNC is running.

Open in your browser:
  http://<JUPYTER_HOST>:${NOVNC_PORT}/vnc.html

VNC password: ${VNC_PASS}
VNC direct port (optional): ${VNC_PORT}
Display: ${DISPLAY}
Geometry: ${GEOM}

To stop:
  stop-desktop.sh
======================================================
MSG
EOF
chmod +x /usr/local/bin/start-desktop.sh

cat > /usr/local/bin/stop-desktop.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DISPLAY_NUM="${DISPLAY_NUM:-1}"
DISPLAY=":${DISPLAY_NUM}"

echo "[STEP] Stopping noVNC (if any)"
if [ -f /tmp/novnc.pid ]; then
  kill "$(cat /tmp/novnc.pid)" >/dev/null 2>&1 || true
  rm -f /tmp/novnc.pid
fi

echo "[STEP] Stopping VNC server ${DISPLAY}"
vncserver -kill "${DISPLAY}" >/dev/null 2>&1 || true

echo "✅ Stopped."
EOF
chmod +x /usr/local/bin/stop-desktop.sh

# Save defaults
echo "${VNC_PASS_DEFAULT}" > /tmp/.vnc_pass_default
echo "${GEOM_DEFAULT}" > /tmp/.geom_default
echo "${DISPLAY_NUM_DEFAULT}" > /tmp/.display_default
echo "${NOVNC_PORT_DEFAULT}" > /tmp/.novnc_port_default

cat > /usr/local/bin/start-desktop-defaults.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export VNC_PASS="$(cat /tmp/.vnc_pass_default 2>/dev/null || echo lt4c)"
export GEOM="$(cat /tmp/.geom_default 2>/dev/null || echo 1280x720)"
export DISPLAY_NUM="$(cat /tmp/.display_default 2>/dev/null || echo 1)"
export NOVNC_PORT="$(cat /tmp/.novnc_port_default 2>/dev/null || echo 8080)"
exec /usr/local/bin/start-desktop.sh
EOF
chmod +x /usr/local/bin/start-desktop-defaults.sh

# --- Sunshine install ---
echo "[STEP] Install Sunshine (remote play)"
SUNSHINE_DEB="sunshine-ubuntu-22.04-amd64.deb"
SUNSHINE_URL="https://github.com/LizardByte/Sunshine/releases/download/v2025.628.4510/${SUNSHINE_DEB}"

wget -O "/tmp/${SUNSHINE_DEB}" "${SUNSHINE_URL}" || true
if [ -f "/tmp/${SUNSHINE_DEB}" ]; then
  apt -y install libopus0 libva-drm2 libva2 libvdpau1 || true
  dpkg -i "/tmp/${SUNSHINE_DEB}" || apt -f install -y
else
  echo "[WARN] Could not download Sunshine .deb"
fi

mkdir -p "$HOME/.config/sunshine"
touch "$HOME/.config/sunshine/apps.json"

cat > /usr/local/bin/start-sunshine.sh <<'EOF'
#!/usr/bin/env bash
echo "[INFO] Starting Sunshine..."
sunshine >/tmp/sunshine.log 2>&1 &
echo $! > /tmp/sunshine.pid
echo "✅ Sunshine started. WebUI: http://<HOST>:47990"
EOF
chmod +x /usr/local/bin/start-sunshine.sh

cat > /usr/local/bin/stop-sunshine.sh <<'EOF'
#!/usr/bin/env bash
if [ -f /tmp/sunshine.pid ]; then
  kill "$(cat /tmp/sunshine.pid)" >/dev/null 2>&1 || true
  rm -f /tmp/sunshine.pid
  echo "✅ Sunshine stopped."
else
  echo "[INFO] Sunshine not running."
fi
EOF
chmod +x /usr/local/bin/stop-sunshine.sh

# --- Desktop icons ---
DESK="$HOME/Desktop"
mkdir -p "$DESK"

cat > "$DESK/Chromium.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Chromium
Exec=chromium %U
Terminal=false
Categories=Network;WebBrowser;
Icon=chromium
EOF
chmod +x "$DESK/Chromium.desktop"

cat > "$DESK/Sunshine.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Sunshine WebUI
Exec=xdg-open http://localhost:47990/
Terminal=false
Categories=Network;Utility;
Icon=applications-internet
EOF
chmod +x "$DESK/Sunshine.desktop"

echo
echo "====================================================="
echo "✅ Setup complete!"
echo "Start desktop with: start-desktop-defaults.sh"
echo "Stop desktop with:  stop-desktop.sh"
echo
echo "Start Sunshine with: start-sunshine.sh"
echo "Stop Sunshine with:  stop-sunshine.sh"
echo
echo "Chromium + Sunshine icons created on Desktop."
echo "====================================================="

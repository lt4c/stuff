#!/usr/bin/env bash
set -euo pipefail

# ==== Default config ====
VNC_PASS_DEFAULT="${VNC_PASS:-lt4c}"
GEOM_DEFAULT="${GEOM:-1280x720}"
DISPLAY_NUM_DEFAULT="${DISPLAY_NUM:-1}"     # VNC :1 -> TCP 5901
# =========================

echo "[STEP] Update & install packages"
export DEBIAN_FRONTEND=noninteractive
apt update
apt -y install xfce4 xfce4-goodies tigervnc-standalone-server dbus-x11 x11-xserver-utils xterm xrdp xorgxrdp curl wget chromium-browser || true

# --- Prepare DBus runtime (no systemd) ---
mkdir -p /run/dbus
chmod 755 /run/dbus || true

# --- Prepare VNC ---
VNC_DIR="${HOME}/.vnc"
mkdir -p "${VNC_DIR}"
chmod 700 "${VNC_DIR}"

printf '%s\n' "${VNC_PASS_DEFAULT}" | vncpasswd -f > "${VNC_DIR}/passwd"
chmod 600 "${VNC_DIR}/passwd"

cat > "${VNC_DIR}/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11
export DISPLAY=${DISPLAY:-:1}
[ -r "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources"
# launch session-bus (not system bus)
if command -v dbus-launch >/dev/null 2>&1; then
  eval "$(dbus-launch --sh-syntax)"
fi
exec startxfce4
EOF
chmod +x "${VNC_DIR}/xstartup"

# --- XFCE for RDP ---
echo "startxfce4" > ~/.xsession
chmod +x ~/.xsession

# --- Create start/stop scripts ---

# Start VNC (prints container/public IPs)
tee /usr/local/bin/start-vnc.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
VNC_PASS="${VNC_PASS:-lt4c}"
GEOM="${GEOM:-1280x720}"
DISPLAY_NUM="${DISPLAY_NUM:-1}"
export DISPLAY=":${DISPLAY_NUM}"

# IP info
CONTAINER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUBLIC_IP="$(curl -s --max-time 2 ifconfig.me || echo 'N/A')"
VNC_PORT=$((5900 + DISPLAY_NUM))

# Ensure DBus session possible
mkdir -p /run/dbus && chmod 755 /run/dbus || true
if ! pgrep -x dbus-daemon >/dev/null 2>&1; then
  dbus-daemon --system --fork || true
fi

printf '%s\n' "${VNC_PASS}" | vncpasswd -f > "${HOME}/.vnc/passwd"
chmod 600 "${HOME}/.vnc/passwd"

vncserver -kill "${DISPLAY}" >/dev/null 2>&1 || true
echo "[INFO] Starting VNC server ${DISPLAY} (port ${VNC_PORT}) geometry ${GEOM}"
vncserver "${DISPLAY}" -geometry "${GEOM}" -depth 24

cat <<MSG

✅ VNC is running.

Connect with a VNC client:
  - Same network (container bridge): ${CONTAINER_IP}:${VNC_PORT}
  - Via published port on host:       <HOST_IP>:${VNC_PORT}
  - Public IP (if routed):            ${PUBLIC_IP}:${VNC_PORT}

VNC password: ${VNC_PASS}
Display: ${DISPLAY}
Geometry: ${GEOM}

Note: If this is a Docker container, ensure you published the port:
  docker run -p ${VNC_PORT}:${VNC_PORT} ...
MSG
EOF
chmod +x /usr/local/bin/start-vnc.sh

# Stop VNC
tee /usr/local/bin/stop-vnc.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DISPLAY_NUM="${DISPLAY_NUM:-1}"
DISPLAY=":${DISPLAY_NUM}"
echo "[INFO] Stopping VNC server ${DISPLAY}"
vncserver -kill "${DISPLAY}" >/dev/null 2>&1 || true
echo "✅ VNC stopped."
EOF
chmod +x /usr/local/bin/stop-vnc.sh

# Start RDP (prints container/public IPs)
tee /usr/local/bin/start-rdp.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Ensure DBus runtime (no systemd)
mkdir -p /run/dbus && chmod 755 /run/dbus || true
if ! pgrep -x dbus-daemon >/dev/null 2>&1; then
  dbus-daemon --system --fork || true
fi

# Restart XRDP processes cleanly
pkill -f xrdp        >/dev/null 2>&1 || true
pkill -f xrdp-sesman >/dev/null 2>&1 || true

/usr/sbin/xrdp-sesman &
sleep 1
/usr/sbin/xrdp &

# IP info
CONTAINER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUBLIC_IP="$(curl -s --max-time 2 ifconfig.me || echo 'N/A')"
RDP_PORT=3389

cat <<MSG

✅ XRDP is running on port ${RDP_PORT}.

Connect with Windows Remote Desktop (mstsc):
  - Same network (container bridge): ${CONTAINER_IP}:${RDP_PORT}
  - Via published port on host:       <HOST_IP>:${RDP_PORT}
  - Public IP (if routed):            ${PUBLIC_IP}:${RDP_PORT}

Login with your container user (e.g., root) & its password.

Note: If this is a Docker container, ensure you published the port:
  docker run -p ${RDP_PORT}:${RDP_PORT} ...
MSG
EOF
chmod +x /usr/local/bin/start-rdp.sh

# Stop RDP
tee /usr/local/bin/stop-rdp.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
pkill -f xrdp        >/dev/null 2>&1 || true
pkill -f xrdp-sesman >/dev/null 2>&1 || true
echo "✅ XRDP stopped"
EOF
chmod +x /usr/local/bin/stop-rdp.sh

# --- Desktop icon (Chromium, optional) ---
DESK="$HOME/Desktop"
mkdir -p "$DESK"
tee "$DESK/Chromium.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=Chromium
Exec=chromium %U
Terminal=false
Categories=Network;WebBrowser;
Icon=chromium
EOF
chmod +x "$DESK/Chromium.desktop"

# --- Save defaults (for convenience if you create wrappers later) ---
echo "${VNC_PASS_DEFAULT}"    > /tmp/.vnc_pass_default
echo "${GEOM_DEFAULT}"        > /tmp/.geom_default
echo "${DISPLAY_NUM_DEFAULT}" > /tmp/.display_default

echo
echo "====================================================="
echo "✅ Setup complete!"
echo "VNC:"
echo "   start-vnc.sh   (connect to port 5901 by default, pass=${VNC_PASS_DEFAULT})"
echo "   stop-vnc.sh"
echo
echo "RDP:"
echo "   start-rdp.sh   (connect with mstsc to port 3389, login with container user)"
echo "   stop-rdp.sh"
echo
echo "Remember to publish ports from container if needed:"
echo "   docker run -p 5901:5901 -p 3389:3389 ..."
echo "====================================================="

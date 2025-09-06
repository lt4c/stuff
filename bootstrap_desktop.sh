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

# Start VNC
cat > /usr/local/bin/start-vnc.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
VNC_PASS="${VNC_PASS:-lt4c}"
GEOM="${GEOM:-1280x720}"
DISPLAY_NUM="${DISPLAY_NUM:-1}"
export DISPLAY=":${DISPLAY_NUM}"

printf '%s\n' "${VNC_PASS}" | vncpasswd -f > "${HOME}/.vnc/passwd"
chmod 600 "${HOME}/.vnc/passwd"

vncserver -kill "${DISPLAY}" >/dev/null 2>&1 || true
echo "[INFO] Starting VNC server ${DISPLAY} (port $((5900+DISPLAY_NUM))) geometry ${GEOM}"
vncserver "${DISPLAY}" -geometry "${GEOM}" -depth 24
echo "✅ VNC running. Connect to <HOST>:$((5900+DISPLAY_NUM)), password=${VNC_PASS}"
EOF
chmod +x /usr/local/bin/start-vnc.sh

# Stop VNC
cat > /usr/local/bin/stop-vnc.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DISPLAY_NUM="${DISPLAY_NUM:-1}"
DISPLAY=":${DISPLAY_NUM}"
echo "[INFO] Stopping VNC server ${DISPLAY}"
vncserver -kill "${DISPLAY}" >/dev/null 2>&1 || true
echo "✅ VNC stopped."
EOF
chmod +x /usr/local/bin/stop-vnc.sh

# Start RDP
cat > /usr/local/bin/start-rdp.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if ! pgrep -x dbus-daemon >/dev/null 2>&1; then
  dbus-daemon --system --fork || true
fi
pkill -f xrdp       >/dev/null 2>&1 || true
pkill -f xrdp-sesman>/dev/null 2>&1 || true
/usr/sbin/xrdp-sesman &
sleep 1
/usr/sbin/xrdp &
echo "✅ XRDP started on port 3389. Use mstsc to connect."
EOF
chmod +x /usr/local/bin/start-rdp.sh

# Stop RDP
cat > /usr/local/bin/stop-rdp.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
pkill -f xrdp        >/dev/null 2>&1 || true
pkill -f xrdp-sesman >/dev/null 2>&1 || true
echo "✅ XRDP stopped"
EOF
chmod +x /usr/local/bin/stop-rdp.sh

# --- Desktop icons (Chromium) ---
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

echo
echo "====================================================="
echo "✅ Setup complete!"
echo "VNC:"
echo "   start-vnc.sh   (connect with any VNC client to port 5901, pass=lt4c)"
echo "   stop-vnc.sh"
echo
echo "RDP:"
echo "   start-rdp.sh   (connect with mstsc to port 3389, login with container user)"
echo "   stop-rdp.sh"
echo "====================================================="

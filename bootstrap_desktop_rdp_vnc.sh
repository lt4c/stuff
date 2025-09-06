cat > bootstrap_desktop_rdp_vnc.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ==== Default config (có thể override qua ENV khi start-vnc.sh) ====
VNC_PASS_DEFAULT="${VNC_PASS:-lt4c}"
GEOM_DEFAULT="${GEOM:-1280x720}"
DISPLAY_NUM_DEFAULT="${DISPLAY_NUM:-1}"     # VNC :1 -> TCP 5901
# ===================================================================

echo "[STEP] Update & install packages"
export DEBIAN_FRONTEND=noninteractive
apt update
apt -y install xfce4 xfce4-goodies tigervnc-standalone-server dbus-x11 x11-xserver-utils xterm xrdp xorgxrdp net-tools curl wget chromium-browser || true

# --- Ensure login user for RDP ---
if id -u lt4c >/dev/null 2>&1; then
  echo "lt4c:lt4c" | chpasswd
else
  useradd -m -s /bin/bash lt4c || true
  echo "lt4c:lt4c" | chpasswd
fi
echo "[INFO] User 'lt4c' ready (password: lt4c)"

# --- Prepare DBus runtime (no systemd) ---
mkdir -p /run/dbus
chmod 755 /run/dbus || true

# --- Allow Xorg in container (Xwrapper) ---
if [ -f /etc/X11/Xwrapper.config ]; then
  sed -i 's/^allowed_users=.*/allowed_users=anybody/' /etc/X11/Xwrapper.config || true
else
  printf "allowed_users=anybody\nneeds_root_rights=yes\n" > /etc/X11/Xwrapper.config
fi

# --- Prepare VNC (password + xstartup) ---
VNC_DIR="${HOME}/.vnc"
mkdir -p "${VNC_DIR}"
chmod 700 "${VNC_DIR}"
printf '%s\n' "${VNC_PASS_DEFAULT}" | vncpasswd -f > "${VNC_DIR}/passwd"
chmod 600 "${VNC_DIR}/passwd"

cat > "${VNC_DIR}/xstartup" <<'XEOF'
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
XEOF
chmod +x "${VNC_DIR}/xstartup"

# --- XFCE session for RDP ---
echo "startxfce4" > ~/.xsession
chmod +x ~/.xsession

# ================== Helper scripts ==================

# Start VNC (bind public; -localhost no)
tee /usr/local/bin/start-vnc.sh >/dev/null <<'XEOF'
#!/usr/bin/env bash
set -euo pipefail
VNC_PASS="${VNC_PASS:-lt4c}"
GEOM="${GEOM:-1280x720}"
DISPLAY_NUM="${DISPLAY_NUM:-1}"
export DISPLAY=":${DISPLAY_NUM}"

CONTAINER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUBLIC_IP="$(curl -s --max-time 2 ifconfig.me || echo 'N/A')"
VNC_PORT=$((5900 + DISPLAY_NUM))

mkdir -p /run/dbus && chmod 755 /run/dbus || true
pgrep -x dbus-daemon >/dev/null 2>&1 || dbus-daemon --system --fork || true

printf '%s\n' "${VNC_PASS}" | vncpasswd -f > "${HOME}/.vnc/passwd"
chmod 600 "${HOME}/.vnc/passwd"

# Clean stale locks, then start with -localhost no
vncserver -kill "${DISPLAY}" >/dev/null 2>&1 || true
rm -rf /tmp/.X11-unix /tmp/.X${DISPLAY_NUM}-lock || true
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

echo "[INFO] Starting VNC server ${DISPLAY} (port ${VNC_PORT}) geometry ${GEOM} -localhost no"
vncserver "${DISPLAY}" -geometry "${GEOM}" -depth 24 -localhost no

cat <<MSG

✅ VNC is running.

Connect with a VNC client:
  - Same network (container bridge): ${CONTAINER_IP}:${VNC_PORT}
  - Via published port on host:       <HOST_IP>:${VNC_PORT}
  - Public IP (if routed):            ${PUBLIC_IP}:${VNC_PORT}

VNC password: ${VNC_PASS}
Display: ${DISPLAY}
Geometry: ${GEOM}
MSG
XEOF
chmod +x /usr/local/bin/start-vnc.sh

# Stop VNC
tee /usr/local/bin/stop-vnc.sh >/dev/null <<'XEOF'
#!/usr/bin/env bash
set -euo pipefail
DISPLAY_NUM="${DISPLAY_NUM:-1}"
DISPLAY=":${DISPLAY_NUM}"
echo "[INFO] Stopping VNC server ${DISPLAY}"
vncserver -kill "${DISPLAY}" >/dev/null 2>&1 || true
echo "✅ VNC stopped."
XEOF
chmod +x /usr/local/bin/stop-vnc.sh

# Start RDP
tee /usr/local/bin/start-rdp.sh >/dev/null <<'XEOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p /run/dbus && chmod 755 /run/dbus || true
pgrep -x dbus-daemon >/dev/null 2>&1 || dbus-daemon --system --fork || true

pkill -f xrdp        >/dev/null 2>&1 || true
pkill -f xrdp-sesman >/dev/null 2>&1 || true
/usr/sbin/xrdp-sesman &
sleep 1
/usr/sbin/xrdp &

CONTAINER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUBLIC_IP="$(curl -s --max-time 2 ifconfig.me || echo 'N/A')"
RDP_PORT=3389

cat <<MSG

✅ XRDP is running on port ${RDP_PORT}.

Connect with Windows Remote Desktop (mstsc):
  - Same network (container bridge): ${CONTAINER_IP}:${RDP_PORT}
  - Via published port on host:       <HOST_IP>:${RDP_PORT}
  - Public IP (if routed):            ${PUBLIC_IP}:${RDP_PORT}

Login example:
  user: lt4c
  pass: lt4c
MSG
XEOF
chmod +x /usr/local/bin/start-rdp.sh

# Stop RDP
tee /usr/local/bin/stop-rdp.sh >/dev/null <<'XEOF'
#!/usr/bin/env bash
set -euo pipefail
pkill -f xrdp        >/dev/null 2>&1 || true
pkill -f xrdp-sesman >/dev/null 2>&1 || true
echo "✅ XRDP stopped"
XEOF
chmod +x /usr/local/bin/stop-rdp.sh

# Diagnostic & auto-fix on demand
tee /usr/local/bin/fix_rdp_vnc.sh >/dev/null <<'XEOF'
#!/usr/bin/env bash
set -euo pipefail
LOG=/srv/lab
mkdir -p "$LOG"
exec > >(tee -a "$LOG/rdp_vnc_diag_$(date +%Y%m%d_%H%M%S).log") 2>&1

echo "[STEP] IPs"
echo "CONTAINER_IP: $(hostname -I 2>/dev/null | awk '{print $1}')"
echo "PUBLIC_IP:    $(curl -s --max-time 2 ifconfig.me || echo N/A)"

echo "[STEP] Ensure packages"
apt update
apt -y install xfce4 xfce4-goodies tigervnc-standalone-server xrdp xorgxrdp dbus-x11 x11-xserver-utils xterm net-tools curl wget

echo "[STEP] DBus runtime"
mkdir -p /run/dbus && chmod 755 /run/dbus
pgrep -x dbus-daemon >/dev/null 2>&1 || dbus-daemon --system --fork || true

echo "[STEP] Unblock Xorg"
if [ -f /etc/X11/Xwrapper.config ]; then
  sed -i 's/^allowed_users=.*/allowed_users=anybody/' /etc/X11/Xwrapper.config || true
else
  printf "allowed_users=anybody\nneeds_root_rights=yes\n" > /etc/X11/Xwrapper.config
fi

echo "[STEP] VNC config"
mkdir -p ~/.vnc
printf '%s\n' "${VNC_PASS:-lt4c}" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd
cat > ~/.vnc/xstartup <<'EOF2'
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
EOF2
chmod +x ~/.vnc/xstartup

echo "[STEP] RDP XFCE session"
echo "startxfce4" > ~/.xsession && chmod +x ~/.xsession

echo "[STEP] Clean locks"
vncserver -kill :1 >/dev/null 2>&1 || true
rm -rf /tmp/.X11-unix /tmp/.X1-lock || true
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

echo "[STEP] Start VNC (:1 -> 5901) -localhost no"
vncserver :1 -geometry 1280x720 -depth 24 -localhost no

echo "[STEP] Start XRDP"
pkill -f xrdp       >/dev/null 2>&1 || true
pkill -f xrdp-sesman>/dev/null 2>&1 || true
/usr/sbin/xrdp-sesman &
sleep 1
/usr/sbin/xrdp &

echo "[STEP] Listening ports"
(ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | tee "$LOG/ports.txt"

echo "[DONE] Logs:"
echo "  VNC: ~/.vnc/*:1.log"
echo "  XRDP: /var/log/xrdp.log, /var/log/xrdp-sesman.log"
XEOF
chmod +x /usr/local/bin/fix_rdp_vnc.sh

# ================== Autostart & connect info ==================
/usr/local/bin/start-vnc.sh || true
/usr/local/bin/start-rdp.sh || true

CONTAINER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUBLIC_IP="$(curl -s --max-time 2 ifconfig.me || echo 'N/A')"
VNC_PORT="$((5900 + DISPLAY_NUM_DEFAULT))"
RDP_PORT="3389"

echo
echo "================= CONNECT INFO ================="
echo "Container IP : ${CONTAINER_IP}"
echo "Public IP    : ${PUBLIC_IP}"
echo
echo "VNC:"
echo "  Connect to ${CONTAINER_IP}:${VNC_PORT}  (or <HOST_IP>:${VNC_PORT})"
echo "  Password: ${VNC_PASS_DEFAULT}"
echo
echo "RDP:"
echo "  Connect to ${CONTAINER_IP}:${RDP_PORT}  (or <HOST_IP>:${RDP_PORT})"
echo "  Login: lt4c / lt4c   (or your container user/password)"
echo
echo "NOTE (Docker): publish ports when running container:"
echo "  docker run -p ${VNC_PORT}:${VNC_PORT} -p ${RDP_PORT}:${RDP_PORT} <image>"
echo "================================================="
EOF
chmod +x bootstrap_desktop_rdp_vnc.sh

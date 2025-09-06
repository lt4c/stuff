# GHI ĐÈ FILE (bản không Docker, có mở tường lửa)
cat > bootstrap_desktop_rdp_vnc.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ==== Config mặc định (có thể override khi start) ====
VNC_PASS_DEFAULT="${VNC_PASS:-lt4c}"
GEOM_DEFAULT="${GEOM:-1280x720}"
DISPLAY_NUM_DEFAULT="${DISPLAY_NUM:-1}"    # :1 -> 5901
RDP_PORT=3389
# =====================================================

# --- Helper: mở firewall nếu có ---
open_firewall() {
  local PORT="$1"
  # UFW
  if command -v ufw >/dev/null 2>&1; then
    (sudo ufw status | grep -qi inactive) || sudo ufw allow "${PORT}"/tcp || true
  fi
  # firewalld
  if command -v firewall-cmd >/dev/null 2>&1; then
    sudo firewall-cmd --permanent --add-port="${PORT}"/tcp >/dev/null 2>&1 || true
    sudo firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  # iptables (fallback)
  if command -v iptables >/dev/null 2>&1; then
    sudo iptables -C INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || \
    sudo iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT || true
  fi
}

echo "[STEP] Update & install packages"
export DEBIAN_FRONTEND=noninteractive
apt update
apt -y install \
  xfce4 xfce4-goodies \
  tigervnc-standalone-server \
  xrdp xorgxrdp \
  dbus-x11 x11-xserver-utils xterm \
  net-tools curl wget ca-certificates \
  chromium-browser || true

# --- Tạo user đăng nhập RDP (nếu cần) ---
if id -u lt4c >/dev/null 2>&1; then
  echo "lt4c:lt4c" | chpasswd
else
  useradd -m -s /bin/bash lt4c || true
  echo "lt4c:lt4c" | chpasswd
fi
echo "[INFO] User 'lt4c' ready (password: lt4c)"

# --- DBus (no systemd) ---
mkdir -p /run/dbus
chmod 755 /run/dbus || true
pgrep -x dbus-daemon >/dev/null 2>&1 || dbus-daemon --system --fork || true

# --- Cho phép Xorg trong container/host tối giản ---
if [ -f /etc/X11/Xwrapper.config ]; then
  sed -i 's/^allowed_users=.*/allowed_users=anybody/' /etc/X11/Xwrapper.config || true
else
  printf "allowed_users=anybody\nneeds_root_rights=yes\n" > /etc/X11/Xwrapper.config
fi

# --- VNC setup ---
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

# --- XFCE session cho RDP ---
echo "startxfce4" > ~/.xsession
chmod +x ~/.xsession

# ================== Scripts tiện ích ==================

# Start VNC (mở firewall, -localhost no)
tee /usr/local/bin/start-vnc.sh >/dev/null <<'XEOF'
#!/usr/bin/env bash
set -euo pipefail
VNC_PASS="${VNC_PASS:-lt4c}"
GEOM="${GEOM:-1280x720}"
DISPLAY_NUM="${DISPLAY_NUM:-1}"
export DISPLAY=":${DISPLAY_NUM}"
VNC_PORT=$((5900 + DISPLAY_NUM))

# DBus
mkdir -p /run/dbus && chmod 755 /run/dbus || true
pgrep -x dbus-daemon >/dev/null 2>&1 || dbus-daemon --system --fork || true

# Password đảm bảo
printf '%s\n' "${VNC_PASS}" | vncpasswd -f > "${HOME}/.vnc/passwd"
chmod 600 "${HOME}/.vnc/passwd"

# Dọn lock và start (bind public)
vncserver -kill "${DISPLAY}" >/dev/null 2>&1 || true
rm -rf /tmp/.X11-unix /tmp/.X${DISPLAY_NUM}-lock || true
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
vncserver "${DISPLAY}" -geometry "${GEOM}" -depth 24 -localhost no

# Mở firewall
if command -v ufw >/dev/null 2>&1; then
  (ufw status | grep -qi inactive) || ufw allow "${VNC_PORT}"/tcp || true
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${VNC_PORT}"/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport "${VNC_PORT}" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -p tcp --dport "${VNC_PORT}" -j ACCEPT || true
fi

# Thông tin
CONTAINER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUBLIC_IP="$(curl -s --max-time 3 ifconfig.me || echo 'N/A')"
echo "[CHECK] VNC listening:"
(ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep ":${VNC_PORT}" || true
cat <<MSG

✅ VNC is running on port ${VNC_PORT} (display ${DISPLAY}) with -localhost no

Connect:
  - LAN/Internal:  ${CONTAINER_IP}:${VNC_PORT}
  - Public (if open): ${PUBLIC_IP}:${VNC_PORT}
Password: ${VNC_PASS}
Resolution: ${GEOM}
MSG
XEOF
chmod +x /usr/local/bin/start-vnc.sh

# Stop VNC
tee /usr/local/bin/stop-vnc.sh >/dev/null <<'XEOF'
#!/usr/bin/env bash
set -euo pipefail
DISPLAY_NUM="${DISPLAY_NUM:-1}"
vncserver -kill ":${DISPLAY_NUM}" >/dev/null 2>&1 || true
echo "✅ VNC stopped."
XEOF
chmod +x /usr/local/bin/stop-vnc.sh

# Start RDP (mở firewall, đảm bảo PID/log/key)
tee /usr/local/bin/start-rdp.sh >/dev/null <<'XEOF'
#!/usr/bin/env bash
set -euo pipefail
RDP_PORT=3389

# DBus
mkdir -p /run/dbus && chmod 755 /run/dbus || true
pgrep -x dbus-daemon >/dev/null 2>&1 || dbus-daemon --system --fork || true

# Run dirs & perms
mkdir -p /var/run/xrdp /var/log/xrdp
chown xrdp:xrdp /var/run/xrdp 2>/dev/null || true
chown xrdp:adm  /var/log/xrdp 2>/dev/null || true
chmod 755 /var/run/xrdp /var/log/xrdp || true

# RSA keys nếu thiếu
if [ ! -f /etc/xrdp/rsakeys.ini ]; then
  xrdp-keygen xrdp /etc/xrdp/rsakeys.ini || true
  chown xrdp:xrdp /etc/xrdp/rsakeys.ini 2>/dev/null || true
  chmod 600 /etc/xrdp/rsakeys.ini 2>/dev/null || true
fi

# Clean & start
rm -f /var/run/xrdp/xrdp.pid /var/run/xrdp/sesman.pid /var/run/xrdp/xrdp-sesman.pid 2>/dev/null || true
pkill -f xrdp        >/dev/null 2>&1 || true
pkill -f xrdp-sesman >/dev/null 2>&1 || true
/usr/sbin/xrdp-sesman &
sleep 1
/usr/sbin/xrdp --nodaemon &> /var/log/xrdp/xrdp-foreground.log &
sleep 1

# Mở firewall
if command -v ufw >/dev/null 2>&1; then
  (ufw status | grep -qi inactive) || ufw allow "${RDP_PORT}"/tcp || true
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${RDP_PORT}"/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi
if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport "${RDP_PORT}" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT -p tcp --dport "${RDP_PORT}" -j ACCEPT || true
fi

# Info
CONTAINER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUBLIC_IP="$(curl -s --max-time 3 ifconfig.me || echo 'N/A')"
echo "[CHECK] RDP listening:"
(ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep ":${RDP_PORT}" || true
cat <<MSG

✅ XRDP should be running on port ${RDP_PORT}.

Connect (mstsc):
  - LAN/Internal:  ${CONTAINER_IP}:${RDP_PORT}
  - Public (if open): ${PUBLIC_IP}:${RDP_PORT}
Login: lt4c / lt4c  (hoặc user của bạn)
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

# ================== Autostart + mở cổng public ==================
/usr/local/bin/start-vnc.sh || true
/usr/local/bin/start-rdp.sh || true

# Mở firewall cấp hệ thống (nếu có)
open_firewall $((5900 + DISPLAY_NUM_DEFAULT))
open_firewall "${RDP_PORT}"

# Thông tin kết nối
CONTAINER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUBLIC_IP="$(curl -s --max-time 3 ifconfig.me || echo 'N/A')"
echo
echo "================= CONNECT INFO ================="
echo "Internal/LAN IP : ${CONTAINER_IP}"
echo "Public IP       : ${PUBLIC_IP}"
echo
echo "VNC:  ${PUBLIC_IP}:$((5900 + DISPLAY_NUM_DEFAULT))  (pass: ${VNC_PASS_DEFAULT})"
echo "RDP:  ${PUBLIC_IP}:${RDP_PORT}  (user/pass gợi ý: lt4c/lt4c)"
echo "================================================"
echo "[CHECK] Listening ports (expect :$((5900 + DISPLAY_NUM_DEFAULT)) & :${RDP_PORT}):"
(ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep -E ":(5901|${RDP_PORT})" || true
EOF

chmod +x bootstrap_desktop_rdp_vnc.sh
# CHẠY LUÔN
bash bootstrap_desktop_rdp_vnc.sh

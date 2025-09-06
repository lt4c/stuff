cat > bootstrap_desktop_rdp_vnc.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# ==== Config mặc định (có thể override khi start) ====
VNC_PASS_DEFAULT="${VNC_PASS:-lt4c}"
GEOM_DEFAULT="${GEOM:-1280x720}"
DISPLAY_NUM_DEFAULT="${DISPLAY_NUM:-1}"    # :1 -> 5901
RDP_PORT_DEFAULT="${RDP_PORT:-3389}"       # có thể đổi sang 443
PROXY_PORT_DEFAULT="${PROXY_PORT:-8443}"   # proxy VNC nếu 5901 bị chặn
# =====================================================

# --- Helper: mở firewall (UFW / firewalld / iptables) ---
open_firewall() {
  local PORT="$1"
  if command -v ufw >/dev/null 2>&1; then
    (ufw status | grep -qi inactive) || ufw allow "${PORT}"/tcp || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}"/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if command -v iptables >/devnull 2>&1; then
    :
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT || true
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
  net-tools curl wget ca-certificates socat \
  chromium-browser || true

# --- User đăng nhập RDP (mặc định: lt4c/lt4c) ---
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

# --- Cho phép Xorg khi không có systemd ---
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

# Start VNC (bind public; -localhost no; mở firewall)
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
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUB_IP="$(curl -s --max-time 3 ifconfig.me || echo 'N/A')"
echo "[CHECK] VNC listening:"
(ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep ":${VNC_PORT}" || true
cat <<MSG

✅ VNC is running on port ${VNC_PORT} (display ${DISPLAY}) with -localhost no

Connect:
  - LAN/Internal:  ${LAN_IP}:${VNC_PORT}
  - Public (if cloud firewall opened): ${PUB_IP}:${VNC_PORT}
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

# Start RDP (bind public; sửa xrdp.ini port & address; mở firewall)
tee /usr/local/bin/start-rdp.sh >/dev/null <<'XEOF'
#!/usr/bin/env bash
set -euo pipefail
RDP_PORT="${RDP_PORT:-3389}"

# DBus
mkdir -p /run/dbus && chmod 755 /run/dbus || true
pgrep -x dbus-daemon >/dev/null 2>&1 || dbus-daemon --system --fork || true

# Sửa xrdp.ini: port & address=0.0.0.0 (bind public)
if [ -f /etc/xrdp/xrdp.ini ]; then
  sed -i "s/^port=.*/port=${RDP_PORT}/" /etc/xrdp/xrdp.ini
  if grep -q '^address=' /etc/xrdp/xrdp.ini; then
    sed -i 's/^address=.*/address=0.0.0.0/' /etc/xrdp/xrdp.ini
  else
    sed -i '1i address=0.0.0.0' /etc/xrdp/xrdp.ini
  fi
fi

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

# Mở firewall nội bộ
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
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUB_IP="$(curl -s --max-time 3 ifconfig.me || echo 'N/A')"
echo "[CHECK] RDP listening:"
(ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep ":${RDP_PORT}" || true
cat <<MSG

✅ XRDP is running on port ${RDP_PORT} (bind 0.0.0.0).

Connect (mstsc):
  - LAN/Internal:  ${LAN_IP}:${RDP_PORT}
  - Public (if cloud firewall opened): ${PUB_IP}:${RDP_PORT}
Login: lt4c / lt4c
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

# Public helper: RDP=443, VNC proxy 8443 -> 5901
tee /usr/local/bin/start-public-remote.sh >/dev/null <<'XEOF'
#!/usr/bin/env bash
set -euo pipefail
PROXY_PORT="${PROXY_PORT:-8443}"
DISPLAY_NUM="${DISPLAY_NUM:-1}"
TARGET_PORT=$((5900 + DISPLAY_NUM))
# VNC base
start-vnc.sh
# Proxy 8443 -> 5901
pkill -f "socat TCP-LISTEN:${PROXY_PORT}" >/dev/null 2>&1 || true
nohup socat TCP-LISTEN:${PROXY_PORT},fork,reuseaddr TCP:127.0.0.1:${TARGET_PORT} >/tmp/vnc-proxy.log 2>&1 &
# RDP trên 443
RDP_PORT=443 start-rdp.sh
# Mở firewall
for P in "${PROXY_PORT}" 443; do
  if command -v ufw >/dev/null 2>&1; then
    (ufw status | grep -qi inactive) || ufw allow "${P}"/tcp || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${P}"/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "${P}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "${P}" -j ACCEPT || true
  fi
done
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUB_IP="$(curl -s --max-time 3 ifconfig.me || echo 'N/A')"
echo
echo "=============== PUBLIC CONNECT INFO ==============="
echo "Public IP:  ${PUB_IP}"
echo "LAN IP:     ${LAN_IP}"
echo
echo "RDP (mstsc):    ${PUB_IP}:443    (user: lt4c, pass: lt4c)"
echo "VNC (proxy):    ${PUB_IP}:${PROXY_PORT}  (pass: lt4c)"
echo "VNC (gốc LAN):  ${LAN_IP}:${TARGET_PORT}"
echo "==================================================="
echo "[CHECK] Listening (expect :443, :${PROXY_PORT}, :${TARGET_PORT}):"
(ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep -E ":443|:${PROXY_PORT}|:${TARGET_PORT}" || true
XEOF
chmod +x /usr/local/bin/start-public-remote.sh

# ================== Autostart + mở cổng public ==================
# Ưu tiên public helper để đảm bảo vào được từ Internet (RDP:443, VNC:8443 proxy)
if [ "${DISABLE_PUBLIC_AUTOSTART:-0}" != "1" ]; then
  /usr/local/bin/start-public-remote.sh || true
else
  /usr/local/bin/start-vnc.sh || true
  RDP_PORT="${RDP_PORT_DEFAULT}" /usr/local/bin/start-rdp.sh || true
fi

# Mở firewall mặc định
open_firewall $((5900 + DISPLAY_NUM_DEFAULT))
open_firewall "${RDP_PORT_DEFAULT}"
open_firewall "${PROXY_PORT_DEFAULT}"
open_firewall 443

# Thông tin kết nối cuối
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUB_IP="$(curl -s --max-time 3 ifconfig.me || echo 'N/A')"
echo
echo "================= CONNECT INFO ================="
echo "LAN IP  : ${LAN_IP}"
echo "Public  : ${PUB_IP}"
echo
echo "VNC direct (LAN): ${LAN_IP}:$((5900 + DISPLAY_NUM_DEFAULT))  (pass: ${VNC_PASS_DEFAULT})"
echo "VNC proxy (WAN):  ${PUB_IP}:${PROXY_PORT_DEFAULT}"
echo "RDP (WAN):        ${PUB_IP}:443   (đổi cổng: RDP_PORT=3389 start-rdp.sh)"
echo "Login (RDP):      lt4c / lt4c"
echo "================================================"
echo "[CHECK] Listening (expect :5901, :443, :${PROXY_PORT_DEFAULT}):"
(ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep -E ":5901|:443|:${PROXY_PORT_DEFAULT}" || true
EOF

chmod +x bootstrap_desktop_rdp_vnc.sh
bash bootstrap_desktop_rdp_vnc.sh

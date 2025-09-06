#!/usr/bin/env bash
set -euo pipefail

# =========================
# LT4C — Ubuntu/Debian RDP+VNC setup (NO systemctl) + Steam via .deb
# =========================
# ENV overrideable
USER_NAME="${USER_NAME:-lt4c}"
USER_PASS="${USER_PASS:-lt4c}"
VNC_PASS="${VNC_PASS:-lt4c}"
GEOM="${GEOM:-1280x720}"
XRDP_COLOR_BPP="${XRDP_COLOR_BPP:-32}"   # 24 hoặc 32
DISPLAY_NUM="${DISPLAY_NUM:-0}"

LOGDIR="/srv/lab"
mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGDIR/lt4c_install_$(date +%Y%m%d_%H%M%S).log") 2>&1

echo "[INFO] Starting setup on $(lsb_release -ds || echo Unknown Distro) ..."
echo "[INFO] User=${USER_NAME} GEOM=${GEOM} XRDP_BPP=${XRDP_COLOR_BPP} VNC_DISPLAY=:${DISPLAY_NUM}"

if ! command -v apt >/dev/null 2>&1; then
  echo "[ERROR] apt required. Aborting."
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
apt -y install xfce4 xfce4-goodies xrdp xorgxrdp tigervnc-standalone-server tigervnc-common dbus-x11 x11-xserver-utils
apt -y install curl wget net-tools htop unzip ca-certificates gnupg
apt -y install chromium-browser || apt -y install chromium || true
apt -y install cron || true

# --- Steam via official .deb (handles better than apt on minimal servers)
echo "[STEP] Enable i386 & install Steam (.deb)"
if ! dpkg --print-architecture | grep -q '^amd64$'; then
  echo "[WARN] Non-amd64 host; Steam may not be supported."
fi
dpkg --add-architecture i386 || true
apt update
# Minimal 32-bit GL runtime (helps headless/minimal images)
apt -y install libc6:i386 libgl1:i386 libgl1-mesa-dri:i386 || true
STEAM_DEB="/tmp/steam_latest.deb"
wget -O "$STEAM_DEB" https://cdn.cloudflare.steamstatic.com/client/installer/steam.deb
# Prefer apt to resolve deps automatically; fallback to dpkg if needed
if ! apt -y install "$STEAM_DEB"; then
  dpkg -i "$STEAM_DEB" || true
  apt -yf install || true
fi
rm -f "$STEAM_DEB"

# --- XRDP config (no systemctl)
echo "[STEP] Configure XRDP"
XRDP_INI="/etc/xrdp/xrdp.ini"
if [ -f "$XRDP_INI" ]; then
  sed -i "s/^max_bpp=.*/max_bpp=${XRDP_COLOR_BPP}/" "$XRDP_INI" || true
  sed -i "s/^#max_bpp=.*/max_bpp=${XRDP_COLOR_BPP}/" "$XRDP_INI" || true
fi

# XFCE default session for RDP user
echo "startxfce4" > "/home/${USER_NAME}/.xsession"
chown "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.xsession"

# --- TigerVNC per-user
echo "[STEP] Configure TigerVNC for ${USER_NAME}"
VNC_HOME="/home/${USER_NAME}/.vnc"
mkdir -p "$VNC_HOME"
chown -R "${USER_NAME}:${USER_NAME}" "$VNC_HOME"

# Set VNC password
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
xrdb "$HOME/.Xresources"
startxfce4 &
EOF
chmod +x "${VNC_HOME}/xstartup"
chown -R "${USER_NAME}:${USER_NAME}" "$VNC_HOME"

# --- Lightweight supervisors (NO systemctl): create start/stop scripts & cron @reboot
echo "[STEP] Create start/stop scripts"

START_SH="/usr/local/bin/lt4c_start_rdp_vnc.sh"
STOP_SH="/usr/local/bin/lt4c_stop_rdp_vnc.sh"

cat > "$START_SH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

LOGDIR="${LOGDIR}"
mkdir -p "\$LOGDIR"

# Start xrdp-sesman (if not running)
if ! pgrep -x xrdp-sesman >/dev/null 2>&1; then
  echo "[BOOT] starting xrdp-sesman"
  nohup /usr/sbin/xrdp-sesman --nodaemon >> "\$LOGDIR/xrdp-sesman.log" 2>&1 &
  sleep 0.5
fi

# Start xrdp (if not running)
if ! pgrep -x xrdp >/dev/null 2>&1; then
  echo "[BOOT] starting xrdp"
  nohup /usr/sbin/xrdp --nodaemon >> "\$LOGDIR/xrdp.log" 2>&1 &
  sleep 0.5
fi

# Start VNC (kill stale then start)
su - ${USER_NAME} -c "vncserver -kill :${DISPLAY_NUM} >/dev/null 2>&1 || true"
su - ${USER_NAME} -c "nohup vncserver -localhost no -geometry ${GEOM} :${DISPLAY_NUM} >> '${LOGDIR}/vnc_${USER_NAME}.log' 2>&1 &"

# Ports check
(netstat -tulpn || ss -tulpn || true) | tee "\$LOGDIR/ports_boot.txt" >/dev/null || true
echo "[BOOT] DONE: RDP on 3389, VNC on \$((5900 + ${DISPLAY_NUM}))"
EOF
chmod +x "$START_SH"

cat > "$STOP_SH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "[STOP] stopping VNC"
pkill -f 'Xvnc.*:.*' || true
pkill -x Xvnc || true
# Try user-friendly kill
for d in $(seq 1 10); do su - '"${USER_NAME}"' -c "vncserver -kill :$d" >/dev/null 2>&1 || true; done

echo "[STOP] stopping XRDP"
pkill -x xrdp || true
pkill -x xrdp-sesman || true
echo "[STOP] done."
EOF
# inject actual user into stop script (since we used single quotes)
sed -i "s/\"\\\${USER_NAME}\"/${USER_NAME}/g" "$STOP_SH"
chmod +x "$STOP_SH"

# --- First start now
"$START_SH"

# --- UFW firewall (if present)
if command -v ufw >/dev/null 2>&1; then
  echo "[STEP] Configure UFW (22,3389,5900-5905)"
  ufw allow 22/tcp || true
  ufw allow 3389/tcp || true
  ufw allow 5900:5905/tcp || true
  ufw status | grep -q "inactive" && ufw --force enable || true
else
  echo "[INFO] UFW not installed. Skipping firewall."
fi

# --- Desktop icons
DESKTOP_DIR="/home/${USER_NAME}/Desktop"
mkdir -p "$DESKTOP_DIR"
chown -R "${USER_NAME}:${USER_NAME}" "$DESKTOP_DIR"

if command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1; then
  cat > "${DESKTOP_DIR}/Chromium.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Chromium
Exec=sh -c 'command -v chromium >/dev/null && exec chromium %U || exec chromium-browser %U'
Terminal=false
Categories=Network;WebBrowser;
Icon=chromium
EOF
  chmod +x "${DESKTOP_DIR}/Chromium.desktop"
fi

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

# --- Autostart on boot via cron (@reboot), no systemd
if command -v crontab >/dev/null 2>&1; then
  echo "[STEP] Install @reboot cron"
  TMPCRON="$(mktemp)"
  crontab -l 2>/dev/null | sed '/lt4c_start_rdp_vnc.sh/d' > "$TMPCRON" || true
  echo "@reboot $START_SH >> ${LOGDIR}/lt4c_boot.log 2>&1" >> "$TMPCRON"
  crontab "$TMPCRON"
  rm -f "$TMPCRON"
else
  echo "[WARN] crontab not found; auto-start on reboot not configured."
fi

# --- Quick diagnostics
echo "[CHECK] Ports"
(netstat -tulpn || ss -tulpn || true) | tee -a "$LOGDIR/ports.txt" || true

echo "[CHECK] Processes"
ps aux | egrep 'xrdp|xrdp-sesman|Xvnc|vnc' | egrep -v egrep || true

echo "[INFO] Done."
echo "[INFO] RDP: connect to <IP>:3389 (user: ${USER_NAME})"
echo "[INFO] VNC: connect to <IP>:$((5900 + DISPLAY_NUM)) (display :${DISPLAY_NUM}), password set."
echo "[INFO] Logs at ${LOGDIR}"
echo "[INFO] Start/Stop manually: $START_SH  |  $STOP_SH"

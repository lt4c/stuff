#!/usr/bin/env bash
    set -euo pipefail

    # =========================
    # LT4C — Ubuntu/Debian VNC + Tailscale (NO systemd)
    # =========================
    # ENV overrideable
    USER_NAME="${USER_NAME:-lt4c}"
    USER_PASS="${USER_PASS:-lt4c}"
    VNC_PASS="${VNC_PASS:-lt4c}"
    GEOM="${GEOM:-1280x720}"
    DISPLAY_NUM="${DISPLAY_NUM:-1}"     # :1 -> 5901
    XRDP_COLOR_BPP="${XRDP_COLOR_BPP:-32}"   # deprecated, kept for compatibility
    LOGDIR="${LOGDIR:-/srv/lab}"

    # Tailscale options (optional, can run interactively if AUTHKEY not set)
    TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
    TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-lt4c-vm}"
    TAILSCALE_ROUTES="${TAILSCALE_ROUTES:-}"
    TAILSCALE_ACCEPT_DNS="${TAILSCALE_ACCEPT_DNS:-false}"
    TAILSCALE_SOCK="/run/tailscaled/tailscaled.sock"

    # --- SUDO helper (root -> no sudo; user -> needs sudo)
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
      if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo -H"
      else
        echo "[ERROR] This script needs root or sudo. Please run as root or install sudo." >&2
        exit 1
      fi
    else
      SUDO=""
    fi

    mkdir -p "$LOGDIR"
    # Allow current user to write logs even if not root
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
      $SUDO chown "$USER":"$USER" "$LOGDIR" || true
    fi
    exec > >(tee -a "$LOGDIR/lt4c_install_$(date +%Y%m%d_%H%M%S).log") 2>&1

    echo "[INFO] Setup VNC + Tailscale on $(lsb_release -ds || echo Unknown Distro)"
    echo "[INFO] USER=${USER_NAME} GEOM=${GEOM} DISPLAY=:${DISPLAY_NUM}"

    if ! command -v apt >/dev/null 2>&1; then
      echo "[ERROR] apt required. Aborting."
      exit 1
    fi

    # --- Remove XRDP completely (packages + running procs)
    echo "[STEP] Remove XRDP packages and kill any running instances"
    $SUDO pkill -f xrdp        >/dev/null 2>&1 || true
    $SUDO pkill -f xrdp-sesman >/dev/null 2>&1 || true
    $SUDO apt -y purge xrdp xorgxrdp 2>/dev/null || true
    $SUDO rm -f /usr/local/bin/lt4c_start_rdp_vnc.sh /usr/local/bin/lt4c_stop_rdp_vnc.sh 2>/dev/null || true

    # --- Base packages
    echo "[STEP] apt update + install packages"
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt update
    $SUDO apt -y upgrade
    $SUDO apt -y install xfce4 xfce4-goodies tigervnc-standalone-server tigervnc-common dbus-x11 x11-xserver-utils xterm
    $SUDO apt -y install curl wget net-tools htop unzip ca-certificates gnupg ufw || true
    $SUDO apt -y install chromium-browser || $SUDO apt -y install chromium || true
    $SUDO apt -y install cron || true

    # --- Create user if missing
    if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
      echo "[INFO] Creating user ${USER_NAME}"
      $SUDO useradd -m -s /bin/bash "${USER_NAME}"
      echo "${USER_NAME}:${USER_PASS}" | $SUDO chpasswd
      $SUDO usermod -aG sudo "${USER_NAME}" || true
    else
      echo "[INFO] User ${USER_NAME} already exists"
      echo "${USER_NAME}:${USER_PASS}" | $SUDO chpasswd || true
    fi

    # --- DBus (no systemd): ensure runtime dir
    $SUDO mkdir -p /run/dbus
    $SUDO chmod 755 /run/dbus || true
    pgrep -x dbus-daemon >/dev/null 2>&1 || $SUDO dbus-daemon --system --fork || true

    # --- Allow anyone to start Xorg in minimal hosts
    if [ -f /etc/X11/Xwrapper.config ]; then
      $SUDO sed -i 's/^allowed_users=.*/allowed_users=anybody/' /etc/X11/Xwrapper.config || true
    else
      printf "allowed_users=anybody\nneeds_root_rights=yes\n" | $SUDO tee /etc/X11/Xwrapper.config >/dev/null
    fi

    # --- Configure TigerVNC for USER_NAME
    echo "[STEP] Configure TigerVNC for ${USER_NAME}"
    VNC_HOME="/home/${USER_NAME}/.vnc"
    $SUDO mkdir -p "$VNC_HOME"
    $SUDO chown -R "${USER_NAME}:${USER_NAME}" "$VNC_HOME"

    # Set VNC password
    su - "${USER_NAME}" -c "printf '%s\n' '${VNC_PASS}' | vncpasswd -f > '${VNC_HOME}/passwd'"
    $SUDO chmod 600 "${VNC_HOME}/passwd"

    # xstartup for XFCE
    tmpfile="$(mktemp)"
    cat > "$tmpfile" <<"EOF"
    #!/bin/sh
    unset SESSION_MANAGER
    unset DBUS_SESSION_BUS_ADDRESS
    export XDG_SESSION_TYPE=x11
    export DESKTOP_SESSION=xfce
    export XDG_CURRENT_DESKTOP=XFCE
    export XDG_SESSION_DESKTOP=xfce
    [ -r "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources"
    if command -v dbus-launch >/dev/null 2>&1; then
      eval "$(dbus-launch --sh-syntax)"
    fi
    exec startxfce4
    EOF
    $SUDO install -m 755 "$tmpfile" "${VNC_HOME}/xstartup"
    $SUDO chown -R "${USER_NAME}:${USER_NAME}" "$VNC_HOME"
    rm -f "$tmpfile"

    # Default X session for RDP-era compatibility (harmless)
    tmpfile="$(mktemp)"
    echo "startxfce4" > "$tmpfile"
    $SUDO install -m 644 "$tmpfile" "/home/${USER_NAME}/.xsession"
    $SUDO chown "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.xsession"
    rm -f "$tmpfile"

    # --- Tailscale install (no systemd autostart)
    echo "[STEP] Install Tailscale"
    if ! command -v tailscale >/dev/null 2>&1; then
      # Official convenience installer (adds repo + installs package)
      curl -fsSL https://tailscale.com/install.sh | $SUDO sh
    fi

    # --- Start/Stop scripts (tailscale + vnc), no systemd
    echo "[STEP] Create start/stop scripts"
    START_TS="/usr/local/bin/lt4c_start_tailscale.sh"
    STOP_TS="/usr/local/bin/lt4c_stop_tailscale.sh"
    START_VNC="/usr/local/bin/lt4c_start_vnc_only.sh"
    STOP_VNC="/usr/local/bin/lt4c_stop_vnc_only.sh"

    # Start tailscaled + tailscale up
    cat > "$START_TS" <<'EOF'
    #!/usr/bin/env bash
    set -euo pipefail
    LOGDIR="${LOGDIR:-/srv/lab}"
    mkdir -p "$LOGDIR"

    # Ensure runtime dir
    sudo mkdir -p /run/tailscaled || true
    sudo chmod 755 /run/tailscaled || true

    # Start tailscaled (foreground -> background via nohup)
    if ! pgrep -x tailscaled >/dev/null 2>&1; then
      echo "[BOOT] starting tailscaled"
      nohup sudo /usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state \
        --socket=/run/tailscaled/tailscaled.sock \
        --port 41641 >> "$LOGDIR/tailscaled.log" 2>&1 &
      sleep 1
    fi

    # Login / bring interface up
    if ! tailscale status >/dev/null 2>&1; then
      if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
        sudo tailscale up --authkey="${TAILSCALE_AUTHKEY}" \
          --hostname="${TAILSCALE_HOSTNAME:-lt4c-vm}" \
          ${TAILSCALE_ROUTES:+--advertise-routes="${TAILSCALE_ROUTES}"} \
          --accept-dns="${TAILSCALE_ACCEPT_DNS:-false}" \
          --reset || true
      else
        echo "[INFO] No TAILSCALE_AUTHKEY provided. You can now authenticate manually:"
        echo "      sudo tailscale up --hostname='${TAILSCALE_HOSTNAME:-lt4c-vm}' --accept-dns='${TAILSCALE_ACCEPT_DNS:-false}'"
      fi
    fi

    tailscale ip || true
    EOF
    $SUDO install -m 755 "$START_TS" "$START_TS"

    # Stop tailscale
    cat > "$STOP_TS" <<'EOF'
    #!/usr/bin/env bash
    set -euo pipefail
    sudo tailscale down || true
    sudo pkill -x tailscaled || true
    echo "[STOP] tailscale stopped."
    EOF
    $SUDO install -m 755 "$STOP_TS" "$STOP_TS"

    # Start VNC only (with tailscale-aware firewall)
    cat > "$START_VNC" <<EOF
    #!/usr/bin/env bash
    set -euo pipefail
    USER_NAME="${USER_NAME}"
    GEOM="${GEOM}"
    DISPLAY_NUM="${DISPLAY_NUM}"
    LOGDIR="${LOGDIR}"
    VNC_PORT=\$((5900 + DISPLAY_NUM))

    mkdir -p "\$LOGDIR" || true

    # Ensure DBus
    sudo mkdir -p /run/dbus && sudo chmod 755 /run/dbus || true
    pgrep -x dbus-daemon >/dev/null 2>&1 || sudo dbus-daemon --system --fork || true

    # Re-assert VNC password (in case changed via env)
    su - "\$USER_NAME" -c "printf '%s\n' '${VNC_PASS}' | vncpasswd -f > '/home/\$USER_NAME/.vnc/passwd'"
    sudo chmod 600 "/home/\$USER_NAME/.vnc/passwd"

    # Clean and start
    su - "\$USER_NAME" -c "vncserver -kill :\${DISPLAY_NUM} >/dev/null 2>&1 || true"
    sudo rm -rf /tmp/.X11-unix /tmp/.X\${DISPLAY_NUM}-lock || true
    sudo mkdir -p /tmp/.X11-unix && sudo chmod 1777 /tmp/.X11-unix

    # If tailscale interface exists, we keep server listening on all but firewall-limit to Tailscale range if ufw exists.
    TS_IP=\$(tailscale ip -4 2>/dev/null | head -n1 || true)
    su - "\$USER_NAME" -c "nohup vncserver :\${DISPLAY_NUM} -geometry \"\${GEOM}\" -depth 24 -localhost no >> \"\${LOGDIR}/vnc_\${USER_NAME}.log\" 2>&1 &"

    # Firewall rules
    if command -v ufw >/dev/null 2>&1; then
      if ufw status | grep -qi inactive; then
        echo "[INFO] UFW inactive; not modifying."
      else
        # Allow from Tailscale only if we have a TS IP; otherwise allow LAN-wide on that port
        if [ -n "\$TS_IP" ]; then
          sudo ufw delete allow \${VNC_PORT}/tcp >/dev/null 2>&1 || true
          sudo ufw allow from 100.64.0.0/10 to any port \${VNC_PORT} proto tcp || true
        else
          sudo ufw allow \${VNC_PORT}/tcp || true
        fi
      fi
    fi

    # Info
    LAN_IP=\$(hostname -I 2>/dev/null | awk '{print $1}')
    PUB_IP=\$(curl -s --max-time 3 ifconfig.me || echo 'N/A')
    echo "[CHECK] VNC listening on port \${VNC_PORT} (display :\${DISPLAY_NUM})"
    (ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep ":\${VNC_PORT}" || true
    echo
    echo "✅ VNC is running."
    if [ -n "\$TS_IP" ]; then
      echo "Connect via Tailscale: \${TS_IP}:\${VNC_PORT}"
    fi
    echo "LAN/Internal:  \${LAN_IP}:\${VNC_PORT}"
    echo "Public (if open): \${PUB_IP}:\${VNC_PORT}"
    echo "Password: ${VNC_PASS}"
    echo "Resolution: ${GEOM}"
    EOF
    $SUDO install -m 755 "$START_VNC" "$START_VNC"

    # Stop VNC only
    cat > "$STOP_VNC" <<'EOF'
    #!/usr/bin/env bash
    set -euo pipefail
    DISPLAY_NUM="${DISPLAY_NUM:-1}"
    pkill -f 'Xvnc.*:.*' || true
    pkill -x Xvnc || true
    su - "${USER_NAME:-lt4c}" -c "vncserver -kill :${DISPLAY_NUM}" >/dev/null 2>&1 || true
    echo "[STOP] VNC stopped."
    EOF
    $SUDO install -m 755 "$STOP_VNC" "$STOP_VNC"

    # --- First start now (Tailscale then VNC)
    "$START_TS" || true
    sleep 2
    "$START_VNC" || true

    # --- Autostart on boot via cron (@reboot), no systemd
    if command -v crontab >/dev/null 2>&1; then
      echo "[STEP] Install @reboot cron"
      TMPCRON="$(mktemp)"
      crontab -l 2>/dev/null | sed '/lt4c_start_tailscale.sh/d' > "$TMPCRON" || true
      echo "@reboot $START_TS >> ${LOGDIR}/tailscale_boot.log 2>&1" >> "$TMPCRON"
      echo "@reboot sleep 5 && $START_VNC >> ${LOGDIR}/vnc_boot.log 2>&1" >> "$TMPCRON"
      crontab "$TMPCRON"
      rm -f "$TMPCRON"
    else
      echo "[WARN] crontab not found; auto-start on reboot not configured."
    fi

    # --- Desktop icon for Chromium (optional)
    DESKTOP_DIR="/home/${USER_NAME}/Desktop"
    $SUDO mkdir -p "$DESKTOP_DIR"
    $SUDO chown -R "${USER_NAME}:${USER_NAME}" "$DESKTOP_DIR"
    if command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1; then
      tmpfile="$(mktemp)"
      cat > "$tmpfile" <<'EOF2'
    [Desktop Entry]
    Type=Application
    Name=Chromium
    Exec=sh -c 'command -v chromium >/dev/null && exec chromium %U || exec chromium-browser %U'
    Terminal=false
    Categories=Network;WebBrowser;
    Icon=chromium
    EOF2
      $SUDO install -m 755 "$tmpfile" "${DESKTOP_DIR}/Chromium.desktop"
      $SUDO chown "${USER_NAME}:${USER_NAME}" "${DESKTOP_DIR}/Chromium.desktop"
      rm -f "$tmpfile"
    fi

    echo "[INFO] Done. Start/Stop:"
    echo "  Tailscale: $START_TS | $STOP_TS"
    echo "  VNC:       $START_VNC | $STOP_VNC"
    echo "[INFO] Logs at ${LOGDIR}"

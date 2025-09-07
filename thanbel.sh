#!/usr/bin/env bash
# lt4c.sh
# Usage: ./lt4c.sh <tailscale_auth_key>

set -euo pipefail

TAILSCALE_KEY="${1:-}"
if [ -z "$TAILSCALE_KEY" ]; then
  echo "Usage: $0 <tailscale_auth_key>"
  exit 1
fi

# ====== CONFIG ======
# Nếu dùng host-network trên Linux (ổn định discovery hơn), set HOST_NETWORK=1
HOST_NETWORK="${HOST_NETWORK:-0}"

# Sunshine WebUI mà autopair sẽ gọi (host side)
SUNSHINE_HOST="${SUNSHINE_HOST:-127.0.0.1:47990}"
PIN="${PIN:-6969}"

# Lưu CWD hiện tại để tmux dùng chính xác thư mục bind-mount
HOST_PWD="$(pwd)"

echo "[*] Install Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey "$TAILSCALE_KEY" --accept-routes --accept-dns

echo "[*] Install tmux + curl..."
apt update -y && apt install -y tmux curl

echo "[*] Write autopair script..."
cat > /tmp/autopair.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SUNSHINE_HOST="${SUNSHINE_HOST:-127.0.0.1:47990}"
PIN="${PIN:-6969}"

# Chờ API Sunshine sẵn sàng
until curl -fsS "http://${SUNSHINE_HOST}/api/state" >/dev/null 2>&1; do
  echo "[*] Waiting Sunshine at ${SUNSHINE_HOST}..."
  sleep 2
done

while true; do
  echo "[*] Sending PIN ${PIN}..."
  RESP="$(curl -s -X POST "http://${SUNSHINE_HOST}/api/pin" \
    -H 'Content-Type: application/json' \
    -d "{\"pin\":\"${PIN}\"}")"
  echo ">>> ${RESP}"
  if echo "${RESP}" | grep -q '"status":"ok"'; then
    echo "[✓] Pair thành công!"
    break
  fi
  sleep 2
done
EOF
chmod +x /tmp/autopair.sh

# Xuất biến cho pane tmux bên phải (autopair) dùng
export SUNSHINE_HOST PIN

# Lệnh docker theo 2 chế độ mạng
if [ "${HOST_NETWORK}" = "1" ]; then
  DOCKER_CMD=(
    docker run --rm --gpus all
    --network host
    --device /dev/uinput
    --device /dev/dri
    -v /dev/input:/dev/input
    -v "${HOST_PWD}/sunshine-data:/cloudy/data"
    -v "${HOST_PWD}/sunshine-conf/xfce4:/cloudy/conf/xfce4"
    thanbel/lt4c-gpu:latest
  )
else
  DOCKER_CMD=(
    docker run --rm --gpus all
    -p 47984:47984
    -p 47989:47989
    -p 47990:47990
    -p 48010:48010
    -p 47998-48010:47998-48010/udp   # full dải UDP
    -p 5353:5353/udp                 # mDNS discovery
    --device /dev/uinput
    --device /dev/dri
    -v /dev/input:/dev/input
    -v "${HOST_PWD}/sunshine-data:/cloudy/data"
    -v "${HOST_PWD}/sunshine-conf/xfce4:/cloudy/conf/xfce4"
    thanbel/lt4c-gpu:latest
  )
fi

echo "[*] Start tmux session (lt4c-gpu)..."
# -c "$HOST_PWD" đảm bảo pane trái chạy đúng thư mục (bind-mount không bị sai)
tmux new-session -d -s lt4c-gpu -c "$HOST_PWD" \
  "${DOCKER_CMD[@]}"

# Pane phải chạy autopair; dùng 'bash -lc' để đảm bảo biến env có hiệu lực và lỗi được bắt
tmux split-window -h "bash -lc '/tmp/autopair.sh'"
tmux select-pane -t 0
tmux attach -t lt4c-gpu

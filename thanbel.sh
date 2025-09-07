#!/usr/bin/env bash
# lt4c.sh
# Usage: ./lt4c.sh <tailscale_auth_key>

set -euo pipefail

TAILSCALE_KEY="${1:-}"
if [ -z "$TAILSCALE_KEY" ]; then
  echo "Usage: $0 <tailscale_auth_key>"
  exit 1
fi

# Sunshine lắng nghe trên 0.0.0.0 để host/container khác có thể truy cập
SUNSHINE_HOST="0.0.0.0:47990"
PIN="6969"

echo "[*] Install Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey "$TAILSCALE_KEY" --accept-routes --accept-dns

echo "[*] Install tmux + curl..."
apt update -y && apt install -y tmux curl

echo "[*] Write autopair script..."
cat > /tmp/autopair.sh <<EOF
#!/usr/bin/env bash
SUNSHINE_HOST="$SUNSHINE_HOST"
PIN="$PIN"

# Chờ đến khi API Sunshine mở cổng
until curl -fsS "http://\$SUNSHINE_HOST/api/state" >/dev/null 2>&1; do
  echo "[*] Waiting Sunshine at \$SUNSHINE_HOST..."
  sleep 2
done

while true; do
  echo "[*] Sending PIN \$PIN..."
  RESP=\$(curl -s -X POST "http://\$SUNSHINE_HOST/api/pin" \
    -H 'Content-Type: application/json' \
    -d "{\"pin\":\"\$PIN\"}")
  echo ">>> \$RESP"
  if echo "\$RESP" | grep -q '"status":"ok"'; then
    echo "[✓] Pair thành công!"
    break
  fi
  sleep 2
done
EOF
chmod +x /tmp/autopair.sh

echo "[*] Start tmux session..."
tmux new-session -d -s lt4c \
  "docker run --rm --gpus all \
    -p 47984:47984 -p 47989:47989 -p 47990:47990 -p 48010:48010 \
    -p 47998:47998/udp -p 47999:47999/udp -p 48000:48000/udp -p 48002:48002/udp \
    --device /dev/uinput -v /dev/input:/dev/input \
    -v $PWD/sunshine-data:/cloudy/data \
    -v $PWD/sunshine-conf/xfce4:/cloudy/conf/xfce4 \
    thanbel/lt4c-gpu:latest" \; \
  split-window -h "sh -c /tmp/autopair.sh" \; \
  select-pane -t 0 \; \
  attach

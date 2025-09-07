#!/usr/bin/env bash
# lt4c.sh
# Usage: ./lt4c.sh <tailscale_auth_key>

set -euo pipefail

TAILSCALE_KEY="${1:-}"

if [ -z "$TAILSCALE_KEY" ]; then
  echo "Usage: $0 <tailscale_auth_key>"
  exit 1
fi

SUNSHINE_HOST="127.0.0.1:47990"
PIN="6969"

echo "[*] Cài tailscale và pair..."
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey "$TAILSCALE_KEY" --accept-routes --accept-dns

echo "[*] Cài tmux..."
apt update -y && apt install -y tmux curl

echo "[*] Tạo tmux session với 2 pane..."
tmux new-session -d -s lt4c \
  "docker run --rm -it --gpus all -p 47984:47984 -p 47989:47989 -p 47990:47990 -p 48010:48010 -p 47998:47998/udp -p 47999:47999/udp -p 48000:48000/udp -p 48002:48002/udp --device /dev/uinput -v /dev/input:/dev/input -v $PWD/sunshine-data:/cloudy/data -v $PWD/sunshine-conf/xfce4:/cloudy/conf/xfce4 thanbel/lt4c-gpu:latest" \; \
  split-window -h "cat > autopair.sh <<EOF
#!/usr/bin/env bash
SUNSHINE_HOST=\"$SUNSHINE_HOST\"
PIN=\"$PIN\"

while true; do
  echo \"[*] Thử gửi PIN \$PIN...\"
  RESP=\$(curl -s -X POST \"http://\$SUNSHINE_HOST/api/pin\" \
    -H 'Content-Type: application/json' \
    -d '{\"pin\":\"'$PIN'\"}')
  echo \">>> \$RESP\"
  if echo \"\$RESP\" | grep -q '\"status\":\"ok\"'; then
    echo \"[✓] Pair thành công!\"
    break
  fi
  sleep 2
done
EOF
chmod +x autopair.sh
./autopair.sh" \; \
  attach

#!/usr/bin/env bash
# lt4c.sh
# Usage: HOST_NETWORK=0 ./lt4c.sh <tailscale_auth_key>
#        HOST_NETWORK=1 ./lt4c.sh <tailscale_auth_key>   # use --network host (Linux)

set -euo pipefail

# ====== INPUT ======
TAILSCALE_KEY="${1:-}"
if [ -z "$TAILSCALE_KEY" ]; then
  echo "Usage: $0 <tailscale_auth_key>"
  exit 1
fi

# ====== CONFIG ======
# 0 = bridge + port mapping (default); 1 = host networking (Linux)
HOST_NETWORK="${HOST_NETWORK:-0}"

# Sunshine WebUI host:port that the autopair hits from the HOST side
export SUNSHINE_HOST="${SUNSHINE_HOST:-127.0.0.1:47990}"
export PIN="${PIN:-6969}"

# Keep the working dir for binds
HOST_PWD="$(pwd)"

# ====== PREP ======
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

# ====== DOCKER CMD ======
if [ "${HOST_NETWORK}" = "1" ]; then
  # Host networking (recommended on Linux for discovery)
  # No -p needed; ensure host firewall allows ports.
  read -r -d '' DOCKER_CMD <<EOF || true
docker run --rm --gpus all \
  --network host \
  --device /dev/uinput \
  --device /dev/dri \
  -v /dev/input:/dev/input \
  -v "${HOST_PWD}/sunshine-data:/cloudy/data" \
  -v "${HOST_PWD}/sunshine-conf/xfce4:/cloudy/conf/xfce4" \
  thanbel/lt4c-gpu:latest
EOF
else
  # Bridge networking with full port mapping (TCP + UDP + mDNS)
  read -r -d '' DOCKER_CMD <<EOF || true
docker run --rm --gpus all \
  -p 47984:47984 \
  -p 47989:47989 \
  -p 47990:47990 \
  -p 48010:48010 \
  -p 47998-48010:47998-48010/udp \
  -p 5353:5353/udp \
  --device /dev/uinput \
  --device /dev/dri \
  -v /dev/input:/dev/input \
  -v "${HOST_PWD}/sunshine-data:/cloudy/data" \
  -v "${HOST_PWD}/sunshine-conf/xfce4:/cloudy/conf/xfce4" \
  thanbel/lt4c-gpu:latest
EOF
fi

# ====== TMUX START ======
echo "[*] Start tmux session (lt4c-gpu)..."

# Ensure TERM is set so tmux doesn't error in some environments
export TERM="${TERM:-xterm-256color}"

# Create or replace session cleanly
if tmux has-session -t lt4c-gpu 2>/dev/null; then
  tmux kill-session -t lt4c-gpu
fi

# Create session (pane 0: docker)
tmux new-session -d -s lt4c-gpu -c "${HOST_PWD}" "${DOCKER_CMD}"

# Split pane (pane 1: autopair)
tmux split-window -t lt4c-gpu:0 -h "bash -lc '/tmp/autopair.sh'"
tmux select-pane -t lt4c-gpu:0.0

# Attach only if running under a TTY
if [ -t 1 ]; then
  exec tmux attach -t lt4c-gpu
else
  echo "[i] Non-interactive shell: tmux session is running detached."
  echo "    Attach later with: tmux attach -t lt4c-gpu"
fi

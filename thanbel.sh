#!/usr/bin/env bash
# lt4c.sh
# Usage: ./lt4c.sh <tailscale_auth_key>

set -euo pipefail

TAILSCALE_KEY="${1:-}"
if [ -z "$TAILSCALE_KEY" ]; then
  echo "Usage: $0 <tailscale_auth_key>"
  exit 1
fi

SUNSHINE_HOST="${SUNSHINE_HOST:-127.0.0.1:47990}"
PIN="${PIN:-6969}"

# Detect TTY for tmux/docker flags
HAS_TTY=0
if [ -t 1 ]; then HAS_TTY=1; fi

log() { printf "[%s] %s\n" "$(date +'%F %T')" "$*"; }

#--- APT in non-interactive mode
export DEBIAN_FRONTEND=noninteractive
log "Update APT + install curl, tmux, ca-certificates..."
apt-get update -yq
apt-get install -yq --no-install-recommends curl tmux ca-certificates gnupg
unset DEBIAN_FRONTEND

#--- Tailscale install + up
log "Install Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
log "Bring up Tailscale..."
tailscale up --authkey "$TAILSCALE_KEY" --accept-routes --accept-dns || {
  log "WARN: tailscale up failed once, retrying in 3s..."
  sleep 3
  tailscale up --authkey "$TAILSCALE_KEY" --accept-routes --accept-dns
}

#--- Checks for Docker & NVIDIA
if ! command -v docker >/dev/null 2>&1; then
  log "ERROR: docker chưa được cài. Hãy cài docker trước."
  exit 2
fi

if ! docker info >/dev/null 2>&1; then
  log "ERROR: docker daemon không chạy hoặc không có quyền (rootless?)."
  exit 3
fi

GPU_FLAG=()
if command -v nvidia-smi >/dev/null 2>&1; then
  # Has NVIDIA, try to expose
  GPU_FLAG=(--gpus all)
else
  log "WARN: Không thấy nvidia-smi → chạy container KHÔNG GPU."
fi

# Input devices (for Sunshine gamepad/mouse forwarding)
if [ ! -e /dev/uinput ]; then
  log "WARN: /dev/uinput không tồn tại, Sunshine có thể thiếu input forwarding."
fi
if [ ! -d /dev/input ]; then
  log "WARN: /dev/input không tồn tại."
fi

# Ensure data dirs
mkdir -p "$PWD/sunshine-data" "$PWD/sunshine-conf/xfce4"

# Docker run flags depending on TTY
DOCKER_TTY_FLAGS=()
if [ "$HAS_TTY" -eq 1 ]; then
  # có terminal thật → ok -it
  DOCKER_TTY_FLAGS=(-it)
else
  # môi trường không có TTY → không dùng -t
  DOCKER_TTY_FLAGS=(-i)
fi

# Compose docker command
DOCKER_CMD=(docker run --rm "${GPU_FLAG[@]}" "${DOCKER_TTY_FLAGS[@]}"
  -p 47984:47984 -p 47989:47989 -p 47990:47990 -p 48010:48010
  -p 47998:47998/udp -p 47999:47999/udp -p 48000:48000/udp -p 48002:48002/udp
  --device /dev/uinput --volume /dev/input:/dev/input
  -v "$PWD/sunshine-data:/cloudy/data"
  -v "$PWD/sunshine-conf/xfce4:/cloudy/conf/xfce4"
  --name lt4c-sunshine
  thanbel/lt4c-gpu:latest
)

# Build autopair script content (runs on host)
AUTOPAIR_SCRIPT="$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SUNSHINE_HOST="${SUNSHINE_HOST}"
PIN="${PIN}"

until curl -fsS "http://${SUNSHINE_HOST}/api/state" >/dev/null 2>&1; do
  echo "[*] Waiting Sunshine at ${SUNSHINE_HOST}..."
  sleep 2
done

echo "[*] Trying PIN ${PIN} until success..."
while true; do
  RESP="$(curl -s -X POST "http://${SUNSHINE_HOST}/api/pin" \
    -H 'Content-Type: application/json' \
    -d "{\"pin\":\"${PIN}\"}")" || true
  echo ">>> ${RESP}"
  if echo "${RESP}" | grep -q '"status":"ok"'; then
    echo "[✓] Pair thành công!"
    break
  fi
  sleep 2
done
EOF
)"

# Create runner for tmux pane 2
mkdir -p /tmp/lt4c
cat > /tmp/lt4c/autopair.sh <<EOF
#!/usr/bin/env bash
export SUNSHINE_HOST="${SUNSHINE_HOST}"
export PIN="${PIN}"
${AUTOPAIR_SCRIPT}
EOF
chmod +x /tmp/lt4c/autopair.sh

log "Khởi chạy Sunshine container..."
# In non-TTY env, better run detached and tail logs
if [ "$HAS_TTY" -eq 1 ]; then
  # Use tmux only if TTY exists
  # Fix TERM if needed
  if [ -z "${TERM:-}" ] || [ "${TERM}" = "dumb" ]; then
    export TERM=xterm-256color
  fi

  log "Tạo tmux 2 pane (1: docker, 2: autopair)"
  tmux new-session -d -s lt4c \
    "${DOCKER_CMD[@]}" \; \
    split-window -h "/tmp/lt4c/autopair.sh" \; \
    select-pane -t 0 \; attach
else
  log "Không có TTY → chạy detached. Dùng: docker logs -f lt4c-sunshine"
  # force detached without -t
  docker run -d --rm "${GPU_FLAG[@]}" -p 47984:47984 -p 47989:47989 -p 47990:47990 -p 48010:48010 \
    -p 47998:47998/udp -p 47999:47999/udp -p 48000:48000/udp -p 48002:48002/udp \
    --device /dev/uinput -v /dev/input:/dev/input \
    -v "$PWD/sunshine-data:/cloudy/data" \
    -v "$PWD/sunshine-conf/xfce4:/cloudy/conf/xfce4" \
    --name lt4c-sunshine \
    thanbel/lt4c-gpu:latest
  # Wait a bit for container to start API
  sleep 3
  /tmp/lt4c/autopair.sh || true
  log "Done. Theo dõi log: docker logs -f lt4c-sunshine"
fi

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

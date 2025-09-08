#!/usr/bin/env bash
# lt4c.sh

# Chạy container
docker run -d --name lt4c \
  --network=host \
  --privileged \
  --gpus all \
  --restart=always \
  -e XDG_RUNTIME_DIR=/tmp/sockets \
  -v /tmp/sockets:/tmp/sockets:rw \
  -e HOST_APPS_STATE_FOLDER=/etc/wolf \
  -v /etc/wolf:/etc/wolf:rw \
  -v /var/run/docker.sock:/var/run/docker.sock:rw \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e NVIDIA_VISIBLE_DEVICES=all \
  --device /dev/dri/ \
  --device /dev/uinput \
  --device /dev/uhid \
  -v /dev/:/dev/:rw \
  -v /run/udev:/run/udev:rw \
  --device-cgroup-rule "c 13:* rmw" \
  ghcr.io/games-on-whales/wolf:stable

# Theo dõi log
docker logs -f lt4c

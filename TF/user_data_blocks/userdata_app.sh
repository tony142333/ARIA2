#!/bin/bash
set -e

TARGET_BRANCH="${git_branch}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y

# 1. Install System Dependencies
apt-get install -y python3-pip python3-venv aria2 git awscli

# 2. Setup Application Directory & Repository
rm -rf /home/ubuntu/stream-grabber-app
git clone -b "$TARGET_BRANCH" https://github.com/tony142333/stream-grabber-app.git /home/ubuntu/stream-grabber-app
chown -R ubuntu:ubuntu /home/ubuntu/stream-grabber-app

# 3. Setup Downloads Directory with Strict User Ownership & Permissions
mkdir -p /home/ubuntu/downloads
chown -R ubuntu:ubuntu /home/ubuntu/downloads
chmod -R 775 /home/ubuntu/downloads

# 4. Python Virtual Environment Setup (Ubuntu User Level)
sudo -u ubuntu bash << 'USER_EOF'
cd /home/ubuntu/stream-grabber-app
python3 -m venv venv
source venv/bin/activate
pip install --no-cache-dir --upgrade pip
pip install --no-cache-dir -r requirements.txt
playwright install chromium
USER_EOF

# 5. Playwright System Shared Libraries (Root Level via venv CLI)
/home/ubuntu/stream-grabber-app/venv/bin/playwright install-deps chromium

# 6. Systemd Service Setup
cat << 'SERVICE_EOF' > /etc/systemd/system/stream-grabber.service
[Unit]
Description=EC2 Stream Grabber FastAPI Console
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/stream-grabber-app
ExecStart=/home/ubuntu/stream-grabber-app/venv/bin/uvicorn server:app --host 0.0.0.0 --port 8085
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF
chown -R ubuntu:ubuntu /home/ubuntu/stream-grabber-app
chmod -R 755 /home/ubuntu/stream-grabber-app
systemctl daemon-reload
systemctl enable --now stream-grabber.service

# 7. S3 Script Retrieval
aws s3 cp s3://mybuckets123tarunv7/scripts/upload.sh /home/ubuntu/upload.sh --region ap-south-2 || true
chown ubuntu:ubuntu /home/ubuntu/upload.sh || true
chmod +x /home/ubuntu/upload.sh || true
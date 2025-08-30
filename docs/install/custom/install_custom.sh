#!/bin/bash
# setup_device_manager.sh
# Usage: sudo ./setup_device_manager.sh [--no-input]

NO_INPUT=false
DEVICE_DIR="/etc/device.d"
mkdir -p $DEVICE_DIR
echo $ENCRYPTION_TOKEN > $DEVICE_DIR/iot_token.txt

# Parse flags
if [[ "$1" == "--no-input" ]]; then
    NO_INPUT=true
fi

# 0. Warning and user confirmation
if ! $NO_INPUT; then
    echo "WARNING: This script will install Docker, Docker Compose, OpenSSH server, openssl, gzip, and nmcli if they are not installed."
    read -p "Do you want to continue? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborting."
        exit 1
    fi
fi

# 1. Determine architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
echo "Detected architecture: $ARCH"

# 2. Permit root login via SSH key
SSHD_CONFIG="/etc/ssh/sshd_config"
if ! grep -qxF "PermitRootLogin yes" "$SSHD_CONFIG"; then
    echo "PermitRootLogin yes" >> "$SSHD_CONFIG"
fi

# 3. Generate SSH keys and set permissions
mkdir -p /root/.ssh
if [[ ! -f /root/.ssh/id_rsa_docker ]]; then
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa_docker -N ""
    cp /root/.ssh/id_rsa_docker "$DEVICE_DIR" 2>/dev/null || true
fi

touch /root/.ssh/authorized_keys
if ! grep -qxF "$(cat /root/.ssh/id_rsa_docker.pub)" /root/.ssh/authorized_keys; then
    cat /root/.ssh/id_rsa_docker.pub >> /root/.ssh/authorized_keys
fi

chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
chmod 600 /root/.ssh/id_rsa_docker /root/.ssh/id_rsa_docker.pub

# 4. Docker run command
DOCKER_IMAGE="collabro/iotdevicemanager:1.0.0-$ARCH"

if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null; then
    echo "Pulling Docker image $DOCKER_IMAGE..."
    docker pull "$DOCKER_IMAGE"
fi

if ! docker ps --filter "name=device_manager" --format '{{.Names}}' | grep -q "^device_manager$"; then
    docker run --restart=unless-stopped -d --name=device_manager --network=host \
        -v /etc/os-release:/etc/os-release \
        -v /etc/hosts:/etc/hosts \
        -v "$DEVICE_DIR":"$DEVICE_DIR" \
        "$DOCKER_IMAGE"
else
    echo "Docker container 'device_manager' is already running."
fi

# Enable and start service
echo "Your encryption token is '${ENCRYPTION_TOKEN}' DO NOT forget it! You need it for offline bundles"
echo "Setup complete - device will reboot. On bootup, Device Manager will be running at http://0.0.0.0:16000."
shutdown -r now

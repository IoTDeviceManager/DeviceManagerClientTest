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

# 1. Install dependencies if missing
install_if_missing() {
    for pkg in "$@"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            echo "Installing $pkg..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg"
        else
            echo "$pkg is already installed, skipping."
        fi
    done
}

apt-get update
install_if_missing docker.io docker-compose openssh-server openssl gzip network-manager

# 2. Link docker-compose -> docker compose if necessary
if ! command -v docker-compose &>/dev/null && command -v docker &>/dev/null; then
    echo "Creating docker-compose alias -> docker compose"
    ln -sf /usr/bin/docker /usr/local/bin/docker-compose
    echo 'alias docker-compose="docker compose"' >> /etc/profile.d/docker-compose-alias.sh
    chmod +x /etc/profile.d/docker-compose-alias.sh
fi

# 3. Determine architecture
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64) ARCH="amd64" ;;
    arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
echo "Detected architecture: $ARCH"

# 4. Permit root login via SSH key
SSHD_CONFIG="/etc/ssh/sshd_config"
if ! grep -qxF "PermitRootLogin yes" "$SSHD_CONFIG"; then
    echo "PermitRootLogin yes" >> "$SSHD_CONFIG"
    systemctl restart sshd
fi

# 5. Generate SSH keys and set permissions
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

# 6. Docker run command
DOCKER_IMAGE="collabro/iotdevicemanager:1.0.0-$ARCH"

if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null; then
    echo "Pulling Docker image $DOCKER_IMAGE..."
    docker pull "$DOCKER_IMAGE"
fi

if ! docker ps --filter "name=device_manager" --format '{{.Names}}' | grep -q "^device_manager$"; then
    docker run -d --name=device_manager --network=host \
        -v /etc/os-release:/etc/os-release \
        -v /etc/hosts:/etc/hosts \
        -v "$DEVICE_DIR":"$DEVICE_DIR" \
        "$DOCKER_IMAGE"
else
    echo "Docker container 'device_manager' is already running."
fi

# 7. Create systemd service
SERVICE_FILE="/etc/systemd/system/device_manager.service"
if [[ ! -f "$SERVICE_FILE" ]]; then
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=IoT Device Manager
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/run_device_manager.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
fi

# 7.1 Create helper script for systemd
RUN_SCRIPT="/usr/local/bin/run_device_manager.sh"
if [[ ! -f "$RUN_SCRIPT" ]]; then
    cat <<'EOR' > "$RUN_SCRIPT"
#!/bin/bash
IMAGE="collabro/iotdevicemanager:1.0.0-$(dpkg --print-architecture)"
if ! docker ps --filter "name=device_manager" --format '{{.Names}}' | grep -q "^device_manager$"; then
    while true; do
        docker run -d --name=device_manager --network=host \
            -v /etc/os-release:/etc/os-release \
            -v /etc/hosts:/etc/hosts \
            -v /etc/device.d:/etc/device.d \
            "$IMAGE" && break
        sleep 5
    done
fi
EOR
    chmod +x "$RUN_SCRIPT"
fi

# Enable and start service
systemctl daemon-reload
systemctl enable device_manager.service
systemctl start device_manager.service

echo "Setup complete. Device Manager is running as a systemd service."

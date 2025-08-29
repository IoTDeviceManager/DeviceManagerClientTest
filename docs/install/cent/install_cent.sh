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
    echo "WARNING: This script will install Docker, Docker Compose, OpenSSH server, openssl, gzip, and NetworkManager if they are not installed."
    read -p "Do you want to continue? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborting."
        exit 1
    fi
fi

# Detect CentOS version and set package manager
if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
    INSTALL_CMD="dnf install -y"
    UPDATE_CMD="dnf update -y"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
    INSTALL_CMD="yum install -y"
    UPDATE_CMD="yum update -y"
else
    echo "Neither yum nor dnf found. This script requires CentOS/RHEL."
    exit 1
fi

# 1. Install dependencies if missing
install_if_missing() {
    for pkg in "$@"; do
        if ! rpm -q "$pkg" &>/dev/null; then
            echo "Installing $pkg..."
            $INSTALL_CMD "$pkg"
        else
            echo "$pkg is already installed, skipping."
        fi
    done
}

# Update package lists
$UPDATE_CMD

# Install EPEL repository if not present (needed for docker-compose on older CentOS)
if ! rpm -q epel-release &>/dev/null; then
    echo "Installing EPEL repository..."
    $INSTALL_CMD epel-release
fi

# Install Docker repository if Docker is not available
if ! $PKG_MGR list docker-ce &>/dev/null 2>&1; then
    echo "Adding Docker repository..."
    $INSTALL_CMD yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
fi

# Install packages (CentOS package names)
install_if_missing docker-ce docker-compose-plugin openssh-server openssl gzip NetworkManager

# Start and enable Docker
systemctl start docker
systemctl enable docker

# 2. Link docker-compose -> docker compose if necessary
if ! command -v docker-compose &>/dev/null && command -v docker &>/dev/null; then
    echo "Creating docker-compose alias -> docker compose"
    ln -sf /usr/bin/docker /usr/local/bin/docker-compose
    echo 'alias docker-compose="docker compose"' >> /etc/profile.d/docker-compose-alias.sh
    chmod +x /etc/profile.d/docker-compose-alias.sh
fi

# 3. Determine architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
echo "Detected architecture: $ARCH"

# 4. Permit root login via SSH key
SSHD_CONFIG="/etc/ssh/sshd_config"
if ! grep -qxF "PermitRootLogin yes" "$SSHD_CONFIG"; then
    echo "PermitRootLogin yes" >> "$SSHD_CONFIG"
    systemctl restart sshd
fi

# Enable and start SSH service
systemctl start sshd
systemctl enable sshd

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
    docker run --restart=unless-stopped -d --name=device_manager --network=host \
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
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/run_device_manager.sh
ExecStop=/usr/bin/docker stop device_manager
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
fi

# 7.1 Create helper script for systemd
RUN_SCRIPT="/usr/local/bin/run_device_manager.sh"
if [[ ! -f "$RUN_SCRIPT" ]]; then
    cat <<'EOR' > "$RUN_SCRIPT"
#!/bin/bash
set -e
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

IMAGE="collabro/iotdevicemanager:1.0.0-$ARCH"
CONTAINER_NAME="device_manager"
docker rm "$CONTAINER_NAME" 2>/dev/null || true

if ! docker ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    while true; do
        docker run \
            --restart=unless-stopped \
            -d \
            --name="$CONTAINER_NAME" \
            --network=host \
            -v /etc/os-release:/etc/os-release \
            -v /etc/hosts:/etc/hosts \ 
            -v /etc/device.d:/etc/device.d \
            "$IMAGE" && break
        
        echo "Failed to start container, retrying in 5 seconds..."
        sleep 5
    done
    echo "Container $CONTAINER_NAME started successfully"
else
    echo "Container $CONTAINER_NAME is already running"
fi
EOR
    chmod +x "$RUN_SCRIPT"
fi

# Enable and start service
systemctl daemon-reload
systemctl enable device_manager.service
systemctl start device_manager.service

echo "Setup complete. Device Manager is running as a systemd service."

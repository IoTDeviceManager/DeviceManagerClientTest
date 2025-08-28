#!/bin/sh
# setup_device_manager_alpine.sh
# Usage: sudo ./setup_device_manager_alpine.sh [--no-input]

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

# 1. Install dependencies if missing
install_if_missing() {
    for pkg in "$@"; do
        if ! apk info -e "$pkg" &>/dev/null; then
            echo "Installing $pkg..."
            apk add --no-cache "$pkg"
        else
            echo "$pkg is already installed, skipping."
        fi
    done
}

# setup-alpine
setup-apkrepos -cf
apk update
install_if_missing docker docker-compose openssh-server openssl gzip networkmanager

# Enable and start Docker service
rc-update add docker boot
service docker start

# Enable and start OpenSSH service
rc-update add sshd default
service sshd start

# Enable and start NetworkManager service
rc-update add networkmanager default
service networkmanager start

# 2. Link docker-compose -> docker compose if necessary
if ! command -v docker-compose &>/dev/null && command -v docker &>/dev/null; then
    echo "Creating docker-compose alias -> docker compose"
    ln -sf /usr/bin/docker /usr/local/bin/docker-compose
    echo 'alias docker-compose="docker compose"' >> /etc/profile.d/docker-compose-alias.sh
    chmod +x /etc/profile.d/docker-compose-alias.sh
fi

# 3. Determine architecture
ARCH=$(apk --print-arch)
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
    service sshd restart
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
    docker run --restart=unless-stopped -d --name=device_manager --network=host \
        -v /etc/os-release:/etc/os-release \
        -v /etc/hosts:/etc/hosts \
        -v "$DEVICE_DIR":"$DEVICE_DIR" \
        "$DOCKER_IMAGE"
else
    echo "Docker container 'device_manager' is already running."
fi

# 7. Create OpenRC service (Alpine's init system)
SERVICE_FILE="/etc/init.d/device_manager"
if [[ ! -f "$SERVICE_FILE" ]]; then
    cat <<'EOF' > "$SERVICE_FILE"
#!/sbin/openrc-run

name="IoT Device Manager"
description="IoT Device Manager Docker Container"

depend() {
    need docker
    after docker
}

start() {
    ebegin "Starting IoT Device Manager"
    /usr/local/bin/run_device_manager.sh
    eend $?
}

stop() {
    ebegin "Stopping IoT Device Manager"
    docker stop device_manager
    eend $?
}

restart() {
    stop
    start
}
EOF
    chmod +x "$SERVICE_FILE"
fi

# 7.1 Create helper script for OpenRC
RUN_SCRIPT="/usr/local/bin/run_device_manager.sh"
if [[ ! -f "$RUN_SCRIPT" ]]; then
    cat <<'EOR' > "$RUN_SCRIPT"
#!/bin/bash
set -e
IMAGE="collabro/iotdevicemanager:1.0.0-$(apk --print-arch | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
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
rc-update add device_manager default
service device_manager start

echo "Setup complete. Device Manager is running as an OpenRC service."

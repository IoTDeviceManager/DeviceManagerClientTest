#!/bin/sh
# setup_device_manager_alpine.sh
# Usage: sudo ./setup_device_manager_alpine.sh [--no-input]

NO_INPUT=false
DEVICE_DIR="/etc/device.d"
mkdir -p $DEVICE_DIR
echo $ENCRYPTION_TOKEN > $DEVICE_DIR/iot_token.txt

# Parse flags
if [ "$1" = "--no-input" ]; then
    NO_INPUT=true
fi

# 0. Warning and user confirmation
if [ "$NO_INPUT" = "false" ]; then
    echo "WARNING: This script will install Docker, Docker Compose, OpenSSH server, openssl, gzip, and NetworkManager if they are not installed."
    printf "Do you want to continue? [y/N]: "
    read confirm
    case "$confirm" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *) echo "Aborting."; exit 1 ;;
    esac
fi

# 1. Install dependencies if missing
install_if_missing() {
    for pkg in "$@"; do
        if ! apk info -e "$pkg" >/dev/null 2>&1; then
            echo "Installing $pkg..."
            apk add --no-cache "$pkg"
        else
            echo "$pkg is already installed, skipping."
        fi
    done
}

apk update
install_if_missing docker docker-compose openssh openssl gzip networkmanager curl

# Enable and start Docker service
rc-update add docker boot
service docker start

# 2. Setup docker-compose compatibility
setup_docker_compose() {
    # Check if docker-compose command exists
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose command already exists, skipping setup."
        return
    fi
    
    # Check if docker compose plugin is available
    if docker compose version >/dev/null 2>&1; then
        echo "Setting up docker-compose wrapper for 'docker compose' plugin..."
        
        # Create a wrapper script that translates docker-compose to docker compose
        cat <<'EOF' > /usr/local/bin/docker-compose
#!/bin/sh
# Wrapper script to make docker-compose work with docker compose plugin
exec docker compose "$@"
EOF
        chmod +x /usr/local/bin/docker-compose
        
        # Also create the alias for interactive shells
        echo 'alias docker-compose="docker compose"' > /etc/profile.d/docker-compose-alias.sh
        chmod +x /etc/profile.d/docker-compose-alias.sh
        
        echo "Created docker-compose wrapper script at /usr/local/bin/docker-compose"
        
    elif command -v docker >/dev/null 2>&1; then
        echo "Docker compose plugin not found, attempting to install standalone docker-compose..."
        
        # Try to install standalone docker-compose as fallback
        if command -v pip3 >/dev/null 2>&1; then
            pip3 install docker-compose
        elif command -v curl >/dev/null 2>&1; then
            # Install docker-compose binary directly
            COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            chmod +x /usr/local/bin/docker-compose
        else
            echo "Warning: Could not install docker-compose. Please install it manually."
        fi
    else
        echo "Docker not found, cannot setup docker-compose."
    fi
}

setup_docker_compose

# 3. Determine architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
echo "Detected architecture: $ARCH"

# 4. Configure SSH for root login
SSHD_CONFIG="/etc/ssh/sshd_config"
if ! grep -qxF "PermitRootLogin yes" "$SSHD_CONFIG"; then
    echo "PermitRootLogin yes" >> "$SSHD_CONFIG"
    rc-service sshd restart
fi

# Enable and start SSH service
rc-update add sshd default
rc-service sshd start

# 5. Generate SSH keys and set permissions
mkdir -p /root/.ssh
if [ ! -f /root/.ssh/id_rsa_docker ]; then
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

if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
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

# 7. Create OpenRC service (Alpine uses OpenRC instead of systemd)
SERVICE_FILE="/etc/init.d/device_manager"
if [ ! -f "$SERVICE_FILE" ]; then
    cat <<'EOF' > "$SERVICE_FILE"
#!/sbin/openrc-run

name="IoT Device Manager"
description="IoT Device Manager Container"

depend() {
    need docker
    after docker
}

start() {
    ebegin "Starting $name"
    /usr/local/bin/run_device_manager.sh
    eend $?
}

stop() {
    ebegin "Stopping $name"
    docker stop device_manager >/dev/null 2>&1
    eend $?
}

restart() {
    stop
    sleep 2
    start
}
EOF
    chmod +x "$SERVICE_FILE"
fi

# 7.1 Create helper script for OpenRC
RUN_SCRIPT="/usr/local/bin/run_device_manager.sh"
if [ ! -f "$RUN_SCRIPT" ]; then
    cat <<'EOR' > "$RUN_SCRIPT"
#!/bin/sh
set -e
IMAGE="collabro/iotdevicemanager:1.0.0-ARCH"
CONTAINER_NAME="device_manager"
docker rm "$CONTAINER_NAME" 2>/dev/null || true

if ! docker ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    while true; do
        docker run --restart=unless-stopped -d --name="$CONTAINER_NAME" --network=host -v /etc/os-release:/etc/os-release -v /etc/hosts:/etc/hosts -v /etc/device.d:/etc/device.d "$IMAGE" && break
        echo "Failed to start container, retrying in 5 seconds..."
        sleep 5
    done
    echo "Container $CONTAINER_NAME started successfully"
else
    echo "Container $CONTAINER_NAME is already running"
fi
EOR
    chmod +x "$RUN_SCRIPT"
    sed -i "s/ARCH/$ARCH/" "$RUN_SCRIPT"
fi

# Enable and start service
rc-update add device_manager default
rc-service device_manager start

echo "Your encryption token is '${ENCRYPTION_TOKEN}' DO NOT forget it! You need it for offline bundles"
echo "Setup complete. Device Manager is running at http://0.0.0.0:16000."

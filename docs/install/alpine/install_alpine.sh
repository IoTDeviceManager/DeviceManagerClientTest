#!/bin/sh
# setup_device_manager_alpine.sh
# Usage: sudo ./setup_device_manager_alpine.sh [--no-input]

NO_INPUT=false
DEVICE_DIR="/etc/device.d"
mkdir -p $DEVICE_DIR

# Generate encryption token if not set
echo $ENCRYPTION_TOKEN > $DEVICE_DIR/iot_token.txt

# Parse flags
if [ "$1" = "--no-input" ]; then
    NO_INPUT=true
fi

# 0. Warning and user confirmation
if [ "$NO_INPUT" = "false" ]; then
    echo "WARNING: This script will install Docker, Docker Compose, OpenSSH server, openssl, gzip, and NetworkManager if they are not installed."
    echo "WARNING: This will transition network management to NetworkManager - your connection may briefly interrupt."
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

setup-apkrepos -cf
apk update
install_if_missing docker docker-compose openssh openssl gzip networkmanager networkmanager-cli curl

# 2. Backup existing network configuration
backup_network_config() {
    echo "Backing up existing network configuration..."
    cp -r /etc/network /etc/network.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    
    # Get current connection info before switching
    CURRENT_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "")
    CURRENT_GATEWAY=$(ip route | grep '^default' | grep -oP 'via \K\S+' || echo "")
    CURRENT_INTERFACE=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || echo "")
    
    echo "Current connection: IP=$CURRENT_IP, Gateway=$CURRENT_GATEWAY, Interface=$CURRENT_INTERFACE"
}

# 3. Configure NetworkManager properly
setup_networkmanager() {
    echo "Setting up NetworkManager configuration..."
    
    # Create NetworkManager config directory
    mkdir -p /etc/NetworkManager/conf.d
    
    # Create a more conservative NetworkManager configuration
    cat > /etc/NetworkManager/NetworkManager.conf <<'EOF'
[main]
plugins=ifupdown,keyfile
dhcp=internal
no-auto-default=*

[ifupdown]
managed=false

[device]
wifi.scan-rand-mac-address=no
wifi.backend=wpa_supplicant

[connection]
connection.autoconnect-retries=3
EOF

    # Create a configuration to manage existing connections
    cat > /etc/NetworkManager/conf.d/10-globally-managed-devices.conf <<'EOF'
[keyfile]
unmanaged-devices=none
EOF

    # Don't let NetworkManager manage loopback
    cat > /etc/NetworkManager/conf.d/99-unmanaged-devices.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:lo
EOF
}

# 4. Transition to NetworkManager safely
transition_to_networkmanager() {
    echo "Transitioning to NetworkManager..."
    
    # Check if NetworkManager is already running
    if rc-service networkmanager status >/dev/null 2>&1; then
        echo "NetworkManager is already running, skipping transition."
        return 0
    fi
    
    # Add NetworkManager to default runlevel
    rc-update add networkmanager default
    
    # Start NetworkManager first (it can coexist briefly)
    echo "Starting NetworkManager..."
    rc-service networkmanager start
    
    # Give NetworkManager time to detect and adopt existing connections
    echo "Waiting for NetworkManager to initialize..."
    sleep 10
    
    # Check if NetworkManager has adopted connections
    if nmcli device status >/dev/null 2>&1; then
        echo "NetworkManager is managing devices successfully"
        
        # Remove them from default runlevel
        rc-update del networking default 2>/dev/null || true
        rc-update del wpa_supplicant default 2>/dev/null || true
        
        # Wait a moment and verify connectivity
        sleep 5
        if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
            echo "Network connectivity verified after transition"
        else
            echo "Warning: Network connectivity test failed, but continuing..."
        fi
    else
        echo "Warning: NetworkManager may not have started properly"
    fi
}

# Backup network config first
backup_network_config

# Setup NetworkManager configuration
setup_networkmanager

# Transition to NetworkManager
transition_to_networkmanager

# Enable and start Docker service
echo "Setting up Docker..."
rc-update add docker boot
service docker start

# Wait for Docker to be ready
echo "Waiting for Docker to start..."
timeout=30
while [ $timeout -gt 0 ]; do
    if docker info >/dev/null 2>&1; then
        break
    fi
    echo "Waiting for Docker... ($timeout seconds left)"
    sleep 2
    timeout=$((timeout - 2))
done

if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker failed to start properly"
    exit 1
fi

# 5. Setup docker-compose compatibility
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
            if [ -n "$COMPOSE_VERSION" ]; then
                curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
                chmod +x /usr/local/bin/docker-compose
            else
                echo "Warning: Could not determine docker-compose version."
            fi
        else
            echo "Warning: Could not install docker-compose. Please install it manually."
        fi
    else
        echo "Docker not found, cannot setup docker-compose."
    fi
}

setup_docker_compose

# 6. Determine architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l) ARCH="arm" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
echo "Detected architecture: $ARCH"

# 7. Configure SSH for root login
echo "Configuring SSH..."
SSHD_CONFIG="/etc/ssh/sshd_config"

# Ensure SSH config directory exists
mkdir -p /etc/ssh

# Check if sshd_config exists, create basic one if not
if [ ! -f "$SSHD_CONFIG" ]; then
    cat > "$SSHD_CONFIG" <<EOF
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_dsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
UsePrivilegeSeparation yes
KeyRegenerationInterval 3600
ServerKeyBits 1024
SyslogFacility AUTH
LogLevel INFO
LoginGraceTime 120
StrictModes yes
RSAAuthentication yes
PubkeyAuthentication yes
IgnoreRhosts yes
RhostsRSAAuthentication no
HostbasedAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
X11Forwarding yes
X11DisplayOffset 10
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
UsePAM yes
PermitRootLogin yes
EOF
fi

if ! grep -qxF "PermitRootLogin yes" "$SSHD_CONFIG"; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
    echo "PermitRootLogin yes" >> "$SSHD_CONFIG"
fi

# Generate SSH host keys if they don't exist
ssh-keygen -A 2>/dev/null || true

# Enable and start SSH service
rc-update add sshd default
rc-service sshd start 2>/dev/null || rc-service sshd restart

# 8. Generate SSH keys and set permissions
echo "Setting up SSH keys..."
mkdir -p /root/.ssh
if [ ! -f /root/.ssh/id_rsa_docker ]; then
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa_docker -N ""
    cp /root/.ssh/id_rsa_docker "$DEVICE_DIR" 2>/dev/null || true
fi

touch /root/.ssh/authorized_keys
if ! grep -qF "$(cat /root/.ssh/id_rsa_docker.pub 2>/dev/null)" /root/.ssh/authorized_keys 2>/dev/null; then
    cat /root/.ssh/id_rsa_docker.pub >> /root/.ssh/authorized_keys 2>/dev/null || true
fi

chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
chmod 600 /root/.ssh/id_rsa_docker* 2>/dev/null || true

# 9. Docker run command
echo "Setting up Docker container..."
DOCKER_IMAGE="collabro/iotdevicemanager:1.0.0-$ARCH"

if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
    echo "Pulling Docker image $DOCKER_IMAGE..."
    docker pull "$DOCKER_IMAGE"
fi

# Stop existing container if running
docker stop device_manager 2>/dev/null || true
docker rm device_manager 2>/dev/null || true

# Start the container
docker run --restart=unless-stopped -d --name=device_manager --network=host \
    -v /etc/os-release:/etc/os-release \
    -v /etc/hosts:/etc/hosts \
    -v "$DEVICE_DIR":"$DEVICE_DIR" \
    "$DOCKER_IMAGE"

echo "Container started successfully"

# 10. Create OpenRC service (Alpine uses OpenRC instead of systemd)
SERVICE_FILE="/etc/init.d/device_manager"
if [ ! -f "$SERVICE_FILE" ]; then
    cat <<'EOF' > "$SERVICE_FILE"
#!/sbin/openrc-run

name="IoT Device Manager"
description="IoT Device Manager Container"

depend() {
    need docker networkmanager
    after docker networkmanager
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

status() {
    if docker ps --filter "name=device_manager" --format '{{.Names}}' | grep -q "^device_manager$"; then
        einfo "$name is running"
        return 0
    else
        eerror "$name is not running"
        return 1
    fi
}
EOF
    chmod +x "$SERVICE_FILE"
fi

# 10.1 Create helper script for OpenRC
RUN_SCRIPT="/usr/local/bin/run_device_manager.sh"
if [ ! -f "$RUN_SCRIPT" ]; then
    cat <<EOR > "$RUN_SCRIPT"
#!/bin/sh
set -e
IMAGE="collabro/iotdevicemanager:1.0.0-$ARCH"
CONTAINER_NAME="device_manager"

# Remove existing container
docker stop "\$CONTAINER_NAME" 2>/dev/null || true
docker rm "\$CONTAINER_NAME" 2>/dev/null || true

# Start container with retry logic
attempts=0
max_attempts=5
while [ \$attempts -lt \$max_attempts ]; do
    if docker run --restart=unless-stopped -d --name="\$CONTAINER_NAME" --network=host \
        -v /etc/os-release:/etc/os-release \
        -v /etc/hosts:/etc/hosts \
        -v /etc/device.d:/etc/device.d \
        "\$IMAGE"; then
        echo "Container \$CONTAINER_NAME started successfully"
        exit 0
    fi
    
    attempts=\$((attempts + 1))
    echo "Failed to start container (attempt \$attempts/\$max_attempts), retrying in 5 seconds..."
    sleep 5
done

echo "Failed to start container after \$max_attempts attempts"
exit 1
EOR
    chmod +x "$RUN_SCRIPT"
fi

# Enable and start service
rc-update add device_manager default
rc-service device_manager start

# Final connectivity check
echo "Performing final network connectivity check..."
if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
    echo "✓ Network connectivity confirmed"
else
    echo "⚠ Warning: Network connectivity test failed"
    echo "You may need to manually configure your network connection using nmcli"
fi

echo ""
echo "=== SETUP COMPLETE ==="
echo "Your encryption token is: ${ENCRYPTION_TOKEN}"
echo "⚠ DO NOT forget this token! You need it for offline bundles"

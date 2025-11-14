#!/usr/bin/env bash
# Pi-hole Installation and Configuration Script
# Run this on the Pi-hole VM after it's created
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✓${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠${NC} $*"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ✗${NC} $*" >&2
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root or with sudo"
    exit 1
fi

log "Starting Pi-hole installation and configuration..."

# Update system
log "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

# Install prerequisites
log "Installing prerequisites..."
apt-get install -y -qq \
    curl \
    git \
    ca-certificates \
    gnupg \
    lsb-release

# Create Pi-hole setup config for unattended installation
log "Creating Pi-hole configuration..."
cat > /etc/pihole/setupVars.conf <<'EOF'
# Pi-hole Configuration
WEBPASSWORD=
PIHOLE_INTERFACE=eth0
IPV4_ADDRESS=192.168.178.100/24
IPV6_ADDRESS=
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=local
PIHOLE_DNS_1=1.1.1.1
PIHOLE_DNS_2=1.0.0.1
PIHOLE_DNS_3=8.8.8.8
PIHOLE_DNS_4=8.8.4.4
DNSSEC=true
TEMPERATUREUNIT=C
WEBUIBOXEDLAYOUT=traditional
API_EXCLUDE_DOMAINS=
API_EXCLUDE_CLIENTS=
API_QUERY_LOG_SHOW=all
API_PRIVACY_MODE=false
BLOCKING_ENABLED=true
EOF

mkdir -p /etc/pihole

# Download and run Pi-hole installer
log "Downloading Pi-hole installer..."
curl -sSL https://install.pi-hole.net -o /tmp/pihole-install.sh

log "Running Pi-hole installer (unattended)..."
bash /tmp/pihole-install.sh --unattended

# Generate random admin password
ADMIN_PASSWORD=$(openssl rand -base64 24)
echo "$ADMIN_PASSWORD" > /root/pihole-admin-password.txt
chmod 600 /root/pihole-admin-password.txt

log "Setting Pi-hole admin password..."
pihole -a -p "$ADMIN_PASSWORD"

# Configure additional blocklists
log "Adding additional blocklists..."
sqlite3 /etc/pihole/gravity.db <<'SQL'
INSERT OR IGNORE INTO adlist (address, enabled, comment) VALUES
('https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts', 1, 'StevenBlack Unified'),
('https://v.firebog.net/hosts/AdguardDNS.txt', 1, 'AdGuard DNS'),
('https://v.firebog.net/hosts/Easylist.txt', 1, 'EasyList'),
('https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt', 1, 'Windows Spy Blocker');
SQL

# Update gravity (blocklists)
log "Updating Pi-hole gravity database..."
pihole -g

# Configure local DNS records (optional)
log "Configuring local DNS records..."
cat > /etc/pihole/custom.list <<'EOF'
# Local DNS Records
192.168.178.93 homepage.local
192.168.178.98 argocd.local
192.168.178.106 k8s-dashboard.local
192.168.178.96 grafana.local
192.168.178.90 prometheus.local
192.168.178.99 git.local
192.168.178.100 pihole.local
EOF

# Restart DNS service
log "Restarting DNS service..."
pihole restartdns

# Enable and configure Pi-hole metrics for Prometheus (optional)
log "Installing Pi-hole Prometheus exporter..."
if [ ! -f /usr/local/bin/pihole-exporter ]; then
    EXPORTER_VERSION="0.4.0"
    curl -sSL "https://github.com/eko/pihole-exporter/releases/download/v${EXPORTER_VERSION}/pihole_exporter-linux-amd64" -o /usr/local/bin/pihole-exporter
    chmod +x /usr/local/bin/pihole-exporter

    # Create systemd service
    cat > /etc/systemd/system/pihole-exporter.service <<'SYSTEMD'
[Unit]
Description=Pi-hole Prometheus Exporter
After=network.target pihole-FTL.service

[Service]
Type=simple
User=pihole
Environment="PIHOLE_HOSTNAME=localhost"
Environment="PIHOLE_PORT=80"
Environment="PIHOLE_API_TOKEN="
ExecStart=/usr/local/bin/pihole-exporter
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SYSTEMD

    systemctl daemon-reload
    systemctl enable pihole-exporter
    systemctl start pihole-exporter

    log_success "Pi-hole Prometheus exporter installed on port 9617"
fi

# Get API token
API_TOKEN=$(cat /etc/pihole/setupVars.conf | grep WEBPASSWORD | cut -d'=' -f2)
echo "$API_TOKEN" > /root/pihole-api-token.txt
chmod 600 /root/pihole-api-token.txt

# Display summary
log_success "Pi-hole installation complete!"
echo ""
echo "============================================"
echo "Pi-hole Configuration Summary"
echo "============================================"
echo "Web Interface:    http://192.168.178.100/admin"
echo "Admin Password:   $(cat /root/pihole-admin-password.txt)"
echo "API Token:        $(cat /root/pihole-api-token.txt)"
echo "DNS Server:       192.168.178.100"
echo "Metrics Exporter: http://192.168.178.100:9617/metrics"
echo ""
echo "Credentials saved to:"
echo "  - /root/pihole-admin-password.txt"
echo "  - /root/pihole-api-token.txt"
echo ""
echo "Next steps:"
echo "  1. Access web interface and verify functionality"
echo "  2. Configure your router to use this DNS server"
echo "  3. Add API token to Bitwarden Secrets Manager"
echo "  4. Update homepage dashboard with credentials"
echo "============================================"

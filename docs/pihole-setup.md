# Pi-hole DNS Ad Blocker Setup

This document describes the Pi-hole deployment for network-wide ad blocking and DNS management.

## Overview

Pi-hole is deployed as a virtual machine on pve3 (Proxmox host 3) to provide:
- Network-wide ad blocking and tracker blocking
- Custom DNS resolution for local services
- DNS query monitoring and statistics
- DHCP server (optional)
- Metrics export to Prometheus/Grafana

## Infrastructure

### VM Specifications
- **Host**: pve3 (192.168.178.140)
- **VM ID**: 200
- **VM Name**: pihole
- **IP Address**: 192.168.178.100 (static)
- **CPU**: 2 cores
- **RAM**: 2GB (2048MB)
- **Disk**: 20GB
- **OS**: Ubuntu 24.04 Noble (cloud-init)
- **Storage**: local-lvm

### Network Configuration
- **Subnet**: 192.168.178.0/24
- **Gateway**: 192.168.178.1
- **DNS**: Self (192.168.178.100)
- **Web Interface**: http://192.168.178.100/admin
- **Metrics**: http://192.168.178.100:9617/metrics

## Deployment

### Step 1: Create VM

Use the custom justfile recipe to create the Pi-hole VM:

```bash
just create-pihole-vm pve3
```

Or manually with custom parameters:
```bash
just create-pihole-vm pve3 200 192.168.178.100
```

**What it does:**
- Creates Ubuntu 24.04 VM with cloud-init
- Sets static IP: 192.168.178.100
- Configures 2 CPU cores, 2GB RAM, 20GB disk
- Creates user 'decoder' with SSH key access
- Installs qemu-guest-agent and Python3

### Step 2: Install Pi-hole

Wait 2-3 minutes for cloud-init to complete, then run the installation script:

```bash
# SSH into the VM
ssh decoder@192.168.178.100

# Copy the installation script
scp scripts/install-pihole.sh decoder@192.168.178.100:~/

# Run the installation script
sudo bash install-pihole.sh
```

**What it does:**
- Updates system packages
- Installs Pi-hole with preset configuration
- Configures upstream DNS servers (Cloudflare + Google)
- Adds curated blocklists (StevenBlack, AdGuard, EasyList)
- Creates local DNS records for homelab services
- Installs Prometheus metrics exporter
- Generates admin password and API token
- Saves credentials to /root/pihole-admin-password.txt and /root/pihole-api-token.txt

### Step 3: Store Credentials in Bitwarden

Store the API token in Bitwarden Secrets Manager:

```bash
# SSH to Pi-hole VM
ssh decoder@192.168.178.100

# Get the API token
sudo cat /root/pihole-api-token.txt

# Add to Bitwarden Secrets Manager with name: PIHOLE_API_KEY
# Copy the Bitwarden secret ID
```

Update the External Secret configuration:

```bash
# Edit gitops/homepage/pihole-externalsecret.yaml
# Replace PIHOLE_API_KEY_BITWARDEN_ID with actual Bitwarden secret ID
```

### Step 4: Verify Deployment

```bash
# Test DNS resolution
nslookup google.com 192.168.178.100

# Test ad blocking
nslookup doubleclick.net 192.168.178.100  # Should return blocked address

# Access web interface
# Open: http://192.168.178.100/admin

# Check metrics
curl http://192.168.178.100:9617/metrics

# Check homepage integration
kubectl get externalsecret -n homepage pihole-api-key
```

## Configuration

### Upstream DNS Servers

Pi-hole forwards non-blocked queries to:
- Primary: Cloudflare (1.1.1.1, 1.0.0.1)
- Secondary: Google (8.8.8.8, 8.8.4.4)
- DNSSEC: Enabled

### Blocklists

The following blocklists are enabled by default:
1. **StevenBlack Unified** - Comprehensive unified hosts file
2. **AdGuard DNS** - AdGuard's DNS blocking list
3. **EasyList** - Popular ad blocking list
4. **Windows Spy Blocker** - Blocks Windows telemetry

To add more blocklists:
1. Access web interface: http://192.168.178.100/admin
2. Navigate to: Group Management → Adlists
3. Add new blocklist URL
4. Run: `pihole -g` to update gravity

### Local DNS Records

Local DNS records are configured in `/etc/pihole/custom.list`:

```
192.168.178.93  homepage.local
192.168.178.98  argocd.local
192.168.178.106 k8s-dashboard.local
192.168.178.96  grafana.local
192.168.178.90  prometheus.local
192.168.178.99  git.local
192.168.178.100 pihole.local
```

To add more records:
```bash
# SSH to Pi-hole VM
ssh decoder@192.168.178.100

# Edit custom DNS records
sudo nano /etc/pihole/custom.list

# Restart DNS
pihole restartdns
```

### Network-wide Deployment

To enable Pi-hole for all devices on the network:

**Option 1: Router Configuration (Recommended)**
1. Access your router admin interface (192.168.178.1)
2. Navigate to DHCP/DNS settings
3. Set primary DNS to: 192.168.178.100
4. Set secondary DNS to: 1.1.1.1 (fallback)
5. Save and reboot router
6. All DHCP clients will automatically use Pi-hole

**Option 2: Manual Device Configuration**
Configure DNS manually on each device:
- Primary DNS: 192.168.178.100
- Secondary DNS: 1.1.1.1

**Option 3: Kubernetes CoreDNS**
Update CoreDNS to forward to Pi-hole:
```bash
kubectl edit configmap coredns -n kube-system
# Add forward directive to use 192.168.178.100
```

## Monitoring

### Homepage Dashboard

Pi-hole is integrated with the homepage dashboard:
- Location: http://192.168.178.93
- Section: Services → Pi-hole
- Widget: Shows queries blocked, percentage blocked, total queries

### Prometheus Metrics

Pi-hole exports metrics on port 9617:
- Endpoint: http://192.168.178.100:9617/metrics
- Exporter: eko/pihole-exporter

**Available Metrics:**
- `pihole_domains_being_blocked` - Total domains on blocklists
- `pihole_dns_queries_today` - Total queries today
- `pihole_ads_blocked_today` - Total ads blocked today
- `pihole_ads_percentage_today` - Percentage of ads blocked

### Creating Grafana Dashboard

1. Access Grafana: http://192.168.178.96
2. Create new dashboard
3. Add Prometheus data source (if not already configured)
4. Import dashboard ID: 10176 (Pi-hole Exporter Full)

## Maintenance

### Update Pi-hole

```bash
ssh decoder@192.168.178.100
pihole -up
```

### Update Blocklists

```bash
ssh decoder@192.168.178.100
pihole -g
```

### View Logs

```bash
ssh decoder@192.168.178.100
pihole -t  # Tail logs in real-time
```

### Flush DNS Cache

```bash
ssh decoder@192.168.178.100
pihole restartdns
```

### Backup Configuration

```bash
# From your local machine
ssh decoder@192.168.178.100 "sudo tar -czf /tmp/pihole-backup.tar.gz /etc/pihole"
scp decoder@192.168.178.100:/tmp/pihole-backup.tar.gz ./backups/pihole-$(date +%Y%m%d).tar.gz
```

### Restore Configuration

```bash
# Copy backup to VM
scp ./backups/pihole-YYYYMMDD.tar.gz decoder@192.168.178.100:/tmp/

# SSH to VM
ssh decoder@192.168.178.100

# Extract backup
sudo tar -xzf /tmp/pihole-YYYYMMDD.tar.gz -C /

# Restart Pi-hole
pihole restartdns
```

## High Availability (Future Enhancement)

For production-grade DNS resilience:

### Secondary Pi-hole Instance

1. Create second Pi-hole VM:
   ```bash
   just create-pihole-vm pve2 201 192.168.178.101
   ```

2. Install Pi-hole with same configuration

3. Configure router with both DNS servers:
   - Primary: 192.168.178.100
   - Secondary: 192.168.178.101

4. Use gravity-sync to keep configurations in sync:
   ```bash
   # Install gravity-sync on both instances
   curl -sSL https://raw.githubusercontent.com/vmstan/gravity-sync/master/GS_INSTALL.sh | bash

   # Configure sync between instances
   gravity-sync config
   ```

## Troubleshooting

### DNS Not Resolving

```bash
# Check Pi-hole FTL service status
ssh decoder@192.168.178.100 "sudo systemctl status pihole-FTL"

# Check DNS resolution locally
ssh decoder@192.168.178.100 "nslookup google.com localhost"

# Restart Pi-hole
ssh decoder@192.168.178.100 "pihole restartdns"
```

### Web Interface Not Accessible

```bash
# Check lighttpd service
ssh decoder@192.168.178.100 "sudo systemctl status lighttpd"

# Restart web server
ssh decoder@192.168.178.100 "sudo systemctl restart lighttpd"
```

### Ads Not Being Blocked

1. Check if blocking is enabled: http://192.168.178.100/admin
2. Verify blocklists are populated: `pihole -g`
3. Check if device is using correct DNS server: `nslookup` from device
4. Clear device DNS cache

### Homepage Widget Not Working

```bash
# Verify API token is correct
kubectl get secret -n homepage homepage-secrets -o jsonpath='{.data.pihole-api-key}' | base64 -d

# Check External Secret sync status
kubectl get externalsecret -n homepage pihole-api-key

# Restart homepage pod
kubectl rollout restart deployment -n homepage homepage
```

## Security Considerations

### Firewall Rules

Pi-hole should only accept:
- DNS queries (53/tcp, 53/udp) from local network
- Web interface (80/tcp) from local network
- Metrics (9617/tcp) from Prometheus server
- SSH (22/tcp) from management hosts

### Password Management

- Admin password stored in: `/root/pihole-admin-password.txt`
- API token stored in: `/root/pihole-api-token.txt`
- Both files have 600 permissions (root only)
- API token also stored in Bitwarden Secrets Manager

### Updates

Enable automatic security updates:
```bash
ssh decoder@192.168.178.100
sudo apt install unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

## Integration with Homelab

### Services Using Pi-hole

Once deployed and configured at router level, all homelab services benefit:
- Kubernetes cluster nodes
- Proxmox hosts
- Network attached storage
- All client devices

### Custom DNS for Services

Add custom DNS entries for easier access:
```bash
# Edit custom list
ssh decoder@192.168.178.100
sudo nano /etc/pihole/custom.list

# Add entries like:
# 192.168.178.XXX service.homelab.local

# Reload
pihole restartdns
```

## References

- Official Documentation: https://docs.pi-hole.net/
- GitHub Repository: https://github.com/pi-hole/pi-hole
- Prometheus Exporter: https://github.com/eko/pihole-exporter
- Community Blocklists: https://firebog.net/
- Gravity Sync: https://github.com/vmstan/gravity-sync

## Support

For issues specific to this homelab deployment:
1. Check this documentation
2. Review Pi-hole logs: `pihole -t`
3. Check VM status on Proxmox
4. Verify network connectivity: `ping 192.168.178.100`

For general Pi-hole issues:
- Discourse: https://discourse.pi-hole.net/
- Reddit: https://reddit.com/r/pihole

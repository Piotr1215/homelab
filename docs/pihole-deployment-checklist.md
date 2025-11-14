# Pi-hole Deployment Checklist

Quick checklist for deploying Pi-hole on pve3.

## Prerequisites

- [ ] Access to Proxmox host pve3 (192.168.178.140)
- [ ] SSH key configured for root@pve3
- [ ] Bitwarden Secrets Manager access
- [ ] IP 192.168.178.100 is available (not in use)

## Deployment Steps

### 1. Create VM on pve3

```bash
# From homelab directory
just create-pihole-vm pve3
```

**Expected Output:**
- VM ID: 200
- VM Name: pihole
- IP: 192.168.178.100
- Status: Running

**Wait Time:** 2-3 minutes for cloud-init to complete

### 2. Verify VM is Ready

```bash
# Test connectivity
ping 192.168.178.100

# SSH into VM
ssh decoder@192.168.178.100

# Check cloud-init status
cloud-init status

# Should see: status: done
```

### 3. Install Pi-hole

```bash
# Copy installation script to VM
scp scripts/install-pihole.sh decoder@192.168.178.100:~/

# SSH to VM
ssh decoder@192.168.178.100

# Run installation script
sudo bash install-pihole.sh
```

**Duration:** ~5-10 minutes

**Expected Output:**
```
============================================
Pi-hole Configuration Summary
============================================
Web Interface:    http://192.168.178.100/admin
Admin Password:   [random password]
API Token:        [long hex string]
DNS Server:       192.168.178.100
Metrics Exporter: http://192.168.178.100:9617/metrics
============================================
```

### 4. Save Credentials

```bash
# SSH to VM if not already connected
ssh decoder@192.168.178.100

# Get admin password
sudo cat /root/pihole-admin-password.txt

# Get API token
sudo cat /root/pihole-api-token.txt
```

**Action Items:**
- [ ] Copy admin password to password manager
- [ ] Copy API token for next step

### 5. Store API Token in Bitwarden

1. **Log into Bitwarden Secrets Manager**
   - Organization: Your homelab organization
   - Project: Same project as other homelab secrets

2. **Create New Secret**
   - Name: `PIHOLE_API_KEY`
   - Value: [paste API token from step 4]
   - Notes: `Pi-hole API token for homepage widget`

3. **Copy Secret ID**
   - After creation, copy the Bitwarden secret ID (UUID format)
   - Example: `a1b2c3d4-1234-5678-9abc-def012345678`

### 6. Update External Secret Configuration

```bash
# Edit the external secret file
vim gitops/homepage/pihole-externalsecret.yaml

# Replace this line:
#   key: PIHOLE_API_KEY_BITWARDEN_ID  # Replace with actual Bitwarden secret ID
# With:
#   key: a1b2c3d4-1234-5678-9abc-def012345678  # Your actual Bitwarden secret ID
```

### 7. Commit and Push Changes

```bash
# Check git status
git status

# Add changes
git add .

# Commit
git commit -m "feat: Add Pi-hole DNS ad-blocker on pve3

- Add justfile recipe for Pi-hole VM creation
- Create automated installation script
- Integrate with homepage dashboard
- Add Prometheus metrics monitoring
- Complete documentation and deployment guide
"

# Push to branch
git push -u origin claude/pihole-implementation-plan-016dgkgJhgMgC7NRcCM3H1rW
```

### 8. Verify ArgoCD Sync

```bash
# Check ArgoCD application sync status
kubectl get app -n argocd

# Manually sync if needed
argocd app sync root

# Or via kubectl
kubectl patch app root -n argocd -p '{"metadata": {"annotations": {"argocd.argoproj.io/refresh": "normal"}}}' --type merge
```

### 9. Verify Deployments

#### Homepage Widget
```bash
# Check external secret
kubectl get externalsecret -n homepage pihole-api-key
# Should show: STATUS = SecretSynced

# Check secret
kubectl get secret -n homepage homepage-secrets -o yaml | grep pihole-api-key

# Restart homepage to pick up changes
kubectl rollout restart deployment -n homepage homepage

# Access homepage
# http://192.168.178.93
# Verify Pi-hole widget shows stats
```

#### Prometheus Metrics
```bash
# Check service and endpoints
kubectl get svc,endpoints -n prometheus pihole

# Check ServiceMonitor
kubectl get servicemonitor -n prometheus pihole

# Verify metrics scraping
# Access Prometheus: http://192.168.178.90:9090
# Query: pihole_domains_being_blocked
# Should return value > 0
```

#### Pi-hole Web Interface
```bash
# Access: http://192.168.178.100/admin
# Login with admin password from step 4
# Verify:
#   - Dashboard shows statistics
#   - Blocklists are populated (~140k+ domains)
#   - Upstream DNS servers configured
#   - Local DNS records present
```

### 10. Test DNS Functionality

```bash
# Test normal DNS resolution
nslookup google.com 192.168.178.100
# Should resolve normally

# Test ad blocking
nslookup doubleclick.net 192.168.178.100
# Should return blocked address (0.0.0.0 or Pi-hole IP)

# Test from Kubernetes pod
kubectl run -it --rm debug --image=alpine --restart=Never -- sh
# Inside pod:
nslookup google.com
# Check if using Pi-hole (if CoreDNS forwarding configured)
```

### 11. Configure Network-wide DNS (Optional)

**Router Configuration:**
1. Access router admin interface (192.168.178.1)
2. Navigate to DHCP/DNS settings
3. Set DNS servers:
   - Primary: 192.168.178.100
   - Secondary: 1.1.1.1 (fallback)
4. Save and apply changes
5. Reboot router or renew DHCP leases on clients

**Verification:**
- Devices should start using Pi-hole automatically
- Check Pi-hole web interface for increasing query count
- Verify ad blocking on client devices

### 12. Configure Grafana Dashboard (Optional)

```bash
# Access Grafana: http://192.168.178.96

# Import Pi-hole dashboard
# Dashboard → Import → Dashboard ID: 10176
# Or create custom dashboard using metrics:
#   - pihole_domains_being_blocked
#   - pihole_dns_queries_today
#   - pihole_ads_blocked_today
#   - pihole_ads_percentage_today
```

## Validation Checklist

After deployment, verify:

- [ ] VM created and running on pve3
- [ ] Pi-hole web interface accessible
- [ ] DNS queries resolving correctly
- [ ] Ads being blocked
- [ ] Homepage widget showing statistics
- [ ] Prometheus scraping metrics
- [ ] External Secret synced
- [ ] Documentation complete
- [ ] Backup strategy in place

## Rollback Procedure

If something goes wrong:

### Quick Rollback
```bash
# Stop Pi-hole VM
ssh root@192.168.178.140 "qm stop 200"

# Or destroy VM completely
ssh root@192.168.178.140 "qm destroy 200"

# Revert git changes
git checkout main
git branch -D claude/pihole-implementation-plan-016dgkgJhgMgC7NRcCM3H1rW
```

### Partial Rollback (Keep VM, remove integrations)
```bash
# Remove homepage widget
git checkout HEAD~1 -- gitops/homepage/homepage.yaml

# Remove Prometheus monitoring
rm gitops/infra/pihole-external-service.yaml

# Commit and push
git add .
git commit -m "Rollback Pi-hole integrations"
git push
```

## Post-Deployment Tasks

- [ ] Set up automatic backups for Pi-hole configuration
- [ ] Document in team wiki/knowledge base
- [ ] Add to monitoring/alerting
- [ ] Schedule regular blocklist updates
- [ ] Plan for high availability (secondary Pi-hole instance)

## Support and Troubleshooting

See detailed troubleshooting in [docs/pihole-setup.md](pihole-setup.md#troubleshooting)

Quick checks:
```bash
# Check VM status
ssh root@192.168.178.140 "qm status 200"

# Check Pi-hole service
ssh decoder@192.168.178.100 "sudo systemctl status pihole-FTL"

# View logs
ssh decoder@192.168.178.100 "pihole -t"

# Restart services
ssh decoder@192.168.178.100 "pihole restartdns"
```

## Next Steps

After successful deployment:

1. **Monitor Performance**
   - Watch query volume in web interface
   - Monitor resource usage (CPU, RAM)
   - Set up alerts for service downtime

2. **Fine-tune Blocklists**
   - Add domain-specific lists
   - Whitelist false positives
   - Review blocked queries regularly

3. **Plan High Availability**
   - Deploy secondary Pi-hole on different host
   - Configure gravity-sync
   - Update router with both DNS servers

4. **Integration Enhancements**
   - Create custom Grafana dashboards
   - Set up alerting for critical metrics
   - Integrate with log aggregation

## Timeline

Estimated deployment time: **30-45 minutes**

- VM Creation: 5 minutes
- Pi-hole Installation: 10 minutes
- Configuration & Testing: 15 minutes
- Integration & Verification: 10 minutes
- Documentation: 5 minutes

## Resources

- Pi-hole Setup Guide: [docs/pihole-setup.md](pihole-setup.md)
- Installation Script: [scripts/install-pihole.sh](../scripts/install-pihole.sh)
- Justfile Recipe: Line 254 in [justfile](../justfile)

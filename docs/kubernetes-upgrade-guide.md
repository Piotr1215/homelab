# Kubernetes Cluster Upgrade Guide

This guide provides comprehensive automation scripts and procedures for upgrading Kubernetes clusters based on official Kubernetes documentation.

## Table of Contents

1. [Overview](#overview)
2. [Best Practices Summary](#best-practices-summary)
3. [Upgrade Scripts](#upgrade-scripts)
4. [Upgrade Workflow](#upgrade-workflow)
5. [Script Usage Examples](#script-usage-examples)
6. [Rollback Procedures](#rollback-procedures)
7. [Troubleshooting](#troubleshooting)
8. [References](#references)

## Overview

Upgrading a Kubernetes cluster requires careful planning and execution to minimize downtime and ensure cluster stability. This guide and accompanying scripts follow official Kubernetes upgrade procedures for kubeadm-managed clusters.

### Key Principles

- **Sequential Upgrades**: Cannot skip minor versions (e.g., must upgrade 1.32 → 1.33 → 1.34)
- **Control Plane First**: Always upgrade control plane nodes before worker nodes
- **One Node at a Time**: Upgrade nodes sequentially to maintain cluster availability
- **Backup Everything**: Create backups before any upgrade attempt
- **Verify at Each Step**: Validate cluster health after each node upgrade

## Best Practices Summary

Based on official Kubernetes documentation, here are the critical best practices:

### Pre-Upgrade Requirements

1. **Review Release Notes**
   - Check https://kubernetes.io/docs/setup/release/notes/ for breaking changes
   - Identify deprecated APIs and features
   - Plan for application compatibility

2. **Backup Critical Data**
   - etcd snapshot (mandatory for disaster recovery)
   - Cluster resource manifests
   - Application data and databases
   - Certificate backups

3. **Verify Cluster Health**
   - All nodes in Ready state
   - No resource pressure conditions
   - System pods running correctly
   - Sufficient capacity for pod rescheduling

4. **Check Version Skew**
   - Validate upgrade path (no skipped versions)
   - Ensure kubelet version compatibility
   - Review component version requirements

5. **Disable Swap**
   - Kubernetes requires swap to be disabled on all nodes
   - Verify with `swapon -s`

### Upgrade Order

For kubeadm clusters, the upgrade follows this sequence:

1. **First Control Plane Node**
   - Upgrade kubeadm package
   - Run `kubeadm upgrade plan` to verify
   - Run `kubeadm upgrade apply v<version>`
   - Upgrade kubelet and kubectl
   - Restart kubelet service

2. **Additional Control Plane Nodes** (if HA setup)
   - Upgrade kubeadm package
   - Run `kubeadm upgrade node`
   - Upgrade kubelet and kubectl
   - Restart kubelet service

3. **Worker Nodes** (one or few at a time)
   - Drain node (evict pods)
   - Upgrade kubeadm package
   - Run `kubeadm upgrade node`
   - Upgrade kubelet and kubectl
   - Restart kubelet service
   - Uncordon node

### Critical Considerations

1. **Package Repositories**
   - Use pkgs.k8s.io (new repositories)
   - Legacy apt.kubernetes.io and yum.kubernetes.io are deprecated
   - Update repository configuration for new minor versions

2. **Certificate Renewal**
   - kubeadm automatically renews certificates during upgrade
   - Can be disabled with `--certificate-renewal=false` if needed
   - Verify certificate expiration post-upgrade

3. **Node Draining**
   - Always drain nodes before kubelet upgrades
   - Use `--ignore-daemonsets` flag
   - Allow sufficient time for pod eviction
   - Container restart after upgrade (spec hash changes)

4. **etcd Upgrade**
   - For API server graceful shutdown during etcd upgrade:
     ```bash
     killall -s SIGTERM kube-apiserver
     sleep 20
     kubeadm upgrade ...
     ```

5. **CNI Plugin**
   - Manually upgrade CNI plugin after first control plane
   - Follow CNI-specific upgrade documentation
   - DaemonSet-based CNIs upgrade automatically

6. **Idempotent Operations**
   - `kubeadm upgrade` is idempotent
   - Safe to re-run if upgrade fails mid-way
   - Cluster state converges to desired state

## Upgrade Scripts

Five production-ready scripts are provided for comprehensive cluster upgrade management:

### 1. Pre-Upgrade Checks Script

**File**: `/home/user/homelab/scripts/k8s-pre-upgrade-checks.sh`

**Purpose**: Comprehensive pre-upgrade validation and backup

**Features**:
- Cluster health verification
- Version compatibility checks
- Automated etcd backup with verification
- Cluster resource backup
- Deprecated API detection (with Pluto if available)
- Resource capacity validation
- Persistent volume health checks
- Swap status verification
- Custom resource backup
- kubeadm upgrade plan execution

**Output**:
- Detailed log file
- Pre-upgrade checklist
- Backup files with timestamps

### 2. Control Plane Upgrade Script

**File**: `/home/user/homelab/scripts/k8s-control-plane-upgrade.sh`

**Purpose**: Automate control plane node upgrades

**Features**:
- Interactive and non-interactive modes
- OS detection (Ubuntu/Debian, CentOS/RHEL)
- Safety checks and confirmations
- Automatic package repository updates
- kubeadm, kubelet, and kubectl upgrades
- Node draining and uncordoning
- Version verification
- Comprehensive logging
- Dry-run mode support

**Modes**:
- First control plane: Uses `kubeadm upgrade apply`
- Additional control planes: Uses `kubeadm upgrade node`

### 3. Worker Node Upgrade Script

**File**: `/home/user/homelab/scripts/k8s-worker-upgrade.sh`

**Purpose**: Automate worker node upgrades

**Features**:
- Single or batch node upgrades
- Interactive node selection mode
- Graceful pod eviction with timeout
- Pre-upgrade health checks
- Automatic package upgrades
- Node cordoning/draining/uncordoning
- Post-upgrade verification
- Remote upgrade capability (with warnings)
- Staggered upgrades with delays

**Modes**:
- Local: Run on the node being upgraded
- Interactive: Select nodes from a list
- Batch: Specify multiple nodes as arguments

### 4. Post-Upgrade Validation Script

**File**: `/home/user/homelab/scripts/k8s-post-upgrade-validation.sh`

**Purpose**: Comprehensive post-upgrade validation

**Features**:
- 14 comprehensive test categories
- Version verification across all nodes
- Component health checks
- Pod status validation
- API server functionality tests
- DNS resolution tests
- Service connectivity checks
- Deployment and DaemonSet health
- PersistentVolume status
- Resource metrics collection
- Certificate expiration checks
- Pod scheduling tests
- Detailed HTML/text reports

**Test Categories**:
1. Cluster connectivity
2. Node version verification
3. Node health status
4. System pod status
5. Critical component checks
6. API server functionality
7. DNS resolution
8. Persistent volumes
9. Service status
10. Deployment health
11. DaemonSet health
12. Resource metrics
13. Certificate expiration
14. Pod scheduling

### 5. Rollback Script

**File**: `/home/user/homelab/scripts/k8s-rollback.sh`

**Purpose**: Emergency rollback procedures (LAST RESORT)

**Features**:
- etcd snapshot restoration
- Package downgrade procedures
- Cluster resource restoration
- Backup verification
- Safety confirmations with typed acknowledgment
- Comprehensive warnings
- Dry-run mode
- Step-by-step recovery process

**Operations**:
- Check available backups
- List etcd snapshots
- Restore etcd from snapshot
- Downgrade Kubernetes packages
- Restore cluster resources

## Upgrade Workflow

### Complete Upgrade Procedure

Follow these steps for a safe, successful cluster upgrade:

#### Phase 1: Pre-Upgrade (1-2 hours)

```bash
# 1. Review release notes
# Visit: https://kubernetes.io/docs/setup/release/notes/

# 2. Run pre-upgrade checks
./scripts/k8s-pre-upgrade-checks.sh v1.33.0

# 3. Review the generated checklist and logs
cat /var/backups/kubernetes/pre-upgrade-checklist-*.txt

# 4. Verify backups were created
ls -lh /var/backups/kubernetes/etcd/
ls -lh /var/backups/kubernetes/resources-*/

# 5. Optional: Install Pluto for deprecated API detection
brew install FairwindsOps/tap/pluto
# or
wget https://github.com/FairwindsOps/pluto/releases/download/v5.18.0/pluto_5.18.0_linux_amd64.tar.gz
tar -xzf pluto_5.18.0_linux_amd64.tar.gz
sudo mv pluto /usr/local/bin/

# Re-run with Pluto installed
./scripts/k8s-pre-upgrade-checks.sh v1.33.0
```

#### Phase 2: Control Plane Upgrade (30 minutes per node)

```bash
# 1. SSH to first control plane node
ssh user@control-plane-1

# 2. Run the upgrade script
sudo ./scripts/k8s-control-plane-upgrade.sh v1.33.0

# 3. Verify the upgrade
kubectl get nodes
kubectl get pods -n kube-system

# 4. For additional control plane nodes (if HA)
ssh user@control-plane-2
sudo ./scripts/k8s-control-plane-upgrade.sh v1.33.0

ssh user@control-plane-3
sudo ./scripts/k8s-control-plane-upgrade.sh v1.33.0

# 5. Update CNI plugin (if required)
# Example for Calico:
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
```

#### Phase 3: Worker Node Upgrade (15-30 minutes per node)

```bash
# Option 1: Interactive mode (select nodes)
./scripts/k8s-worker-upgrade.sh v1.33.0 --interactive

# Option 2: Upgrade specific nodes
./scripts/k8s-worker-upgrade.sh v1.33.0 worker-1 worker-2

# Option 3: Upgrade all workers one by one (safest)
for worker in $(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name); do
    node_name=$(echo $worker | cut -d/ -f2)
    ./scripts/k8s-worker-upgrade.sh v1.33.0 $node_name
    # Wait and verify before proceeding
    sleep 60
    kubectl get nodes
done
```

#### Phase 4: Post-Upgrade Validation (15 minutes)

```bash
# 1. Run comprehensive validation
./scripts/k8s-post-upgrade-validation.sh v1.33.0

# 2. Review the validation report
cat /tmp/k8s-validation-report-*.txt

# 3. Check specific components
kubectl get nodes -o wide
kubectl get pods --all-namespaces
kubectl top nodes
kubectl top pods --all-namespaces

# 4. Test application functionality
# Verify your applications are working correctly
# Check ingress, services, and external access
```

#### Phase 5: Post-Upgrade Cleanup (Optional)

```bash
# 1. Clean up old container images (if needed)
# On each node:
crictl rmi --prune

# 2. Verify and clean old backups
ls -lh /var/backups/kubernetes/

# 3. Update documentation with new version
# Document the upgrade date and version
```

## Script Usage Examples

### Pre-Upgrade Checks

```bash
# Basic check without target version
./scripts/k8s-pre-upgrade-checks.sh

# With target version for version skew validation
./scripts/k8s-pre-upgrade-checks.sh v1.33.0

# Custom backup directory
BACKUP_DIR=/custom/backup/path ./scripts/k8s-pre-upgrade-checks.sh v1.33.0

# Review the checklist
cat /var/backups/kubernetes/pre-upgrade-checklist-*.txt
```

### Control Plane Upgrade

```bash
# Interactive mode (with confirmations)
sudo ./scripts/k8s-control-plane-upgrade.sh v1.33.0

# Non-interactive mode (auto-approve)
sudo ./scripts/k8s-control-plane-upgrade.sh v1.33.0 --yes

# Dry run (see what would happen)
DRY_RUN=true sudo ./scripts/k8s-control-plane-upgrade.sh v1.33.0
```

### Worker Node Upgrade

```bash
# Upgrade current node
./scripts/k8s-worker-upgrade.sh v1.33.0

# Upgrade specific nodes
./scripts/k8s-worker-upgrade.sh v1.33.0 worker-1 worker-2 worker-3

# Interactive mode
./scripts/k8s-worker-upgrade.sh v1.33.0 --interactive

# Auto-approve all prompts
AUTO_APPROVE=true ./scripts/k8s-worker-upgrade.sh v1.33.0 worker-1

# Custom drain timeout (default: 300s)
DRAIN_TIMEOUT=600s ./scripts/k8s-worker-upgrade.sh v1.33.0 worker-1
```

### Post-Upgrade Validation

```bash
# Basic validation
./scripts/k8s-post-upgrade-validation.sh

# Validation with expected version check
./scripts/k8s-post-upgrade-validation.sh v1.33.0

# Custom test namespace
TEST_NAMESPACE=kube-system ./scripts/k8s-post-upgrade-validation.sh v1.33.0

# View detailed report
cat /tmp/k8s-validation-report-*.txt
```

### Rollback Procedures

```bash
# Check available backups
./scripts/k8s-rollback.sh --check-backups

# List etcd snapshots
./scripts/k8s-rollback.sh --list-etcd-snapshots

# Restore etcd (DANGEROUS - last resort only!)
sudo ./scripts/k8s-rollback.sh --restore-etcd /var/backups/kubernetes/etcd/etcd-snapshot-20250108-120000.db

# Downgrade packages (RISKY!)
sudo ./scripts/k8s-rollback.sh --downgrade-packages v1.32.0

# Restore cluster resources
./scripts/k8s-rollback.sh --restore-resources /var/backups/kubernetes/resources-20250108-120000/

# Dry run any operation
./scripts/k8s-rollback.sh --dry-run --downgrade-packages v1.32.0
```

## Rollback Procedures

### When to Rollback

Rollback should be considered ONLY when:
- The upgrade has catastrophically failed
- The cluster is completely non-functional
- All recovery attempts have failed
- You have verified backups

### Safer Alternatives to Rollback

Before attempting rollback, try these alternatives:

1. **Wait for Stabilization**
   - Upgrades can take 10-30 minutes to stabilize
   - Pods may restart multiple times
   - Be patient and monitor logs

2. **Fix Specific Components**
   - Identify failing components in logs
   - Restart specific pods or services
   - Check configuration errors

3. **Roll Back Applications**
   - Roll back application deployments instead of cluster
   - Use `kubectl rollout undo deployment/<name>`
   - Much safer than cluster rollback

4. **Consult Logs**
   ```bash
   # API server logs
   kubectl logs -n kube-system kube-apiserver-<node>

   # Controller manager logs
   kubectl logs -n kube-system kube-controller-manager-<node>

   # Kubelet logs
   sudo journalctl -u kubelet -f

   # etcd logs
   kubectl logs -n kube-system etcd-<node>
   ```

### Rollback Options

#### Option 1: etcd Restore (Most Drastic)

```bash
# 1. Verify backup
./scripts/k8s-rollback.sh --list-etcd-snapshots

# 2. Restore from snapshot (LAST RESORT!)
sudo ./scripts/k8s-rollback.sh --restore-etcd <snapshot-file>

# 3. Verify cluster
kubectl get nodes
kubectl get pods --all-namespaces
```

**Consequences**:
- All changes after backup are lost
- May require application redeployment
- Potential data loss
- Extended downtime

#### Option 2: Package Downgrade (Risky)

```bash
# 1. Check current versions
kubeadm version
kubelet --version
kubectl version

# 2. Downgrade packages
sudo ./scripts/k8s-rollback.sh --downgrade-packages v1.32.0

# 3. Reconfigure node
sudo kubeadm upgrade node
sudo systemctl restart kubelet
```

**Consequences**:
- May cause configuration conflicts
- Requires manual reconfiguration
- Not officially supported
- May leave cluster in inconsistent state

#### Option 3: Resource Restoration (Selective)

```bash
# Restore specific resources without full rollback
./scripts/k8s-rollback.sh --restore-resources /var/backups/kubernetes/resources-*/

# Or manually restore specific resources
kubectl apply -f /var/backups/kubernetes/resources-*/namespaces/app-namespace/
```

## Troubleshooting

### Common Issues and Solutions

#### Issue: Nodes Not Ready After Upgrade

```bash
# Check node status
kubectl describe node <node-name>

# Check kubelet logs
sudo journalctl -u kubelet -f

# Restart kubelet
sudo systemctl restart kubelet

# Check CNI plugin
kubectl get pods -n kube-system | grep -i cni
```

#### Issue: Pods Stuck in Pending

```bash
# Check events
kubectl get events --all-namespaces --sort-by='.lastTimestamp'

# Check node resources
kubectl top nodes
kubectl describe nodes

# Check pod details
kubectl describe pod <pod-name> -n <namespace>
```

#### Issue: API Server Not Responding

```bash
# Check API server logs
kubectl logs -n kube-system kube-apiserver-<node>

# Check API server pod
kubectl get pods -n kube-system | grep apiserver

# Restart API server (static pod)
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 10
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
```

#### Issue: etcd Issues

```bash
# Check etcd health
kubectl get pods -n kube-system | grep etcd

# Check etcd logs
kubectl logs -n kube-system etcd-<node>

# Verify etcd endpoint health
ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

#### Issue: Certificate Errors

```bash
# Check certificate expiration
sudo kubeadm certs check-expiration

# Renew certificates
sudo kubeadm certs renew all

# Restart kubelet
sudo systemctl restart kubelet
```

#### Issue: Version Mismatch

```bash
# Check all component versions
kubectl get nodes -o wide
kubectl version
kubeadm version
kubelet --version

# Verify version consistency
kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}'
```

### Debug Commands

```bash
# Cluster information
kubectl cluster-info dump > cluster-info.txt

# Node diagnostics
kubectl describe nodes > nodes-describe.txt

# Pod status across all namespaces
kubectl get pods --all-namespaces -o wide > all-pods.txt

# Events
kubectl get events --all-namespaces --sort-by='.lastTimestamp' > events.txt

# Resource usage
kubectl top nodes > nodes-resources.txt
kubectl top pods --all-namespaces > pods-resources.txt

# Component status
kubectl get componentstatuses

# API server health
kubectl get --raw='/healthz?verbose'
kubectl get --raw='/readyz?verbose'
```

## Version Compatibility Matrix

| Component | Version Skew | Notes |
|-----------|--------------|-------|
| kube-apiserver | N/A | Reference version |
| kube-controller-manager | kube-apiserver -1 | Must be same or one minor version lower |
| kube-scheduler | kube-apiserver -1 | Must be same or one minor version lower |
| kubelet | kube-apiserver -2 | Can be up to two minor versions lower |
| kubectl | kube-apiserver ±1 | Can be one minor version higher or lower |
| kube-proxy | kubelet | Should match kubelet version |

## References

### Official Kubernetes Documentation

- **Upgrading kubeadm clusters**: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- **Cluster upgrade overview**: https://kubernetes.io/docs/tasks/administer-cluster/cluster-upgrade/
- **Version skew policy**: https://kubernetes.io/docs/setup/release/version-skew-policy/
- **Release notes**: https://kubernetes.io/docs/setup/release/notes/
- **Package repositories**: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/

### Tools and Resources

- **Pluto** (deprecated API detection): https://github.com/FairwindsOps/pluto
- **kubectl-convert**: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/#install-kubectl-convert-plugin
- **etcd backup/restore**: https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- **Kubernetes changelog**: https://github.com/kubernetes/kubernetes/tree/master/CHANGELOG

### Best Practice Guides

- Upgrade during maintenance windows
- Test upgrades in non-production first
- Have a rollback plan
- Monitor cluster during upgrade
- Upgrade one minor version at a time
- Keep backups for at least 30 days
- Document your upgrade process
- Train team on rollback procedures

## Support and Contributions

For issues or improvements to these scripts:
1. Check logs in `/tmp/k8s-*.log`
2. Review official documentation
3. Test in non-production environment
4. Create detailed issue reports with logs

## License

These scripts follow Kubernetes licensing and best practices based on official documentation.

---

**Last Updated**: 2025-01-08
**Kubernetes Version Coverage**: 1.28 - 1.33+
**Script Version**: 1.0.0

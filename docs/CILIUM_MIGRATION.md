# Calico → Cilium Migration - Step-by-Step Execution Guide

**⚠️ COMPREHENSIVE BACKUP COMPLETED ✓**
- etcd snapshot: 175 MB, 4007 keys, verified
- K8s configs: 114 KB (certificates, configs)
- All resources: 2 MB, 58,205 lines
- Restore procedure: `/tmp/cilium-migration-backup/RESTORE_PROCEDURE.md`
- Valid until: 2025-11-09 16:00 CET

**Confidence: 9/10 - HIGH (upgraded from 8/10 with full backup)**

---

## 🎯 EXECUTION STATUS

- [ ] M0.1: Backup created ✅ (COMPLETED - see above)
- [ ] M0.2: SSH access verified
- [ ] M0.3: Current state documented
- [ ] M1.1: Helm repo added
- [ ] M1.2: Cilium CLI installed
- [ ] M1.3: Cilium deployed (FIRST RESTORE POINT)
- [ ] M1.4: Dual-CNI verified
- [ ] M2.1: Worker3 migrated
- [ ] M2.2: Worker4 migrated
- [ ] M2.3: Worker1 migrated
- [ ] M2.4: Control plane migrated (CRITICAL)
- [ ] M3.1: Policy enforcement enabled
- [ ] M4.1: Cilium ownership verified
- [ ] M4.2: Calico removed (POINT OF NO RETURN)
- [ ] M4.3: iptables cleaned
- [ ] M5.1: Final verification

---

## 📋 NEXT SESSION QUICK START

**Resume with**: `@docs/CILIUM_MIGRATION.md`

**Commands to execute in order**:
1. Start at **M0.2: Verify SSH Access**
2. Each milestone requires approval before execution
3. AI will stop after each milestone for verification
4. Update checklist above as you progress

---

## ⚠️ CRITICAL FAILURE MODES (Research-Based)

### Failure Mode 1: Network Split-Brain (SEVERITY: CRITICAL)
**What**: Pods on Calico nodes cannot reach pods on Cilium nodes → cluster partitioned
**Root Cause**: Routing table doesn't know how to reach both CNI pod CIDRs
**Detection**: Cross-node pod communication fails; DNS timeouts
**Prevention**:
- ✅ We use same Pod CIDR (10.233.64.0/18) for both CNIs
- ✅ hostLegacyRouting=true enables legacy routing during dual-overlay
- ✅ Test connectivity after each node migration

### Failure Mode 2: iptables Conflicts (SEVERITY: HIGH)
**What**: Cilium daemon fails with "failed to install iptables rules"
**Root Cause**: Conflicting iptables rules from Calico, kube-proxy, or old Cilium
**Detection**: Cilium pods CrashLoopBackOff; iptables errors in logs
**Prevention**:
- ✅ We keep kube-proxy (kubeProxyReplacement=disabled)
- ✅ Different VXLAN port (Calico: 4789, Cilium: 8472)
- 🔄 Monitor Cilium pod logs during Phase 1

### Failure Mode 3: DNS Resolution Failure (SEVERITY: HIGH)
**What**: CoreDNS pods lose connectivity; all DNS queries timeout
**Root Cause**: CoreDNS pod's node migrated but CNI not properly configured
**Detection**: `nslookup kubernetes.default` fails from pods
**Prevention**:
- ✅ CoreDNS will be rescheduled during node drain
- 🔄 Test DNS after each node migration
- 📍 Restore Point: After each node migration

### Failure Mode 4: Node Drain Stuck (SEVERITY: MEDIUM)
**What**: `kubectl drain` hangs; pods refuse eviction
**Root Cause**: PodDisruptionBudgets (PDBs) block eviction; CNI pods prevent drain
**Detection**: Drain command timeout (>10 min)
**Prevention**:
- ✅ Use --ignore-daemonsets (allows CNI pods to stay)
- ✅ Timeout set to 10 min
- 🔧 Fallback: Use --disable-eviction if PDB blocks

### Failure Mode 5: VXLAN Port Collision (SEVERITY: MEDIUM)
**What**: Packets dropped; intermittent connectivity
**Root Cause**: Both CNIs use same VXLAN port
**Detection**: Packet loss in overlay network; interface conflicts
**Prevention**:
- ✅ Calico uses port 4789, Cilium uses port 8472 (distinct)
- ✅ vxlanPort: 8472 explicitly set in values

### Failure Mode 6: Performance Degradation (SEVERITY: LOW)
**What**: Network throughput drops after migration (reported by Samsung Ads)
**Root Cause**: Suboptimal Cilium config; hostLegacyRouting overhead
**Detection**: iPerf3 tests show lower throughput
**Prevention**:
- ⏳ Expected during migration (hostLegacyRouting=true)
- 🔧 Can optimize post-migration (enable eBPF routing)

### Failure Mode 7: Control Plane Isolation (SEVERITY: CRITICAL)
**What**: Worker nodes lose API server connectivity during control plane migration
**Root Cause**: kube-apiserver pod evicted; CNI switchover breaks connectivity
**Detection**: `kubectl` commands hang; nodes show NotReady
**Prevention**:
- ✅ Migrate control plane LAST (after all workers proven stable)
- ✅ Wait 60s after control plane drain for stabilization
- 📍 CRITICAL Restore Point: Before M2.4

---

## 📍 RESTORE POINTS (12 Milestones)

| Milestone | Restore Point | Rollback Time | Risk Level | Status |
|-----------|--------------|---------------|------------|--------|
| M0.1 | Pre-migration backup | N/A | None | ✅ DONE |
| M0.2-M0.3 | Verification only | N/A | None | ⏸️ |
| M1.1-M1.2 | Helm repo added, CLI installed | 1 min | None | ⏸️ |
| **M1.3** | **Cilium deployed alongside Calico** | **5 min** | **LOW** | ⏸️ |
| M1.4 | Dual-CNI verified | 5 min | LOW | ⏸️ |
| **M2.1** | **Worker3 migrated** | **10 min** | **MEDIUM** | ⏸️ |
| **M2.2** | **Worker4 migrated** | **15 min** | **MEDIUM** | ⏸️ |
| **M2.3** | **Worker1 migrated** | **20 min** | **MEDIUM** | ⏸️ |
| **M2.4** | **Control plane migrated** | **30 min** | **HIGH** | ⏸️ |
| M3.1 | Policy enforcement enabled | 5 min | MEDIUM | ⏸️ |
| M4.1 | Cilium ownership verified | 2 min | LOW | ⏸️ |
| M4.2 | Calico removed | 10 min | MEDIUM | ⏸️ |
| M4.3 | iptables cleaned | 5 min | LOW | ⏸️ |

**Bold** = Critical restore points with rollback procedures

---

## 🔄 ROLLBACK PROCEDURES (Per Restore Point)

### RP1: After M1.3 (Cilium Deployed, Calico Intact)
**Symptoms**: Cilium pods failing, iptables errors, cluster unstable
```bash
# Remove Cilium completely
helm uninstall cilium -n kube-system
kubectl delete pods -n kube-system -l k8s-app=cilium --force --grace-period=0
kubectl delete daemonset -n kube-system cilium --ignore-not-found=true

# Verify Calico still working
kubectl get pods -n kube-system | grep calico
kubectl run test-rollback --image=curlimages/curl --rm -i --restart=Never -- curl --connect-timeout 5 http://kubernetes.default.svc.cluster.local/healthz
```

### RP2: After M2.1 (Worker3 Migrated)
**Symptoms**: Worker3 pods cannot reach other nodes; DNS fails
```bash
# Re-migrate worker3 back to Calico
kubectl cordon kube-worker3
kubectl drain kube-worker3 --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=5m
kubectl label node kube-worker3 migration.cilium- --overwrite
ssh decoder@192.168.178.107 "sudo systemctl restart kubelet"
kubectl uncordon kube-worker3

# Verify connectivity restored
kubectl run test-worker3-rollback --image=curlimages/curl --rm -i --restart=Never --overrides='{"spec":{"nodeName":"kube-worker3"}}' -- curl --connect-timeout 5 http://kubernetes.default.svc.cluster.local/healthz
```

### RP3: After M2.2/M2.3 (Multiple Workers Migrated)
**Symptoms**: Cross-node communication broken; services unreachable
```bash
# Rollback ALL migrated workers one by one
for node in kube-worker4 kube-worker1; do
  echo "=== Rolling back $node ==="
  kubectl cordon $node
  kubectl drain $node --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=5m
  kubectl label node $node migration.cilium- --overwrite
  kubectl uncordon $node
  sleep 60
done

# Full cluster rollback if needed
helm uninstall cilium -n kube-system
```

### RP4: After M2.4 (Control Plane Migrated) - CRITICAL
**Symptoms**: API server unreachable; cluster non-functional
```bash
# EMERGENCY: Use etcd restore procedure
# See /tmp/cilium-migration-backup/RESTORE_PROCEDURE.md
# Recovery time: 10-15 minutes

# Quick attempt:
ssh decoder@192.168.178.87
sudo systemctl restart kubelet
sudo systemctl status kubelet

# If still broken, full etcd restore needed
```

### RP5: After M3.1 (Policy Enforcement Enabled)
**Symptoms**: Network policies blocking legitimate traffic; services down
```bash
# Disable policy enforcement immediately
helm upgrade cilium cilium/cilium \
  --version 1.16.1 \
  --namespace kube-system \
  --set policyEnforcementMode=never \
  --reuse-values

# Verify connectivity restored
cilium connectivity test
```

### RP6: After M4.2 (Calico Removed) - POINT OF NO RETURN
**After this point, rollback requires full cluster restore**
```bash
# Only option: Restore from backup
kubectl apply -f /tmp/cilium-migration-backup/all-resources.yaml

# OR full etcd restore (45+ min recovery)
# See /tmp/cilium-migration-backup/RESTORE_PROCEDURE.md
```

---

## 🚦 GO/NO-GO DECISION POINTS

### Before M1.3 (Cilium Deploy): Pre-Flight Checks
- [ ] Backup exists: `/tmp/cilium-migration-backup/all-resources.yaml` ✅
- [ ] etcd snapshot verified ✅
- [ ] All nodes Ready: `kubectl get nodes` (4/4 Ready)
- [ ] All pods Running: `kubectl get pods -A | grep -v Running | wc -l` (≤5 non-running)
- [ ] SSH access works: All 4 nodes respond
- [ ] Disk space: Each node >10GB free
- [ ] Calico healthy: All calico pods Running

**GO**: All checks pass → Proceed to M1.3
**NO-GO**: Any check fails → Fix issue before proceeding

### Before M2.1 (First Node Migration): Dual-CNI Validation
- [ ] Cilium pods Running: `kubectl get pods -n kube-system -l k8s-app=cilium` (all Running)
- [ ] Cilium status healthy: `cilium status` (no errors)
- [ ] Calico still working: `kubectl get pods -n kube-system | grep calico` (all Running)
- [ ] Connectivity test passed: Test pod completes successfully
- [ ] No iptables errors: `kubectl logs -n kube-system -l k8s-app=cilium --tail=50` (no "failed to install")

**GO**: All checks pass → Proceed to M2.1
**NO-GO**: Cilium unhealthy → Rollback via RP1

### Before M2.4 (Control Plane Migration): Worker Validation
- [ ] All workers migrated successfully: 3/3 labels show `migration.cilium=complete`
- [ ] All workers Ready: `kubectl get nodes` (workers all Ready)
- [ ] Cross-node connectivity: Pods on different workers can communicate
- [ ] DNS working: `nslookup kubernetes.default` from any pod succeeds
- [ ] No Calico traffic: `kubectl logs -n kube-system daemonset/calico-node --tail=10` (minimal activity)

**GO**: All checks pass → Proceed to M2.4 (CRITICAL STEP)
**NO-GO**: Any worker failing → Rollback that worker via RP2/RP3

### Before M4.2 (Calico Removal): Point of No Return Check
- [ ] All nodes migrated: 4/4 labels show `migration.cilium=complete`
- [ ] Cilium endpoint count matches pod count: Approximately equal
- [ ] Zero Calico traffic for 10+ min: Calico logs silent
- [ ] All critical services working: ArgoCD, Prometheus, Grafana accessible
- [ ] Backup still valid: Less than 4 hours old ✅

**GO**: All checks pass → Proceed to M4.2 (IRREVERSIBLE)
**NO-GO**: Cilium not fully operational → ABORT, investigate before removal

---

## 📋 MIGRATION PROCEDURE

### Pre-Migration (Milestone 0)

#### M0.1: Create Backup ✅ COMPLETED
**Status**: DONE - 2025-11-09 12:01:52 CET
- etcd snapshot: 175 MB, verified
- K8s configs: 114 KB
- All resources: 2 MB (58,205 lines)
- Restore procedure: Available

#### M0.2: Verify SSH Access [NEXT]
```bash
for ip in 87 88 107 111; do
  echo "=== Node $ip ===" && ssh -o ConnectTimeout=5 decoder@192.168.178.$ip "hostname && uptime"
done
```
**Verification**: All 4 nodes respond with hostname

#### M0.3: Document Current State
```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system | grep calico
kubectl cluster-info dump 2>/dev/null | grep cluster-cidr
kubectl get ipaddresspool -n metallb-system
kubectl get svc -A --field-selector spec.type=LoadBalancer
```
**Verification**: Pod CIDR is `10.233.64.0/18`, all services have IPs

---

### Phase 1: Deploy Cilium (Milestone 1-4)

#### M1.1: Add Cilium Helm Repo
```bash
helm repo add cilium https://helm.cilium.io
helm repo update
helm search repo cilium/cilium --versions | head -5
```
**Verification**: Version `1.16.1` appears in list

#### M1.2: Install Cilium CLI
```bash
CILIUM_CLI_VERSION="v0.18.7"
curl -L https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz -o /tmp/cilium-cli.tar.gz
sudo tar xzvfC /tmp/cilium-cli.tar.gz /usr/local/bin
rm /tmp/cilium-cli.tar.gz
cilium version --client
```
**Verification**: `cilium version --client` shows v0.18.7

#### M1.3: Deploy Cilium Alongside Calico [RP1: FIRST RESTORE POINT]
```bash
helm install cilium cilium/cilium \
  --version 1.16.1 \
  --namespace kube-system \
  -f gitops/infra/cilium-migration-values.yaml
```
**Verification**: `helm list -n kube-system | grep cilium` (deployed)

**🔄 Rollback if fails**: See RP1 above

#### M1.4: Verify Dual-CNI Operation
```bash
# Wait for Cilium pods (max 5 min)
kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=5m

# Check both CNIs running
kubectl get pods -n kube-system | grep -E "calico|cilium"

# Verify Cilium status
cilium status

# Test basic connectivity
kubectl run test-connectivity --image=curlimages/curl --rm -i --restart=Never -- curl --connect-timeout 5 http://kubernetes.default.svc.cluster.local/healthz
```
**Verification**:
- Cilium pods: Running (4/4)
- Calico pods: Running (still active)
- Connectivity test: `ok` response

**🚦 GO/NO-GO**: If Cilium unhealthy → **NO-GO**, execute RP1 rollback

---

### Phase 2: Migrate Nodes (Milestone 2.1-2.4)

#### M2.1: Migrate kube-worker3 (192.168.178.107) [RP2]
```bash
kubectl cordon kube-worker3
kubectl drain kube-worker3 --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=10m
kubectl label node kube-worker3 migration.cilium=in-progress --overwrite
ssh decoder@192.168.178.107 "sudo systemctl restart kubelet && sudo systemctl status kubelet --no-pager -l"
sleep 30
kubectl uncordon kube-worker3
kubectl get nodes kube-worker3
sleep 30
kubectl run test-worker3 --image=curlimages/curl --rm -i --restart=Never --overrides='{"spec":{"nodeName":"kube-worker3"}}' -- curl --connect-timeout 5 http://kubernetes.default.svc.cluster.local/healthz
kubectl run test-dns-worker3 --image=curlimages/curl --rm -i --restart=Never --overrides='{"spec":{"nodeName":"kube-worker3"}}' -- nslookup kubernetes.default
kubectl label node kube-worker3 migration.cilium=complete --overwrite
kubectl get node kube-worker3 --show-labels | grep migration
```
**Verification**: Node Ready, connectivity OK, DNS OK, label `migration.cilium=complete`

#### M2.2: Migrate kube-worker4 (192.168.178.111) [RP3]
```bash
sleep 120
kubectl cordon kube-worker4
kubectl drain kube-worker4 --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=10m
kubectl label node kube-worker4 migration.cilium=in-progress --overwrite
ssh decoder@192.168.178.111 "sudo systemctl restart kubelet && sudo systemctl status kubelet --no-pager -l"
sleep 30
kubectl uncordon kube-worker4
kubectl get nodes kube-worker4
sleep 30
kubectl run test-worker4 --image=curlimages/curl --rm -i --restart=Never --overrides='{"spec":{"nodeName":"kube-worker4"}}' -- curl --connect-timeout 5 http://kubernetes.default.svc.cluster.local/healthz
kubectl run test-dns-worker4 --image=curlimages/curl --rm -i --restart=Never --overrides='{"spec":{"nodeName":"kube-worker4"}}' -- nslookup kubernetes.default
kubectl label node kube-worker4 migration.cilium=complete --overwrite
kubectl get node kube-worker4 --show-labels | grep migration
```
**Verification**: Same as M2.1

#### M2.3: Migrate kube-worker1 (192.168.178.88) [RP3]
```bash
sleep 120
kubectl cordon kube-worker1
kubectl drain kube-worker1 --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=10m
kubectl label node kube-worker1 migration.cilium=in-progress --overwrite
ssh decoder@192.168.178.88 "sudo systemctl restart kubelet && sudo systemctl status kubelet --no-pager -l"
sleep 30
kubectl uncordon kube-worker1
kubectl get nodes kube-worker1
sleep 30
kubectl run test-worker1 --image=curlimages/curl --rm -i --restart=Never --overrides='{"spec":{"nodeName":"kube-worker1"}}' -- curl --connect-timeout 5 http://kubernetes.default.svc.cluster.local/healthz
kubectl run test-dns-worker1 --image=curlimages/curl --rm -i --restart=Never --overrides='{"spec":{"nodeName":"kube-worker1"}}' -- nslookup kubernetes.default
kubectl label node kube-worker1 migration.cilium=complete --overwrite
kubectl get nodes --show-labels | grep migration
```
**Verification**: All 3 workers show `migration.cilium=complete`

**🚦 GO/NO-GO**: Verify ALL workers stable for 5+ minutes before M2.4

#### M2.4: Migrate kube-main (192.168.178.87) - Control Plane [RP4: CRITICAL]
**⚠️ WARNING: HIGHEST RISK - Control plane failure = cluster down**

**Pre-Flight Check**:
```bash
kubectl get nodes | grep -v control-plane
kubectl get --raw /healthz
kubectl get pods -n kube-system | grep -E "kube-apiserver|kube-controller|kube-scheduler|etcd"
```

**Execute**:
```bash
sleep 120
kubectl cordon kube-main
kubectl drain kube-main --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=10m
kubectl label node kube-main migration.cilium=in-progress --overwrite
ssh decoder@192.168.178.87 "sudo systemctl restart kubelet && sudo systemctl status kubelet --no-pager -l"
sleep 30
kubectl uncordon kube-main
kubectl get nodes kube-main
sleep 60
kubectl get pods -n kube-system | grep -E "kube-apiserver|kube-controller|kube-scheduler|etcd"
kubectl run test-main --image=curlimages/curl --rm -i --restart=Never --overrides='{"spec":{"nodeName":"kube-main"}}' -- curl --connect-timeout 5 http://kubernetes.default.svc.cluster.local/healthz
kubectl run test-dns-main --image=curlimages/curl --rm -i --restart=Never --overrides='{"spec":{"nodeName":"kube-main"}}' -- nslookup kubernetes.default
kubectl label node kube-main migration.cilium=complete --overwrite
kubectl get nodes --show-labels | grep migration
```
**Verification**: Control plane pods Running, API accessible, all 4 nodes migrated

**🔄 Emergency**: If API unreachable, execute RP4 (etcd restore)

---

### Phase 3: Enable Policy Enforcement (Milestone 3)

#### M3.1: Update Cilium Configuration [RP5]
```bash
helm upgrade cilium cilium/cilium \
  --version 1.16.1 \
  --namespace kube-system \
  --set policyEnforcementMode=always \
  --reuse-values

kubectl rollout status daemonset/cilium -n kube-system
cilium config view | grep policyEnforcementMode
cilium connectivity test
```
**Verification**: Policy mode = `always`, connectivity test passes

---

### Phase 4: Cleanup Calico (Milestone 4.1-4.3)

#### M4.1: Verify Cilium Ownership [RP6]
```bash
echo "Cilium endpoints: $(cilium endpoint list --output=json | jq '. | length')"
echo "Total pods: $(kubectl get pods -A --no-headers | wc -l)"
kubectl logs -n kube-system daemonset/calico-node --tail=50 --all-containers=true
```
**Verification**: Endpoints ≈ pods, Calico logs minimal

**🚦 GO/NO-GO**: If Calico still routing → **NO-GO**

#### M4.2: Remove Calico Resources [RP6: POINT OF NO RETURN]
**⚠️ IRREVERSIBLE - After this, rollback requires full restore**
```bash
kubectl delete daemonset calico-node -n kube-system
kubectl delete deployment calico-kube-controllers -n kube-system
kubectl delete namespace tigera-operator --ignore-not-found=true
kubectl delete namespace calico-system --ignore-not-found=true
kubectl delete namespace calico-apiserver --ignore-not-found=true
kubectl get crd | grep projectcalico.org | awk '{print $1}' | xargs -r kubectl delete crd
kubectl get pods -A | grep calico
```
**Verification**: Zero Calico resources

#### M4.3: Clean Node Network Config
```bash
for ip in 87 88 107 111; do
  echo "=== Cleaning node 192.168.178.$ip ==="
  ssh decoder@192.168.178.$ip "
    sudo iptables-save | grep -v calico | sudo iptables-restore
    sudo systemctl restart kubelet
  "
done

for ip in 87 88 107 111; do
  echo "=== Node 192.168.178.$ip ==="
  ssh decoder@192.168.178.$ip "sudo systemctl status kubelet --no-pager | head -3"
done
```
**Verification**: All nodes kubelet active (running)

---

### Post-Migration Verification (Milestone 5)

#### M5.1: Final Checks
```bash
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed
cilium status
kubectl get svc -n kube-system hubble-ui
kubectl get svc -A --field-selector spec.type=LoadBalancer
kubectl get all -A | grep calico
cilium endpoint list
cilium policy get
kubectl run final-test-1 --image=curlimages/curl --rm -i --restart=Never --overrides='{"spec":{"nodeName":"kube-worker3"}}' -- curl --connect-timeout 5 http://kubernetes.default.svc.cluster.local/healthz
kubectl run final-test-2 --image=curlimages/curl --rm -i --restart=Never --overrides='{"spec":{"nodeName":"kube-main"}}' -- curl --connect-timeout 5 http://kubernetes.default.svc.cluster.local/healthz
```
**Verification**: All nodes Ready, all pods Running, no Calico, connectivity OK

**🎉 MIGRATION COMPLETE**

---

## 🆘 EMERGENCY PROCEDURES

### Complete Cluster Failure
See `/tmp/cilium-migration-backup/RESTORE_PROCEDURE.md`
- etcd restore: 10-15 min
- Full restore: 45+ min

### DNS Completely Broken
```bash
kubectl rollout restart deployment/coredns -n kube-system
kubectl wait --for=condition=available deployment/coredns -n kube-system --timeout=2m
```

### Cilium Pods Failing
```bash
kubectl logs -n kube-system -l k8s-app=cilium --tail=100
NODE_IP="192.168.178.X"
NODE_NAME=$(kubectl get nodes -o jsonpath="{.items[?(@.status.addresses[0].address=='$NODE_IP')].metadata.name}")
kubectl delete pod -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=$NODE_NAME
```

---

## 📊 Success Metrics

- [ ] Zero downtime (all services remained accessible)
- [ ] All pods Running (<5 pending/failed)
- [ ] DNS resolution working
- [ ] Cross-node pod communication working
- [ ] MetalLB services accessible
- [ ] Prometheus/Grafana collecting metrics
- [ ] No Calico resources remaining
- [ ] Cilium endpoint count = pod count
- [ ] Migration completed in <4 hours

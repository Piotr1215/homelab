# MetalLB Troubleshooting Runbook

## Common Issue: Services Not Accessible via LoadBalancer IP

### Symptoms
- Services with LoadBalancer type are assigned an IP but not reachable
- `curl http://<LoadBalancer-IP>` returns "Connection refused"
- Service works from inside the cluster but not externally

### Root Causes
1. **Stale ARP cache entries** - Most common issue with Layer 2 mode
2. MetalLB speakers not properly announcing IPs
3. Node changes causing IP reassignment without proper ARP updates
4. Network interface exclusions in speaker configuration

### Quick Fix
```bash
# Restart all MetalLB components
kubectl rollout restart deployment controller -n metallb-system
kubectl delete pod -l component=speaker -n metallb-system

# Wait 15 seconds for stabilization
sleep 15

# Test the service
curl -I http://<service-ip>
```

### Diagnostic Commands
```bash
# Check MetalLB pod status
kubectl get pods -n metallb-system

# Check which node is announcing the service
kubectl describe svc <service-name> -n <namespace> | grep "announcing from"

# Check MetalLB logs
kubectl logs -n metallb-system -l component=controller --tail=50
kubectl logs -n metallb-system -l component=speaker --tail=50

# Check service endpoints
kubectl get endpoints <service-name> -n <namespace>

# Test from inside cluster
kubectl run test-curl --image=curlimages/curl:latest --rm -it --restart=Never -- curl -I http://<cluster-ip>

# Check ARP table on host
arp -n | grep <loadbalancer-ip>
```

### Prevention Strategies

#### 1. Apply Health Check CronJob
```bash
kubectl apply -f metallb/health-check-cronjob.yaml
```

#### 2. Monitor MetalLB in Homepage
The homepage now includes MetalLB monitoring widgets to track:
- Controller status
- Speaker pod health across all nodes

#### 3. Configure More Stable Announcements
Consider pinning services to specific nodes if experiencing frequent failovers:
```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advert
  namespace: metallb-system
spec:
  ipAddressPools:
  - first-pool
  nodeSelectors:
  - matchLabels:
      kubernetes.io/hostname: kube-worker2
```

#### 4. Regular Health Checks
Run the health check script periodically:
```bash
./scripts/check-metallb-health.sh
```

### Long-term Solutions

1. **Consider BGP mode** instead of Layer 2 if your network supports it
2. **Use static ARP entries** on critical systems
3. **Implement proper monitoring** with Prometheus/Grafana
4. **Set up alerts** for MetalLB pod restarts

### Related Issues
- If multiple services fail simultaneously: Check MetalLB controller
- If only one service fails: Check the specific pod/deployment
- If intermittent failures: Check for IP conflicts in the pool range

### Contact
For persistent issues, check:
- MetalLB GitHub issues: https://github.com/metallb/metallb/issues
- Kubernetes Slack #metallb channel
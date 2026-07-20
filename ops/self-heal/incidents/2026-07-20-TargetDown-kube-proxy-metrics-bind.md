# TargetDown — kube-proxy metrics targets (2026-07-20)

- Alert: `TargetDown` (severity warning), heal id `309a872d`
- Labels: job=kube-proxy, namespace=kube-system, service=kube-prometheus-stack-kube-proxy
- Annotation: "100% of the kube-proxy/... targets in kube-system are down."

## Root cause (verified)

kube-proxy itself was healthy: DaemonSet 7/7 Running, service + endpoints
populated on `:10249`. Only the metrics scrape failed. The live `kube-proxy`
ConfigMap in kube-system had:

```
metricsBindAddress: 127.0.0.1:10249
```

so kube-proxy exposed metrics only on each node's loopback. Prometheus scrapes
the pod endpoint IP (e.g. `192.168.178.87:10249`) and got connection-refused
(verified with an in-cluster curl probe → "Could not connect"). Prometheus
reported `up{job="kube-proxy"} = 0` for all 7 nodes.

Cilium `kube-proxy-replacement=false`, so kube-proxy is the real proxy and its
metrics are legitimately wanted; this is not a benign false positive.

## Why it drifted

The Kubespray inventory already declares the correct intent:

`inventory/homelab/group_vars/k8s_cluster/k8s-cluster.yml:175`
```
kube_proxy_metrics_bind_address: 0.0.0.0:10249
```

(with a comment explaining this exact TargetDown alert). The live ConfigMap was
still on the old Kubespray default `127.0.0.1:10249`, meaning that inventory
change was never re-applied by an ansible run after it was made. Config drift,
not a regression. `inventory/` is gitignored, so the source intent lives only on
the box, not in gitops.

## Fix applied (non-destructive)

1. Backed up the ConfigMap → `/tmp/heal-targetdown/kube-proxy-cm.backup.json`.
2. Reconciled live ConfigMap `metricsBindAddress` → `0.0.0.0:10249`
   (`kubectl replace`, jq-edited config.conf).
3. `kubectl rollout restart daemonset/kube-proxy -n kube-system` — rolling,
   iptables/ipvs rules persist across restart, no traffic disruption. Rollout
   completed 7/7.

## Verification

- Direct curl to `192.168.178.87:10249/metrics` → HTTP 200, ~90 KB (was refused).
- `sum(up{job="kube-proxy"})` = 7/7.
- Alert expr `100 * count(up==0)/count(up)` = 0.
- No active or pending `TargetDown` alert for job=kube-proxy in Prometheus.

## Durability / follow-up

- Inventory already correct (`0.0.0.0:10249`), so a future `just ansible-cluster`
  run will keep the fix; it will not revert. No gitops change required.
- No action needed unless the ConfigMap is manually reset again. If this recurs,
  the live ConfigMap has drifted from inventory again — reconcile + restart as above.

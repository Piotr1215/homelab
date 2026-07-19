# Incident: LonghornVolumeDegraded (volume=pvc-785e0a66, pvc=spire-data-spire-spire-server-0)

- Date: 2026-07-19 ~16:39 CEST
- Alert id: 30a7c87cb901
- Severity: warning
- Healer: homelaber-heal-lhdegraded
- Status: NEEDS HUMAN (destructive cleanup deferred). No self-heal applied. SPIRE is healthy.

## What fired

LonghornVolumeDegraded, volume pvc-785e0a66-66f2-4b84-a735-ed6e1f3ee6ee,
pvc=spire-data-spire-spire-server-0, ns spire-server, reported via longhorn-manager
on kube-worker2. A second instance of the same rule is also firing for the falco
redis volume pvc-9f692440 (out of scope for this incident, same benign class).

Alert rule: `longhorn_volume_robustness == 0 for 10m`. Robustness code 0 is
"unknown", which is what Longhorn reports for any DETACHED volume. So despite the
name "Degraded", this rule fires on a volume that stays detached, not on replica
loss. Live metric at diagnosis: longhorn_volume_robustness{volume=pvc-785e0a66} = 0.

## Root cause

The PVC is orphaned leftover, not live data.

- Running pod spire-server-0 (StatefulSet spire-server) mounts PVC
  spire-data-spire-server-0 -> volume pvc-792a0c91, which is attached and
  robustness=healthy on kube-worker5. SPIRE is fully up (pod 3/3, 27d).
- The alerting PVC is spire-data-spire-**spire**-server-0 (doubled name) ->
  volume pvc-785e0a66. It belonged to a former StatefulSet spire-spire-server that
  no longer exists (`get sts spire-spire-server` -> NotFound). No pod mounts it, no
  ownerReferences. It has sat detached (state=detached, robustness=unknown, both
  replicas stopped on kube-worker3/4) for ~91d and trips the rule continuously.
- Origin: commit d9b1847 "fix(spire): drop nameOverride entries that broke
  service/agent naming" renamed the workload. The StatefulSet rename left the old
  per-replica PVC behind (StatefulSets never GC their PVCs).

No Longhorn backup exists for the orphan volume; it holds the superseded SPIRE
datastore from the pre-rename install. Current SPIRE has run fine on the new PVC
for 27d, so the orphan is not needed operationally.

## Why no self-heal was applied

The only fix that clears this alert is deleting the orphaned PVC (the volume can
never re-attach: its workload is gone). Deleting a PVC / PV / Longhorn volume is a
destructive storage op, which the heal charter reserves for the human. Deferred by
design, not because the diagnosis is uncertain.

## Recommended fix (for the human, not run by the healer)

The orphan PV reclaimPolicy is Delete, so removing the PVC cascades to the PV and
the Longhorn volume + replicas in one step.

    # confirm nothing mounts it (expect no output)
    kubectl -n spire-server describe pvc spire-data-spire-spire-server-0 | grep -i 'Used By'

    # delete the orphaned PVC (cascades to PV + Longhorn volume via reclaimPolicy=Delete)
    kubectl -n spire-server delete pvc spire-data-spire-spire-server-0

    # verify the Longhorn volume is gone and the alert clears
    kubectl -n longhorn-system get volume pvc-785e0a66-66f2-4b84-a735-ed6e1f3ee6ee
    curl -s 'http://192.168.178.90:9090/api/v1/query' \
      --data-urlencode 'query=longhorn_volume_robustness{volume="pvc-785e0a66-66f2-4b84-a735-ed6e1f3ee6ee"}'

If you want to keep the old datastore, snapshot/back it up in the Longhorn UI
before deleting. The alert rule carries for:10m, so allow one scrape+hold after
deletion before it resolves.

## Follow-ups (optional)

- The falco redis volume pvc-9f692440 (falco-falcosidekick-ui-redis-data-...-0) is
  detached with no pod and trips the same rule. Same triage: delete if the redis is
  permanently gone, or leave it if intentionally scaled to zero.
- Rule semantics: `robustness == 0` (unknown/detached) firing as "Degraded" is
  noisy for intentionally-idle volumes. Consider gating the rule on volumes that
  have a workload, or splitting detached-vs-degraded, if these recur.

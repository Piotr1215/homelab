# Incident: LonghornVolumeDegraded (volume=pvc-9f692440, pvc=falco-falcosidekick-ui-redis-data-...-redis-0)

- Date: 2026-07-19 ~19:13 CEST
- Alert id: 91da7518c497
- Severity: warning
- Healer: homelaber-heal-longhorn-falco-redis
- Status: RESOLVED (no infra action). Confirmed benign false positive; rule fix
  already deployed in da6eedc; stale alert auto-clears on next hourly evaluation.

## What fired

LonghornVolumeDegraded, volume pvc-9f692440-274e-4181-8c1a-fd2bddbcf091,
pvc=falco-falcosidekick-ui-redis-data-falco-falcosidekick-ui-redis-0, ns falco,
reported via longhorn-manager on kube-worker4. This is the second benign instance
of the same class as the spire orphan (see
2026-07-19-longhornvolumedegraded-spire.md); da6eedc names this exact volume.

## Root cause (false positive, already fixed at the rule level)

The volume is a benign DETACHED idle PVC, not real degradation:

- `longhorn_volume_robustness{volume=pvc-9f692440}` = 0. Code 0 is
  "unknown", which Longhorn reports for any DETACHED volume, not degraded (2).
  It has read 0 continuously for 30h; cluster-wide `robustness==2` is empty.
- Volume state = detached. Both replicas (r-159befec on kube-worker6,
  r-7c480687 on kube-worker4) are healthy (healthyAt set, no failedAt), just
  stopped because the volume is detached.
- The workload is gone: `kubectl -n falco get sts falco-falcosidekick-ui-redis`
  and pod `falco-falcosidekick-ui-redis-0` both NotFound. The falcosidekick UI
  redis was scaled down / removed; its per-replica StatefulSet PVC lingers
  (StatefulSets never GC their PVCs). No live data is at risk.

The alerting rule was already corrected in commit da6eedc: expr changed from
`longhorn_volume_robustness == 0` to `== 2`, so it fires only on genuine replica
loss while attached and stays quiet for detached (0) volumes. That commit was
written specifically to silence this falco redis volume and the spire orphan.

## Why it was still showing "firing" at diagnosis

The rule lives in Prometheus rule group `backup.rules`, which evaluates on a 1h
interval. Timeline (UTC):

- 16:27:01Z last evaluation of backup.rules (old `==0` rule, alert active).
- 16:45:31Z da6eedc committed; ArgoCD synced.
- 16:48:33Z Prometheus config reloaded -> live rule now `== 2`.
- The 2 old active alerts (value 0e+00, activeAt 2026-07-18T14:27) were carried
  across the reload into the new rule object; the group had not re-evaluated
  since (rule health "unknown", lastEvaluation zero-value).
- Next scheduled eval ~17:27:01Z. At that eval, `== 2` returns empty for these
  volumes, so both stale alerts resolve automatically.

Alertmanager already showed no active LonghornVolumeDegraded alert at diagnosis.

## Action taken

None on infra. The remediation (rule scoping) was already in place via da6eedc;
nothing is actually degraded; no safe additional fix is needed and the destructive
option (deleting the orphan PVC) belongs to the human, same as the spire orphan.
This note records the falco-redis instance and the post-reload hourly-eval lag so
a future healer seeing this alert after da6eedc recognizes it as expected residue.

## Follow-up (optional, for the human, not blocking)

`LonghornVolumeDegraded` sits in the 1h `backup.rules` group, so real degradation
would take up to ~1h (+ the 10m `for`) to alert. If faster detection matters,
consider moving it to a shorter-interval group. Out of scope for this incident.

Also: the two detached orphan PVCs (spire pvc-785e0a66, falco redis pvc-9f692440)
can be deleted if the superseded data is confirmed unneeded. Human decision;
deferred as destructive.

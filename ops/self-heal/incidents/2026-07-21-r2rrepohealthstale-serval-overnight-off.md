# R2RRepoHealthStale — serval overnight power-off (2026-07-21)

- Alert: `R2RRepoHealthStale` (severity warning), heal id `db18308292c2`
- Labels: job=r2r-repo-health, namespace=ai-tools, pod=r2r-repo-health-5b7d66784d-s2ncn
- Annotation: "The receiver has accepted no fresh health push for 10h 6m 57s (threshold 1h)."
- Verdict: false positive. Rule retuned in gitops, no infra touched.

## Root cause (verified)

The push pipeline is healthy end to end. The alert threshold assumed serval is a
24/7 host. It is not: it is my workstation and it is powered off every night.

Evidence gathered live:

- Receiver pod up 44h, 0 restarts, `/metrics` served a push timestamp ~30s old
  at investigation time. `r2r_repo_health_push_total` 323,
  `r2r_repo_health_last_push_valid` 1, `r2r_repo_health_up` 1, drift/failed/
  zero-file repo counts all 0 across 9 repos.
- `journalctl --user -u r2r-repo-health-push.service`: pushes every 5 min,
  every one "Finished", up to 23:02 CEST. Then a boot boundary. Next push
  09:12:14 CEST, immediately after boot (`OnBootSec=3min`). No transport error,
  no rejection, no failed unit.
- `journalctl --list-boots` over two weeks: the machine is shut down nightly.
  Measured off-windows: 8h36m, 9h02m, 9h06m, 9h21m, 9h34m, 10h06m, 10h09m,
  10h19m, 10h21m, 10h59m. Every one exceeds the 1h threshold.
- Prometheus `time() - r2r_repo_health_received_timestamp_seconds` over 3 days
  shows the same ramp on the night of 07-19/20 (peaked 8.3h) and last night
  (peaked 9.7h). The alert was structurally guaranteed to fire every morning.

The alert cleared on its own at 09:12 when serval booted and pushed
(staleness back to ~200s, no longer in the Prometheus alerts list).

## Why the old threshold was wrong

While serval is off, the ingester cannot run, so no repo can drift and no sync
can fail. A blind drift-detection window during the power-off costs nothing.
The failure actually worth paging on is a dead push while serval is up and
working, which the 1h threshold could not distinguish from a normal night.

Gating on serval liveness instead would be the sharper fix, but Prometheus has
no serval-sourced target (no node-exporter, no blackbox exporter, no
pushgateway on this cluster), and the health push is itself the only serval
signal, so that gate would be circular. Threshold sizing is the honest option
without adding infra.

## Fix applied (gitops, non-destructive)

`gitops/apps/kube-prometheus-stack/prometheus-rules-homelab.yaml`,
group `r2r-repo-vector.rules`:

```
- expr: time() - r2r_repo_health_received_timestamp_seconds > 3600     # 1h
+ expr: time() - r2r_repo_health_received_timestamp_seconds > 50400    # 14h
```

`for: 15m` and `severity: warning` unchanged. Description now states the 14h
threshold is sized above the nightly power-off, and a comment records the
measured off-windows so the number is not re-litigated blind.

14h clears the longest observed off-window (10h59m) by ~3h while still catching
a push that dies during a working day.

## Verification

- YAML parses; rule present in `r2r-repo-vector.rules` with expr `> 50400`.
- Live alert already cleared after serval's boot push.
- Rule change is inert until the human pushes; ArgoCD then syncs
  kube-prometheus-stack and Prometheus reloads the rule.

## Follow-up

- If serval is ever off for a full day (vacation, >14h), this fires once at
  warning. Acceptable; a further fix would need a real serval liveness signal
  (blackbox probe of serval on the LAN, or a node-exporter on the workstation),
  which is a deliberate infra addition, not a self-heal.
- Nothing else in `r2r-repo-vector.rules` needed retuning; the drift/failure
  rules are already gated on `r2r_repo_health_scan_complete`.

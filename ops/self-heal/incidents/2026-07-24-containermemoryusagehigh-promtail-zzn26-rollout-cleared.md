# ContainerMemoryUsageHigh: promtail-zzn26 cleared by the f115437 rollout

Date: 2026-07-24
Alert: ContainerMemoryUsageHigh (warning)
Trigger pod: loki/promtail-zzn26/promtail on kube-worker6 (96.18% of memory limit)
Verdict: genuine signal, already fixed; alert cleared on its own as the fix rolled out. No new change needed.

## What fired

    summary:     Container loki/promtail-zzn26/promtail memory usage high
    description: Container is using 96.18% of memory limit.

Populated container label, real percentage. This is the exact pod the 2026-07-24
note `containermemoryusagehigh-promtail-limit-bound.md` predicted would fire next
(it listed promtail-zzn26 at 95.1%). Same genuine signal, not a false positive.

## Why no new fix

The durable fix was already committed, pushed, and syncing when this alert fired:

    commit f115437  fix(observability): give promtail memory headroom ...
    gitops/apps/promtail/values.yaml  memory 137Mi -> 256Mi (requests==limits)

At investigation time:
- f115437 was on origin/main (git: local main == origin/main, 0 ahead).
- ArgoCD promtail app = Synced, selfHeal=true, status Progressing.
- DaemonSet desired spec already = 256Mi.
- Rolling update in flight (maxUnavailable=1): updated climbed 3/7 -> 6/7 -> 7/7
  across my checks. The alert pod promtail-zzn26 was replaced on worker6 by
  promtail-v6g82 (256Mi) mid-investigation, then returned NotFound.

A live kubectl patch was neither needed nor safe: desired state was already 256Mi
and the rollout was converging on its own. Interfering would only churn the
DaemonSet.

## Verification (Prometheus 192.168.178.90:9090, kubectl)

After rollout completed, all 7 promtail pods run at 256Mi, working set 30-41% of
limit (was ~95% of 137Mi):

    promtail-v6g82 (worker6, replaced zzn26) . 40.77%
    promtail-hdvbb (worker4, replaced s5fk7) . 35.39%
    others ................................... 30-37%

Firing promtail ContainerMemoryUsageHigh alerts: 0. The 30-41% ratios confirm the
~131 MiB steady-state working set was genuinely limit-bound at 137Mi, not a leak;
256Mi gives the intended ~2x headroom.

## Takeaway

When ContainerMemoryUsageHigh fires on a promtail pod, first check whether the
f115437 rollout (256Mi DaemonSet) has reached that node. A snapshot alert can fire
for an old 137Mi pod that is seconds away from being replaced. Confirm against the
live DaemonSet updated/desired counts before treating it as a new problem.

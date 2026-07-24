# ContainerMemoryUsageHigh: promtail genuinely limit-bound at 137Mi

Date: 2026-07-24
Alert: ContainerMemoryUsageHigh (warning)
Trigger pod: loki/promtail-s5fk7/promtail (95.17% of memory limit)
Verdict: genuine signal (not a false positive), fixed by raising the limit in gitops

## What fired

    summary:     Container loki/promtail-s5fk7/promtail memory usage high
    description: Container is using 94.71% of memory limit.

Populated container label, a real percentage (not `+Inf`). This is a true hit,
the opposite of the 2026-07-23 divide-by-zero flood.

## Context: this is the signal yesterday's rule fix surfaced

On 2026-07-23 (commit 51519e7) the ContainerMemoryUsageHigh rule was corrected
to stop firing on pause-container divide-by-zero. That fix explicitly named the
3 genuine hits it uncovered and left them for later:

    loki/promtail-s5fk7/promtail ....... 96.6%
    loki/promtail-zzn26/promtail ....... 95.1%
    ai-tools/agent-memory-worker/worker  95.0%

This alert is the first of those three coming due. The rule is CORRECT; the
right move is to fix the workload, not retune the rule.

## Live evidence (Prometheus 192.168.178.90:9090, kubectl)

promtail is a DaemonSet in loki ns, 7 pods, limit 137Mi with
requests==limits (Guaranteed QoS). Memory ratio per pod:

    promtail-s5fk7 (worker4) .. 95.17%  130.4 MiB   FIRING
    promtail-zzn26 (worker6) .. 95.35%  130.6 MiB   FIRING
    promtail-bb89x (worker5) .. 73.23%  100.3 MiB
    promtail-6mkpg (worker2) .. 70.85%   97.1 MiB
    promtail-lvf54 (worker1) .. 60.78%   83.3 MiB
    promtail-k9qnb (main) ..... 56.38%   77.2 MiB
    promtail-9dxfn (worker3) .. 52.27%   71.6 MiB

The two firing pods sit on the high-log-volume nodes. No recent OOMKills:
s5fk7 last restart 2026-06-21 (exit 255, reason Unknown, NOT OOMKilled),
Running 32d. Stable but limit-bound: one log burst on worker4/worker6 pushes
working set over 137Mi and OOMKills promtail, dropping log shipping on that
node. That is the failure mode the prior note predicted.

## Fix

gitops/apps/promtail/values.yaml: memory 137Mi -> 256Mi, both request and
limit (keeps Guaranteed QoS). ~2x headroom over the ~131 MiB observed peak,
still modest for a log shipper. CPU (35m, usage 9-15m) left alone: not
alerting, has headroom. Rule untouched: it is doing its job.

promtail ArgoCD app is Synced/Healthy with selfHeal:true, so a live kubectl
patch would be reverted within minutes (and would churn the DaemonSet twice
for nothing). The committed gitops change is the durable fix; it rolls out on
human push + ArgoCD sync, which recreates the pods with the new limit and
clears both firing promtail alerts.

## Out of scope

ai-tools/agent-memory-worker (95.0%) is the third genuine hit and a separate
workload; not this alert. Worth a look next but not touched here.

## Precedent

Continues the 51519e7 thread: that commit fixed the rule's false positives,
this one addresses the real signal the fix revealed. Fixing the workload, not
silencing the alert.

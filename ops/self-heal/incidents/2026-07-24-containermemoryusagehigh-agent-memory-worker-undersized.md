# ContainerMemoryUsageHigh: agent-memory-worker undersized memory limit

Date: 2026-07-24
Alert: ContainerMemoryUsageHigh (warning)
Firing pod: ai-tools/agent-memory-worker-84dfbd94c7-4r4jj, container `worker`, node kube-worker2
Verdict: genuine signal (not a false positive), gitops resource bump

## What fired

    summary:     Container ai-tools/agent-memory-worker-84dfbd94c7-4r4jj/worker memory usage high
    description: Container is using 94.82% of memory limit.

## Why this is real, not noise

This is the same worker that `51519e7` (2026-07-23) surfaced. That heal fixed
the rule's pause-container divide-by-zero and explicitly listed this worker at
~95% as one of 3 genuine hits that had been buried under 615 false ones,
deferred as "worth a look". The rule is now correctly reporting a real
memory-pressure condition, so retuning the rule again would silence a true
signal. The fix belongs on the workload, not the alert.

## Live evidence (Prometheus 192.168.178.90:9090, kubectl)

Working-set trend, 6 days (MiB):

    07-18 21:28   283.9   <- pod start
    07-19 21:28   486.7   <- warmup complete (~24h)
    07-20..07-24  ~486    <- flat plateau, 5 days
    07-23 21:28   508.6   <- spike to 99.3% of the 512Mi limit

    working_set / limit ............ 0.9486
    restart count .................. 0 (no OOMKills yet)
    kubectl top .................... 485Mi

Not a leak: memory warms to a steady plateau and holds. The worker loads
in-process NER + topic-extraction models (ENABLE_NER, ENABLE_TOPIC_EXTRACTION),
which is the resident set. The 512Mi limit is simply too tight for the
workload's legitimate footprint. The single 509Mi spike shows it is one
compaction burst (COMPACTION_EVERY_MINUTES=180) away from an OOMKill; it has
survived on luck, not headroom.

The request was also wrong: 128Mi reserved for a workload that actually holds
~486Mi, a ~4x under-reservation that mis-sizes the scheduler's view.

## Fix

`gitops/apps/agent-memory-server/worker.yaml`, worker container resources:

    requests.memory  128Mi -> 512Mi   (match measured steady state)
    limits.memory    512Mi -> 768Mi   (~37% headroom over the plateau)

replicas left at 1 (compaction uses non-distributed locking; concurrent
workers corrupt the merge index). Image, entrypoint, and liveness probe
untouched.

## Delivery

The agent-memory-server app is ArgoCD-managed with selfHeal, so a live
`kubectl` edit of the limit would be reverted to git state. The commit is the
fix; it takes effect on push + ArgoCD sync, which rolls a new worker pod with
the larger envelope. No live patch attempted. No emergency restart done: the
pod is steady at 486Mi with 0 restarts, so there is no active OOM to firefight,
and a restart would only reset the warmup clock without fixing the sizing.

## Precedent

Follows `51519e7`, which surfaced this exact worker as deferred real signal.
Class of fix is the opposite of a rule retune: the metric was telling the
truth, so the workload envelope was corrected instead of the alert.

# Incident: R2RMemorySyncStale (cronjob=r2r-memory-sync, ns=ai-tools)

- Date: 2026-07-20 ~07:34 UTC
- Alert id: 524994f60415
- Severity: warning
- Healer: homelaber-heal-r2rmemsync
- Status: RESOLVED via gitops (config fix committed; awaits human push + ArgoCD sync to deploy).

## What fired

R2RMemorySyncStale: "CronJob r2r-memory-sync last succeeded 3h 29m 23s ago. New
agent memories won't appear in RAG search."

Rule (gitops/apps/kube-prometheus-stack/prometheus-rules-homelab.yaml):

    expr: time() - kube_cronjob_status_last_successful_time{cronjob="r2r-memory-sync", namespace="ai-tools"} > 3 * 3600
    for: 10m

## Root cause (false-positive alert, real config bug behind it)

The hourly r2r-memory-sync CronJob is actually running and succeeding. Its pods
reach Succeeded, agent-memory API is ok (2060 memories), R2R holds 14831 docs,
all ai-tools memory pods are healthy. The sync completes in a few seconds when
the memory delta is small.

The alert reads `kube_cronjob_status_last_successful_time`, which comes from the
CronJob's `.status.lastSuccessfulTime`. That field only advances when the
CronJob controller observes one of its own child Jobs complete. Here the child
Jobs were being deleted before the controller could persist the timestamp.

The deleter is kube-cleanup-operator (quay.io/lwolf/kube-cleanup-operator:0.8.4).
Its log shows it deleting the child Job about 6 seconds after each hourly
creation:

    07:00:00  cronjob-controller  Created job r2r-memory-sync-29742180
    07:00:06  kube-cleanup-operator  Deleting job 'r2r-memory-sync-29742180'
    07:00:06  kube-cleanup-operator  Deleting pod 'r2r-memory-sync-29742180-dfx2x'
    07:00:xx  cronjob-controller  Active job went missing: r2r-memory-sync-29742180

Same pattern at 02:00, 03:00, 04:00, 05:00, 06:00, 07:00 (descheduler jobs are
hit identically). The 04:00 run won the race and recorded
lastSuccessfulTime=04:00:05Z; 05/06/07 lost, so `time() - lastSuccessfulTime`
crossed 3h and the alert fired. This is a race, so it is nondeterministic.

Why the operator deletes so fast: its manifest set

    - name: IGNORE_OWNED_BY_CRONJOB
      value: "false"

directly under a comment reading "Don't delete jobs created by CronJob by
default". The value contradicts the intent. With the flag false the operator
manages CronJob-owned Jobs and deletes them right after the pod Succeeds,
ignoring DELETE_SUCCESSFUL_AFTER=3600 for that code path, which races every
CronJob's status update. Note: the operator only deletes pods already in
Succeeded phase, so the sync work itself was never truncated; only the metric
stalled.

## Remediation applied (non-destructive, one attempt, gitops)

Set the flag to match its documented intent:

    - name: IGNORE_OWNED_BY_CRONJOB
      value: "true"

File: gitops/apps/kube-cleanup-operator/kube-cleanup-operator.yaml

With this, the operator ignores CronJob-owned Jobs and Kubernetes' native
CronJob history limits handle cleanup (r2r-memory-sync has
successfulJobsHistoryLimit=3, failedJobsHistoryLimit=3). Child Jobs then live
long enough for the controller to persist lastSuccessfulTime. Fixes the same
latent race for every CronJob on the cluster (descheduler included).

## Why not a live patch

ArgoCD app kube-cleanup-operator has automated selfHeal=true, so a live
`kubectl set env` would be reverted within one reconcile. The durable fix must
go through gitops. Per the never-push rule, the change is committed locally; the
human's push + ArgoCD sync deploys it (operator pod restarts with the new env).

## Verification / expected clear

After deploy: the next r2r-memory-sync run (top of the hour) survives, the
CronJob controller persists lastSuccessfulTime, `time() - lastSuccessfulTime`
drops below 3h, and R2RMemorySyncStale clears after its 10m `for`. Until deploy,
the alert may keep flapping (each hourly run still races). No data risk: memories
continue syncing regardless, because the operator only ever removed already-
completed Jobs.

## Why not retune the alert rule

The rule is sound (a 3h staleness guard on RAG freshness). The signal was
stalled by an external deleter, not by a miscalibrated threshold, so the correct
fix is at the source (the operator config), not the rule.

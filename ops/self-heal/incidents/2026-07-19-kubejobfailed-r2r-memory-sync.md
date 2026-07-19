# Incident: KubeJobFailed (job=r2r-memory-sync, ns=ai-tools)

- Date: 2026-07-19 ~17:05 UTC
- Alert id: aa6c76488d2a
- Severity: warning
- Healer: homelaber-heal-kubejobfailed
- Status: RESOLVED. Alert cleared after one non-destructive remediation.

## What fired

KubeJobFailed on two jobs in namespace ai-tools, both children of the hourly
CronJob `r2r-memory-sync`:

- r2r-memory-sync-29739660 (scheduled 2026-07-18 13:00 UTC)
- r2r-memory-sync-29739720 (scheduled 2026-07-18 14:00 UTC)

Both failed ~28h before the alert was handled.

## Root cause

Both jobs failed with reason `DeadlineExceeded` ("Job was active longer than
specified deadline"). Job condition on 29739660:

    FailureTarget: DeadlineExceeded  (2026-07-18T13:05:00Z)
    Failed:        DeadlineExceeded  (2026-07-18T13:05:31Z)

The CronJob does a full agent-memory -> R2R reconciliation each hour
(gitops/apps/r2r/cronjob-memory-sync.yaml). Its job template sets
activeDeadlineSeconds=3000 (50 min). Those two runs exceeded it, most likely a
one-time heavy reconciliation / slow embedding pass, and were killed.

The failure was transient and already self-resolved. The CronJob has run
cleanly every hour since: lastSuccessfulTime 2026-07-19T17:01:48Z, with the
17:00 run (r2r-memory-sync-29741340) completing in ~2 minutes. No ongoing
failures, concurrencyPolicy=Forbid, suspend=false.

The alert kept firing only because the two failed Job tombstones were retained
by failedJobsHistoryLimit=3, so kube-state-metrics kept exporting
`kube_job_failed{job_name=...}=1` for them. Confirmed against live Prometheus:
both `kube_job_failed > 0` and the two firing `ALERTS{alertname="KubeJobFailed"}`
series mapped exactly to those two job names, nothing else.

## Remediation applied (non-destructive, one attempt)

Deleted the two stale failed Job objects (the runbook_url annotation endorses
this: "Removing failed job after investigation should clear this alert"). The
pods were already gone; a failed batch Job object holds no data, so this is
cleanup, not a destructive op.

    kubectl -n ai-tools delete job r2r-memory-sync-29739660 r2r-memory-sync-29739720

## Verification

- `kubectl -n ai-tools get jobs | grep memory-sync` -> none remaining.
- Prometheus `kube_job_failed{namespace="ai-tools",job_name=~"r2r-memory-sync.*"} > 0`
  went from 2 series to 0 within one scrape.
- `ALERTS{alertname="KubeJobFailed",namespace="ai-tools",alertstate="firing"}`
  went from 2 to 0.

## Why no rule / manifest change

The alert rule (kube-prometheus-stack KubeJobFailed) is standard and fired on a
genuine job failure, not a false positive. The 3000s deadline is generously
sized versus the normal ~2-minute runtime, so it is not miscalibrated; the
28h-old failures were a one-off. No gitops change is warranted. If long
reconciliations recur, revisit activeDeadlineSeconds or shard the sync, but
there is no evidence of that today (every run since has succeeded).

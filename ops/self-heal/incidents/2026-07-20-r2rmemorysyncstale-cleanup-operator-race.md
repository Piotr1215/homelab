# Incident: R2RMemorySyncStale (cronjob=r2r-memory-sync, ns=ai-tools)

- Date: 2026-07-20 ~07:34 UTC
- Alert id: 524994f60415
- Severity: warning
- Healer: homelaber-heal-r2rmemsync (then continued interactively with the human)
- Status: RESOLVED via gitops after a corrected second commit. First commit
  (3d23ba6) was INEFFECTIVE; the working fix is a follow-up commit.

## What fired

R2RMemorySyncStale: "CronJob r2r-memory-sync last succeeded 3h 29m 23s ago. New
agent memories won't appear in RAG search."

Rule (gitops/apps/kube-prometheus-stack/prometheus-rules-homelab.yaml):

    expr: time() - kube_cronjob_status_last_successful_time{cronjob="r2r-memory-sync", namespace="ai-tools"} > 3 * 3600
    for: 10m

## Root cause (false-positive alert; real config bug in kube-cleanup-operator)

The hourly r2r-memory-sync CronJob is actually running and succeeding (pods reach
Succeeded; agent-memory API ok with 2060 memories; R2R 14831 docs; all pods
healthy). The alert reads `kube_cronjob_status_last_successful_time`, sourced
from the CronJob's `.status.lastSuccessfulTime`, which only advances when the
CronJob controller observes one of its own child Jobs complete.

kube-cleanup-operator (quay.io/lwolf/kube-cleanup-operator:0.8.4) deletes each
child Job ~4-6s after it is created, before the controller records the success:

    07:00:00  cronjob-controller     Created job r2r-memory-sync-29742180
    07:00:06  kube-cleanup-operator  Deleting job 'r2r-memory-sync-29742180'
    07:00:xx  cronjob-controller     Active job went missing: r2r-memory-sync-29742180

Same pattern every hour (descheduler jobs hit identically). The 04:00 run won the
race and recorded lastSuccessfulTime=04:00:05Z; 05/06/07 lost, crossing 3h. This
is a nondeterministic race. The operator only ever deletes pods already in
Succeeded phase, so the sync work itself is never truncated; only the metric
stalls.

### The real bug (why the first fix failed)

kube-cleanup-operator 0.8.4 is configured by COMMAND-LINE FLAGS, not environment
variables. The deployment had only env vars set (DELETE_SUCCESSFUL_AFTER,
IGNORE_OWNED_BY_CRONJOB, ...), which the binary ignores entirely. Proof:

- `/proc/1/cmdline` inside the pod = `./kube-cleanup-operator` with NO flags.
- `--help` shows all config is flags; defaults are `-legacy-mode=true` and, in
  legacy mode, `-keep-successful=0` = never keep = delete successful jobs
  immediately.

So for 240 days the operator ran on defaults (legacy mode, delete-successful
immediately), which is exactly why child jobs vanished in seconds. Every env var
in the manifest was decorative. DELETE_SUCCESSFUL_AFTER=3600 was never honored
(hence 6s deletions, not 1h).

## Remediation

### First attempt (commit 3d23ba6) — INEFFECTIVE, do not rely on it

Changed env `IGNORE_OWNED_BY_CRONJOB` from "false" to "true". Deployed and the
operator pod restarted, but it STILL deleted a cronjob-owned job at 07:45:04
(descheduler-29742225) because env vars are ignored. Lesson: verify the operator
actually consumes the setting (check `/proc/1/cmdline`), not just that the pod
restarted.

### Working fix (follow-up commit) — flags instead of env

Replaced the inert env block with real args in
gitops/apps/kube-cleanup-operator/kube-cleanup-operator.yaml:

    args:
    - -legacy-mode=false           # activate delete-*-after (legacy keep-* deletes now)
    - -ignore-owned-by-cronjobs    # leave CronJob children to their history limits
    - -delete-successful-after=1h
    - -delete-failed-after=24h
    - -delete-pending-pods-after=24h
    - -delete-orphaned-pods-after=1h

Two independent guarantees that the metric stops stalling:
1. `-ignore-owned-by-cronjobs` (new-mode only, hence `-legacy-mode=false`) makes
   the operator skip CronJob-owned jobs entirely; CronJob history limits
   (successfulJobsHistoryLimit/failedJobsHistoryLimit, both 3 here) reap them.
2. Even if that experimental flag misbehaved, `-delete-successful-after=1h` gives
   every successful job a 1h grace window, far longer than the controller needs
   to persist lastSuccessfulTime.

## Deploy / verification

ArgoCD app kube-cleanup-operator has automated selfHeal=true, so live patches are
reverted; the fix must go through gitops (commit; human pushes; ArgoCD syncs;
operator restarts with new args). Per the never-push rule, changes are committed
locally.

Verify after deploy:
- `kubectl exec deploy/kube-cleanup-operator -- cat /proc/1/cmdline` shows the new
  flags (NOT bare `./kube-cleanup-operator`).
- Operator log stops emitting "Deleting job 'descheduler-...'" / "r2r-memory-sync-..."
  at the next descheduler tick (5-min cadence = fast confirmation).
- r2r-memory-sync `.status.lastSuccessfulTime` advances past 04:00:05Z on the next
  hourly run; `R2RMemorySyncStale` clears (expr false → resolves at next eval).

No data risk on any path: the operator only ever removed already-Succeeded jobs,
so memory sync was never interrupted; this was a false-positive staleness alert.

## Why not retune the alert rule

The rule is sound (a 3h RAG-freshness guard). The signal was stalled by an
external deleter using a broken config, not by a miscalibrated threshold, so the
fix belongs at the source (operator flags), not the rule.

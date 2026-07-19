# Incident: R2RRepoCacheDrift (repo=claude-wt, source=commit)

- Date: 2026-07-19 ~16:35 CEST
- Alert id: 324a18f8b877
- Severity: warning
- Healer: homelaber-heal-claude-wt
- Status: RESOLVED. One remediation attempt (reconcile --fix), drift cleared to 0
  and pushed; alert resolves on the next Prometheus eval.

## What fired

R2RRepoCacheDrift, repo=claude-wt, source=commit, ns=ai-tools. The commit hash
cache disagrees with the live R2R store by one document.

Live evidence at diagnosis:
- commit: live=69, cache=68, expected=69, drift=+1, flags [cache_desync]
- file: drift=0 (healthy)
- last_run: result=failed, failed=1
- Prometheus r2r_repo_drift_documents{repo="claude-wt",source="commit"} = 1

## Root cause

A cache_desync in the opposite direction from the homelab/file incident earlier
today. Here the store is AHEAD of the cache: read-only reconcile showed

    cache_keys=108, store_keys=109, in_store_not_cache=1, in_cache_not_store=0,
    orphan_store_docs=0, in_sync=False
    missing key: claude-wt:commit:f5980f6cdd99e25ce5d82cce88cf3d3ecda3d7ab

The last sync (result=failed) inserted commit f5980f6 into the R2R store, then
failed before persisting the cache update, leaving the store one commit ahead of
the local hash cache. Retrieval was NOT stale or incomplete: the store already
held the doc (live=expected=69). Only local bookkeeping was behind.

## Remediation (sanctioned category: non-destructive cache repair)

    python3 ~/.claude/scripts/__r2r_repo_manage.py reconcile claude-wt --fix

reconcile edits the LOCAL cache only and never touches the store (hard invariant).
For in_store_not_cache it ADDs the missing key; the reverse-wipe guard did not
trip (store read healthy at 109 keys, removal set empty), so no --force was
needed. Applied: added_to_cache=1, removed_from_cache=0.

Chose reconcile --fix over the runbook's resync --force because the drift is
store-ahead-of-cache: the store is already complete, so a --force re-ingest is the
wrong hammer (multi-minute, and risks a duplicate store doc), while reconcile
repairs exactly the one stale cache key. Yesterday's homelab/file note also
established that resync --force cannot clear a cache_desync on its own.

## Verification

    reconcile (dry): cache_keys=109, store_keys=109, in_sync=true
    status: live commits=69, state_file commits=69
    __r2r_repo_health_push.sh -> push ok http=200
    pod-served r2r_repo_drift_documents{repo="claude-wt"} commit=0 file=0
    Prometheus r2r_repo_drift_documents{repo="claude-wt",source="commit"} = 0

The alert rule carries for:30m (pending only); resolution is not delayed by it.
Once Prometheus re-evaluates the rule against drift=0 the firing alert clears.

## Follow-up for the human (optional)

The root cause was a failed sync (last_run result=failed) that left the store
ahead of the cache. If claude-wt syncs keep failing, check the ingest log
(~/.local/state/r2r-repo-sync.log) for the underlying cause; this reconcile fixes
the symptom (the cache gap), not a recurring sync failure.

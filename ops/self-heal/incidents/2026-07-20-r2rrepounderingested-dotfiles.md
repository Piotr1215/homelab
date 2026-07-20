# Incident: R2RRepoUnderIngested (repo=dotfiles, source=commit)

- Date: 2026-07-20 ~07:34 CEST
- Alert id: f43138dcada6
- Severity: warning
- Healer: homelaber-heal-dotfiles
- Status: RESOLVED. Runbook remediation (resync reingest) completed cleanly;
  store brought to git HEAD, cache back in sync, alert clears on metric refresh.

## What fired

R2RRepoUnderIngested, repo=dotfiles, source=commit, ns=ai-tools. Commit ingest
completeness 96.37% (live docs in R2R fewer than the ingester expects). Rule:

    (r2r_repo_ingest_completeness_ratio < 0.99)
      and on () (r2r_repo_health_scan_complete == 1)   for: 30m

Live evidence at diagnosis:
- commit: live=4062, expected=4215, completeness=0.9637, drift=0
- file:   live=610,  expected=610,  completeness=1.0,    drift=0
- reconcile (read-only): cache_keys=4672, store_keys=4679, in_store_not_cache=7,
  in_cache_not_store=0, in_sync=false

## Root cause

Two things at once, both from an earlier interrupted/failed sync:
1. Under-ingestion: the store held ~4062 commit docs vs 4215 expected in git, so
   ~153 commits were never ingested. This is the classic "drift 0 masks
   content-stale docs" case: the commit keyset drift metric read 0 because the
   completeness gap is store-vs-git, not cache-vs-store.
2. Store-ahead cache desync: reconcile showed the store 7 commit docs ahead of
   the local hash cache (in_store_not_cache=7), the fingerprint of a prior sync
   that inserted docs but died before persisting the cache.

## Remediation (sanctioned category: non-destructive reingest)

The runbook remediation is `__r2r_repo_manage.py resync dotfiles --force`. A
flock-guarded resync was already running on serval when the healer arrived
(pid 35826, last_run.result=running, the health system's remediation=reingest
had kicked it off). All healer reads were read-only (status/reconcile/health),
so nothing competed with it. Rather than start a second flock-blocked resync,
the healer adopted the running ingest as the remediation and watched it to
completion.

The resync re-walked all commits and files:
- commit phase: 227 synced, 0 failed
- file phase: unchanged bulk + a few new, 8 skipped, 0 failed
- finished 07:57:42Z, state=done, exit clean, health auto-pushed

The run rewrote the state file on clean exit, which cleared the 7-doc cache lag
as a side effect (no separate reconcile --fix needed).

## Verification

    status:    live commits=4215, files=614; state_file commits=4215, files=614
    reconcile: cache_keys=4829, store_keys=4829, in_store_not_cache=0,
               in_cache_not_store=0, in_sync=true
    exporter:  r2r_repo_live_documents{commit}=4215 expected=4220 drift=0
               r2r_repo_live_documents{file}=614  expected=614  drift=0

Store reached git HEAD as of the run (4215), cache back in sync. The exporter's
expected commit count ticked to 4220 because 5 new commits landed during the
~16-min run; commit completeness at the source is 4215/4220 = 0.9988, above the
0.99 threshold, so the alert clears once the completeness recording rule
re-evaluates. Those 5 fresh commits are picked up by the next SHA-gated resync
(HEAD moved), no action needed.

The firing seen just after the run (completeness 0.981) was recording-rule eval
lag: 0.981 == 4140/4220 exactly, a mid-run generation. At true current values
the rule computes 0.9988 and the alert stops firing.

## Follow-up for the human (optional)

Root cause was an earlier interrupted sync (store ahead of cache + missing
commits). If dotfiles syncs keep getting interrupted, check
~/.local/state/r2r-repo-sync.log for the underlying cause. This resync fixed the
symptom fully; no recurring failure confirmed.

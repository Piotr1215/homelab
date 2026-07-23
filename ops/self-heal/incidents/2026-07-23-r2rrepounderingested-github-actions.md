# Incident: R2RRepoUnderIngested (repo=github-actions, source=file)

- Date: 2026-07-23 ~08:31 CEST
- Alert id: b1a2b183e785
- Severity: warning
- Healer: homelaber-heal-r2r-gha
- Status: RESOLVED. Runbook remediation (resync --force reingest) completed
  cleanly; the 5 missing file docs were ingested, store now at git HEAD, cache
  in sync. Alert clears on the next completeness recording-rule eval.

## What fired

R2RRepoUnderIngested, repo=github-actions, source=file, ns=ai-tools. File ingest
completeness 97.96% (live docs in R2R fewer than a full ingest expects). Rule:

    (r2r_repo_ingest_completeness_ratio < 0.99)
      and on () (r2r_repo_health_scan_complete == 1)   for: 30m

where the ratio is a recording rule in group r2r-repo-vector.rules:

    r2r_repo_ingest_completeness_ratio = r2r_repo_live_documents / (r2r_repo_expected_documents > 0)

Live evidence at diagnosis:
- file:   live=240, expected=245, completeness=0.9796, drift=0
- commit: live=174, expected=175, completeness=0.9943 (above threshold), drift=0
- reconcile (read-only): cache_keys=519, store_keys=519, in_store_not_cache=0,
  in_cache_not_store=0, in_sync=true
- last_run.result=ok, failed=0 (the prior sync 18h earlier was clean, NOT failed)

## Root cause

Genuine under-ingestion of 5 files, NOT a false positive. The store held 240
file docs where a full ingest at ref origin/main (sha 93453c4) should hold 245,
a leftover from an earlier partial run. This is the "drift 0 masks content-stale
docs" case: the keyset drift metric read 0 because cache and store agreed
(both 240), so the SHA-gated incremental resync never re-picked the stragglers.

Confirmed the metric is correctly calibrated before acting: re-derived both sets
from local git at the current ref. The manage tool's expected count uses git
numstat (skip binary `-`, skip empty `0/0`); the ingester skips empty raw +
`is_binary` (NUL in first 8000 bytes). Recomputing the ingester's own filter
over ls-tree yielded exactly 245 ingestable files == expected 245, with a zero
symmetric difference. So the 5-file gap was real missing content, not a
classifier mismatch. Retuning the rule would have been wrong here.

## Remediation (sanctioned category: non-destructive reingest)

Runbook remediation: `__r2r_repo_manage.py resync github-actions --force`. No
resync was running (last done 18h prior), so the healer launched one, backgrounded
it, and polled to completion. reconcile --fix was NOT needed: drift=0, cache
in_sync, and last_run.result=ok (the "do both" path is only for a desync that
followed a FAILED sync).

Run walked commit -> file -> pr phases, failed=0, finished 2026-07-23T08:40:03Z,
state=done, health auto-pushed.

## Verification

    status:    live commits=175, files=245, prs=106; state_file identical
    health:    live=expected for commits(175) and files(245); drift 0; flags=[]
               (under_ingested cleared); file completeness=1.0, commit=1.0
    reconcile: cache_keys=526, store_keys=526, in_store_not_cache=0,
               in_cache_not_store=0, in_sync=true
    prometheus raw gauges: r2r_repo_live_documents{file}=245 expected=245

Store reached git HEAD (commits 175, files 245). The resync also picked up the
1 missing commit and 1 new PR that had landed. Post-run the recording rule
r2r_repo_ingest_completeness_ratio{file} briefly still read 0.9796 (= 240/245):
its last eval (08:39:24Z) predated the resync finish (08:40:03Z). The raw
live/expected gauges already read 245/245, so on the next rule eval the ratio
recomputes to 1.0, the alert expr goes false, and the alert resolves (the 30m
`for:` only delays firing, not clearing). Same recording-rule eval lag noted in
the 2026-07-20 dotfiles incident.

## Follow-up for the human (optional)

Root cause was an earlier partial/interrupted ingest leaving 5 files unwritten
while cache and store stayed mutually consistent (so drift stayed 0 and the
incremental resync never retried them). If github-actions under-ingestion
recurs, check ~/.local/state/r2r-repo-sync.log for the interrupted run. A
periodic `resync --force` (full re-walk, ignores the SHA gate) is the general
cure for drift-0 content-stale gaps. This run fixed the symptom fully.

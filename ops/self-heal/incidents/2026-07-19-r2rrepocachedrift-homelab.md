# Incident: R2RRepoCacheDrift (repo=homelab, source=file)

- Date: 2026-07-19 ~16:05 CEST
- Alert id: 85e2e9b209d4
- Severity: warning
- Healer: homelaber-heal-r2rdrift
- Status: NEEDS HUMAN. One sanctioned remediation attempted, drift not cleared.

## What fired

R2RRepoCacheDrift, repo=homelab, source=file, ns=ai-tools. The file hash cache
disagrees with the live R2R store by one document.

Live Prometheus / r2r-repo-health at diagnosis:
- file: cache=256, live=255, expected=257, drift=-1, completeness=0.992,
  flags [cache_desync, under_ingested]
- commit: drift=0, completeness=1.0 (healthy)

## Root cause

This is a cache_desync, not a stale git delta. The local hash cache
(~/.local/state/r2r-repo-homelab-hashes.json) records one file doc as synced
that the R2R store does not actually hold (a phantom key). Confirmed by a
read-only reconcile:

    cache_keys=1253, store_keys=1252, in_store_not_cache=0,
    in_cache_not_store=1, in_sync=False

The ingester is incremental and trusts its cache, so it treats the phantom doc
as already-synced and skips it on every run. That is why live stays at 255.

## Remediation attempted (sanctioned, one attempt)

    python3 ~/.claude/scripts/__r2r_repo_manage.py resync homelab --force

Ran to completion (not store-busy-deferred): resync done 16:06:28Z, immediate
health push 16:06:31Z. Exit 0. Post-resync health scan still shows file
drift=-1, flags [cache_desync, under_ingested]. resync --force cannot clear a
cache_desync because it does not bypass the per-doc cache skip. That is the job
of the separate reconcile command.

## Recommended fix (for the human, not run by the healer)

reconcile edits the LOCAL cache only and never deletes from the store (hard
invariant in the script). The store read is healthy (1252 keys, non-zero), so
the reverse-wipe guard will not trip and --force is not needed.

    # 1. remove the 1 phantom key from the local cache
    python3 ~/.claude/scripts/__r2r_repo_manage.py reconcile homelab --fix
    # 2. re-run the delta so the store re-inserts the doc
    python3 ~/.claude/scripts/__r2r_repo_manage.py resync homelab --force
    # 3. verify drift returns to 0
    curl -s 'http://192.168.178.90:9090/api/v1/query' \
      --data-urlencode 'query=r2r_repo_drift_documents{repo="homelab",source="file"}'

Note expected=257 vs live=255 is 2 short (under_ingested). Reconcile+resync
re-inserts the phantom (live -> 256); confirm whether the remaining 1 is a
genuinely skipped file (binary/empty) or needs a follow-up delta.

The alert rule carries for:30m, so it will not resolve the instant drift hits 0;
allow one scrape+hold after the fix.

# ContainerMemoryUsageHigh: pause container divide-by-zero fires on every pod

Date: 2026-07-23
Alert: ContainerMemoryUsageHigh (warning)
Trigger pod: harbor/harbor-trivy-0 (arbitrary; 251 pods were firing)
Verdict: false positive, rule fixed in gitops

## What fired

    summary:     Container harbor/harbor-trivy-0/ memory usage high
    description: Container is using +Inf% of memory limit.

Two tells in the payload itself: the container field in the summary is empty,
and the value renders as `+Inf%`. The firing series carried
`image=registry.k8s.io/pause:3.10.1`.

## Root cause

The rule expr had no series filtering:

    (container_memory_working_set_bytes / container_spec_memory_limit_bytes) > 0.9

Every pod runs a pause/sandbox container that reports
`container_spec_memory_limit_bytes = 0`. In PromQL `x / 0` is `+Inf`, and
`+Inf > 0.9` is always true, so the rule matched every pod in the cluster
regardless of actual memory use. Containers that simply declare no memory
limit hit the same path.

## Live evidence (Prometheus 192.168.178.90:9090)

    firing alerts from this rule ................... 618
    distinct pods affected ........................ 251
    series with memory limit == 0 ................. 612
    series with empty container label (pause) ..... 541
    matches of the broken expr .................... 618
    containers genuinely over 90% of a real limit .. 3

615 of 618 firing alerts were artifacts.

The trigger pod was healthy: `harbor-trivy-0` has one real container `trivy`
with a 1Gi limit, using 0.7% of it, Running 32d with 0 restarts.

## Fix

Filter the series on both sides of the division:

    (container_memory_working_set_bytes{container!=""} / (container_spec_memory_limit_bytes{container!=""} > 0)) > 0.9

`container!=""` drops pause/sandbox and pod-level rollup series. The `> 0`
guard on the denominator drops containers with no declared limit, so the
division only runs where a real limit exists. This is the standard
kube-prometheus-stack pattern.

Validated against live Prometheus before commit: the corrected expr returns
exactly 3 series, all with populated namespace/pod/container labels, and zero
`+Inf` values.

## Real signal that was buried

The 3 genuine hits were invisible under 615 false ones. Fixing the rule
surfaces them rather than silencing them:

    loki/promtail-s5fk7/promtail ................. 96.6%
    loki/promtail-zzn26/promtail ................. 95.1%
    ai-tools/agent-memory-worker-.../worker ...... 95.0%

Two promtail pods and the agent-memory worker are sitting near their limits.
Not addressed here (out of scope for this alert, and not obviously wrong for
a log shipper at steady state), but they are worth a look: if promtail is
genuinely limit-bound it will start getting OOMKilled under log bursts.

## Delivery note

The kube-prometheus-stack ArgoCD app runs `selfHeal: true`, so patching the
live PrometheusRule with kubectl would be reverted to the remote git state
within minutes. The commit is the fix; it takes effect when the human pushes
and ArgoCD syncs. No live patch was attempted for that reason.

## Precedent

Same class as `da6eedc` (LonghornVolumeDegraded matched detached volumes, not
just degraded ones) and `44518df` / `6f4d033` (r2r rule thresholds retuned).
Pattern: homelab alert rules written without filtering against the benign
states of the underlying metric. Worth auditing the rest of
`prometheus-rules-homelab.yaml` for unguarded divisions the same way.

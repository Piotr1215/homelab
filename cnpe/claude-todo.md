# CNPE Lab Setup - Action Plan

## Exam Overview
- **17 tasks in 2 hours** = ~7 min per task
- **Pass score**: 64%
- **K8s version**: v1.34

## Official Exam Tools (pick one per category)
Argo, Crossplane, Flagger, Flux, Gatekeeper, Grafana, Istio, Jaeger, Kyverno, Linkerd, OPA, OpenCost, OpenTelemetry, Prometheus, Tekton

**Note**: NOT tested on deep tool-specific knowledge unless referenced in domains.

## Domain Coverage

### 1. GitOps and Continuous Delivery (25%)
**Tools**: ArgoCD, Argo Rollouts, Tekton

| Exercise | Tool | Status |
|----------|------|--------|
| 01-fix-broken-sync | ArgoCD | ✅ Done |
| 02-canary-deployment | Argo Rollouts | ✅ Done |
| 03-tekton-trigger | Tekton Triggers | ✅ Done |
| 04-environment-promotion | ArgoCD ApplicationSets | ❌ TODO |

### 2. Platform APIs and Self-Service (25%)
**Tools**: Crossplane, Custom CRDs, Operators

| Exercise | Tool | Status |
|----------|------|--------|
| 01-fix-composition | Crossplane | ⏭️ Skipped (user knows well) |
| 02-custom-crd | Custom CRDs | ❌ TODO |
| 03-operator-troubleshoot | Operators | ❌ TODO |

### 3. Observability and Operations (20%)
**Tools**: Prometheus, Grafana, Jaeger/OpenTelemetry

| Exercise | Tool | Status |
|----------|------|--------|
| 01-prometheus-alert | Prometheus | ❌ TODO |
| 02-grafana-dashboard | Grafana | ❌ TODO |
| 03-tracing | Jaeger/Tempo | ❌ TODO |

### 4. Platform Architecture (15%)
**Tools**: Networking, Storage, OpenCost, Service Mesh

| Exercise | Tool | Status |
|----------|------|--------|
| 01-network-policy | Cilium/NetworkPolicy | ❌ TODO |
| 02-storage-class | Longhorn/StorageClass | ❌ TODO |
| 03-cost-allocation | OpenCost | ❌ TODO (need to install) |
| 04-service-mesh | Istio (ambient) | ❌ TODO (need to install) |

### 5. Security and Policy Enforcement (15%)
**Tools**: Kyverno, RBAC

| Exercise | Tool | Status |
|----------|------|--------|
| 01-fix-broken-policy | Kyverno | ✅ Done |
| 02-rbac-troubleshoot | RBAC | ❌ TODO |

## Tool Installation Status

### Installed in Cluster
- [x] ArgoCD
- [x] Argo Rollouts
- [x] Tekton (Pipelines v1.6.0, Triggers v0.34.0, Dashboard v0.63.1)
- [x] Kyverno v1.16.1
- [x] Prometheus + Grafana (kube-prometheus-stack)
- [x] Tempo (tracing)
- [x] Loki (logging)
- [x] Cilium (networking)
- [x] Longhorn (storage)
- [x] Harbor (registry)

### Need to Install
- [ ] OpenCost
- [ ] Istio (ambient mode)

### CLI Tools (devbox)
- [x] KUTTL v0.24.0
- [x] ArgoCD CLI
- [x] Tekton CLI (tkn) v0.43.0
- [x] Kyverno CLI v1.15.2
- [ ] istioctl

## Exercise Infrastructure

### Completed
- [x] Folder structure (cnpe/, docs/, exercises/)
- [x] Runner script (scripts/run-exercise.sh) with timer
- [x] KUTTL test framework
- [x] kuttl-test.yaml per domain

### Notes
- Exercise pattern: `setup.yaml` (broken state) + `XX-assert.yaml` (wait for fix)
- KUTTL naming: must be `XX-assert.yaml` (numbered prefix required)
- `steps.txt` format: `0:Description`
- `answer.md` for solutions (encrypt later with age)
- Pin versions for external resources (avoid CRD drift)
- Add `ignoreDifferences` for CRDs: `.metadata`, `.status`, `.spec.conversion`

## Priority Order
1. ~~GitOps exercises~~ (mostly done)
2. **Security exercises** (RBAC next)
3. Observability (Prometheus/Grafana/tracing)
4. Platform APIs (CRDs, Operators)
5. Architecture (NetworkPolicy, Storage, OpenCost, Istio)

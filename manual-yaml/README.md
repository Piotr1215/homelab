# Manual YAML Manifests

**This directory is NOT tracked by ArgoCD.**

Contains Kubernetes manifests that are applied manually via `kubectl apply`.
These resources are NOT part of GitOps workflow.

## Usage

Apply manually:
```bash
kubectl apply -f manual-yaml/<dir>/
```

## Directories

- `spin/` - Spin Operator and WebAssembly runtime setup

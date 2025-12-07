# Answer: Fix OutOfSync ArgoCD Application

## What Was Broken

The Application `cnpe-broken-app` has an incorrect `spec.source.path`:
- **Wrong:** `guestbook-broken` (does not exist in repo)
- **Correct:** `guestbook` (or any valid path in the repo)

## How to Diagnose

1. Check Application status:
   ```bash
   kubectl get app cnpe-broken-app -n argocd -o yaml
   ```

2. Look at sync status message - it will show path not found error

3. Or use ArgoCD CLI:
   ```bash
   argocd app get cnpe-broken-app
   ```

4. Or check ArgoCD UI - the app will show error about missing path

## Solution

Edit the Application and fix the path:

```bash
kubectl patch app cnpe-broken-app -n argocd --type merge -p '{"spec":{"source":{"path":"guestbook"}}}'
```

Or edit directly:
```bash
kubectl edit app cnpe-broken-app -n argocd
# Change: path: guestbook-broken
# To:     path: guestbook
```

## Alternative Valid Paths

The argocd-example-apps repo contains:
- `guestbook` (plain YAML)
- `helm-guestbook` (Helm chart)
- `kustomize-guestbook` (Kustomize)

Any of these would make the Application sync successfully.

## Why This Matters

Path errors are one of the most common GitOps issues:
- Typos in directory names
- Renamed folders in Git not updated in Application
- Branch merges changing structure

Always verify repo structure when debugging sync issues.

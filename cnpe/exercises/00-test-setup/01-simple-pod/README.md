# Exercise: Create a Pod with Labels

**Time Limit:** 5 minutes

## Context

Your platform team requires all pods to have proper labels for cost attribution and ownership tracking.

## Task

Create a pod named `test-pod` in namespace `cnpe-test` with:
- Image: `nginx:alpine`
- Labels:
  - `team: platform`
  - `env: test`

## Verification

```bash
kubectl kuttl test ./exercises/00-test-setup --test 01-simple-pod
```

## Hints

- Check `kubectl run --help` for label syntax
- Or create a YAML manifest

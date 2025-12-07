# Solution: Fix Broken Kyverno Policy

## Diagnosis with kyverno CLI

```bash
kubectl get clusterpolicy require-memory-limits -o yaml
kyverno apply require-memory-limits.yaml --resource pod.yaml  # test locally
```

## Phase 1: Fix Policy Action

Change `validationFailureAction` from `Audit` to `Enforce`:

```bash
kubectl edit clusterpolicy require-memory-limits
```

Change:
```yaml
spec:
  validationFailureAction: Audit
```

To:
```yaml
spec:
  validationFailureAction: Enforce
```

## Phase 2: Fix Namespace Selector

Change the namespace from `cnpe-other-namespace` to `cnpe-security-test`:

```bash
kubectl edit clusterpolicy require-memory-limits
```

Change:
```yaml
    match:
      any:
      - resources:
          namespaces:
          - cnpe-other-namespace
```

To:
```yaml
    match:
      any:
      - resources:
          namespaces:
          - cnpe-security-test
```

## Phase 3: Verify

Test that pods without limits are rejected:
```bash
kubectl run test-pod --image=nginx -n cnpe-security-test
# Should fail with: "Memory limits are required for all containers."
```

Test that pods with limits are allowed:
```bash
kubectl run compliant-pod --image=nginx -n cnpe-security-test \
  --overrides='{"spec":{"containers":[{"name":"compliant-pod","image":"nginx","resources":{"limits":{"memory":"128Mi"}}}]}}'
# Should succeed
```

## Key Concepts

1. **validationFailureAction**: `Audit` only logs violations, `Enforce` blocks them
2. **match.resources.namespaces**: Limits policy to specific namespaces
3. **validate.pattern**: Uses Kyverno's pattern matching to check resource fields
4. `?*` means "any non-empty value must be present"

## Useful kyverno Commands

```bash
kubectl get clusterpolicy                    # List policies
kubectl get policyreport -A                  # View policy reports
kyverno apply policy.yaml --resource pod.yaml  # Test policy locally
```

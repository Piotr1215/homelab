# Fix Broken Kyverno Policy

**Time:** 8 minutes
**Skills tested:** Kyverno ClusterPolicy, validation rules, match/exclude selectors

## Context

The security team deployed a Kyverno policy to enforce resource limits on all Pods in the `cnpe-security-test` namespace. However, Pods without resource limits are still being created. You must diagnose and fix the policy.

## Task

Fix the ClusterPolicy so that Pods without memory limits are rejected in the `cnpe-security-test` namespace.

### Phase 1: Fix Policy Action
The policy is in audit mode. Change it to enforce mode so violations are blocked.

### Phase 2: Fix Namespace Selector
The policy excludes the wrong namespaces. Fix the match selector to apply to `cnpe-security-test`.

### Phase 3: Verify Policy Works
First, verify a Pod WITHOUT limits is rejected:
```bash
kubectl run test-pod --image=nginx -n cnpe-security-test
# Should fail with policy violation
```

Then create a compliant Pod WITH limits (this will be checked):
```bash
kubectl run compliant-pod --image=nginx -n cnpe-security-test \
  --overrides='{"spec":{"containers":[{"name":"compliant-pod","image":"nginx","resources":{"limits":{"memory":"128Mi"}}}]}}'
```

## Verification

Each phase is checked automatically. Complete all phases to pass.

## Allowed Documentation

- [Kyverno Policies](https://kyverno.io/docs/writing-policies/)
- [Match and Exclude](https://kyverno.io/docs/writing-policies/match-exclude/)
- [Validation Rules](https://kyverno.io/docs/writing-policies/validate/)

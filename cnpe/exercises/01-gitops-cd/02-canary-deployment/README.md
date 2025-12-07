# Migrate Deployment to Canary Rollout

**Time:** 7 minutes
**Skills tested:** Non-disruptive migration, Argo Rollouts, progressive delivery

## Context

The `web-api` application in namespace `cnpe-canary-test` is running as a standard Deployment. The platform team wants to enable canary releases WITHOUT causing downtime during the migration.

## Task

Migrate the existing Deployment to an Argo Rollout with canary strategy. You must complete this **without disrupting running pods**.

### Phase 1: Prepare
Pause the Deployment to prevent it from interfering with the migration.

### Phase 2: Create Rollout
Create a Rollout with:
- Same pod spec as the Deployment
- Canary strategy using `web-api` (stable) and `web-api-canary` services
- Steps: 20% → pause 30s → 50% → pause 30s → 100%

### Phase 3: Complete Migration
Scale the Deployment to 0 and verify the Rollout is healthy.

## Why This Order?

1. **Pause first** - Prevents Deployment from scaling pods while Rollout creates its own
2. **Create Rollout** - New controller takes over traffic management
3. **Scale to 0** - Clean handoff, Deployment no longer needed

## Verification

Each phase is checked automatically. Complete all phases to pass.

## Allowed Documentation

- [Argo Rollouts Migrating](https://argo-rollouts.readthedocs.io/en/stable/migrating/)
- [Argo Rollouts Canary](https://argo-rollouts.readthedocs.io/en/stable/features/canary/)

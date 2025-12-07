# Fix Broken Tekton Trigger

**Time:** 8 minutes
**Skills tested:** Tekton Triggers, EventListener, TriggerBinding, TriggerTemplate

## Context

The platform team set up a CI trigger for the `build-app` pipeline in namespace `cnpe-tekton-test`. The EventListener is running but webhooks fail to create PipelineRuns. You must diagnose and fix the trigger configuration.

## Task

Fix the Tekton Trigger so that sending a POST request to the EventListener creates a PipelineRun.

### Phase 1: Fix TriggerTemplate
The TriggerTemplate references a non-existent pipeline. Correct the pipeline reference.

### Phase 2: Fix TriggerBinding
The TriggerBinding has wrong parameter name and JSON path. Fix the parameter to extract `repo-url` from the correct webhook payload path.

### Phase 3: Test the Trigger
Send a test webhook to verify a PipelineRun is created:
```bash
curl -X POST http://el-build-trigger.cnpe-tekton-test.svc.cluster.local:8080 \
  -H "Content-Type: application/json" \
  -d '{"repository":{"clone_url":"https://github.com/example/app"}}'
```

## Verification

Each phase is checked automatically. Complete all phases to pass.

## Allowed Documentation

- [Tekton Triggers](https://tekton.dev/docs/triggers/)
- [TriggerTemplate](https://tekton.dev/docs/triggers/triggertemplates/)
- [TriggerBinding](https://tekton.dev/docs/triggers/triggerbindings/)

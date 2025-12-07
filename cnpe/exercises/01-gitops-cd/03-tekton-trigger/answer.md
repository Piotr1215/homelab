# Solution: Fix Broken Tekton Trigger

## Diagnosis with tkn CLI

First, inspect the resources:
```bash
tkn tt describe build-trigger-template -n cnpe-tekton-test
tkn tb describe build-trigger-binding -n cnpe-tekton-test
tkn pipeline list -n cnpe-tekton-test
```

## Phase 1: Fix TriggerTemplate

The TriggerTemplate references `build-application` but the pipeline is named `build-app`.

```bash
kubectl edit triggertemplate build-trigger-template -n cnpe-tekton-test
# Change: name: build-application
# To:     name: build-app
```

## Phase 2: Fix TriggerBinding

The TriggerBinding has wrong param name (`git-url`) and wrong JSON path (`$(body.repo.url)`).

```bash
kubectl edit triggerbinding build-trigger-binding -n cnpe-tekton-test
```

Change:
```yaml
spec:
  params:
    - name: git-url
      value: $(body.repo.url)
```

To:
```yaml
spec:
  params:
    - name: repo-url
      value: $(body.repository.clone_url)
```

## Phase 3: Test the Trigger

Send a test webhook:
```bash
kubectl run curl-test --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST http://el-build-trigger.cnpe-tekton-test.svc.cluster.local:8080 \
  -H "Content-Type: application/json" \
  -d '{"repository":{"clone_url":"https://github.com/example/app"}}'
```

Verify PipelineRun created:
```bash
tkn pr list -n cnpe-tekton-test
tkn pr logs -n cnpe-tekton-test --last
```

## Key Concepts

1. **TriggerTemplate** - Defines the resource (PipelineRun) to create when triggered
2. **TriggerBinding** - Extracts parameters from webhook payload using JSONPath
3. **EventListener** - HTTP endpoint that receives webhooks and connects bindings to templates
4. **Parameter flow**: Webhook payload → TriggerBinding → TriggerTemplate → PipelineRun

## Useful tkn Commands

```bash
tkn tt list -n <namespace>        # List TriggerTemplates
tkn tb list -n <namespace>        # List TriggerBindings
tkn el list -n <namespace>        # List EventListeners
tkn pr list -n <namespace>        # List PipelineRuns
tkn pr logs --last -n <namespace> # View last PipelineRun logs
```

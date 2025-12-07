# Answer: Migrate Deployment to Canary Rollout

## Phase 1: Pause Deployment

```bash
kubectl rollout pause deployment web-api -n cnpe-canary-test
```

Verify:
```bash
kubectl get deployment web-api -n cnpe-canary-test -o jsonpath='{.spec.paused}'
# Should return: true
```

## Phase 2: Create Rollout

```bash
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: web-api
  namespace: cnpe-canary-test
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-api
  template:
    metadata:
      labels:
        app: web-api
    spec:
      containers:
        - name: web-api
          image: nginx:1.25
          ports:
            - containerPort: 8080
  strategy:
    canary:
      stableService: web-api
      canaryService: web-api-canary
      steps:
        - setWeight: 20
        - pause: {duration: 30s}
        - setWeight: 50
        - pause: {duration: 30s}
        - setWeight: 100
EOF
```

## Phase 3: Complete Migration

```bash
kubectl scale deployment web-api -n cnpe-canary-test --replicas=0
```

Wait for Rollout to become healthy:
```bash
kubectl get rollout web-api -n cnpe-canary-test -w
```

## Why This Order Matters

| Step | What Happens | Why |
|------|--------------|-----|
| Pause Deployment | Controller stops reconciling | Prevents fighting over pods |
| Create Rollout | New pods created by Rollout | Takes over traffic management |
| Scale to 0 | Deployment pods terminated | Clean handoff complete |

## One-liner (for speed)

```bash
kubectl rollout pause deploy/web-api -n cnpe-canary-test && \
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: web-api
  namespace: cnpe-canary-test
spec:
  replicas: 3
  selector:
    matchLabels: {app: web-api}
  template:
    metadata:
      labels: {app: web-api}
    spec:
      containers:
      - name: web-api
        image: nginx:1.25
        ports: [{containerPort: 8080}]
  strategy:
    canary:
      stableService: web-api
      canaryService: web-api-canary
      steps:
      - setWeight: 20
      - pause: {duration: 30s}
      - setWeight: 50
      - pause: {duration: 30s}
      - setWeight: 100
EOF
kubectl scale deploy/web-api -n cnpe-canary-test --replicas=0
```

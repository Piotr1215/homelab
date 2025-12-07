# CNPE Exam Preparation Lab

Interactive, homelab-based preparation for the **Certified Cloud Native Platform Engineer (CNPE)** exam using progressive testing with [KUTTL](https://kuttl.dev/).

## What is This?

An unofficial practice environment for CNPE exam preparation. These are hands-on scenarios I created for learning - not official exam questions. You configure GitOps workflows, set up canary deployments, create observability dashboards, and troubleshoot policies on a real cluster.

**Note**: This lab assumes an existing Kubernetes cluster with components already installed (ArgoCD, Kyverno, etc.). It's designed for my homelab but should work on any cluster with the prerequisites.

## CNPE Exam Overview

| Aspect | Detail |
|--------|--------|
| Duration | 2 hours (120 min) |
| Tasks | ~17 hands-on tasks |
| Pass Score | 64% |
| Format | Remote Linux desktop, terminal + browser |
| K8s Version | v1.34 |

## Curriculum

Exercises are based on the [CNCF CNPE Curriculum (November 2024)](https://training.linuxfoundation.org/certification/certified-cloud-native-platform-engineer-cnpe/). The exam covers five domains: GitOps and Continuous Delivery (25%), Platform APIs and Self-Service (25%), Observability and Operations (20%), Platform Architecture (15%), and Security and Policy Enforcement (15%). Each exercise in this lab maps to a specific competency from the curriculum - see the exercise README for details.

## Prerequisites

- Kubernetes cluster (v1.34 recommended)
- CLI tools: kubectl, [kuttl](https://kuttl.dev/docs/cli.html), argocd, tkn, kyverno
- Cluster components: ArgoCD, Argo Rollouts, Tekton, Kyverno, Prometheus, Grafana

## How KUTTL Progressive Testing Works

[KUTTL](https://kuttl.dev/) (KUbernetes Test TooL) is a declarative testing framework. We use it to create **progressive, multi-step exercises** that simulate real exam scenarios.

### Why Progressive Testing?

Real troubleshooting isn't a single fix - it's a sequence of steps. Progressive assertions let you:
- Work through problems step-by-step (each `XX-assert.yaml` is a checkpoint)
- Get immediate feedback when a step is correct
- Practice the iterative debugging workflow used in the actual exam

### Exercise Structure

```
exercises/01-gitops-cd/01-fix-broken-sync/
├── setup.yaml      # Creates the broken state (runs first)
├── 00-assert.yaml  # Step 1: waits for initial fix
├── 01-assert.yaml  # Step 2: validates additional requirements
├── steps.txt       # Hints (format: "0:First step description")
├── answer.md       # Solution - try without peeking!
└── README.md       # Exercise description, curriculum mapping, docs links
```

### How It Works

1. **Setup Phase**: KUTTL applies `setup.yaml` to create a broken resource (misconfigured ArgoCD app, bad RBAC, etc.)

2. **Assertion Phase**: KUTTL waits for `00-assert.yaml` conditions to become true. You fix the issue in another terminal. When your fix is correct, the assertion passes and moves to the next step.

3. **Timer**: A 7-minute timeout runs (visible in terminal). This matches exam pace (~17 tasks in 2 hours).

4. **Auto-Cleanup**: When the test completes, times out, or you press `Ctrl+C`, KUTTL automatically deletes all resources it created. No manual cleanup needed.

### During the Exercise

- **Split your terminal**: Run KUTTL in one pane, fix issues in another
- **Watch the timer**: Top-right shows remaining time before timeout
- **Use the docs**: Each exercise README links to relevant documentation - use them! The real exam gives you access to official docs
- **Check steps.txt**: If stuck, hints are available (but try without first)

### Running Exercises

```bash
# List all exercises
just cnpe-list

# Run specific exercises (all tab-completable)
just cnpe-gitops-fix        # ArgoCD sync issue
just cnpe-gitops-canary     # Argo Rollouts canary
just cnpe-gitops-tekton     # Tekton triggers
just cnpe-gitops-promotion  # ArgoCD ApplicationSets
just cnpe-security-policy   # Kyverno policy

# Run all exercises in a domain
just cnpe-domain-gitops
just cnpe-domain-security
```

## Tools

This lab uses one tool per category from the [official CNPE tool list](https://training.linuxfoundation.org/certification/certified-cloud-native-platform-engineer-cnpe/):

- **GitOps**: [ArgoCD](https://argo-cd.readthedocs.io/)
- **Progressive Delivery**: [Argo Rollouts](https://argoproj.github.io/rollouts/)
- **CI/CD**: [Tekton](https://tekton.dev/docs/)
- **Policy**: [Kyverno](https://kyverno.io/docs/)
- **Service Mesh**: [Istio](https://istio.io/latest/docs/) (ambient mode)
- **Observability**: [Prometheus](https://prometheus.io/docs/), [Grafana](https://grafana.com/docs/), [Tempo](https://grafana.com/docs/tempo/)
- **Cost**: [OpenCost](https://www.opencost.io/docs/)
- **Infrastructure**: [Crossplane](https://docs.crossplane.io/)


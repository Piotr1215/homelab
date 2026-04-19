# SPIRE Operations Runbook

Identity substrate for agents-mcp-server + NATS mTLS.
Tracking issues: [Piotr1215/claude#126][126] (this slice) / [#124][124] (epic).

[126]: https://github.com/Piotr1215/claude/issues/126
[124]: https://github.com/Piotr1215/claude/issues/124

## Topology

| Component | Chart | Namespace |
|---|---|---|
| SPIRE Server | `spiffe/helm-charts-hardened` spire | `spire-server` |
| SPIRE Agent | spire (DaemonSet) | `spire-system` |
| SPIRE Controller Manager | spire | `spire-server` |
| SPIFFE CSI Driver | spire (DaemonSet) | `spire-system` |
| SPIFFE OIDC Discovery Provider | spire | `spire-server` |
| CRDs (ClusterSPIFFEID, ClusterFederatedTrustDomain) | spire-crds | cluster-scoped |

Trust domain: `agents.loft.internal` (single name across homelab + loft.rocks).
Cluster name: `homelab`.

## Phase-1 success criteria

Base substrate is "ready" when ALL of the following hold:

1. SPIRE Server pod is `Ready`; SPIRE Agent DaemonSet covers every schedulable node.
2. A test workload in a labelled namespace can fetch an SVID via the SPIFFE
   Workload API socket (`/spiffe-workload-api/spire-agent.sock`, mounted via
   CSI driver).
3. **Rotation:** SVIDs renewed automatically before expiry (default 1h).
   `kubectl -n spire-server logs deployment/spire-server | grep -i "issued x509"`
   shows re-issuance without manual intervention.
4. **Bundle recovery:** after a simulated server restart (`kubectl -n
   spire-server rollout restart statefulset/spire-server`), agents re-attest
   and existing workloads continue to validate each other.

## Workload registration

Workloads register via `ClusterSPIFFEID` CRs reconciled by the controller
manager. Example for NATS (added in phase 2):

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: nats-server
spec:
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
  podSelector:
    matchLabels:
      app.kubernetes.io/name: nats
  workloadSelectorTemplates:
    - "k8s:ns:nats"
    - "k8s:sa:nats"
```

## Routine ops

### CA rotation

SPIRE auto-rotates intermediate CAs. The root CA (caSubject in
`gitops/apps/spire/values.yaml`) rotates by:

1. Update `global.spire.caSubject` (commonName stays; bump serial/org if
   desired) OR bump `global.spire.caTTL` to force a new CA.
2. Commit + push; ArgoCD sync triggers SPIRE Server restart.
3. SPIRE publishes the new root into the trust bundle; agents pull it within
   one refresh interval (default 30s). Workloads refresh on next SVID renewal.
4. Verify: `kubectl -n spire-server exec statefulset/spire-server -- \
     /opt/spire/bin/spire-server bundle show -format pem` shows both roots
     during overlap, then only the new one.

### SVID revocation

Workload entries are deleted by removing the `ClusterSPIFFEID` CR (or
tightening its selector). Active SVIDs remain valid until their TTL
(default 1h) — SPIRE does not implement CRLs. For emergency revocation
of a still-trusted workload: rotate the root CA (above) and exclude the
target from the new trust bundle.

### Adding a new workload

1. Label the pod/namespace so a `ClusterSPIFFEID` selector matches.
2. Mount the SPIFFE Workload API socket via the CSI driver:
   ```yaml
   volumes:
     - name: spiffe-workload-api
       csi:
         driver: csi.spiffe.io
         readOnly: true
   volumeMounts:
     - name: spiffe-workload-api
       mountPath: /spiffe-workload-api
       readOnly: true
   ```
3. Point the workload at `SPIFFE_ENDPOINT_SOCKET=unix:///spiffe-workload-api/spire-agent.sock`.
4. Verify entry: `kubectl -n spire-server exec statefulset/spire-server -- \
     /opt/spire/bin/spire-server entry show`.

## Attestation strategy

### In-cluster workloads (NATS, agents-mcp-server when deployed to k8s)

- **Node attestor:** `k8s_psat` (projected service account token).
- **Workload attestor:** `k8s` (pod UID + service account match).

Both are the SPIRE-canonical choices for k8s-native workloads.

### Off-cluster workloads (engineer laptop running Claude CLI)

**Phase-2 MVP: `join_token`.** Manual one-shot token per laptop; fine for
2-3 engineers while we bootstrap.

**Phase-3 target (before >10 engineers): OIDC federation.** Wire SPIRE
Server's OIDC discovery provider to Ory Hydra (already in `loft-prod/main/
ory-hydra`, per epic #124 ws1/bobo's lane). Engineer SSO → Hydra → SPIRE
OIDC attestor → per-session SVID. Avoids the manual-token ceiling baked
into `join_token`.

> Scaling note (from #126 code review): `join_token` does NOT scale past
> ~10 engineers. OIDC federation is phase-3 MUST, not nice-to-have.

## Known gaps / debt

- **NATS has zero auth today.** Until phase 2 lands (`verify_and_map` +
  SPIFFE users on NATS), anyone with tailnet access can pub/sub on
  `:4222` (MetalLB `192.168.178.93` in-cluster, tailscale LB externally).
  Interim mitigation options: tailnet ACL restricting port 4222 to
  known peer tags, or a basic NATS user/password in
  `gitops/apps/nats/values.yaml` as a stopgap.
- **No CRLs.** Relying on short SVID TTL + root rotation for revocation.
- **Single SPIRE Server replica, sqlite datastore.** Adequate for
  homelab; must upgrade to HA + cloudnative-pg backend (already in
  cluster) before loft.rocks rollout.
- **Trust-manager federation deferred.** Self-signed CA for now;
  unification with `homelab-ca-issuer` is phase-3 work.

## Relation to epic #124

This runbook covers ws3 (reliability & observability) + the infra
prerequisite for ws1 (identity & access). Downstream:

- ws1 (bobo): per-subject ACLs + Hydra OIDC callout on top of this
  substrate.
- ws2: JetStream retention + DSAR export (separate slice).
- ws4: per-subject ACL + conditional-access enforcement point.

# Homelab Infrastructure Improvement Research - November 2025

## Executive Summary

Comprehensive research into improvements for your Kubernetes homelab infrastructure, focusing on DNS (dnsmasq) and HTTPS/TLS (Envoy Gateway, cert-manager) implementations.

### Key Findings

**Critical Security Updates Required:**
- **dnsmasq 2.90-r3 → 2.91**: Critical CVE-2023-49441 (cache poisoning vulnerability)
- **Envoy Gateway**: Upgrade to v1.6.0 to address CVE-2025-24030 and CVE-2025-25294
- **DNS Security**: No DNSSEC, no encrypted upstream queries (DoT/DoH)

**Major Simplification Opportunities:**
- **9 individual certificates → 1 wildcard**: 89% reduction in certificate management overhead
- **Manual DNS entries → CoreDNS k8s_gateway**: Automatic service discovery
- **Self-signed CA → Smallstep step-ca**: Proper PKI with ACME automation

**Performance & Observability Gaps:**
- dnsmasq has no metrics endpoint (Prometheus integration missing)
- CoreDNS offers native Prometheus metrics on port 9153
- Envoy Gateway v1.6.0 brings zone-aware routing and performance improvements

---

## Current State Analysis

### DNS Infrastructure (dnsmasq)

**Location:** `/home/user/homelab/gitops/apps/dnsmasq/`

**Current Configuration:**
- **Version:** 4km3/dnsmasq:2.90-r3 (Alpine-based)
- **Replicas:** 2 (HA setup)
- **LoadBalancer IP:** 192.168.178.101 (MetalLB)
- **Cache Size:** 1,000 entries
- **Upstream DNS:** Google DNS (8.8.8.8, 8.8.4.4)
- **Split-Horizon:** `*.homelab.local` → 192.168.178.92 (Envoy Gateway)
- **Security:** No DNSSEC, no DoT/DoH, basic logging enabled

**Issues Identified:**
- ❌ **CVE-2023-49441** - Integer overflow vulnerability (FIXED in 2.91)
- ❌ **Cache poisoning vulnerability** - August 2025 discovery (mitigated by DNSSEC)
- ❌ **No encryption** - Plain DNS to upstream resolvers
- ❌ **Privacy concerns** - Google DNS logs IPs for 24-48h
- ❌ **No metrics** - Can't integrate with Prometheus/Grafana
- ❌ **Manual DNS entries** - Must update config for each service

### HTTPS/TLS Infrastructure (Envoy Gateway + cert-manager)

**Location:** `/home/user/homelab/gitops/apps/envoy-gateway-resources/`

**Current Configuration:**
- **Envoy Gateway:** Unknown version (needs verification)
- **Gateway API:** v1 (gateway.networking.k8s.io/v1) ✅
- **cert-manager:** v1.19.1 (latest) ✅
- **Certificate Pattern:** 9 individual certificates (IP-based: 192.168.178.98)
- **Issuer:** Self-signed CA (homelab-ca-issuer)
- **TLS Mode:** Terminate (not passthrough)
- **HTTP Redirect:** ❌ Not configured

**Certificate Inventory:**
1. argocd-tls (namespace: argocd)
2. grafana-tls (namespace: prometheus)
3. prometheus-tls (namespace: prometheus)
4. longhorn-tls (namespace: longhorn-system)
5. homepage-tls (namespace: homepage)
6. hubble-tls (namespace: kube-system)
7. falco-tls (namespace: falco)
8. forgejo-tls (namespace: git-mirror)
9. vcluster-tls (namespace: default)

**Issues Identified:**
- ❌ **Security vulnerabilities** - CVE-2025-24030, CVE-2025-25294 (fixed in v1.6.0)
- ❌ **No HTTP→HTTPS redirect** - Users can access insecure endpoints
- ❌ **IP-based certificates** - Not DNS-based (limits portability)
- ❌ **Management overhead** - 29 resource files, 9 ReferenceGrants
- ❌ **No resource limits** - EnvoyProxy has no CPU/memory constraints
- ❌ **No HA configured** - Single EnvoyProxy replica (pinned to kube-worker2)
- ❌ **No TLS hardening** - No ClientTrafficPolicy for TLS 1.3, cipher suites

---

## Version Matrix - Current vs Latest (2025)

| Component | Current Version | Latest Stable | Release Date | Security Impact |
|-----------|----------------|---------------|--------------|-----------------|
| **dnsmasq** | 2.90-r3 | 2.91 | March 20, 2025 | 🔴 **CRITICAL** CVE-2023-49441 |
| **dnsmasq container** | 4km3/dnsmasq:2.90-r3 | dockurr/dnsmasq:2.91 | March 21, 2025 | 🔴 High |
| **Envoy Gateway** | Unknown | v1.6.0 | November 11, 2025 | 🔴 **CRITICAL** CVE-2025-24030, CVE-2025-25294 |
| **Gateway API** | v1 | v1.4.0 | October 6, 2025 | ✅ Compatible |
| **cert-manager** | v1.19.1 | v1.19.1 | November 2025 | ✅ **CURRENT** |
| **CoreDNS** | N/A (alternative) | 1.13.1 | October 8, 2025 | N/A |
| **Smallstep step-ca** | N/A (alternative) | Latest | 2025 | N/A |

---

## Improvement Recommendations

### Category 1: Critical Security Updates (Immediate)

#### 1.1 Upgrade dnsmasq to 2.91

**Priority:** 🔴 **CRITICAL**

**Issue:** CVE-2023-49441 - Integer overflow allowing cache poisoning

**Solution:**
```yaml
# /home/user/homelab/gitops/apps/dnsmasq/dnsmasq-deployment.yaml
containers:
- name: dnsmasq
  image: dockurr/dnsmasq:2.91  # Alternative: build from Alpine 3.22
  # OR wait for 4km3/dnsmasq:2.91 release
```

**Alternative (Custom Build):**
```dockerfile
FROM alpine:3.22
RUN apk add --no-cache dnsmasq=2.91-r0
COPY dnsmasq.conf /etc/dnsmasq.conf
ENTRYPOINT ["dnsmasq", "-k"]
```

**Testing:**
```bash
kubectl set image deployment/dnsmasq -n kube-system dnsmasq=dockurr/dnsmasq:2.91
kubectl rollout status deployment/dnsmasq -n kube-system
dig @192.168.178.101 grafana.homelab.local
```

#### 1.2 Enable DNSSEC Validation

**Priority:** 🔴 **HIGH**

**Issue:** No DNSSEC validation - vulnerable to cache poisoning attacks

**Solution:**
```yaml
# /home/user/homelab/gitops/apps/dnsmasq/dnsmasq-configmap.yaml
data:
  dnsmasq.conf: |
    # Existing config...

    # DNSSEC validation (NEW)
    dnssec
    trust-anchor=.,20326,8,2,E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D
    dnssec-check-unsigned
    proxy-dnssec

    # Additional hardening
    dns-loop-detect
    bogus-priv
    domain-needed
```

**Verification:**
```bash
# Should FAIL for invalid DNSSEC
dig @192.168.178.101 dnssec-failed.org

# Should SUCCEED with RRSIG records
dig @192.168.178.101 cloudflare.com +dnssec
```

#### 1.3 Switch to Privacy-Respecting Upstream DNS

**Priority:** 🟡 **MEDIUM**

**Issue:** Google DNS (8.8.8.8) logs IP addresses for 24-48h

**Solution:**
```yaml
# Replace in dnsmasq-configmap.yaml
# Primary: Quad9 (security + privacy)
server=9.9.9.9
server=149.112.112.112

# Fallback: Cloudflare (speed + privacy)
server=1.1.1.1
server=1.0.0.1
```

**Comparison:**
- **Quad9**: Swiss non-profit, zero IP logging, malware/phishing blocking
- **Cloudflare**: Fastest globally (4.98ms avg), 24h log retention, KPMG audited
- **Google DNS**: Logs full IPs 24-48h ❌

#### 1.4 Upgrade Envoy Gateway to v1.6.0

**Priority:** 🔴 **CRITICAL**

**Issue:** CVE-2025-24030 (admin interface exposed), CVE-2025-25294 (log injection)

**Solution:**
```bash
helm upgrade eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.6.0 \
  -n envoy-gateway-system \
  --reuse-values
```

**Verify:**
```bash
kubectl get deployment -n envoy-gateway-system envoy-gateway -o jsonpath='{.spec.template.spec.containers[0].image}'
```

---

### Category 2: TLS/Certificate Simplification (High Priority)

#### 2.1 Consolidate to Wildcard Certificate

**Priority:** 🟡 **HIGH**

**Benefits:**
- 89% reduction in certificate management (9 → 1 cert)
- 31% reduction in resource files (29 → 20)
- 89% reduction in annual renewals (36 → 4)
- No ReferenceGrants needed (cert in Gateway namespace)

**Implementation:**

**Step 1: Create Wildcard Certificate**
```yaml
# /home/user/homelab/gitops/apps/envoy-gateway-resources/certificate-wildcard.yaml
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: homelab-wildcard-tls
  namespace: envoy-gateway-system
spec:
  secretName: homelab-wildcard-tls
  issuerRef:
    name: homelab-ca-issuer
    kind: ClusterIssuer
  commonName: "*.homelab.local"
  dnsNames:
    - "*.homelab.local"
  duration: 2160h  # 90 days
  renewBefore: 720h  # 30 days
  privateKey:
    rotationPolicy: Always  # Rotate key on renewal
```

**Step 2: Update Gateway**
```yaml
# /home/user/homelab/gitops/apps/envoy-gateway-resources/gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: homelab-gateway
  namespace: envoy-gateway-system
spec:
  gatewayClassName: envoy-gateway
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All

  - name: https
    protocol: HTTPS
    port: 443
    hostname: "*.homelab.local"
    allowedRoutes:
      namespaces:
        from: All
    tls:
      mode: Terminate
      certificateRefs:
        - kind: Secret
          name: homelab-wildcard-tls
```

**Step 3: Cleanup (After Testing)**
```bash
# Remove individual certificate files
rm gitops/apps/envoy-gateway-resources/certificate-argocd.yaml
rm gitops/apps/envoy-gateway-resources/certificate-grafana.yaml
rm gitops/apps/envoy-gateway-resources/certificate-prometheus.yaml
rm gitops/apps/envoy-gateway-resources/certificate-longhorn.yaml
rm gitops/apps/envoy-gateway-resources/certificate-homepage.yaml
rm gitops/apps/envoy-gateway-resources/certificate-hubble.yaml
rm gitops/apps/envoy-gateway-resources/certificate-falco.yaml
rm gitops/apps/envoy-gateway-resources/certificate-forgejo.yaml
rm gitops/apps/envoy-gateway-resources/certificate-vcluster.yaml

# HTTPRoutes remain unchanged - they work with wildcard cert
```

#### 2.2 Implement HTTP to HTTPS Redirect

**Priority:** 🟡 **HIGH**

**Issue:** Services accessible via insecure HTTP

**Solution:**
```yaml
# /home/user/homelab/gitops/apps/envoy-gateway-resources/httproute-redirect.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https-redirect
  namespace: envoy-gateway-system
spec:
  parentRefs:
  - name: homelab-gateway
    namespace: envoy-gateway-system
    sectionName: http  # Attach to HTTP listener
  hostnames:
  - "*.homelab.local"
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301  # Permanent redirect
```

**Testing:**
```bash
curl -I http://grafana.homelab.local
# Should return: HTTP/1.1 301 Moved Permanently
# Location: https://grafana.homelab.local
```

#### 2.3 Add TLS Hardening with ClientTrafficPolicy

**Priority:** 🟡 **MEDIUM**

**Solution:**
```yaml
# /home/user/homelab/gitops/apps/envoy-gateway-resources/client-traffic-policy.yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: homelab-tls-policy
  namespace: envoy-gateway-system
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: homelab-gateway
    sectionName: https
  tls:
    minVersion: "1.3"  # Enforce TLS 1.3
    alpnProtocols:
    - h2
    - http/1.1
    cipherSuites:
    - TLS_AES_128_GCM_SHA256
    - TLS_AES_256_GCM_SHA384
    - TLS_CHACHA20_POLY1305_SHA256
```

---

### Category 3: DNS Modernization (Medium Priority)

#### 3.1 Option A: Add Encrypted DNS (DoT/DoH) to dnsmasq

**Priority:** 🟡 **MEDIUM**

**Challenge:** dnsmasq does NOT support DoT/DoH natively

**Solution:** Deploy Unbound as proxy

**Architecture:**
```
[Clients] → [dnsmasq (caching + split-horizon)] → [Unbound (DoT)] → [Quad9/Cloudflare]
```

**Deployment:**
```yaml
# /home/user/homelab/gitops/apps/unbound/unbound-deployment.yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: unbound-config
  namespace: kube-system
data:
  unbound.conf: |
    server:
      interface: 0.0.0.0
      port: 53
      do-ip4: yes
      do-ip6: no
      do-udp: yes
      do-tcp: yes

      # Enable DoT
      tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt

    forward-zone:
      name: "."
      # Quad9 DoT
      forward-addr: 9.9.9.9@853#dns.quad9.net
      forward-addr: 149.112.112.112@853#dns.quad9.net
      # Cloudflare DoT
      forward-addr: 1.1.1.1@853#cloudflare-dns.com
      forward-addr: 1.0.0.1@853#cloudflare-dns.com
      forward-tls-upstream: yes

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unbound
  namespace: kube-system
spec:
  replicas: 2
  selector:
    matchLabels:
      app: unbound
  template:
    metadata:
      labels:
        app: unbound
    spec:
      containers:
      - name: unbound
        image: mvance/unbound:latest
        ports:
        - containerPort: 53
          protocol: UDP
        - containerPort: 53
          protocol: TCP
        volumeMounts:
        - name: config
          mountPath: /opt/unbound/etc/unbound/unbound.conf
          subPath: unbound.conf
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
      volumes:
      - name: config
        configMap:
          name: unbound-config

---
apiVersion: v1
kind: Service
metadata:
  name: unbound
  namespace: kube-system
spec:
  selector:
    app: unbound
  ports:
  - name: dns-udp
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
```

**Update dnsmasq to forward to Unbound:**
```yaml
# In dnsmasq-configmap.yaml, replace:
server=8.8.8.8
server=8.8.4.4

# With:
server=unbound.kube-system.svc.cluster.local
```

#### 3.2 Option B: Replace dnsmasq with CoreDNS

**Priority:** 🟡 **MEDIUM** (alternative to Option A)

**Benefits:**
- Native Kubernetes integration
- Automatic service discovery (k8s_gateway plugin)
- Prometheus metrics (port 9153)
- Multi-core scalability
- CNCF graduated project

**Trade-offs:**
- More complex configuration (Corefile vs dnsmasq.conf)
- Higher CPU usage (100m+ vs 50m)
- Requires custom image for k8s_gateway plugin

**Implementation:** See full deployment in research section "CoreDNS vs dnsmasq"

**Quick Comparison:**
| Feature | dnsmasq | CoreDNS |
|---------|---------|---------|
| **Metrics** | None | Prometheus native ✅ |
| **Service Discovery** | Manual | Automatic (k8s_gateway) ✅ |
| **Multi-core** | No | Yes ✅ |
| **Config Complexity** | Simple | Complex |
| **Resource Usage** | 50m CPU | 100m+ CPU |

**Recommendation:** Start with dnsmasq + Unbound (Option A) for simplicity, migrate to CoreDNS later if needed.

---

### Category 4: Advanced Certificate Management (Long-term)

#### 4.1 Implement DNS-01 Challenge for Wildcard Certs

**Priority:** 🔵 **LOW** (future improvement)

**Benefits:**
- Can use Let's Encrypt for publicly trusted certs
- Supports wildcard certificates
- No HTTP exposure required

**Requirements:**
- RFC2136-compatible DNS server (BIND9, not dnsmasq)
- TSIG key for dynamic DNS updates

**Implementation:**
```yaml
# Deploy BIND9 with RFC2136 support
# Configure cert-manager ClusterIssuer with DNS-01
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-dns-key
    solvers:
    - dns01:
        rfc2136:
          nameserver: "192.168.178.1:53"  # BIND9 server
          tsigKeyName: homelab-local-secret
          tsigAlgorithm: HMACSHA512
          tsigSecretSecretRef:
            name: rfc2136-secret
            key: tsig-secret-key
```

**Note:** Requires migrating from dnsmasq to BIND9 for DNS server (dnsmasq doesn't support RFC2136).

#### 4.2 Upgrade to Smallstep step-ca

**Priority:** 🔵 **LOW** (future improvement)

**Benefits:**
- Proper PKI hierarchy (Root CA + Intermediate CA)
- ACME support out-of-the-box
- Short-lived certificates (24h default, automated renewal)
- Built-in CRL/OCSP
- Hardware security module support (YubiKey)
- Audit logging

**vs Self-Signed CA:**
| Feature | Self-Signed CA | Smallstep step-ca |
|---------|---------------|------------------|
| Setup | Simple | Medium complexity |
| Automation | Manual | ACME built-in |
| PKI Structure | Single root | Root + Intermediate |
| Revocation | Manual CRL | Automated CRL/OCSP |
| Lifetime | Manual (90d) | Auto (24h default) |

**When to Migrate:**
- Need proper PKI structure for compliance
- Want short-lived certificates (security best practice)
- Need automated CRL/OCSP for revocation
- Planning mTLS across all services

---

### Category 5: High Availability & Resilience (Medium Priority)

#### 5.1 Add EnvoyProxy Resource Limits and HA

**Priority:** 🟡 **MEDIUM**

**Issue:** No resource limits, single replica pinned to kube-worker2

**Solution:**
```yaml
# /home/user/homelab/gitops/apps/envoy-gateway-resources/envoy-proxy.yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: homelab-proxy
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        replicas: 2  # High availability
        pod:
          affinity:
            podAntiAffinity:  # Distribute across nodes
              preferredDuringSchedulingIgnoredDuringExecution:
              - weight: 100
                podAffinityTerm:
                  labelSelector:
                    matchLabels:
                      gateway.envoyproxy.io/owning-gateway-name: homelab-gateway
                  topologyKey: kubernetes.io/hostname
          resources:
            limits:
              cpu: 2000m
              memory: 2Gi
            requests:
              cpu: 500m
              memory: 512Mi
        container:
          env:
          - name: ENVOY_CONCURRENCY
            value: "2"  # Match CPU cores
      envoyService:
        annotations:
          metallb.universe.tf/address-pool: static-pool
          metallb.universe.tf/loadBalancerIPs: "192.168.178.92"
```

#### 5.2 Deploy trust-manager for CA Distribution

**Priority:** 🔵 **LOW**

**Use Case:** Distribute homelab root CA to all pods automatically

**Installation:**
```bash
helm install trust-manager jetstack/trust-manager \
  --namespace cert-manager \
  --wait
```

**Configuration:**
```yaml
apiVersion: trust-manager.io/v1alpha2
kind: ClusterBundle
metadata:
  name: homelab-ca-bundle
spec:
  sources:
  - secret:
      name: "homelab-root-ca"
      key: "ca.crt"
  - useDefaultCAs: true  # Include Mozilla CA bundle

  target:
    configMap:
      key: "ca-bundle.crt"
    namespaceSelector:
      matchLabels:
        trust-injection: "enabled"
```

**Usage in Pods:**
```yaml
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: app
    env:
    - name: SSL_CERT_FILE
      value: /etc/ssl/certs/ca-bundle.crt
    volumeMounts:
    - name: ca-bundle
      mountPath: /etc/ssl/certs
      readOnly: true
  volumes:
  - name: ca-bundle
    configMap:
      name: homelab-ca-bundle
```

---

## Implementation Roadmap

### Phase 1: Critical Security (Week 1)

**Priority:** 🔴 **CRITICAL** - Do this FIRST

1. ✅ **Upgrade dnsmasq to 2.91**
   - Replace image: `dockurr/dnsmasq:2.91`
   - Test DNS resolution
   - Verify no regressions

2. ✅ **Enable DNSSEC in dnsmasq**
   - Add dnssec, trust-anchor, dnssec-check-unsigned
   - Add dns-loop-detect, bogus-priv, domain-needed
   - Test DNSSEC validation

3. ✅ **Switch to Quad9/Cloudflare upstream DNS**
   - Replace Google DNS (8.8.8.8) with Quad9 (9.9.9.9)
   - Add Cloudflare (1.1.1.1) as fallback
   - Monitor query performance

4. ✅ **Upgrade Envoy Gateway to v1.6.0**
   - `helm upgrade eg oci://docker.io/envoyproxy/gateway-helm --version v1.6.0`
   - Verify CVE patches applied
   - Test existing HTTPRoutes

**Validation:**
```bash
# Check dnsmasq version
kubectl get pod -n kube-system -l app=dnsmasq -o jsonpath='{.items[0].spec.containers[0].image}'

# Test DNSSEC
dig @192.168.178.101 dnssec-failed.org  # Should FAIL
dig @192.168.178.101 cloudflare.com +dnssec  # Should show RRSIG

# Check Envoy Gateway version
helm list -n envoy-gateway-system
```

### Phase 2: TLS Simplification (Week 2)

**Priority:** 🟡 **HIGH**

1. ✅ **Create wildcard certificate**
   - Apply certificate-wildcard.yaml
   - Wait for cert-manager to issue
   - Verify secret created

2. ✅ **Update Gateway with wildcard listener**
   - Add new HTTPS listener with wildcard cert
   - Keep old listeners temporarily (zero downtime)
   - Test one service (homepage)

3. ✅ **Implement HTTP→HTTPS redirect**
   - Apply httproute-redirect.yaml
   - Test redirect: `curl -I http://grafana.homelab.local`

4. ✅ **Add TLS hardening**
   - Apply client-traffic-policy.yaml (TLS 1.3, modern ciphers)
   - Test TLS version: `nmap --script ssl-enum-ciphers -p 443 192.168.178.92`

5. ✅ **Remove individual certificates**
   - Scale down verification: test all 9 services with wildcard
   - Delete individual certificate files
   - Remove old ReferenceGrants
   - Clean up Gateway config

**Validation:**
```bash
# Test all services
for svc in argocd grafana prometheus longhorn homepage hubble falco forgejo; do
  echo "Testing $svc..."
  curl -k -I https://$svc.homelab.local | head -1
done

# Verify wildcard cert in use
echo | openssl s_client -connect grafana.homelab.local:443 2>/dev/null | openssl x509 -noout -subject
# Should show: CN=*.homelab.local
```

### Phase 3: DNS Modernization (Week 3-4)

**Priority:** 🟡 **MEDIUM**

**Choose ONE option:**

**Option A: dnsmasq + Unbound (Simpler)**
1. Deploy Unbound with DoT configuration
2. Update dnsmasq to forward to Unbound
3. Verify encrypted upstream queries
4. Monitor performance

**Option B: Migrate to CoreDNS (More features)**
1. Deploy CoreDNS alongside dnsmasq (different IP)
2. Configure split-horizon DNS and k8s_gateway
3. Test DNS resolution and service discovery
4. Switch MetalLB IP from dnsmasq to CoreDNS
5. Scale down dnsmasq
6. Add ServiceMonitor for Prometheus metrics

**Recommended:** Start with Option A (dnsmasq + Unbound) for quick security win.

### Phase 4: Advanced Features (Month 2+)

**Priority:** 🔵 **LOW** - Optional improvements

1. **Add HA to EnvoyProxy**
   - 2 replicas with pod anti-affinity
   - Resource limits (CPU/memory)
   - Zone-aware routing

2. **Deploy trust-manager**
   - Distribute homelab CA to all pods
   - Simplify TLS trust configuration

3. **Consider Smallstep step-ca**
   - Proper PKI hierarchy
   - Short-lived certificates (24h)
   - ACME automation

4. **Implement DNS-01 challenges**
   - Requires BIND9 (not dnsmasq)
   - Enables Let's Encrypt wildcard certs
   - Public trust for external services

---

## Monitoring & Validation

### DNS Health Checks

```bash
# Check dnsmasq pod status
kubectl get pods -n kube-system -l app=dnsmasq

# View dnsmasq logs
kubectl logs -n kube-system -l app=dnsmasq -f

# Test internal DNS
dig @192.168.178.101 grafana.homelab.local

# Test external DNS
dig @192.168.178.101 google.com

# Test DNSSEC (after implementation)
dig @192.168.178.101 +dnssec cloudflare.com

# Check cache stats (if implemented)
kubectl exec -n kube-system deploy/dnsmasq -- kill -USR1 1
kubectl logs -n kube-system -l app=dnsmasq | grep "cache size"
```

### TLS/Certificate Health Checks

```bash
# Check certificate expiration
kubectl get certificate -A

# Detailed certificate info
kubectl describe certificate homelab-wildcard-tls -n envoy-gateway-system

# Check cert-manager logs
kubectl logs -n cert-manager deploy/cert-manager -f

# Test HTTPS endpoint
curl -k -v https://grafana.homelab.local 2>&1 | grep "subject:"

# Verify TLS version
nmap --script ssl-enum-ciphers -p 443 192.168.178.92

# Check Gateway status
kubectl get gateway homelab-gateway -n envoy-gateway-system -o yaml

# Check HTTPRoute status
kubectl get httproute -A
```

### Prometheus Metrics (After CoreDNS Migration)

```yaml
# Grafana dashboard queries
# DNS query rate
rate(coredns_dns_requests_total[5m])

# DNS response codes
sum by (rcode) (rate(coredns_dns_responses_total[5m]))

# Cache hit rate
rate(coredns_cache_hits_total[5m]) / rate(coredns_cache_requests_total[5m])

# DNS latency
histogram_quantile(0.99, rate(coredns_dns_request_duration_seconds_bucket[5m]))
```

---

## Risk Assessment & Rollback Plans

### dnsmasq Upgrade Risks

**Risk:** DNS resolution failure breaks entire homelab

**Mitigation:**
- HA setup (2 replicas) ensures one pod always available
- Rolling update strategy (maxUnavailable: 0)
- Test in one pod first before full rollout

**Rollback:**
```bash
kubectl set image deployment/dnsmasq -n kube-system dnsmasq=4km3/dnsmasq:2.90-r3
kubectl rollout status deployment/dnsmasq -n kube-system
```

### Wildcard Certificate Risks

**Risk:** Wildcard cert compromise affects all services

**Mitigation:**
- Homelab internal CA (not public)
- Private network only (192.168.178.0/24)
- 90-day rotation with automatic renewal
- Can revert to individual certs if needed

**Rollback:**
```bash
# Restore individual certificates
git checkout HEAD~1 gitops/apps/envoy-gateway-resources/certificate-*.yaml
kubectl apply -f gitops/apps/envoy-gateway-resources/

# Update Gateway to reference individual certs
git checkout HEAD~1 gitops/apps/envoy-gateway-resources/gateway.yaml
kubectl apply -f gitops/apps/envoy-gateway-resources/gateway.yaml
```

### Envoy Gateway Upgrade Risks

**Risk:** Gateway API changes break routing

**Mitigation:**
- Gateway API v1 is stable (backwards compatible)
- Test in development first
- Helm rollback available

**Rollback:**
```bash
helm rollback eg -n envoy-gateway-system
kubectl get httproute -A  # Verify routes still work
```

---

## Cost-Benefit Analysis

### Time Investment

| Task | Estimated Time | Complexity | Impact |
|------|---------------|------------|--------|
| dnsmasq upgrade | 30 min | Low | 🔴 Critical security |
| DNSSEC enable | 15 min | Low | 🔴 High security |
| Upstream DNS switch | 10 min | Low | 🟡 Medium privacy |
| Envoy Gateway upgrade | 20 min | Low | 🔴 Critical security |
| Wildcard cert | 1-2 hours | Medium | 🟡 High management |
| HTTP→HTTPS redirect | 15 min | Low | 🟡 Medium security |
| TLS hardening | 30 min | Low | 🟡 Medium security |
| Unbound deployment | 1-2 hours | Medium | 🟡 Medium privacy |
| CoreDNS migration | 2-4 hours | High | 🔵 Low (alternative) |
| **TOTAL (Phase 1-2)** | **4-6 hours** | Mixed | Critical + High wins |

### Maintenance Reduction

**Before:**
- 9 certificates to track and renew (4 renewals/year each = 36 operations)
- 29 resource files to maintain
- Manual DNS entries for each new service
- No visibility into DNS performance

**After (with wildcard cert):**
- 1 certificate to renew (4 operations/year = -89% reduction)
- ~20 resource files (-31% reduction)
- Still manual DNS (unless CoreDNS migration)
- DNS metrics available (if CoreDNS)

**Annual Time Savings (wildcard cert only):** ~10-15 hours

---

## References & Sources

### dnsmasq Research
- [Dnsmasq Official Changelog](https://thekelleys.org.uk/dnsmasq/CHANGELOG)
- [CVE-2023-49441 GitHub Advisory](https://github.com/advisories/GHSA-wh73-785p-7wcf)
- [Gentoo Security Advisory GLSA 202412-10](https://security.gentoo.org/glsa/202412-10)
- [Man page of DNSMASQ](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)
- [dnsmasq ArchWiki](https://wiki.archlinux.org/title/Dnsmasq)

### DNS Security
- [Best DNS Options for Home Lab 2025](https://mattadam.com/2025/04/03/the-best-dns-options-for-your-home-lab-speed-security-and-control/)
- [DNS Resolvers Performance Compared](https://medium.com/@nykolas.z/dns-resolvers-performance-compared-cloudflare-x-google-x-quad9-x-opendns-149e803734e5)
- [Best DNS Servers 2025](https://axis-intelligence.com/best-dns-servers-2025-speed-security-test/)
- [DNS Security Best Practices for Logging](https://graylog.org/post/dns-security-best-practices-for-logging/)
- [Overview of dnsmasq Vulnerabilities](https://unit42.paloaltonetworks.com/overview-of-dnsmasq-vulnerabilities-the-dangers-of-dns-cache-poisoning/)

### Envoy Gateway
- [Envoy Gateway Releases](https://github.com/envoyproxy/gateway/releases)
- [Gateway API 1.4 Release](https://kubernetes.io/blog/2025/11/06/gateway-api-v1-4/)
- [HTTP Redirects - Envoy Gateway](https://gateway.envoyproxy.io/docs/tasks/traffic/http-redirect/)
- [Secure Gateways - Envoy Gateway](https://gateway.envoyproxy.io/docs/tasks/security/secure-gateways/)
- [CVE-2025-24030](https://advisories.gitlab.com/pkg/golang/github.com/envoyproxy/gateway/CVE-2025-24030/)
- [CVE-2025-25294](https://advisories.gitlab.com/pkg/golang/github.com/envoyproxy/gateway/CVE-2025-25294/)

### cert-manager
- [cert-manager GitHub Releases](https://github.com/cert-manager/cert-manager/releases)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [DNS01 Challenge Documentation](https://cert-manager.io/docs/configuration/acme/dns01/)
- [trust-manager Documentation](https://cert-manager.io/docs/trust/trust-manager/)
- [approver-policy Documentation](https://cert-manager.io/docs/policy/approval/approver-policy/)

### Smallstep step-ca
- [Build a Tiny CA with Raspberry Pi + YubiKey](https://smallstep.com/blog/build-a-tiny-ca-with-raspberry-pi-yubikey/)
- [step-ca for Certificate Provisioning in Homelab](https://fredrickb.com/2024/04/06/using-step-ca-for-certificate-provisioning-in-the-homelab/)
- [step-ca GitHub Repository](https://github.com/smallstep/certificates)

### CoreDNS
- [CoreDNS 1.13.1 Release](https://coredns.io/2025/10/08/coredns-1.13.1-release/)
- [k8s_gateway GitHub Repository](https://github.com/k8s-gateway/k8s_gateway)
- [CoreDNS Prometheus Plugin](https://coredns.io/plugins/metrics/)
- [Cluster DNS: CoreDNS vs Kube-DNS](https://coredns.io/2018/11/27/cluster-dns-coredns-vs-kube-dns/)

### Gateway API
- [TLS - Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/guides/tls/)
- [BackendTLSPolicy](https://gateway-api.sigs.k8s.io/api-types/backendtlspolicy/)
- [External-DNS Gateway API Sources](https://kubernetes-sigs.github.io/external-dns/latest/docs/sources/gateway-api/)
- [Gateway API Overview](https://gateway-api.sigs.k8s.io/concepts/api-overview/)

---

## Conclusion

Your homelab has grown significantly, particularly the dnsmasq and HTTPS implementations. The research identified **critical security vulnerabilities** that should be addressed immediately (dnsmasq CVE-2023-49441, Envoy Gateway CVEs), along with significant **simplification opportunities** (wildcard certificates reducing management overhead by 89%).

### Recommended Priority Order

1. **🔴 CRITICAL (Do First):** Security updates (dnsmasq 2.91, Envoy Gateway v1.6.0, DNSSEC)
2. **🟡 HIGH (Week 2):** TLS simplification (wildcard cert, HTTP redirect, TLS hardening)
3. **🟡 MEDIUM (Week 3-4):** DNS privacy (Unbound for DoT, or CoreDNS migration)
4. **🔵 LOW (Future):** Advanced features (step-ca, DNS-01, trust-manager)

The Phase 1-2 implementation (4-6 hours) will address critical security issues and significantly reduce ongoing maintenance burden. This provides the best return on investment for your homelab.

### Next Steps

1. Review this research document
2. Create a backup of current configuration: `git tag homelab-pre-improvements`
3. Start with Phase 1 (Critical Security) - estimated 1-2 hours
4. Test thoroughly between each phase
5. Monitor metrics after each change
6. Document any custom decisions in your homelab docs

Good luck with the improvements! 🚀

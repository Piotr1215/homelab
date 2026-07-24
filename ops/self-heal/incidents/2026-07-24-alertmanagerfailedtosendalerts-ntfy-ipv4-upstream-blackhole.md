# AlertmanagerFailedToSendAlerts — ntfy.sh IPv4 upstream blackhole

- Date: 2026-07-24
- Alert: `AlertmanagerFailedToSendAlerts` (severity warning)
- Labels: `integration=webhook`, `reason=contextDeadlineExceeded`, `pod=alertmanager-kube-prometheus-stack-alertmanager-0`, `namespace=prometheus`
- Firing since: 2026-07-23 21:43Z (~10h at spawn)
- Outcome: NEEDS-HUMAN / external cause. No safe in-cluster fix. Alert self-cleared during the heal (transient), root cause unresolved and will recur.

## Root cause (verified from live evidence)

The webhook receiver is the in-cluster `ntfy-alertmanager` bridge (ns `ntfy-alertmanager`),
which forwards Alertmanager webhooks to external `https://ntfy.sh`
(config: `server https://ntfy.sh`, `topic homelab-piotr1215-warning`).

The bridge pod is healthy (Running 1/1, /health probe passing, up 244d). Its logs
showed a continuous flood (every ~3s) of:
`Post "https://ntfy.sh/homelab-piotr1215-warning": context deadline exceeded (Client.Timeout exceeded while awaiting headers)`.
Alertmanager's webhook call to the bridge then times out → this alert.

The failure is an **upstream IPv4 routing blackhole to ntfy.sh's only IPv4, `159.203.148.75`**,
external to the homelab:

- DNS resolves fine cluster-side (CoreDNS OK). ntfy.sh has one A (`159.203.148.75`)
  and one AAAA (`2604:a880:800:14:0:1:73c0:2000`).
- TCP connect to `159.203.148.75:443` hangs (SYN blackhole) from **pods, the node's
  own netns (hostNetwork), AND my LAN laptop** — all via home router `192.168.178.1`.
- Every other external target works instantly from the cluster: `1.1.1.1`, `github.com`,
  `registry-1.docker.io`, and a **neighboring DigitalOcean IP `159.203.100.1:443`**
  (401, ~88ms). So it is this one destination IP, not DO in general, not cluster egress.
- `ip route get 159.203.148.75` on the node is normal (`via 192.168.178.1`), no blackhole route.
- Traceroute from the node leaves the home router fine and dies deep in the Cogent
  backbone (hop 12 `154.54.40.154`) before reaching DigitalOcean → transit-level fault.
- Ruled out in-cluster: no NetworkPolicies (k8s/Calico/Cilium), no Calico global
  policies/sets, CNI healthy (Calico), no egress blocklist tooling running.

Why it hits the cluster specifically: my laptop *appears* to recover because it has
working IPv6 and curl's happy-eyeballs picks the reachable AAAA
(`remote_ip=2604:a880:...`, 200 in ~280ms). Force IPv4 on the laptop also times out.
The Calico cluster is **IPv4-only**, so `ntfy-alertmanager` has no IPv6 fallback and
is fully stuck on the broken IPv4 path.

## Why the alert cleared during the heal (do not be fooled)

At report time firing count = 0 and the bridge logged 0 errors in the last 60s — but
IPv4 to `159.203.148.75` is **still down**. The alert is a rate ratio
(`failed/total notifications`); it cleared only because notification *attempts* stopped
(many source alerts, e.g. the promtail/agent-memory memory alerts, were resolved earlier
this morning, so there was nothing to deliver). This is transient relief, not a fix.
The next alert that needs delivery will fail again and re-fire this alert until the
upstream IPv4 route recovers.

## Fix decision

- No safe in-cluster remediation. The fault is upstream internet routing to ntfy.sh's
  IPv4, outside the homelab. Cannot fix Cogent/DO transit from here.
- Did NOT retune/silence the rule: this is a genuine notification failure, not a false
  positive. Silencing would hide a real broken delivery path.
- Did NOT restart pods (path is broken, not the pod) or touch node routes/iptables
  (external cause; node routing is correct).

## Handed to human / options (human decision, not applied)

1. Wait it out — most likely self-resolves when upstream IPv4 routing to `159.203.148.75`
   recovers. Nothing actionable in-cluster.
2. Resilience (if this recurs): give cluster egress an IPv6/dual-stack path so
   ntfy-alertmanager can use ntfy.sh's working AAAA; or self-host ntfy in-cluster; or add
   a second Alertmanager receiver (e.g. email/msmtp) so notification delivery is not
   single-pathed through one external IPv4.

## Verification commands used

- `kubectl logs -n ntfy-alertmanager ntfy-alertmanager-... --since=60s`
- pod + hostNetwork(node) curl/nc to `159.203.148.75:443` vs `159.203.100.1:443`
- `curl -w '%{remote_ip}' https://ntfy.sh/v1/health` (host: AAAA 200; -4: timeout)
- traceroute from node → dies in Cogent backbone
- Prometheus `/api/v1/alerts` firing count

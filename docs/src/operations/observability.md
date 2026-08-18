# Observability

Metrics, logs, and dashboards for the cluster. Versions are in
[Reference → Versions](../reference/versions.md); why the stack sits in
`infrastructure/` rather than `apps/` is in
[Architecture → Observability](../architecture.md#observability).

There is **nothing to run by hand** — Flux brings all four pieces up from
`kubernetes/infrastructure/platform/controllers/`. This page is day-2: what runs, what it keeps,
and where to look when something is missing.

## What runs where

| HelmRelease | Namespace | Stage | Role |
| --- | --- | --- | --- |
| `victoria-metrics` (`victoria-metrics-k8s-stack`) | `victoria-metrics` | controllers | VM operator, `vmsingle` store, `vmagent` scraper, kube-state-metrics, node-exporter |
| `loki` | `loki` | controllers | Log store, single-binary mode |
| `grafana` | `grafana` | controllers | Dashboards and query UI |
| `alloy` | `alloy` | controllers | DaemonSet shipping pod logs to Loki |
| `VMServiceScrape`s | `rook-ceph`, `kube-system` | configs | Scrape targets for Ceph and Cilium |
| `Ingress`es | `grafana`, `loki`, `victoria-metrics`, `alloy` | configs | HTTPS front door for each web endpoint |

The scrape CRs are `configs`, not `controllers`, because they are custom resources of the
VictoriaMetrics operator and would fail against CRDs that do not exist yet. The Ingresses
sit in `configs` for the neighbouring reason: they name a `ClusterIssuer`, which is itself
a `configs` resource.

Grafana is a **separate release** from the `victoria-metrics-k8s-stack` chart's bundled
Grafana subchart, which is disabled. Running it standalone keeps its version, storage, and
datasources independent of the metrics stack's release cycle. The stack's dashboard
ConfigMaps still land, because Grafana's dashboard sidecar watches all namespaces for the
`grafana_dashboard` label and the stack's dashboards are rewritten to the `VictoriaMetrics`
datasource UID.

## Access

Every web endpoint in the stack is reached over HTTPS through a Cilium `Ingress` holding a
Let's Encrypt certificate — see
[DNS & Certificates](./dns-and-certificates.md). The backing Services are `ClusterIP`; the
Ingress pins the LoadBalancer IP the hostname resolves to.

| URL | Backend | What it is |
| --- | --- | --- |
| `https://grafana.lilstrudel.io` | `grafana:80` | Dashboards and query UI |
| `https://vmsingle.lilstrudel.io` | `vmsingle-vm:8428` | VictoriaMetrics API and `vmui` |
| `https://loki.lilstrudel.io` | `loki-gateway:80` | Loki query and push API |
| `https://alloy.lilstrudel.io` | `alloy-syslog:12345` | `alloy-syslog` component UI and metrics |

`syslog.lilstrudel.io` (`10.69.65.43`) is the one endpoint that is not fronted this way. It
is the UDP 514 sink for the MikroTik devices, and an Ingress cannot carry UDP, so
`alloy-syslog` keeps a `LoadBalancer` Service. The Alloy chart publishes port 12345 on that
same Service, so the component UI stays reachable in plaintext on the LAN at
`http://10.69.65.43:12345` alongside the HTTPS route above.

In-cluster traffic does not go through any of this: Grafana's datasources and Alloy's
`loki.write` address the `ClusterIP` Services directly over cluster DNS.

Each service pins its LoadBalancer IP from the services range like anything else — see
`local.services` in `terraform/main.tf` for the allocations.

## Retention

Seven days, everywhere: `vmsingle`'s `retentionPeriod` and Loki's `retention_period`
(with the compactor's retention enabled) both hold a week. Storage is Ceph
(`ceph-block`), so nothing depends on which node a pod lands on.

## Pod security

Two of the four namespaces need more than `baseline`:

| Namespace | Enforce | Why |
| --- | --- | --- |
| `victoria-metrics` | `privileged` | node-exporter needs `hostNetwork`, `hostPID`, and hostPath mounts to read node-level metrics. |
| `alloy` | `privileged` | Tailing `/var/log/pods` needs a hostPath mount and root — the path is root-owned on Talos. |
| `loki` | `baseline` | — |
| `grafana` | `baseline` | — |

## What is scraped, and what is not

`vmagent` picks up the standard workload and node targets from the chart, plus the
`VMServiceScrape`s for Ceph (mgr + exporter) and Cilium (agent, operator, envoy). Cilium's
Helm values turn on `prometheus.metricsService` for the agent and operator: the agent runs
in `hostNetwork`, so without a Service there is nothing for a scrape CR to select.

Four of the chart's default control-plane targets are switched off on purpose, and their
absence is expected rather than a fault:

| Target | Why off |
| --- | --- |
| kube-proxy | Cilium is the kube-proxy replacement — there is nothing running to scrape. |
| kube-controller-manager, kube-scheduler | Talos binds them to localhost, unreachable from a scrape pod. |
| etcd | Talos requires client certificates the scrape pod does not hold. |

Alertmanager, `vmalert`, and the chart's default rules are disabled too — there is no
alerting path yet, and rules that fire into nothing are noise.

## Logs

Alloy runs as a DaemonSet (tolerating the control-plane taint, so all six nodes ship) and
discovers only the pods on **its own node**, via a field selector on `spec.nodeName`. It
reads container logs from `/var/log/pods`, parses them with the CRI stage, and writes to
the Loki gateway. Labels are `namespace`, `pod`, `container`, `node`, and a
`namespace/container` `job`.

Loki runs `SingleBinary` with `filesystem` storage on a `ceph-block` PVC — no object
store, no read/write/backend split, no caches. Ceph already provides the replication and
durability that a distributed Loki deployment would be reaching for.

A second Alloy release, `alloy-syslog`, runs as a **Deployment** rather than a DaemonSet
and does no discovery at all: it listens on UDP 514 (remapped to 1514 inside the
unprivileged container) for syslog from the MikroTik devices and labels it `job=routeros`,
plus `hostname`, `severity`, and `source_ip` off the syslog header. One message is dropped
before it reaches Loki — see [WAN RA MTU Syslog](../decisions/wan-ra-mtu.md).

## Keeping the log volume honest

Three sources will drown the others if left on their defaults. Each is turned down at the
source rather than filtered at query time, so the noise never costs ingest or storage.

### Ceph cluster log level

Ceph defaults `mon_cluster_log_level` to `debug`, which puts a `pgmap` line into the
cluster log every couple of seconds and an audit line for every admin-socket liveness
probe Rook makes against every mon. At `info` the mons emit the state changes, elections,
and health transitions worth reading and nothing else. Set via `cephConfig` on the
`CephCluster` — see [Rook-Ceph Values](../decisions/rook-ceph.md#ceph-cluster--the-divergences-we-keep).

The `debug_mon` daemon log is left at its default. It is a fraction of the cluster-log
volume and is what post-mortems are reconstructed from.

### Loki gateway access log

The gateway's nginx logs every request, and almost all of them are Alloy's own
`POST /loki/api/v1/push` — a shipper writing an access-log line that the shipper then
ships. `gateway.verboseLogging: false` switches nginx from unconditional logging to
`access_log … if=$loggable`, where `$loggable` is false for 2xx and 3xx:

```nginx
map $status $loggable {
  ~^[23]  0;
  default 1;
}
```

This is a **status filter, not a path or user-agent filter**, which is the reason to
prefer it. Every failed push still logs — a 429 from rate limiting, a 400 from a malformed
batch, a 500 from the backend — as does every failed query and every failed probe. Only
requests that succeeded are dropped, and a successful push is fully accounted for by
Loki's own ingest metrics.

### MikroTik WAN syslog

One upstream-generated warning accounts for the large majority of router syslog and is
dropped at `alloy-syslog`. The reasoning and the ways to see it anyway are in
[WAN RA MTU Syslog](../decisions/wan-ra-mtu.md).

## Health check

```bash
kubectl -n victoria-metrics get pods
kubectl -n loki get pods
kubectl -n alloy get daemonset alloy
kubectl -n grafana get ingress grafana
kubectl get certificate -A
```

The Grafana admin credentials come from the `grafana-admin` SOPS secret in
`platform/controllers/grafana/`; see [Secrets](./secrets.md).

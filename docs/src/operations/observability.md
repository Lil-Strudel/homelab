# Observability

Metrics, logs, and dashboards for the cluster. Versions are in
[Reference → Versions](../reference/versions.md); why the stack sits in
`infrastructure/` rather than `apps/` is in
[Architecture → Observability](../architecture.md#observability).

There is **nothing to run by hand** — Flux brings all four pieces up from
`kubernetes/infrastructure/controllers/`. This page is day-2: what runs, what it keeps,
and where to look when something is missing.

## What runs where

| HelmRelease | Namespace | Stage | Role |
| --- | --- | --- | --- |
| `victoria-metrics` (`victoria-metrics-k8s-stack`) | `victoria-metrics` | controllers | VM operator, `vmsingle` store, `vmagent` scraper, kube-state-metrics, node-exporter |
| `loki` | `loki` | controllers | Log store, single-binary mode |
| `grafana` | `grafana` | controllers | Dashboards and query UI |
| `alloy` | `alloy` | controllers | DaemonSet shipping pod logs to Loki |
| `VMServiceScrape`s | `rook-ceph`, `kube-system` | configs | Scrape targets for Ceph and Cilium |

The scrape CRs are `configs`, not `controllers`, because they are custom resources of the
VictoriaMetrics operator and would fail against CRDs that do not exist yet.

Grafana is a **separate release** from the `victoria-metrics-k8s-stack` chart's bundled
Grafana subchart, which is disabled. Running it standalone keeps its version, storage, and
datasources independent of the metrics stack's release cycle. The stack's dashboard
ConfigMaps still land, because Grafana's dashboard sidecar watches all namespaces for the
`grafana_dashboard` label and the stack's dashboards are rewritten to the `VictoriaMetrics`
datasource UID.

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

## Health check

```bash
kubectl -n victoria-metrics get pods
kubectl -n loki get pods
kubectl -n alloy get daemonset alloy
kubectl -n grafana get svc grafana
```

The Grafana admin credentials come from the `grafana-admin` SOPS secret in
`controllers/grafana/`; see [Secrets](./secrets.md).

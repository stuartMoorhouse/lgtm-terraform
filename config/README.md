# Solution configuration files

Static configuration consumed by Terraform (`helm_release` values, ConfigMaps). No secrets or hostnames are
stored here. Charts inspected on 2026-10-29: grafana-community/loki 20.0.2 (app 3.7.9), grafana-community/tempo
3.2.1 (3.1.1), grafana/mimir-distributed 6.2.2 (3.2.3), grafana-community/grafana 14.2.0 (13.3.0),
grafana/alloy 1.14.4 (v1.21.3), otel/opentelemetry-demo 0.42.6 (app 3.1.0),
prometheus-community/kube-state-metrics 8.7.1. Note: the `grafana/loki`, `grafana/tempo` and `grafana/grafana`
charts in the legacy `grafana` repo are older (loki 7.5.0, tempo 1.24.4, grafana 10.5.15); the current
charts live in `https://grafana-community.github.io/helm-charts`. Agent 1 chooses; the URLs below hold for both.

## Files

| File | Purpose | Consumed by |
|---|---|---|
| `grafana/datasources.yaml` | Datasources (uids `mimir`, `loki`, `tempo`) with trace-to-logs/metrics, service map, derived fields | Grafana chart `datasources."datasources.yaml"` (or ConfigMap in `/etc/grafana/provisioning/datasources`). Whole file is the provisioning doc (`apiVersion: 1` at top level). |
| `grafana/dashboards/*.json` | Astronomy Shop RED, Astronomy Shop logs, Kubernetes cluster | ConfigMap(s) mounted via Grafana dashboard sidecar or `dashboardsConfigMaps` + a file provider. Reference datasources by uid. |
| `grafana/alerting/rules.yaml` | Alert rules (error rate, p95, error log burst, crash loop) | Mounted at `/etc/grafana/provisioning/alerting/rules.yaml` (chart `alerting."rules.yaml"`). |
| `alloy/config.alloy` | OTLP pipeline, span metrics, service graph, pod logs, cadvisor + KSM scrape | Alloy chart `alloy.configMap.content` (use `file()` in Terraform) |
| `astronomy-shop/values.yaml` | Values for opentelemetry-demo | `helm_release.astronomy_shop` `values = [file(...)]` |

## Assumed in-cluster URLs (Agent 1: verify against your values)

Verified with `helm template` for release names loki, tempo, mimir, alloy, kube-state-metrics in `lgtm`.

| Service | URL / port | Notes |
|---|---|---|
| Loki | `http://loki.lgtm.svc.cluster.local:3100` | Push `/loki/api/v1/push`, OTLP `/otlp` (exporter adds `/v1/logs`). `loki-gateway:80` also exists (nginx) but is not used. |
| Tempo | `tempo.lgtm.svc.cluster.local` query `3200`, OTLP gRPC `4317`, OTLP HTTP `4318` | Single-binary chart exposes all on Service `tempo`. |
| Mimir | `http://mimir-gateway.lgtm.svc.cluster.local` (port 80) | Push `/api/v1/push`, Prometheus API prefix `/prometheus`. Gateway also on 8080. |
| Alloy | `alloy.lgtm.svc.cluster.local` | Chart service exposes only 12345; OTLP 4317/4318 must be added (see below). |
| kube-state-metrics | `kube-state-metrics.lgtm.svc.cluster.local:8080` | Requires extra chart. |
| Demo collector | `otel-collector.astronomy-shop` 4317/4318 | Created by the demo chart. |

Tenancy: assumed single tenant. Loki chart default is `auth_enabled: true`, so Agent 1 must set
`loki.auth_enabled: false` (otherwise every push/query needs `X-Scope-OrgID`). Tempo `multitenancyEnabled`
defaults to false. Mimir gateway injects the default tenant when no header is sent.

## Required settings in Terraform-managed chart values (not in these files)

- **Alloy**: `controller.type: deployment`, `controller.replicas: 1` (chart default is daemonset; several replicas
  would duplicate pod logs and scrapes). `alloy.extraPorts` for `otlp-grpc` 4317 and `otlp-http` 4318 (TCP).
  `rbac.rules` replaces the default list, so keep the defaults and append
  `{apiGroups: [""], resources: ["nodes", "nodes/proxy", "nodes/metrics"], verbs: ["get","list","watch"]}`
  (nodes list/watch is needed for `discovery.kubernetes role=node`; `nodes/proxy` get for the cadvisor scrape).
- **kube-state-metrics**: separate `helm_release` (prometheus-community/kube-state-metrics, name
  `kube-state-metrics`, namespace `lgtm`). Needed for restarts/crash-loop alert and dashboard panels.
  node-exporter is NOT assumed; node panels use cadvisor root cgroup (`id="/"`) and `machine_*` metrics.
- **Mimir** (decision: stay on `mimir-distributed` 6.x, shrunk). Re-verified with `helm template mimir` in `lgtm`
  with `minio.enabled=false`: Service `mimir-gateway` is still ClusterIP on ports 80 and 8080, so
  `http://mimir-gateway.lgtm.svc.cluster.local` (port 80), `/prometheus` and `/api/v1/push` hold. The gateway still
  injects the default tenant. Settings Agent 1 must apply:
  - `minio.enabled: false`; S3 via `mimir.structuredConfig.common.storage` (`backend: s3`, `s3.endpoint`
    `s3.us-east-1.amazonaws.com`, `region`, buckets for `blocks_storage`, `alertmanager_storage`, `ruler_storage`)
    and IRSA annotation on the Mimir service account (`serviceAccount.annotations`); no static keys.
  - Retention 7d: `mimir.structuredConfig.limits.compactor_blocks_retention_period: 7d` (plus the S3 lifecycle).
  - Minimal replicas: chart defaults are ingester 3, store-gateway 1, distributor/query-frontend/querier 1-2,
    query-scheduler 2; set each to 1 (`ingester.replicas: 1`, `query_scheduler.replicas: 1`, etc.) and
    `ingester.zoneAwareReplication.enabled: false`, `store_gateway.zoneAwareReplication.enabled: false`,
    `alertmanager.zoneAwareReplication.enabled: false`. Reduce `replication_factor` to 1 in
    `mimir.structuredConfig.ingester.ring`. Consider disabling alertmanager, ruler, overrides_exporter (Grafana
    handles alerting) and `metaMonitoring`/caches.
  - Kafka / ingest storage IS involved: chart 6.x defaults to `mimir.structuredConfig.ingest_storage.enabled: true`
    with an in-chart `mimir-kafka` StatefulSet (`kafka.enabled: true`, Service `mimir-kafka:9092`, topic
    `mimir-ingest` auto-created). It cannot be dropped without switching ingest storage off; keep it and size its
    persistence/resources small. Kafka needs its PVC (gp3 EBS, encrypted via StorageClass).
- **Loki**: `deploymentMode: SingleBinary`, zero replicas for read/write/backend, `loki.auth_enabled: false`,
  disable canary/caches. Needs structured metadata (default on with schema v13) for `trace_id` and `detected_level`.
- **Tempo**: enable the OTLP receivers (chart default does) and 7-day retention via `tempo.retention`.

## Assumed metric and log sources

- `traces_span_metrics_calls_total`, `traces_span_metrics_duration_milliseconds_{bucket,sum,count}`: generated
  in Alloy (`otelcol.connector.spanmetrics`); labels `service_name`, `span_name`, `span_kind`, `status_code`.
- `traces_service_graph_request_*`: Alloy `otelcol.connector.servicegraph` (Tempo service map).
- cadvisor `container_*` and `machine_*`: Alloy scrape via API server node proxy (filtered keep-list).
- `kube_*`: kube-state-metrics.
- App OTLP metrics (runtime, kafka, collector self metrics): forwarded to Mimir as received.
- Logs: OTLP logs from the demo apps go to Loki's native OTLP endpoint (label `service_name`, structured
  metadata `trace_id`, `detected_level`). Pod stdout logs of `astronomy-shop` and `lgtm` are also collected with label
  `log_source="pod"`. Dashboards and the log alert filter `log_source=""` to exclude the pod copy of the
  astronomy-shop logs and avoid double counting. Pod logs are queryable with `{log_source="pod"}`.

## Astronomy Shop values notes

- Disabled: bundled jaeger, prometheus, grafana, opensearch, ebpf profiler; components agent, chatbot, mcp
  (LLM dependent), opamp-server, firepit, telemetry-docs.
- Collector exports all signals to `alloy.lgtm.svc.cluster.local:4317`. The chart's backend exporters
  (jaeger, prometheus, opensearch, firepit) stay defined but unreferenced, because Helm cannot delete nested
  subchart keys (null produced a render error). Node/cluster metric presets are off to avoid duplicates with Alloy.
- Load generator: 3 users, browser traffic disabled (saves about 1 GB).
- Small CPU/memory requests are set for every enabled component; chart memory limits kept.
- Rendered with `helm template` against chart 0.42.6 without errors.

## Ingress

One Gateway API gateway (Envoy Gateway) on the NLB hostname serves the storefront at `/` and Grafana at `/grafana`,
with a self-signed CA certificate from cert-manager (the browser must trust that CA). There are no DNS names.
Terraform owns the Gateway, certificates and HTTPRoutes; Grafana must run with `grafana.ini` `server.root_url`
ending in `/grafana` (`%(protocol)s://%(domain)s/grafana/`) and `server.serve_from_sub_path: true`, also set by
Terraform. Nothing under `config/` contains a public URL, hostname or sub-path: datasources, dashboards, alerts and
Alloy use only in-cluster `svc.cluster.local` addresses, and dashboards link only by uid (no absolute links).
In `astronomy-shop/values.yaml`: `frontend-proxy` is `ClusterIP` on 8080 with chart ingress disabled (HTTPRoute
backend: `frontend-proxy.astronomy-shop:8080`, path `/`). The frontend's
`PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` is overridden from `http://localhost:8080/otlp-http/v1/traces` to the
relative `/otlp-http/v1/traces`, which resolves against the origin root where the storefront is served and is routed
by frontend-proxy to the collector. The `/grafana` route must be matched before `/` (longest-prefix) and must not
swallow `/otlp-http`.
The frontend-proxy chart also proxies `/grafana` to a `grafana` host; that is unused (the Gateway routes `/grafana`
directly to the Grafana service, and the bundled Grafana is disabled).

## Validation done

JSON via `python3 -m json.tool`, YAML via PyYAML, demo values via `helm template`. Alloy syntax was reviewed by
hand only (the `alloy` binary is not installed); run `alloy fmt config/alloy/config.alloy` / `alloy run` check
if available. kubescape: no Kubernetes manifests in `config/` (nothing to scan).

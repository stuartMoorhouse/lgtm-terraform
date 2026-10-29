# 1. Stack overview and how to run queries

This stack is the Grafana LGTM set running on EKS, fed by the OpenTelemetry Astronomy Shop demo.

| Letter | Component | Signal | Query language | In-cluster service |
|---|---|---|---|---|
| L | Loki | Logs | LogQL | `loki.lgtm:3100` |
| G | Grafana | UI | n/a | `grafana.lgtm:80` (served at `/grafana`) |
| T | Tempo | Traces | TraceQL | `tempo.lgtm:3200` |
| M | Mimir | Metrics | PromQL | `mimir-gateway.lgtm:80` |

Grafana Alloy receives OTLP from the demo, derives span metrics and a service graph from the traces, and forwards
metrics to Mimir, traces to Tempo and logs to Loki. Alloy also scrapes cAdvisor, and kube-state-metrics supplies
Kubernetes object state.

```
Astronomy Shop --OTLP--> Alloy --> Mimir (metrics)
                               --> Tempo (traces)
                               --> Loki  (logs)
```

## Option A: Grafana Explore

1. Get the URL with `scripts/get-urls.sh` and the admin password with `terraform -chdir=terraform output -raw grafana_admin_password`.
2. Open Explore and pick a datasource: Mimir for PromQL, Loki for LogQL, Tempo for TraceQL.
3. Paste a query, set the time range to the last 1 hour, and run it.

## Option B: the HTTP APIs through port-forward

This is how `scripts/test-doc-queries.py` verifies every query in these tutorials.

```bash
kubectl port-forward -n lgtm svc/mimir-gateway 9009:80 &
kubectl port-forward -n lgtm svc/loki 3100:3100 &
kubectl port-forward -n lgtm svc/tempo 3200:3200 &
```

Auth is disabled, so no tenant header is needed.

```bash
# PromQL (Mimir exposes the Prometheus API under /prometheus)
curl -s -G http://localhost:9009/prometheus/api/v1/query \
  --data-urlencode 'query=count(up)'

# LogQL
curl -s -G http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={service_name="frontend"}' \
  --data-urlencode "start=$(date -v-1H +%s)000000000" \
  --data-urlencode 'limit=5'

# TraceQL
curl -s -G http://localhost:3200/api/search \
  --data-urlencode 'q={ resource.service.name = "frontend" }' \
  --data-urlencode 'limit=5'
```

`date -v-1H` is the macOS form. On Linux use `date -d '1 hour ago' +%s`.

## Your first query in each language

Count the targets Mimir knows about, which is a sanity check that metrics are flowing:

```promql
count(up)
```

Fetch the most recent frontend logs:

```logql
{service_name="frontend"}
```

Find recent frontend traces:

```traceql
{ resource.service.name = "frontend" }
```

## Naming conventions in this stack

OTLP attribute names contain dots, but the storage layers rewrite them differently:

| Signal | Example attribute | How it appears |
|---|---|---|
| Metrics (Mimir) | `service.name` | `service_name` |
| Logs (Loki) | `k8s.namespace.name` | `k8s_namespace_name` |
| Traces (Tempo) | `service.name` | `resource.service.name` (dots kept) |

Every metric also carries `cluster="lgtm-demo"`, added by Alloy's remote write.

Next: [PromQL selectors and labels](02-promql-selectors-and-labels.md).

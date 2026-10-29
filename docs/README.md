# LGTM stack tutorials

Hands-on tutorials for querying the Grafana LGTM stack (Loki, Grafana, Tempo, Mimir) deployed by this repository, using
the live telemetry from the OpenTelemetry Astronomy Shop demo.

| # | Tutorial | Language |
|---|---|---|
| 1 | [Stack overview and how to run queries](01-stack-overview-and-access.md) | all |
| 2 | [PromQL selectors and labels](02-promql-selectors-and-labels.md) | PromQL |
| 3 | [Counters, rate and increase](03-promql-counters-rate-increase.md) | PromQL |
| 4 | [Aggregation operators](04-promql-aggregation.md) | PromQL |
| 5 | [Histograms and latency percentiles](05-promql-histograms-and-latency.md) | PromQL |
| 6 | [The RED method for Astronomy Shop](06-promql-red-method.md) | PromQL |
| 7 | [Kubernetes resource metrics](07-promql-kubernetes-resources.md) | PromQL |
| 8 | [Advanced PromQL](08-promql-advanced.md) | PromQL |
| 9 | [LogQL for Loki](09-logql-for-loki.md) | LogQL |
| 10 | [TraceQL for Tempo and correlating signals](10-traceql-and-correlation.md) | TraceQL |

## Testing the queries

Every query in a `promql`, `logql` or `traceql` fenced block is executed against the live backends by
`scripts/test-doc-queries.py`. A query fails if the API returns an error or no data. Queries that are legitimately
empty on a healthy demo (for example error-only queries) carry an `allow-empty` flag on the fence.

```bash
kubectl port-forward -n lgtm svc/mimir-gateway 9009:80 &
kubectl port-forward -n lgtm svc/loki 3100:3100 &
kubectl port-forward -n lgtm svc/tempo 3200:3200 &
python3 -I scripts/test-doc-queries.py
```

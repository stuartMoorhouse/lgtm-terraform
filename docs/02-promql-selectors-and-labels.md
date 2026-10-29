# 2. PromQL selectors and labels

PromQL is the query language for Mimir. Everything starts with a selector: a metric name plus optional label matchers.

Run these in Grafana Explore against the Mimir datasource.

## Instant vector selectors

Is everything being scraped? `up` is 1 for a healthy target and 0 for a failed one:

```promql
up
```

Restrict by a label:

```promql
up{job="kube-state-metrics"}
```

## Label matchers

| Operator | Meaning |
|---|---|
| `=` | equals |
| `!=` | not equals |
| `=~` | regex match (fully anchored) |
| `!~` | regex does not match |

Several services at once with a regex:

```promql
traces_span_metrics_calls_total{service_name=~"frontend|checkout|cart"}
```

Everything in the demo namespace except one pod prefix:

```promql
container_memory_working_set_bytes{namespace="astronomy-shop", pod!~"load-generator.*", container!=""}
```

The `container!=""` matcher drops cAdvisor's pod-level aggregate series, which have an empty `container` label.
You will use it on almost every cAdvisor query.

## Counting what exists

How many time series does a metric have?

```promql
count(traces_span_metrics_calls_total)
```

How many distinct services emit span metrics?

```promql
count(count by (service_name) (traces_span_metrics_calls_total))
```

How many targets are up versus down?

```promql
count by (job) (up == 0) or count by (job) (up == 1)
```

## Discovering metric and label names

Search metric names by regex using the special `__name__` label. This lists every Kubernetes pod metric:

```promql
count by (__name__) ({__name__=~"kube_pod_.+"})
```

Which values does a label take? Group by it:

```promql
count by (status_code) (traces_span_metrics_calls_total)
```

The same discovery through the HTTP API, which Grafana's label browser uses:

```bash
curl -s http://localhost:9009/prometheus/api/v1/label/service_name/values
curl -s http://localhost:9009/prometheus/api/v1/labels
```

## Range vectors

Appending `[5m]` turns an instant vector into a range vector: for each series, all samples in the last five minutes.
You cannot graph a range vector directly. You pass it to a function such as `rate()` (next tutorial).

```promql
count_over_time(up{job="kube-state-metrics"}[5m])
```

## Instant versus range queries

| Query type | Returns | Used for |
|---|---|---|
| Instant | One value per series at one timestamp | Stat panels, tables, alert rules |
| Range | A series of values over a window at a step interval | Graphs |

Explore runs a range query by default. Switch the Type toggle to Instant to see the table form.

## Staleness and resolution

Series stop appearing roughly five minutes after the last sample (the lookback window). If a selector you expect returns nothing, widen
the time range, then check the job is still up with `up{job="..."}`.

Next: [Counters, rate and increase](03-promql-counters-rate-increase.md).

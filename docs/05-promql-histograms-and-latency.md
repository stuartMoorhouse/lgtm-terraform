# 5. Histograms and latency percentiles

A classic Prometheus histogram is three metric families:

| Suffix | Meaning |
|---|---|
| `_bucket{le="X"}` | Cumulative count of observations less than or equal to X |
| `_sum` | Sum of all observed values |
| `_count` | Number of observations |

In this stack there are two good sources of latency histograms:

| Metric | Unit | Source |
|---|---|---|
| `traces_span_metrics_duration_milliseconds_bucket` | milliseconds | Derived from traces by Alloy, covers every service |
| `http_server_request_duration_seconds_bucket` | seconds | Emitted by the frontend's own instrumentation |

**How to run these:** open **Explore**, choose the `Mimir` datasource, switch the editor from **Builder** to **Code**, paste a query, set the time range to **Last 1 hour** and click **Run query**. Every query in this tutorial is PromQL. Full steps are in [tutorial 1](01-stack-overview-and-access.md#running-queries-in-grafana-explore).

## Percentiles with histogram_quantile

The recipe is always the same: `rate()` the buckets, sum by `le` (plus any label you want to keep), then
`histogram_quantile`.

p95 latency across all server spans:

```promql
histogram_quantile(0.95, sum by (le) (rate(traces_span_metrics_duration_milliseconds_bucket{span_kind="SPAN_KIND_SERVER"}[5m])))
```

p95 per service, which is the expression behind the "high p95 latency" alert:

```promql
histogram_quantile(0.95, sum by (le, service_name) (rate(traces_span_metrics_duration_milliseconds_bucket{span_kind="SPAN_KIND_SERVER"}[5m])))
```

You must keep `le` in the `by` clause. Forgetting it is the most common histogram mistake and produces no data.

## p50, p95 and p99 side by side

```promql
histogram_quantile(0.50, sum by (le) (rate(traces_span_metrics_duration_milliseconds_bucket{service_name="frontend", span_kind="SPAN_KIND_SERVER"}[5m])))
```

```promql
histogram_quantile(0.99, sum by (le) (rate(traces_span_metrics_duration_milliseconds_bucket{service_name="frontend", span_kind="SPAN_KIND_SERVER"}[5m])))
```

In Explore, add the p50, p95 and p99 as separate queries (A, B, C) to plot them together.

## Average latency from sum and count

The mean is cheaper and exact, though it hides outliers:

```promql
sum by (service_name) (rate(traces_span_metrics_duration_milliseconds_sum{span_kind="SPAN_KIND_SERVER"}[5m]))
/
sum by (service_name) (rate(traces_span_metrics_duration_milliseconds_count{span_kind="SPAN_KIND_SERVER"}[5m]))
```

## The slowest operations

Rank individual endpoints (`span_name`) by p95:

```promql
topk(10, histogram_quantile(0.95, sum by (le, service_name, span_name) (rate(traces_span_metrics_duration_milliseconds_bucket{span_kind="SPAN_KIND_SERVER"}[5m]))))
```

## Seconds-based histograms

The frontend's own HTTP histogram is in seconds. p95 for incoming HTTP requests:

```promql
histogram_quantile(0.95, sum by (le) (rate(http_server_request_duration_seconds_bucket{service_name="frontend"}[5m])))
```

Cart operation latency from a custom demo metric:

```promql
histogram_quantile(0.95, sum by (le) (rate(demo_cart_add_item_latency_seconds_bucket[5m])))
```

## Fraction of requests under an SLO

What share of frontend server spans finished within 500 ms? Pick a bucket boundary that exists (`le="500"`):

```promql
sum(rate(traces_span_metrics_duration_milliseconds_bucket{service_name="frontend", span_kind="SPAN_KIND_SERVER", le="500"}[5m]))
/
sum(rate(traces_span_metrics_duration_milliseconds_count{service_name="frontend", span_kind="SPAN_KIND_SERVER"}[5m]))
```

List the available boundaries first:

```promql
count by (le) (traces_span_metrics_duration_milliseconds_bucket{service_name="frontend"})
```

## Accuracy caveat

`histogram_quantile` interpolates inside a bucket, so the answer is only as precise as the bucket layout. If your
p99 sits in a wide top bucket, it is an estimate. Averages of percentiles across services are meaningless: always
sum the buckets first, then take the quantile.

Next: [The RED method for Astronomy Shop](06-promql-red-method.md).

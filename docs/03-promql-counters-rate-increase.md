# 3. Counters, rate and increase

A counter only ever goes up (and resets to zero on restart). The raw value is rarely useful. You want how fast it grows.
Counter names end in `_total` by convention.

## rate()

`rate(counter[window])` is the per-second average increase over the window, handling resets:

```promql
rate(traces_span_metrics_calls_total{service_name="frontend"}[5m])
```

That returns one series per label combination. Almost always you want to aggregate afterwards. Total requests per
second across the whole shop for server-side spans:

```promql
sum(rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))
```

Requests per second per service, busiest first:

```promql
sort_desc(sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m])))
```

Rule: always apply `rate()` first, then `sum()`. Summing raw counters first hides resets and gives wrong results.

## increase()

`increase(counter[window])` is the total growth over the window. It is `rate()` multiplied by the window in
seconds, so it suits "how many in the last hour" questions:

```promql
sum(increase(demo_payment_transactions_total[1h]))
```

Payment transactions by currency over the last hour:

```promql
sum by (demo_payment_currency) (increase(demo_payment_transactions_total[1h]))
```

Pod restarts in the last 15 minutes, the same expression the "Pod crash looping" alert uses:

```promql
sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total{namespace=~"astronomy-shop|lgtm"}[15m]))
```

`increase()` extrapolates to the window edges, so results can be fractional for integer counters. This is expected.

## Choosing the window

| Window | Behaviour |
|---|---|
| Too short (under 4x the scrape interval) | Gaps and noisy results |
| `[5m]` | A good default for dashboards and alerts |
| Long (`[1h]`) | Smooth, but slow to show changes |

In Grafana dashboards use the built-in `$__rate_interval` variable so the window adapts to the zoom level. The tutorials use fixed
windows so they also work in plain API calls.

## Error ratio

Divide one rate by another to get a ratio. The fraction of server spans ending in an error, per service. This is
the expression behind the "high error rate" alert:

```promql allow-empty
sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER", status_code="STATUS_CODE_ERROR"}[5m]))
/
sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))
```

Services with zero errors have no numerator series, so they disappear from the result rather than showing 0. Tutorial 6
shows an `or` pattern that fixes that.

## irate()

`irate()` uses only the last two samples in the window, so it reacts instantly but is spiky. Use it for
zoomed-in debugging, never for alerts:

```promql
irate(container_cpu_usage_seconds_total{namespace="astronomy-shop", container="frontend"}[5m])
```

## Gauges are different

Gauges go up and down (memory, queue length). Do not use `rate()` on them. Use the raw value, `avg_over_time()`,
or `delta()`:

```promql
delta(container_memory_working_set_bytes{namespace="astronomy-shop", container="frontend"}[30m])
```

Next: [Aggregation operators](04-promql-aggregation.md).

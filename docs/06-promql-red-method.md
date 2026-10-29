# 6. The RED method for Astronomy Shop

RED is the standard first look at any request-driven service:

- **R**ate: requests per second
- **E**rrors: failing requests per second, or as a fraction
- **D**uration: how long requests take

Alloy's `spanmetrics` connector turns every span into metrics, so all three come from the same two metric families for every service without extra instrumentation:

| Metric | Type | Key labels |
|---|---|---|
| `traces_span_metrics_calls_total` | counter | `service_name`, `span_name`, `span_kind`, `status_code` |
| `traces_span_metrics_duration_milliseconds_*` | histogram | same |

`span_kind="SPAN_KIND_SERVER"` selects spans where the service handled an incoming request. Use `SPAN_KIND_CLIENT` for outgoing calls.

## Rate

Requests per second for each service:

```promql
sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))
```

Requests per second for the busiest endpoints:

```promql
topk(10, sum by (service_name, span_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m])))
```

## Errors

Error rate in errors per second:

```promql allow-empty
sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER", status_code="STATUS_CODE_ERROR"}[5m]))
```

Error ratio per service, with zero shown for healthy services. The `or` adds a zero series for any service missing
from the numerator, so graphs and alerts do not have gaps:

```promql
(
  sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER", status_code="STATUS_CODE_ERROR"}[5m]))
  or
  sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m])) * 0
)
/
sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))
```

Success rate as a percentage, the shape most SLO dashboards want:

```promql
100 * (1 - (
  (
    sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER", status_code="STATUS_CODE_ERROR"}[5m]))
    or
    sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m])) * 0
  )
  /
  sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))
))
```

## Duration

p95 latency per service in milliseconds:

```promql
histogram_quantile(0.95, sum by (le, service_name) (rate(traces_span_metrics_duration_milliseconds_bucket{span_kind="SPAN_KIND_SERVER"}[5m])))
```

## Dependencies with the service graph

Alloy's `servicegraph` connector records caller and callee pairs. Calls per second between services:

```promql
sum by (client, server) (rate(traces_service_graph_request_total[5m]))
```

Failed calls per second between services:

```promql allow-empty
sum by (client, server) (rate(traces_service_graph_request_failed_total[5m]))
```

Server-side p95 latency of each edge, in seconds:

```promql
histogram_quantile(0.95, sum by (le, client, server) (rate(traces_service_graph_request_server_seconds_bucket[5m])))
```

## Business metrics from the demo

The demo services also emit custom counters. Payments per second by currency:

```promql
sum by (demo_payment_currency) (rate(demo_payment_transactions_total[5m]))
```

Items shipped per minute:

```promql
sum(rate(demo_shipping_items_shipped_total[5m])) * 60
```

Ads served versus requested:

```promql
sum(rate(demo_ad_served_total[5m])) / sum(rate(demo_ad_requests_total[5m]))
```

## Try it: break something

`scripts/trigger-incidents.sh enable paymentFailure` makes the payment service fail a share of requests. After a minute or two the
error ratio query above should show `payment` and `checkout` rising. Undo it with `scripts/trigger-incidents.sh disable paymentFailure`
or `scripts/reset-demo.sh`.

Next: [Kubernetes resource metrics](07-promql-kubernetes-resources.md).

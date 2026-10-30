# 9. LogQL for Loki

LogQL mirrors PromQL's structure. A query is a stream selector, followed by a pipeline that filters and parses lines.
Wrap it in a function such as `rate()` and you get a metric.

**How to run these:** open **Explore**, choose the `Loki` datasource, switch the editor from **Builder** to **Code**, paste a query, set the time range to **Last 1 hour** and click **Run query**. Every query in this tutorial is LogQL. Full steps are in [tutorial 1](01-stack-overview-and-access.md#running-queries-in-grafana-explore).

## Labels in this stack

Loki indexes only a small set of labels (the rest are structured metadata, queryable after the selector).
Useful stream labels:

| Label | Example values |
|---|---|
| `service_name` | `frontend`, `checkout`, `loki`, `tempo` |
| `k8s_namespace_name` | `astronomy-shop`, `lgtm` |
| `k8s_pod_name`, `k8s_deployment_name`, `k8s_container_name` | pod and workload names |
| `log_source` | `pod` for logs Alloy tails from container stdout. Absent for logs that arrive over OTLP from the demo apps |

Two ingest paths feed Loki. The demo apps send logs over OTLP and carry rich metadata (`severity_text`,
`trace_id`). The LGTM components' own logs are tailed from stdout by Alloy and carry `log_source="pod"`.

Discover label values in Explore: with `Loki` selected, stay on **Builder**, open the **Label filters** dropdown and pick a label such as `service_name`. The value dropdown lists every value Loki has seen.

## Stream selectors

Selectors use the same matchers as PromQL (`=`, `!=`, `=~`, `!~`). At least one matcher must be non-empty.

All logs for one service:

```logql
{service_name="checkout"}
```

Everything in the shop namespace:

```logql
{k8s_namespace_name="astronomy-shop"}
```

Several services:

```logql
{service_name=~"frontend|cart|checkout"}
```

## Line filters

Line filters are the fastest part of a pipeline, so put them first.

| Operator | Meaning |
|---|---|
| `\|=` | line contains string |
| `!=` | line does not contain string |
| `\|~` | line matches regex |
| `!~` | line does not match regex |

Lines mentioning a failed connection:

```logql
{k8s_namespace_name="astronomy-shop"} |= "Connection failed"
```

Exclude noise:

```logql
{service_name="loki"} != "recalculate_owned_streams"
```

Case-insensitive regex:

```logql
{k8s_namespace_name="lgtm"} |~ "(?i)error|exception|fatal"
```

## Filtering on detected level

Loki records a `detected_level` for every line. It is structured metadata, so it is filtered after the selector, not inside it:

```logql
{k8s_namespace_name="astronomy-shop"} | detected_level="error"
```

Warnings and errors from anywhere in the stack:

```logql
{service_name=~".+"} | detected_level=~"warn.*|error"
```

## Parsers

Parsers extract fields from the line so you can filter and aggregate on them.

`logfmt` for `key=value` logs, such as the LGTM components' own logs:

```logql
{service_name="loki"} | logfmt | level="info" | caller=~"metrics.*"
```

`json` for JSON logs, then a field filter:

```logql allow-empty
{service_name="frontend"} | json | level="error"
```

`pattern` for fixed-layout text. Envoy access logs from the demo's `frontend-proxy` look like
`[time] "GET /path HTTP/1.1" 200 ...`. Extract the method, path and status, and keep everything that was not a plain 200 (redirects included):

```logql
{service_name="frontend-proxy"} | pattern `[<_>] "<method> <path> <_>" <status> <_>` | status != 200
```

Requests that returned 5xx:

```logql allow-empty
{service_name="frontend-proxy"} | pattern `[<_>] "<method> <path> <_>" <status> <_>` | status >= 500
```

## Reformatting output

`line_format` rewrites the displayed line using extracted fields:

```logql
{service_name="frontend-proxy"} | pattern `[<_>] "<method> <path> <_>" <status> <_>` | line_format "{{.status}} {{.method}} {{.path}}"
```

## Metric queries

Wrap a log selector in a range function to get a number per series.

| Function | Meaning |
|---|---|
| `count_over_time(...[5m])` | Log lines in the window |
| `rate(...[5m])` | Lines per second |
| `bytes_over_time(...[5m])` | Bytes of log volume |
| `bytes_rate(...[5m])` | Bytes per second |

Log lines per second for each service:

```logql
sum by (service_name) (rate({k8s_namespace_name="astronomy-shop"}[5m]))
```

Error lines per service in the last 5 minutes, which is the alert "Astronomy Shop error log burst":

```logql allow-empty
sum by (service_name) (count_over_time({k8s_namespace_name="astronomy-shop"} | detected_level=~"(?i)error|fatal|critical" [5m]))
```

The five noisiest services by log volume:

```logql
topk(5, sum by (service_name) (bytes_over_time({k8s_namespace_name="astronomy-shop"}[10m])))
```

Log volume by level:

```logql
sum by (detected_level) (count_over_time({k8s_namespace_name="astronomy-shop"}[5m]))
```

HTTP status code distribution at the edge proxy:

```logql
sum by (status) (count_over_time({service_name="frontend-proxy"} | pattern `[<_>] "<method> <path> <_>" <status> <_>` [5m]))
```

## Jumping from a log line to its trace

Logs sent over OTLP keep `trace_id` as structured metadata. Find the logs for one trace:

```logql allow-empty
{service_name="frontend-proxy"} | trace_id="0000000000000000"
```

Replace the placeholder with a real ID from Tempo. Grafana does this automatically through the derived link configured on the
Loki datasource.

Next: [TraceQL for Tempo and correlating signals](10-traceql-and-correlation.md).

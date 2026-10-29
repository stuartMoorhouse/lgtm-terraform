# 8. Advanced PromQL

These are the techniques you reach for once the basics work: comparing over time, joining series, detecting missing
data and forecasting.

## offset: compare with the past

Request rate now versus the same time one hour ago:

```promql
sum(rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))
/
sum(rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m] offset 1h))
```

A value above 1 means traffic grew. `offset` goes directly after the selector's range, before the closing parenthesis.

## Subqueries

A subquery evaluates an expression at a step and returns a range vector, so you can apply `*_over_time` to a
computed series. The peak per-second request rate seen in the last hour:

```promql
max_over_time(sum(rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))[1h:1m])
```

The syntax is `[range:resolution]`. Subqueries are expensive on long ranges. For anything recurring, record the inner
expression as a recording rule instead.

## Boolean filtering with comparison operators

Comparison operators between a vector and a number filter series:

```promql
sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m])) > 1
```

Add `bool` to get 0 or 1 instead of filtering, which is useful for graphing a state:

```promql
sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m])) > bool 1
```

## Vector matching and joins

When both sides have labels, PromQL matches series with identical label sets. Use `on(...)` or `ignoring(...)` to
choose the matching labels, and `group_left` / `group_right` when one side has several series per match.

Attach the host IP of a pod's node to its memory metric by joining with `kube_pod_info`. The `* on (...) group_left (host_ip)` form copies `host_ip` from the right-hand side:

```promql
sum by (namespace, pod) (container_memory_working_set_bytes{namespace="astronomy-shop", container!=""})
* on (namespace, pod) group_left (host_ip)
max by (namespace, pod, host_ip) (kube_pod_info)
```

The `kube_*_info` metrics always have value 1, which makes them ideal "label carriers" for this pattern.

## Set operators: and, or, unless

Services with traffic that are NOT reporting errors. `unless` removes series whose labels appear on the right:

```promql
sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))
unless
sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER", status_code="STATUS_CODE_ERROR"}[5m]))
```

## Detecting missing data with absent()

`absent(selector)` returns 1 only when the selector matches nothing. It is the standard way to alert on a service that
vanished, since a missing series otherwise evaluates to "no data" and never fires:

```promql allow-empty
absent(up{job="kube-state-metrics"})
```

For a metric that should always exist, wrap a selector that does not match to see the 1 returned:

```promql
absent(up{job="this-job-does-not-exist"})
```

`absent_over_time(selector[10m])` does the same over a window and is more tolerant of brief scrape gaps:

```promql allow-empty
absent_over_time(up{job="kube-state-metrics"}[10m])
```

## Forecasting with predict_linear

Will any container's memory hit 2 GiB within the next four hours, extrapolating the last hour's trend?

```promql allow-empty
predict_linear(container_memory_working_set_bytes{namespace="astronomy-shop", container!=""}[1h], 4 * 3600) > 2 * 1024 * 1024 * 1024
```

## Changes and resets

How many times did a pod's restart counter change? `changes()` counts value changes in a series,
and `resets()` counts counter resets, which is another way to spot restarts and redeploys:

```promql
sum by (pod) (changes(kube_pod_container_status_restarts_total{namespace="astronomy-shop"}[1h]))
```

```promql
sum by (service_name) (resets(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[1h]))
```

## Labels and formatting

`label_replace` builds new labels from regex captures. This splits the OTLP `instance` label into a clean pod name:

```promql
label_replace(up{job="kube-state-metrics"}, "short_instance", "$1", "instance", "([^.]+)\\..*")
```

Clamp results to avoid negative or tiny values in ratios:

```promql
clamp_min(sum(rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m])), 0.001)
```

Handle a missing series by substituting zero:

```promql
sum(rate(traces_span_metrics_calls_total{service_name="does-not-exist"}[5m])) or vector(0)
```

## Time functions

Seconds since each pod started, a quick way to see recent rollouts:

```promql
time() - kube_pod_start_time{namespace="astronomy-shop"}
```

Next: [LogQL for Loki](09-logql-for-loki.md).

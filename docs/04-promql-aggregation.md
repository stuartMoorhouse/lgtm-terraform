# 4. Aggregation operators

Aggregation collapses many series into fewer. The pattern is `operator by (labels) (expression)` or
`operator without (labels) (expression)`.

## by and without

`by` keeps only the listed labels. `without` drops the listed labels and keeps everything else.

CPU cores used per namespace:

```promql
sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))
```

The same idea with `without`, dropping noisy per-container labels but keeping the rest:

```promql
sum without (id, name, image, container, cpu) (rate(container_cpu_usage_seconds_total{namespace="astronomy-shop", container!=""}[5m]))
```

Rule of thumb: use `by` for dashboards (you choose the dimensions), use `without` when writing generic rules that
should survive new labels appearing.

## The operators

| Operator | Use |
|---|---|
| `sum` | Total |
| `avg` | Mean across series |
| `min`, `max` | Extremes |
| `count` | Number of series |
| `topk(n, ...)`, `bottomk(n, ...)` | Largest or smallest n series |
| `quantile(q, ...)` | Quantile across series (not over time) |
| `stddev`, `stdvar` | Spread |
| `count_values("label", ...)` | Histogram of distinct values |
| `group` | Always 1, for existence checks and joins |

## Practical examples

Memory working set per namespace, in MiB:

```promql
sum by (namespace) (container_memory_working_set_bytes{container!=""}) / 1024 / 1024
```

The 10 most memory-hungry pods:

```promql
topk(10, sum by (namespace, pod) (container_memory_working_set_bytes{container!=""}))
```

The 5 pods using the most CPU:

```promql
topk(5, sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{container!=""}[5m])))
```

Pods per namespace that are currently running (`kube_pod_status_phase` is 1 for the pod's current phase, 0 for the others):

```promql
sum by (namespace) (kube_pod_status_phase{phase="Running"})
```

Number of pods in each phase across the cluster:

```promql
sum by (phase) (kube_pod_status_phase)
```

Average memory per container for each service in the shop, and the spread between them:

```promql
avg by (container) (container_memory_working_set_bytes{namespace="astronomy-shop", container!=""})
```

## count and count_values

How many pods does each node run?

```promql
count by (node) (kube_pod_info)
```

How many containers have each restart count? `count_values` turns the sample values into a label:

```promql
count_values("restarts", kube_pod_container_status_restarts_total{namespace="astronomy-shop"})
```

## Arithmetic with aggregates

Cluster-wide CPU utilisation as a fraction of all cores:

```promql
sum(rate(container_cpu_usage_seconds_total{container!=""}[5m])) / sum(machine_cpu_cores)
```

Because both sides are single-value results with no labels, they match without extra syntax. When both sides keep
labels, you need vector matching, covered in the advanced tutorial.

## topk gotcha

`topk` inside a dashboard graph picks the top n at each step, so series can appear and disappear as ranks change.
For a stable top n over a range, rank on an instant query or on a longer `avg_over_time`.

Next: [Histograms and latency percentiles](05-promql-histograms-and-latency.md).

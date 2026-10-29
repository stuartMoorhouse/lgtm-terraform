# 7. Kubernetes resource metrics

Two sources describe the cluster:

| Source | Metric prefix | Tells you |
|---|---|---|
| cAdvisor (scraped by Alloy) | `container_*`, `machine_*` | Actual CPU, memory and network use |
| kube-state-metrics (`lgtm` namespace) | `kube_*` | Desired and observed state of Kubernetes objects |

## Nodes

Number of nodes and total cores:

```promql
count(kube_node_info)
```

```promql
sum(machine_cpu_cores)
```

Which nodes are Ready?

```promql
kube_node_status_condition{condition="Ready", status="true"}
```

CPU utilisation per node, as a fraction of its cores:

```promql
sum by (node) (rate(container_cpu_usage_seconds_total{container!=""}[5m])) / on (node) group_left () sum by (node) (label_replace(machine_cpu_cores, "node", "$1", "instance", "(.*)"))
```

Memory utilisation per node:

```promql
sum by (node) (container_memory_working_set_bytes{container!=""}) / on (node) group_left () sum by (node) (label_replace(machine_memory_bytes, "node", "$1", "instance", "(.*)"))
```

`machine_*` series are labelled by `instance` (the node name) while `container_*` series use `node`. `label_replace`
copies one label to another so the two sides can be joined with `on (node)`.

## Pods

Pods by phase in the shop namespace:

```promql
sum by (phase) (kube_pod_status_phase{namespace="astronomy-shop"})
```

Pods that are not Ready (should be empty when healthy):

```promql allow-empty
kube_pod_status_ready{condition="false", namespace=~"astronomy-shop|lgtm"} == 1
```

Containers waiting, and why (for example `CrashLoopBackOff`, `ImagePullBackOff`):

```promql allow-empty
kube_pod_container_status_waiting_reason{namespace=~"astronomy-shop|lgtm"} == 1
```

Restarts in the last hour, only for pods that restarted:

```promql allow-empty
sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[1h])) > 0
```

Deployments whose available replicas lag the desired count:

```promql allow-empty
kube_deployment_spec_replicas - kube_deployment_status_replicas_available > 0
```

## CPU and memory per workload

CPU cores used per pod in the shop:

```promql
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="astronomy-shop", container!=""}[5m]))
```

Memory working set per container in MiB, largest first:

```promql
sort_desc(sum by (container) (container_memory_working_set_bytes{namespace="astronomy-shop", container!=""})) / 1024 / 1024
```

Network receive and transmit throughput per pod (bytes per second):

```promql
topk(10, sum by (pod) (rate(container_network_receive_bytes_total{namespace="astronomy-shop"}[5m])))
```

```promql
topk(10, sum by (pod) (rate(container_network_transmit_bytes_total{namespace="astronomy-shop"}[5m])))
```

## Usage versus limits

Memory use as a fraction of the container's limit. Only containers that define a memory limit appear, since
the join needs a match on both sides:

```promql
sum by (namespace, pod, container) (container_memory_working_set_bytes{container!=""})
/ on (namespace, pod, container)
sum by (namespace, pod, container) (kube_pod_container_resource_limits{resource="memory"})
```

Containers throttled by their CPU limit, which shows as latency before it shows as CPU saturation:

```promql
topk(10, sum by (namespace, pod) (rate(container_cpu_cfs_throttled_periods_total{container!=""}[5m])) / sum by (namespace, pod) (rate(container_cpu_cfs_periods_total{container!=""}[5m])))
```

CPU requests versus actual use per namespace (cores). A large gap means over-provisioned requests and wasted node capacity:

```promql
sum by (namespace) (kube_pod_container_resource_requests{resource="cpu"})
```

```promql
sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))
```

## Stack health

The LGTM components are pods too. Mimir, Loki and Tempo pods currently running:

```promql
sum by (pod) (kube_pod_status_phase{namespace="lgtm", phase="Running"})
```

Next: [Advanced PromQL](08-promql-advanced.md).

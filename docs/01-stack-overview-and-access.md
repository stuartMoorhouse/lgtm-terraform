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

## Key terms

| Term | Meaning |
|---|---|
| Datasource | A saved connection from Grafana to one backend. This stack has three: `Mimir`, `Loki` and `Tempo`. |
| Metric | A numeric time series, such as requests per second or memory used. |
| Trace | The path of one request through several services, made of spans. |
| Span | One step inside a trace, such as "frontend called the cart service". It has a start time and a duration. |
| Label | A `name="value"` tag on data, such as `service_name="frontend"`. Queries use labels to select data. |

## Running queries in Grafana Explore

Explore is the part of Grafana for typing a query and seeing the result straight away. It is the easiest way to follow
these tutorials.

### Sign in

1. In a terminal, in the repo root, run `scripts/get-urls.sh`. It prints the Grafana URL (it ends in `/grafana`).
2. Get the password: `terraform -chdir=terraform output -raw grafana_admin_password`
3. Open the URL in your browser. Your browser will warn that the connection is not private, because the stack uses a
   self-signed certificate. This is expected. Choose the option to proceed anyway (usually under "Advanced").
4. If the page never loads, your public IP has probably changed. Only the IP set as `allowed_cidr` in
   `terraform/terraform.tfvars` can reach the stack.
5. Sign in with username `admin` and the password from step 2.

### Open Explore and pick a datasource

1. In the left-hand menu, click **Explore**. If you cannot see the menu, click the three-line icon at the top left to open it.
2. At the top left of the Explore page there is a dropdown showing a datasource name. Click it and choose the one that
   matches the language you want to use:

| To query | Language | Choose this datasource |
|---|---|---|
| Metrics | PromQL | `Mimir` |
| Logs | LogQL | `Loki` |
| Traces | TraceQL | `Tempo` |

3. At the top right, click the time range button (it shows something like "Last 1 hour") and pick **Last 1 hour**.
   If a query returns nothing, widen the range first.
4. Type or paste your query into the box, then click the blue **Run query** button at the top right (or press
   Shift+Enter).

## Your first query in each language

Do these three in order. Each one uses a different datasource and a different language, so you can see the pattern: pick
the datasource first, then paste a query written in that datasource's language.

### 1. Metrics: PromQL on the Mimir datasource

What it does: `up` is a metric that is `1` for every target the collector (Grafana Alloy) is successfully scraping and `0`
for any that is failing. `count(up)` counts them. It is a quick check that metrics are arriving.

1. Open **Explore** and choose the **Mimir** datasource.
2. Above the query box, switch from **Builder** to **Code**. This is a small toggle at the top right of the query area.
3. Paste the query below into the box. The language is PromQL.

```promql
count(up)
```

4. Set the time range to **Last 1 hour** and click **Run query**.

What you should see: a graph with a single line, and a number (greater than zero) in the legend. If you see "No data",
the demo is probably still starting up. Wait a few minutes and run it again.

### 2. Logs: LogQL on the Loki datasource

What it does: the part in braces picks which logs to show. `service_name="frontend"` means "only logs written by the
frontend service". Anything inside `{ }` in LogQL is a label filter.

1. Open **Explore** and choose the **Loki** datasource.
2. Switch from **Builder** to **Code** (the same toggle as before).
3. Paste the query below into the box. The language is LogQL.

```logql
{service_name="frontend"}
```

4. Set the time range to **Last 1 hour** and click **Run query**.

What you should see: a bar chart of log volume at the top and, below it, a list of log lines with the newest first.
Click any line to expand it and see its labels.

### 3. Traces: TraceQL on the Tempo datasource

What it does: finds traces that contain at least one span from the frontend service. `resource.service.name` is the
trace-side name for the same service label you used in the logs query.

1. Open **Explore** and choose the **Tempo** datasource.
2. Tempo shows a row of query types above the query box. Click **TraceQL**. (Not **Search**, which is a form, and not
   **Service Graph**, which is a diagram.)
3. Paste the query below into the box. The language is TraceQL.

```traceql
{ resource.service.name = "frontend" }
```

4. Set the time range to **Last 1 hour** and click **Run query**.

What you should see: a table of traces, one per row, with columns such as trace ID, service, name and duration. Click a
trace ID to open it as a timeline of its spans.

## Naming conventions in this stack

OTLP attribute names contain dots, but the storage layers rewrite them differently:

| Signal | Example attribute | How it appears |
|---|---|---|
| Metrics (Mimir) | `service.name` | `service_name` |
| Logs (Loki) | `k8s.namespace.name` | `k8s_namespace_name` |
| Traces (Tempo) | `service.name` | `resource.service.name` (dots kept) |

Every metric also carries `cluster="lgtm-demo"`, added by Alloy's remote write.

Next: [PromQL selectors and labels](02-promql-selectors-and-labels.md).

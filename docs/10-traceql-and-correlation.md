# 10. TraceQL for Tempo and correlating signals

TraceQL selects spans by their attributes. A query is a set of span filters in braces, optionally combined with
structural operators and aggregates.

## Attribute scopes

| Prefix | Scope | Example |
|---|---|---|
| `resource.` | The service or process that produced the span | `resource.service.name` |
| `span.` | The individual span | `span.http.response.status_code` |
| none | Intrinsics | `duration`, `status`, `name`, `kind` |

Unlike metric labels, trace attributes keep their dots.

## Basic span filters

All traces that touched the frontend:

```traceql
{ resource.service.name = "frontend" }
```

Spans with an error status:

```traceql
{ status = error }
```

Slow spans in a particular service:

```traceql
{ resource.service.name = "frontend" && duration > 50ms }
```

Match a span name with a regex:

```traceql
{ name =~ "GET.*" && resource.service.name = "frontend" }
```

Any gRPC span:

```traceql
{ span.rpc.system = "grpc" }
```

Spans that are server-side entry points:

```traceql
{ kind = server && resource.service.name = "checkout" }
```

## HTTP and RPC failures

5xx responses seen by the frontend:

```traceql allow-empty
{ span.http.response.status_code >= 500 }
```

gRPC calls that did not return OK:

```traceql allow-empty
{ span.rpc.grpc.status_code != 0 }
```

Failed spans in the payment service:

```traceql allow-empty
{ resource.service.name = "payment" && status = error }
```

## Business attributes

The demo instruments checkout and payments with custom attributes. Find the orders that went through the payment service:

```traceql
{ resource.service.name = "payment" && span.demo.payment.card_type != nil }
```

Spans for one product:

```traceql allow-empty
{ span.demo.product.id = "OLJCESPC7Z" }
```

## Structural queries

Structural operators relate spans in the same trace.

| Operator | Meaning |
|---|---|
| `>>` | descendant (any depth) |
| `>` | direct child |
| `~` | sibling |

Traces where the frontend, directly or indirectly, led to a call in the cart service:

```traceql
{ resource.service.name = "frontend" } >> { resource.service.name = "cart" }
```

Traces where the frontend called product-catalog as a direct child:

```traceql
{ resource.service.name = "frontend" } > { resource.service.name = "product-catalog" }
```

## Aggregates

Pipe a span set into an aggregate and filter on the result. Traces with more than 20 spans in the
checkout service:

```traceql allow-empty
{ resource.service.name = "checkout" } | count() > 20
```

Traces with an average span duration over 20 ms in the frontend:

```traceql
{ resource.service.name = "frontend" } | avg(duration) > 20ms
```

Traces lasting longer than 500 ms overall:

```traceql allow-empty
{ } | max(duration) > 500ms
```

## TraceQL metrics

Recent Tempo versions can compute metrics straight from stored spans. Spans per second for the frontend:

```traceql
{ resource.service.name = "frontend" } | rate()
```

Request rate split by service:

```traceql
{ kind = server } | rate() by (resource.service.name)
```

Error spans per second by service:

```traceql allow-empty
{ status = error } | rate() by (resource.service.name)
```

p95 span duration for the frontend:

```traceql
{ resource.service.name = "frontend" } | quantile_over_time(duration, .95)
```

## Correlating metrics, logs and traces

The point of a single stack is moving between signals without losing context. A typical investigation:

1. **Metrics tell you something is wrong.** The error ratio or p95 query from [tutorial 6](06-promql-red-method.md)
   rises for one service.
2. **Traces show where.** Run `{ resource.service.name = "checkout" && status = error }` in Tempo. Open a trace and
   follow the red spans to the failing downstream call.
3. **Logs explain why.** From the span, use Grafana's "Logs for this span" link (trace-to-logs, configured on the Tempo
   datasource) or query Loki directly:

   ```logql
   {service_name="checkout"} | detected_level=~"warn.*|error|info"
   ```

4. **Back to metrics.** The trace-to-metrics link jumps to the span metrics for that service and operation, confirming
   whether this one trace is typical or an outlier.

Exemplars and derived fields tie the same loop together. The Loki datasource turns `trace_id` into a link to Tempo.

## Verifying the whole pipeline

`scripts/test-doc-queries.py` runs every query in this `docs/` folder against live Mimir, Loki and Tempo. Use it
after any change to Alloy or the datasources, since a rename in the pipeline (for example span-metric label names)
breaks queries silently.

```bash
python3 -I scripts/test-doc-queries.py
```

# Performance and OpenTelemetry

The Dashboard Overview includes **API performance** for this browser: in-flight
requests, peak concurrency, completed requests, shared duplicate reads, latency
p95 and failures over the last 240 samples. The route table separates browser
duration (network plus JSON decoding) from the latest Core processing time.
This information is available without a collector and resets on page reload.

Core returns `Server-Timing: core;dur=…` and `X-Sloppy-Route` on routed responses,
including authorization failures and unmatched routes. Timing covers authorization,
handler execution and response encoding, ending when an SSE stream is established,
not when its stream finishes. It excludes time queued before entering CoreRouter
and time sending the response over the transport.

## Export metrics and traces

Sloppy uses [Swift OTel](https://github.com/swift-otel/swift-otel) as the OTLP backend
for Swift Metrics and Swift Distributed Tracing. Export is opt-in:

```sh
docker compose -f utils/observability/compose.yml up -d
SLOPPY_OTEL_ENABLED=1 \
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
sloppy run --no-gui
```

Restart the Core process with these environment variables. SDK exporters run in
the background, batch exports, and shut down gracefully when the server closes.
An unavailable collector does not hold up HTTP requests. Existing file/console
logging remains enabled; this integration exports metrics and traces only.
Standard `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_*`, `OTEL_METRIC_EXPORT_INTERVAL`
(milliseconds), and `OTEL_TRACES_SAMPLER` options are supported by the SDK. The
default transport here is HTTP/protobuf, with metrics exported every 15 seconds.
This build includes the HTTP exporter; do not configure the gRPC transport.

Open [Prometheus](http://localhost:9090) for queries and
[Jaeger](http://localhost:16686) for request and tool spans. The supplied stack
binds published ports to localhost and is for local development. Docker must be
installed separately. Docker configuration should be validated with
`docker compose -f utils/observability/compose.yml config` on a Docker host.

Metrics:

| Instrument | Meaning |
| --- | --- |
| `http.server.request.duration` | Core request duration histogram in seconds |
| `sloppy.http.requests` | Request counter by method, route template, status |
| `sloppy.model.time_to_first_token` | Model TTFT histogram |
| `sloppy.model.generation.duration` | Model generation duration histogram |
| `sloppy.model.delta.interval` | Average inter-delta interval per run |
| `sloppy.tool.calls` / `sloppy.tool.errors` | Tool calls and failures per completed run |

Model measurements include native and ACP runs via RuntimePerformanceTelemetry.
Each recorded run contributes once; an unfinished run has no final sample.
Existing `tool.invoke`, `tool.invoke.channel`, and `runtime.event.persist` spans
now export through the same tracing backend. Incoming W3C trace context is
extracted by the server; the Dashboard does not currently create browser spans.

Prometheus converts dots to underscores and adds unit/type suffixes. For example:

```promql
histogram_quantile(0.95, sum by (le, http_route) (rate(http_server_request_duration_seconds_bucket[5m])))
sum by (http_route) (rate(sloppy_http_requests_total[5m]))
sum(rate(sloppy_http_requests_total{http_response_status_code=~"5.."}[5m]))
```

Only method, registered route template and status become HTTP labels. Unmatched
requests use `unmatched`; URLs, query strings, credentials, prompts, channel IDs
and session IDs are excluded from the added metrics and HTTP spans. Existing tool
spans may contain tool identifiers and error details; review their attributes
before exporting to a remote collector.

## Request behavior

Concurrent identical JSON GETs share a single in-flight request. The key includes
destination, headers, token and auth revision. There is no response cache;
mutations and caller-cancellable reads are never shared. JSON GETs time out after
30 seconds so an unreachable read cannot leave an indefinite loading state.
Cancelled reads do not trigger the connection-lost notification. Mutations have
no new timeout because agent generation and tool operations can take longer.

Overview reads fleet sessions with one `/v1/agent-sessions` call instead of one
per agent. Activity loads independently from the main cards. Memory configuration
loads independently from its count and scope catalog; scope catalogs use project
summaries. Agent/project memory graphs load only when Graph is selected.
Git worktree discovery runs outside CoreService isolation so slow repository
processes allow other Core requests to proceed.

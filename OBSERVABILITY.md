# BrowseTerm Observability Plan

> Status: **PLAN ONLY** — not started. To be built *after* the current feature work
> (save/snapshot flow) is finished and stable.

## Why this exists

We just spent a long debugging session reconstructing a single failed "Save" by hand —
reading a `save_error` column out of Postgres and squinting at block-buffered `kubectl logs`.
That does not scale. We cannot attach a debugger to every microservice, and we cannot ask a
human to hand-assemble "what happened" every time something breaks.

**Goal: Grafana becomes the debugger.** When something fails, we open one place and see the
full story — *the user clicked Save → the server did X → container-maker did Y → the Job did Z →
it failed HERE, with this error* — without SSHing into pods or reading source.

## Where we are today (the gap)

- **No logging infrastructure.** Services `print()` to stdout; logs are per-pod, ephemeral,
  block-buffered (they don't even flush promptly), and lost on pod restart. There is no
  aggregation, no search, no history.
- **No metrics.** We have no idea about request rates, error rates, latencies, or resource
  pressure until something is already on fire (e.g. the container-maker OOM — we only found it
  via an exit-code 137 after the fact).
- **No tracing.** No way to follow one request across service boundaries.
- **Band-aid in place:** the `containers.save_error` / `save_status` columns are a manual,
  domain-specific version of "record what happened." Useful, but it only covers the save flow
  and only lives in one table. It is not a general solution.

## The stack (Grafana "LGTM" + OpenTelemetry)

All self-hostable in the `docker-desktop` cluster now, and portable to prod later.

| Pillar   | Tool                         | Purpose                                                 |
|----------|------------------------------|---------------------------------------------------------|
| Logs     | **Loki** (+ **Alloy**/Promtail to ship) | Aggregate + search all service logs centrally.          |
| Metrics  | **Prometheus** (+ **Grafana**)          | Resource + request health, trends, alerting.            |
| Traces   | **Tempo** + **OpenTelemetry** SDKs      | The per-request lifecycle timeline across services.     |
| UI       | **Grafana**                             | Single pane: query logs, metrics, traces; dashboards.   |

OpenTelemetry (OTel) is the vendor-neutral instrumentation standard — one SDK per service emits
logs, metrics, and traces to an **OTel Collector**, which fans out to Loki / Prometheus / Tempo.
This keeps the app code decoupled from the backends.

---

## Pillar 1 — Logging (do this FIRST; we have none)

Everything below depends on logs existing and being structured.

1. **Structured logging in every service.** Replace ad-hoc `print()` with a real logger emitting
   **JSON** lines: `timestamp, level, service, message, request_id, user_id, container_id, ...`.
   - Python services (browseterm-server, container-maker, snapshot-job): `logging` +
     a JSON formatter (e.g. `python-json-logger`), `PYTHONUNBUFFERED=1` so lines flush immediately.
   - socket-ssh (Node): `pino` (JSON by default).
2. **Ship to Loki.** Deploy **Alloy** (or Promtail) as a DaemonSet to tail pod stdout and push to
   Loki. No app change needed beyond writing JSON to stdout.
3. **Free immediate win (can land before any infra):** set `PYTHONUNBUFFERED=1` on the Python
   deployments so `print`/log output actually appears in `kubectl logs` in real time. This alone
   would have saved hours in the save debugging.

### "Trace everything through logs alone" — the correlation id

This is the lifecycle-reconstruction you asked for, using **logs only** (no Tempo required yet):

- Generate a **`request_id`** (a correlation id, a UUID) at the entry point — the moment the user
  clicks Save, browseterm-server mints one.
- **Thread it through the entire flow** and stamp it on every log line:
  - HTTP: accept/emit an `X-Request-Id` header.
  - gRPC (server → container-maker): pass it in gRPC **metadata**.
  - Detached Job (container-maker → snapshot-job): inject it as an **env var** on the Job.
  - Persist it: write `request_id` onto the `containers` row alongside `save_status`.
- Then in Grafana/Loki you filter `{ } |= request_id="…"` and get **every log line from every
  service for that one request, in time order**. That *is* the lifecycle:
  ```
  request_id=abc123  server         POST /save-container -> PENDING
  request_id=abc123  server         gRPC saveContainer -> container-maker
  request_id=abc123  container-maker resolved pod namah-ssh-...-pod-1784454306
  request_id=abc123  container-maker tar streamed 214MB -> minio
  request_id=abc123  container-maker creating snapshot job ... ERROR 403 Forbidden
  ```
- Reconstructed from logs alone. This is the 80/20 and should be built with Pillar 1.

---

## Pillar 2 — Metrics ("how are our resources doing")

Prometheus scrapes numeric time-series; Grafana dashboards + alerts sit on top.

- **Infra/resource metrics** (answers your "how are resources doing"): CPU / memory / disk per
  pod and node via `kube-state-metrics` + `node-exporter` (or the Prometheus community chart).
  This is what would have flagged the container-maker OOM *before* it killed the pod.
- **App metrics** (each service exposes `/metrics`):
  - browseterm-server: HTTP request count / latency / error rate by route; active SSE clients.
  - container-maker: gRPC call count/latency/errors; snapshot Job success/failure counter;
    snapshot duration; snapshot bytes streamed.
  - snapshot-job: build duration, push duration, outcome.
- **Alerts** (later): save failure rate > X, any pod OOMKilled, gRPC error rate spike.

Metrics answer *aggregate* questions ("what's our save success rate?", "is memory trending up?").
They do **not** explain a single failed request — that's logs + traces.

---

## Pillar 3 — Traces (what they actually are)

You said you're not sure what traces do — here's the mental model, and why they're the real
"lifecycle" tool.

**A trace is the complete, timed story of ONE request as it flows through every service.**
It's made of **spans**:

- A **span** = one unit of work with a start and end time: an HTTP handler, a gRPC call, a DB
  query, the tar step, the Job run. Each span records duration, status (ok/error), and attributes
  (container_id, pod name, bytes, etc.).
- All spans of one request share a **`trace_id`**, and each span has a **parent** — so you get a
  nested **waterfall/timeline**, not just a flat list.

For our Save flow, one trace would render like this in Grafana/Tempo:

```
Trace abc123  (total 12.4s)  ── STATUS: ERROR
└─ POST /save-container                        (server)          8ms
   ├─ set save_status=PENDING (DB write)        (server)          3ms
   └─ gRPC saveContainer                         (server→cm)      12.3s
      └─ save()                                   (container-maker)
         ├─ find_container_pod                    (container-maker) 40ms
         ├─ build_tar (tar + stream + minio)      (container-maker) 11.9s
         └─ create_snapshot_job                   (container-maker) 60ms  ◄── ERROR 403 Forbidden
```

Instantly you see: it reached Job creation, the failing span is highlighted red with the error,
and you can see *how long each step took* (e.g. that the tar/stream dominated the time). No log
spelunking.

**How the three pillars differ:**
- **Logs** = discrete events ("X happened", free-text/JSON). Great for detail and messages.
- **Metrics** = aggregates over time ("p95 latency", "error rate"). Great for health/trends/alerts.
- **Traces** = the causal, timed graph of *one* request across services. Great for "where did
  *this* specific request slow down or fail, and in what order did things happen."

Modern setups **link them**: a trace span carries the `request_id`/`trace_id`, so from a red span
in Tempo you jump straight to the correlated Loki logs, and from a metric spike to exemplar traces.

### The hard part: context propagation

Auto-instrumentation (OTel) handles most of it, but our topology has two tricky hops:

1. **gRPC boundary** (server → container-maker): needs OTel gRPC client/server interceptors so the
   `traceparent` rides along in gRPC metadata. (Off-the-shelf, but must be wired.)
2. **The detached snapshot Job** (container-maker → snapshot-job): the Job is *not* in the request
   call path — it runs asynchronously in Kubernetes. We propagate the `trace_id` (same one as
   `request_id`) into the Job via an **env var**, and the Job starts its spans as children of that
   trace. This is the interesting engineering and the piece that makes the *whole* lifecycle —
   including the async Job — show up as one trace.

> Decision: make `request_id == trace_id` so the logs-based correlation (Pillar 1) and true
> tracing (Pillar 3) converge on a single id the whole way through.

---

## Pillar 4 — Expose observability to AI via MCP (the payoff)

Vision: an AI agent (Claude) debugs autonomously the way we did manually today — but in seconds.

- Stand up an **MCP server** that exposes the observability backends as tools:
  - `query_logs(request_id | filter, time_range)` → LogQL against Loki
  - `query_metrics(promql, time_range)` → PromQL against Prometheus
  - `get_trace(trace_id)` / `find_traces(filter)` → TraceQL against Tempo
  - `list_recent_errors(service, window)` → convenience over logs/traces
- **Option:** Grafana ships an official **`grafana-mcp`** server that already exposes datasource
  queries, dashboards, and incidents — likely faster than building our own. Evaluate it first.
- Payoff loop: *"save failed"* → AI grabs the trace by `request_id`, reads the failing span + its
  correlated logs, identifies the cause (e.g. the 403 RBAC), and proposes/enacts the fix. Exactly
  the loop we ran by hand — automated.
- Note: MCP servers that reach the cluster/observability backends handle sensitive data; scope
  credentials to read-only query access and keep it internal.

---

## Rollout plan (phased, after current feature work)

- **Phase 0 — free win:** `PYTHONUNBUFFERED=1` on Python services so logs flush live. (No infra.)
- **Phase 1 — Logging + correlation id:** structured JSON logs in all 4 services; `request_id`
  minted at entry and propagated through HTTP → gRPC → Job → DB; deploy Loki + Alloy + Grafana;
  verify we can filter one Save by `request_id` across services in Grafana.
- **Phase 2 — Metrics:** Prometheus + kube-state-metrics + node-exporter; `/metrics` in each
  service; Grafana dashboards for resource health + save success/latency; first alerts (OOM, save
  failure rate).
- **Phase 3 — Traces:** OTel SDK + Collector; Tempo; auto-instrument HTTP + gRPC; propagate trace
  context across the gRPC hop and into the snapshot Job; link traces↔logs in Grafana.
- **Phase 4 — MCP for AI:** evaluate `grafana-mcp` (or build a thin MCP) exposing Loki/Prom/Tempo
  queries; wire it so an agent can pull a request's full lifecycle and debug it.

## Per-service work

| Service            | Language | Logging          | Metrics            | Tracing (OTel)                    |
|--------------------|----------|------------------|--------------------|-----------------------------------|
| browseterm-server  | Python   | JSON logger      | FastAPI `/metrics` | HTTP auto + mint request_id       |
| container-maker    | Python   | JSON logger      | gRPC `/metrics`    | gRPC interceptor + Job propagation|
| snapshot-job       | Python   | JSON logger      | push/pushgateway   | continue trace from injected env  |
| socket-ssh         | Node     | pino             | prom-client        | OTel JS auto-instrumentation      |

## Open questions / decisions to make

- **Prometheus vs Grafana Mimir** for metrics storage (Prometheus is simpler to start).
- **Tempo vs Jaeger** for traces (Tempo integrates tighter with the Grafana stack).
- Retention + storage sizing for Loki/Tempo on the local cluster (start small, object storage in
  prod — we already run MinIO, which Loki/Tempo can use as their object store).
- Managed vs self-hosted Grafana in production.
- Build our own MCP vs adopt `grafana-mcp`.

## Guiding principles

- **One id end-to-end** (`request_id == trace_id`) — the thread that ties logs, traces, and the
  `save_status` row together.
- **Structured over free-text** — JSON logs so machines (and the MCP/AI) can query them.
- **App code stays decoupled** — emit via OTel/loggers to a Collector; backends are swappable.
- **Read-only, internal** — observability + its MCP surface never expose write access or leave the
  trusted network.
</content>
</invoke>

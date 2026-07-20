# BrowseTerm — TODO Plan (everything left to a working, shippable product)

**Pitch:** a way to create **remote workspaces** for people (Codespaces/Gitpod for terminals).

Legend: `[ ]` todo · `[~]` in progress / partially done · `[x]` done this cycle · ⚠️ decision needed

---

## 0. Finish & verify the SAVE flow (in flight — closest to done)

The snapshot/save pipeline is code-complete and deployed; it has NOT yet been confirmed green end-to-end.

- [~] Save flow: server `PENDING` → gRPC → container-maker resolves pod → tar → **stream** to MinIO → snapshot Job docker build+push → DB `saved_image`+`SUCCEEDED` → NOTIFY → SSE → spinner stops.
- [x] Fixed: container-maker OOM (stream instead of buffering whole fs), stale-UID pod resolution (resolve by pod name + self-heal), RBAC 403 (`pods/log`), save-button spinner + notifications (base.js wiring).
- [ ] **Confirm end-to-end**: click Save → watch `save_status` go `Pending→Running→Succeeded`, Job runs to completion, image in registry, success toast. The snapshot Job's docker build+push has never executed successfully yet — likely next place something surfaces.
- [ ] Add `ttlSecondsAfterFinished` verification + confirm Job cleanup after 5 min.

---

## 1. Workspace lifecycle — wire SAVE into hibernate/resume/recovery (the big "figure out")

Save is **not** for create. It exists to persist a workspace so it can be restored when a user is
inactive past a threshold, or when an active user's terminal crashes. See `WORKSPACE_LIFECYCLE.md`
(to be written).

- [x] **Persistence model — DECIDED: image-snapshot** (what save already produces). Hibernate = delete the pod; resume = recreate from `saved_image`. No PVC/hybrid.
- [x] **Reaper — DECIDED: Kubernetes CronJob** (a new small job component, same pattern as cert-manager — NOT a third-party tool; it's our code that sweeps for idle terminals on a schedule).
- [x] **Inactivity threshold — DECIDED: 1 week** (configurable).
- [ ] **Activity tracking** — socket-ssh stamps `last_active_at` (Redis key w/ TTL or DB column) on WS connect / heartbeat / disconnect.
- [ ] **Reaper CronJob** — queries DB for containers idle > 1 week and still `running` → save (reuse `saveContainer`) → delete pod → set status `HIBERNATED`. New job image + CronJob manifest.
- [ ] **Resume flow** — on login/open of a HIBERNATED container, `create` branches: if the row has `saved_image`, spin the pod **from that image**; else base image. (Reuses create path.) This is ADDITIVE to crash recovery below, not a replacement.
- [x] **Keep + fixed `_update_pod_image` (crash recovery, NOT dropped)** — decided to keep it: it points the live pod at the saved image so the kubelet restarts a *crashed* container from the snapshot immediately (in-place recovery for an active user, no resume step). Fixed the missing `{repo_name}/` prefix that was causing ImagePullBackOff. Note: patching the image triggers an immediate restart, and it restores to the last save point.
- [ ] **Crash detection + recovery** — `status_sidecar` (already in every pod) detects an active user's pod died → recover (recreate from `saved_image`).
- [ ] **New container statuses** — e.g. `HIBERNATED`, `RESUMING` (extend the enum + migration + re-apply trigger).
- [ ] Write `WORKSPACE_LIFECYCLE.md` (design doc).

---

## 2. Observability (see `OBSERVABILITY.md` for the full plan)

Grafana becomes the debugger; one `request_id`/`trace_id` end-to-end.

- [ ] **Phase 0 (free win):** `PYTHONUNBUFFERED=1` on Python services so logs flush live.
- [ ] **Logging:** structured JSON logs in all 4 services + `request_id` propagated HTTP→gRPC→Job→DB; deploy **Loki + Alloy + Grafana**; reconstruct a request from logs.
- [ ] **Metrics:** **Prometheus** + kube-state-metrics + node-exporter; `/metrics` per service; dashboards (save success/latency, resource health); alerts (OOM, save-fail rate).
- [ ] **Traces:** **OTel + Tempo**; auto-instrument HTTP+gRPC; propagate trace context across the gRPC hop and into the detached snapshot Job; link traces↔logs.
- [ ] **MCP for AI:** evaluate `grafana-mcp` (or thin custom) exposing Loki/Prom/Tempo queries so an agent can pull a request's lifecycle and debug it.

---

## 3. Payments — full system

Note: browseterm-db already has `subscription_ops`, `subscription_type_ops`, `orders_ops` and a
per-tier container limit (`is_user_within_container_limit`) — foundation exists.

- [ ] ⚠️ **Pick provider** (Stripe recommended).
- [ ] Define **plans/tiers** (free vs paid: container count, resources, hibernation threshold, ads on/off).
- [ ] **Checkout flow** (hosted checkout / billing portal).
- [ ] **Webhooks** — subscription created/updated/canceled/payment-failed → update `subscriptions`/`orders`.
- [ ] **Entitlement enforcement** — gate container creation / resources / resume on active subscription.
- [ ] Billing history, invoices, upgrade/downgrade, dunning.
- [ ] Secure webhook signature verification; idempotency.

---

## 4. Ads

The terminal page already has an `ads-sidebar` with placeholder `ad-banner`s.

- [ ] ⚠️ **Pick ad source** (network vs self-served house ads).
- [ ] Ad serving + rotation into the existing sidebar slots.
- [ ] **Free-tier only** — suppress ads for paid plans (ties to #3 entitlements).
- [ ] Basic targeting / fill logic + analytics (impressions/clicks).

---

## 5. Monorepo single-command deploy + teardown (task #7)

- [ ] **Aggregated `env.mk`** with per-service prefixes (`SERVER_*`, `CM_*`, `DB_*`, …).
- [ ] One `make setup` — cluster + ingress-nginx + MetalLB + cert-manager + postgres + redis + migrate/seed + all services, in order, non-interactive.
- [ ] One `make teardown`.
- [ ] Fix remaining broken make targets (`build_all`, `prod_*`, `build_letsencrypt_issuer`, etc.).

---

## 6. Known bugs / tech debt

- [ ] `browseterm-db/init.py` drops the NOTIFY triggers on autogenerate — re-created by hand; needs a proper fix (model-level DDL event or preserved migration).
- [ ] `status_sidecar` has **no tests** — add dummy-call coverage (mock k8s watch + `update_container_status`).
- [ ] Integration suites unverified: container-maker `tests/k8s/integration/*` (incl. stale `test_job_manager`), browseterm-server backend `tests/integration/*` (`test_save_status_listener`, `test_save_container_service`). Run steps documented; wire into CI.
- [ ] Per-user repo credentials: `REPO_NAME`/`REPO_PASSWORD` are **per-user** — each user pushes snapshots to their own registry, so there is NO single global repo password to secretize. The values in `env.mk` are a dev stand-in. Future: source per-user creds from the user's settings and thread them into the save gRPC → container-maker → snapshot Job.
- [ ] Drop pod-level `privileged=True` where not required.
- [ ] Reconcile MetalLB (IPs not host-reachable locally; we use port-forward) into a coherent local story.
- [ ] Optional: replace custom cert-manager with official jetstack cert-manager (CA issuer for mTLS + ACME for public TLS) + Reloader.

---

## 7. Production-grade / security (before public launch)

- [ ] **Multi-tenant isolation** (CRITICAL — we run user workloads): NetworkPolicies, resource quotas/limits per namespace, seccomp/gVisor/Kata for stronger sandboxing, egress controls.
- [ ] **Public TLS/WSS** via Let's Encrypt on a real domain (local uses plain ws over port-forward).
- [ ] Rate limiting + abuse prevention (crypto-mining, spam).
- [ ] **HA**: deploy `postgres_ha` + `redis_ha` (repos exist) in prod; backups for Postgres + MinIO.
- [ ] Autoscaling / capacity planning for per-user pods.
- [ ] AuthN/Z hardening, session security review.

---

## 8. Testing & CI

- [ ] Fix/verify the integration suites above; document run steps in each repo README (snapshot_job done).
- [ ] Add `status_sidecar` tests.
- [ ] **CI pipeline** — run unit + (containerized) integration tests on push; build/push images on merge.
- [ ] Keep to the project norm: **integration tests over unit tests**, run against a live Postgres on a separate DB.

---

## 9. Docs & go-to-market assets

- [ ] `WORKSPACE_LIFECYCLE.md` (#1) and keep `OBSERVABILITY.md` current.
- [ ] **Architecture writeup + diagram** — doubles as onboarding, recruitment portfolio, and Global-Talent-visa evidence.
- [ ] Public README / landing ("remote workspaces") + demo video (login → spin terminal → save/resume).
- [ ] Per-repo READMEs kept accurate (largely done this cycle).

---

## Suggested order

1. **Confirm save end-to-end** (#0) — almost done.
2. **Workspace lifecycle** (#1) — makes save actually useful; core product behavior.
3. **Observability** (#2) — so everything after is debuggable (start with Phase 0 + logging).
4. **Payments** (#3) — needed to monetize; foundation already in the DB.
5. **Single-command deploy** (#5) — quality-of-life, unblocks clean prod/staging.
6. **Ads** (#4) — after payments (entitlement gating).
7. **Production hardening** (#7) — before any public launch, especially isolation.

---

## Effort estimates (dev-days)

Rough estimates for **one experienced dev already familiar with this codebase**. Ranges are
optimistic–realistic; "plan" is what to schedule against. A dev-day = one focused working day.

| # | Area | Range | Plan |
|---|---|---:|---:|
| 0 | Finish & verify SAVE end-to-end | 1–2 | **1.5** |
| 1 | Workspace lifecycle (activity → resume → reaper → crash recovery) | 8–13 | **10** |
| 2 | Observability (logging → Loki → Prometheus → Tempo → MCP) | 9–15 | **12** |
| 3 | Payments (Stripe: plans, checkout, webhooks, entitlements, billing UI) | 8–14 | **11** |
| 4 | Ads (integration, serving, free-tier gating, analytics) | 3–5 | **4** |
| 5 | Single-command deploy + teardown (aggregated env.mk, make setup/teardown, fix targets) | 4–5 | **4** |
| 6 | Known bugs / tech debt (trigger fix, sidecar tests, secret hygiene, privileged, MetalLB) | 5–8 | **6** |
| 7 | Production hardening / security / HA / backups (**isolation dominates**) | 13–23 | **17** |
| 8 | Testing & CI (CI pipeline; suite verification net of #6) | 2–3 | **3** |
| 9 | Docs & GTM (architecture writeup, landing, demo video) | 3–5 | **4** |
| | **Total to production launch** | **56–93** | **≈ 72** |

So **~72 dev-days ≈ 14–15 working weeks (~3–4 months) solo** to a hardened public launch.
A **demoable MVP** (0, 1, minimal 2, 5) is far closer — **~20–25 dev-days**.

### Tomorrow's picks

**Easy wins (≤1 day each, low-risk, high-value):**
- [x] **`PYTHONUNBUFFERED=1`** on the Python deployments — done (baked in Dockerfiles + applied live).
- [ ] **Verify save end-to-end** (~0.5d + any small fixes) — the last confirmation; unblocks the lifecycle work.
- [ ] **`status_sidecar` tests** — dummy-call coverage mirroring snapshot_job (~0.5–1d).
- [ ] **Persistence-model decision** for the lifecycle — PVC vs image vs hybrid (~0.5d; a decision, not code, but it unblocks #1).

**Larger scheduled item (§5, ~4d — start tomorrow):**
- [ ] **Monorepo single-command deploy + teardown** — aggregated `env.mk` (per-service prefixes), one `make setup` (cluster → ingress-nginx → MetalLB → cert-manager → postgres → redis → migrate/seed → all services, ordered, non-interactive), one `make teardown`, and fix the remaining broken make targets (`build_all`, `prod_*`, `build_letsencrypt_issuer`). The aggregated `env.mk` + target fixes are the ≤1d slice; full orchestration is the rest.

### Caveats

- Estimates assume the current architecture holds; a persistence-model change (#1) or an isolation
  approach like gVisor/Kata (#7) could swing #1/#7 meaningfully.
- **#7 isolation is the widest range and the riskiest** — running untrusted user containers safely
  is genuinely hard; budget conservatively.
- Solo numbers. Parallelizing (e.g. a second dev on payments/ads) compresses calendar time but not
  total dev-days.
</content>
</invoke>

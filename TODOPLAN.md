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

- [ ] ⚠️ **Decide persistence model:** PVC-backed (cheap crash-restart, fs survives) vs image-snapshot (frees resources on hibernate) vs **hybrid** (PVC live + image-snapshot on hibernate — recommended).
- [ ] **Activity tracking** — socket-ssh stamps `last_active_at` (Redis key w/ TTL or DB column) on WS connect / heartbeat / disconnect.
- [ ] **Resume flow** — `create` branches: if the container row has `saved_image`, spin the pod **from that image**; else base image. (Reuses create path.)
- [ ] **Reaper controller** — finds terminals idle > threshold → save → delete pod → set status `HIBERNATED`. ⚠️ CronJob vs in-process loop in browseterm-server.
- [ ] **Crash detection + recovery** — `status_sidecar` (already in every pod) detects an active user's pod died → recover (restart from PVC or rebuild from `saved_image`).
- [ ] **New container statuses** — e.g. `HIBERNATED`, `RESUMING`, `CRASHED` (extend the enum + migrations + trigger).
- [ ] ⚠️ Decide the **inactivity threshold** value.
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
- [ ] Secret hygiene: `REPO_PASSWORD` (real Docker Hub pw) sits plaintext in `env.mk` → move to k8s Secret + rotate to an access token.
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
</content>
</invoke>

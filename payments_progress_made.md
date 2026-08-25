# Payment Gateway v0 — Progress (2026-08-24 → 2026-08-25)

Implements `browseterm-monorepo/PAYMENTS.md`: a standalone gRPC payment-service,
wired into Browseterm the same way ContainerMaker is (same TLS/cert-manager
pattern, same k8s conventions, same client pattern in browseterm-server), with
a hardcoded `SUCCESS` response for v0. No Stripe, no DB, no real payment logic
yet — this phase only proves the infrastructure path end-to-end.

See also: `progress_made.md`'s "STANDING CONVENTION" section for the
never-add-Claude-co-author-trailer rule that applied to every commit made
during this work.

## New repos (both live on GitHub under `Zim95`)

- **`payment-gateway-spec`** — protobuf contract. Mirrors
  `container-maker-spec`'s pattern: flat `spec/*.proto`, a Poetry `build.py`
  build-hook running `grpc_tools.protoc`, generated code committed to git,
  consumed as a Poetry git dependency (not a submodule) by both
  `payment-gateway` and `browseterm-server`.
  - **One deliberate deviation, found the hard way**: both `container-maker-spec`
    and (originally) `payment-gateway-spec` declared their proto files as
    literally `types.proto`/`service.proto`. protobuf's global descriptor pool
    keys registered files by that literal name, not by Python package path —
    so `browseterm-server`, which imports *both* specs in one process, hit
    `TypeError: Couldn't build proto file into descriptor pool: duplicate file
    name types.proto` at import time. Fixed by renaming
    `payment-gateway-spec`'s files to `payment_types.proto`/
    `payment_service.proto` (and the generated `payment_types_pb2*.py` /
    `payment_service_pb2*.py`). Required updating imports in `payment-gateway`
    and `browseterm-server` to match. Verified fixed by importing both specs
    together successfully.
  - Service: `PaymentGatewayAPI.makePayment(PaymentRequest) returns
    (PaymentResponse)`.

- **`payment-gateway`** — standalone gRPC server. Mirrors `container-maker`'s
  `app.py` exactly: Click CLI, `grpc.server(ThreadPoolExecutor,
  interceptors=[RequestIdInterceptor()])`, TLS via `SERVER_KEY`/`SERVER_CRT`/
  `CA_CRT` (env var, falls back to `./cert/*` files). `makePayment` always
  returns a hardcoded `payment_id="pay_test_001"`, `status=SUCCESS`,
  `message="Payment request accepted"`.
  - Deliberately **omits** what ContainerMaker needs but this doesn't: no k8s
    API client, no ServiceAccount/ClusterRole/RBAC, no
    `securityContext.privileged` — payment-gateway never manages cluster
    resources on a user's behalf.
  - Port `50053` (container-maker uses `50052`).

## cert-manager

`browseterm_workload/cert-manager/services.list.json` — the certificate
generator is already generic over this list, so the only change needed was
appending `"payment-gateway-development-service"` and
`"payment-gateway-service"`. No code change. Mints the same 5-key bundle
(`ca.crt`, `server.crt`, `server.key`, `client.crt`, `client.key`) into
Secrets `payment-gateway-{development-,}service-certs`.

## browseterm-server integration

- `src/payments/payments_service.py` (new): `PaymentService`, same shape as
  `ContainerService` — reads client/CA certs live from the
  `PAYMENT_GATEWAY_CERTS_SECRET_NAME` k8s Secret via
  `read_cert_from_k8s_secret`, builds a `GRPCUtils` channel/stub, calls
  `makePayment` with `x-request-id` metadata forwarded from the logging
  contextvar.
  - **Deliberate addition over `ContainerService`'s pattern**: a 5s call
    timeout and explicit `grpc.RpcError` handling
    (`UNAVAILABLE`/`DEADLINE_EXCEEDED` → 503), since PAYMENTS.md requires a
    payment-gateway outage not hang the request. `ContainerService` sets no
    deadline today.
- `POST /create-payment` (`src/api_handlers.py`, registered in `app.py`):
  `@authenticate_session`-protected, `user_id` comes from
  `request.state.user_info.id` (never the browser). `amount_minor`/`currency`
  hardcoded for v0 with a `# TODO` to resolve them server-side from `plan_id`
  once real plans exist.
- Frontend: `templates/static/js/subscriptions.js`'s existing "Select Plan" →
  confirm → `processPurchase()` flow already had a `// TODO: Redirect to
  payment gateway` stub for exactly this. Wired it to call `/create-payment`
  and show the response via the existing `NotificationManager` toast, instead
  of adding a redundant new button.
- `pyproject.toml`: `payment-gateway-spec` added as a Poetry git dependency.
- Tests: unit tests for `PaymentService` (mocked stub — success, `UNAVAILABLE`
  → `PaymentGatewayUnavailableException`, other RPC errors →
  `PaymentGatewayException`) and an e2e test confirming an unauthenticated
  request is redirected to `/login` and never reaches `PaymentService`. All
  pass; full existing suite showed no regressions (3 pre-existing unrelated
  failures: stale `CONTAINER_MAKER_CLIENT_*_ENV_VAR` imports in two test files,
  and Redis/DB-dependent tests needing live services).

## Deploy-wiring gap found and fixed

`config.py`/`gen-env.sh` had the `PAYMENT_GATEWAY_HOST/PORT/CERTS_SECRET_NAME`
plumbing from the start, but the actual k8s manifests and deploy scripts never
passed them into the pod — so the running container would have silently
fallen back to `config.py`'s dev-default hostnames regardless of environment.
Fixed by adding the env entries to both `infra/deployment/deployment.yaml` and
`infra/development/development.yaml`, and threading the 3 new values through
`deployment-setup.sh`/`development-setup.sh` and the `Makefile`'s
`dev_setup`/`prod_setup` targets, matching the `CONTAINER_MAKER_*` pattern
exactly.

**Trap hit while deploying**: the monorepo's `browseterm-server` *submodule
checkout* was still pinned to the commit before this wiring fix, so the first
`make prod_setup` run silently used the old Makefile/manifest (kubectl
reported `deployment.apps/browseterm-server unchanged`). Fixed by
fast-forwarding the submodule checkout to the fix commit before re-running.
**Lesson for next time**: after pushing a fix to a submodule's standalone repo,
always fast-forward the monorepo's copy of that submodule *before* running any
`make`/deploy target from inside it — the two checkouts are independent
working trees, not the same directory.

## Monorepo wiring

- `payment-gateway` and `payment-gateway-spec` added as real git submodules
  (`https://github.com/Zim95/payment-gateway(-spec).git`), matching every
  other submodule's convention (no local-path submodules exist in this repo).
- `scripts/gen-env.sh`: fans out a `payment-gateway/env.mk` block, and adds
  `PAYMENT_GATEWAY_*` vars to the generated `browseterm-server/env.mk`.
- `env.mk.example` (and the real gitignored `env.mk`): added
  `PAYMENT_GATEWAY_CERTS_SECRET_NAME`.
- `scripts/setup.sh`: deploys `payment-gateway` in the service chain (right
  after `container-maker`), with a matching rollout-status wait and
  cert-Secret wait.
- `PAYMENTS.md`: appended a short "Status: v0 implemented" note at the top.

## Live deployment to `browseterm-k3s`

Cluster: single-node k3s, namespace `browseterm`, images on Docker Hub under
`zim95/*`. This node has known, pre-existing instability (see "Known cluster
issues" below) — worth knowing before assuming a stuck rollout means broken
code.

1. Built + pushed `zim95/cert-manager:latest` (picks up the updated
   `services.list.json`), triggered a one-off job
   (`kubectl create job --from=cronjob/cert-manager ...`). Succeeded — minted
   `payment-gateway-service-certs` and `payment-gateway-development-service-certs`.
   Cert-manager's `rollout_service_deployments()` then auto-triggered a
   rollout on any deployment matching the service name (this is why
   `container-maker` and `payment-gateway` both got fresh ReplicaSets around
   the same time — expected behavior, not a bug).
2. Built + pushed `zim95/payment-gateway:latest`, applied
   `infra/k8s/deployment/deployment.yaml` (prod manifest — this cluster runs
   the prod path, not `-development`). Pod came up `1/1 Running`, TLS server
   started cleanly.
3. Built + pushed `zim95/browseterm-server:latest` (includes the payment
   integration code + the deploy-wiring fix above), ran `make prod_setup`,
   force-pulled via a one-time imperative `imagePullPolicy: Always` patch
   (not persisted to git — `IfNotPresent` + same `:latest` tag risks reusing a
   stale cached image on a redeploy).
4. **Verified with a real payment request**: port-forwarded to
   `payment-gateway-service`, extracted its client/CA certs from the k8s
   Secret, and made an actual mTLS `makePayment` gRPC call —
   `payment_id="pay_test_001"`, `status=SUCCESS`, and the pod's own structured
   logs show the `request_id` correlation ID threaded through correctly.
5. **Verified the HTTP auth gate**: `curl -X POST http://localhost:9999/create-payment`
   from inside the `browseterm-server` pod, unauthenticated → `302` to
   `/login`. Confirmed via `payment-gateway`'s logs that it was never
   contacted by that request.

### End state (as of 2026-08-25)
- `payment-gateway` deployment: `1/1 Running`.
- `browseterm-server` deployment: `1/1 Running` (new pod, with
  `PAYMENT_GATEWAY_*` env vars confirmed present via `kubectl exec ... env`).
- `/create-payment` auth-gates correctly.
- **Not yet done**: an actual browser-based end-to-end test (log in → go to
  Subscriptions → click "Select Plan" → see the "Payment successful /
  Payment ID: pay_test_001" toast). Everything below the browser layer is
  verified; the UI click-through itself hasn't been exercised by a human yet.

## Known cluster issues (pre-existing, NOT caused by this work)

- **CoreDNS was in `CrashLoopBackOff`** (96+ restarts) — liveness/readiness
  probes timing out (`context deadline exceeded`), not a config error. This is
  what caused `browseterm-server`'s old pod to crash-loop on Postgres DNS
  resolution (`could not translate host name "browseterm-pg-service"`),
  independent of payment-gateway.
- **The node repeatedly flapped `NodeNotReady`** over many hours.
- **The node's outbound network to Docker Hub was broken for 7+ hours**
  during this deploy: `lookup registry-1.docker.io: Try again` (DNS) and
  `read: connection reset by peer` (mid-transfer resets) — this is what stuck
  the new `browseterm-server` pod in `ImagePullBackOff` for a long stretch.
  Connectivity recovered on its own (user investigated the node/network
  directly); the rollout then completed cleanly with no further changes
  needed.
- All of the above point at the single-node VM's resource/network capacity
  being marginal (consistent with the existing HPA comment: "single
  4-core/8GB dev VM can't absorb autoscaling"). Worth the user's attention
  independent of payments — likely to recur.

## TLS cert detail worth knowing (not a bug, matches existing pattern)

Both `container-maker`'s and `payment-gateway`'s server certs have **no SAN
(Subject Alternative Name) extension** — just a bare CN. This is because
`cert_manager.py`'s `create_server_cert`/`create_client_cert` sign the CSR via
`openssl x509 -req` without `-copy_extensions`/`-extfile`, so the `-addext
subjectAltName=...` added at CSR-creation time never makes it into the final
certificate. It works in practice because the in-cluster hostname
(`payment-gateway-service`, `container-maker-service`) is set to exactly match
the cert's CN, and grpc's TLS stack falls back to CN matching when no SAN is
present. Confirmed this is pre-existing (container-maker has the same gap),
not something introduced by payment-gateway — mirrored faithfully rather than
"fixed", per the instruction to not invent a different security model than
what ContainerMaker already has.

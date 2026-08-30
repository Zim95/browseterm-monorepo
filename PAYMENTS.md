> **Status: v0 implemented.** `payment-gateway` (server) and `payment-gateway-spec`
> (protobuf contract) exist as standalone repos, added to this monorepo as submodules —
> mirroring `container-maker`/`container-maker-spec` exactly, including its TLS/cert-manager
> pattern, dev/prod k8s manifests, and Makefile/scripts shape. `browseterm-server` calls it
> via `POST /create-payment` (wired to the existing Subscriptions page's "Select Plan" flow).
> See `payment-gateway/README.md` for the one deliberate deviation from the ContainerMaker
> pattern (proto file naming, to avoid a protobuf descriptor-pool collision).

---

# Current Architecture (as-built, 2026-08-29)

This section describes what is actually running today, verified directly against the code and
the live cluster rather than restated from the original task spec below (which is kept as
historical context — see "Task: Add Payment gRPC Service v0 to Browseterm" onward). Where this
section and the spec disagree, this section is the truth.

## End-to-end flow

```text
Browser (/subscriptions "Select Plan")
    │  redirect
    ▼
Browser (/payment?plan_id=...)
    │  browseterm-server renders Plan/Price/Currency/GST/Total (client-computed, display-only)
    │  payment.js mints one idempotency key per checkout attempt (crypto.randomUUID()),
    │  reused across every Pay click/retry on this page, never rendered in the DOM
    │
    │  POST /create-payment  { plan_id, idempotency_key }
    │  existing session cookie — no card data, no amount, ever sent from the browser
    ▼
browseterm-server (FastAPI, src/api_handlers.py::create_payment)
    │  @authenticate_session — user_id comes from the server-side Redis session, never the body
    │  amount_minor/currency are still HARDCODED here (49900 / "INR") — no real plans/pricing
    │  table exists yet, so nothing browser-supplied is trusted for the actual charge
    ▼
PaymentService (src/payments/payments_service.py)
    │  reads client.key/client.crt/ca.crt live from the PAYMENT_GATEWAY_CERTS_SECRET_NAME
    │  k8s Secret on every instantiation (same pattern as ContainerService)
    │  builds a GRPCUtils channel/stub, calls makePayment with a 5s deadline
    │  x-request-id gRPC metadata carries the same request_id as browseterm-server's own
    │  structured logs (contextvar-based), so a request is traceable across both services
    ▼
gRPC over TLS  →  payment-gateway:50053 (ClusterIP Service, internal only, no Ingress)
    ▼
payment-gateway (Click-driven app.py + grpc.server, ThreadPoolExecutor,
                 RequestIdInterceptor — mirrors container-maker's server shape exactly)
    │  PaymentGatewayAPIServicerImpl.makePayment (src/grpc/servicer.py):
    │    - logs the full request (user_id, plan_id, amount_minor, currency, idempotency_key)
    │    - returns a HARDCODED response: payment_id="pay_test_001", status=SUCCESS
    │    - no persistence, no Stripe, no real charge — this only proves the path end to end
    ▼
Response bubbles back up unchanged; browseterm-server translates gRPC errors
(UNAVAILABLE/DEADLINE_EXCEEDED → HTTP 503, anything else → HTTP 500) so a payment-gateway
outage returns a controlled error instead of hanging the request.
    ▼
Browser: NotificationManager toast — "Payment successful, Payment ID: pay_test_001"
```

## Proto contract (`payment-gateway-spec`)

```proto
service PaymentGatewayAPI {
  rpc makePayment(PaymentRequest) returns (PaymentResponse);
}

message PaymentRequest {
  string user_id = 1;           // resolved server-side by browseterm-server, never from the browser
  string plan_id = 2;
  int64 amount_minor = 3;       // integer minor currency unit (e.g. 49900 = ₹499.00) — already
                                 // minor-unit end to end at this layer; only browseterm-db's own
                                 // subscription_types.amount (DECIMAL rupees) still needs migrating
  string currency = 4;          // ISO 4217, e.g. "INR"
  string request_id = 5;        // cross-service log correlation id (NOT the idempotency key)
  string idempotency_key = 6;   // client-generated, one per checkout attempt, logged only (see below)
}

message PaymentResponse {
  string payment_id = 1;
  PaymentStatus status = 2;     // PAYMENT_STATUS_UNSPECIFIED | _SUCCESS | _FAILED
  string message = 3;
}
```

`request_id` and `idempotency_key` are deliberately separate fields with different lifetimes:
`request_id` is a per-hop tracing id (new on every HTTP request, even a retry); `idempotency_key`
is stable across every retry of the *same* checkout attempt. Conflating them was considered and
rejected early in this work.

## TLS — real state, not just the intended design

Both `browseterm-server` and `payment-gateway` mount the **same shared Secret**
(`payment-gateway-service-certs` in prod, `payment-gateway-development-service-certs` in dev —
5 keys: `server.key`, `server.crt`, `client.key`, `client.crt`, `ca.crt`), minted/rotated by a
shared `cert-manager` CronJob in the `browseterm` namespace (the same one used for
`container-maker`'s certs — not the cert-manager *operator*'s `Certificate` CRD, a homegrown
rotation job).

**However**: `payment-gateway/app.py::serve()` calls `grpc.ssl_server_credentials(...)` with
`root_certificates` set but **without `require_client_auth=True`**. That means the server
currently does **not** actually verify the client certificate `browseterm-server` presents — this
is server-authenticated TLS today, not enforced mutual TLS, even though every piece of cert
material for real mTLS already exists and is mounted (`CLIENT_KEY`/`CLIENT_CRT` env vars are set
in the Deployment manifest but never read anywhere in `payment-gateway`'s own code). Flipping this
to real mTLS is a one-line change (`require_client_auth=True`) plus reading/wiring the client cert
env vars — not done yet, noted here so it isn't assumed to already be enforced.

## Kubernetes

- `payment-gateway` Deployment: 1 replica, `zim95/payment-gateway:latest`, `imagePullPolicy:
  IfNotPresent` in prod manifest, container port `50053`, requests `100m`/`256Mi`, limits
  `500m`/`512Mi`.
- `payment-gateway-service`: `ClusterIP`, port `50053` → `50053`. Not exposed via Ingress —
  internal-only, matching the spec's explicit "do not expose publicly, Stripe webhooks come
  later" instruction.
- `browseterm-server` reaches it via `PAYMENT_GATEWAY_HOST`/`PAYMENT_GATEWAY_PORT` env vars
  (default `payment-gateway-development-service`/`50053` in dev).

## Idempotency key — what's real vs. what's still just logging

- Generated client-side (`payment.js`, `crypto.randomUUID()` with a manual fallback), once per
  page load, reused for every Pay click/retry on that page, never rendered in the UI.
- Flows browser → `CreatePaymentRequest.idempotency_key` → `PaymentService.make_payment` →
  `PaymentRequest.idempotency_key` (proto) → `payment-gateway`'s `makePayment` logs it via
  structured JSON logging.
- **Not yet enforced or deduplicated** — there is no persistence layer to check "have I seen this
  key before" against, so two calls with the same key today would both return
  `pay_test_001`/`SUCCESS` independently. The only verification path that exists right now is
  visual: grep/query `payment-gateway`'s logs (Loki/Grafana once wired) for repeated
  `idempotency_key` values across retries of the same checkout attempt, per `plan.md`'s explicit
  ask. Real deduplication needs a payments table keyed on `idempotency_key` — listed under "not yet
  implemented" below.

## What's still genuinely not implemented (v0, unchanged from the original spec's "do not implement yet" list except where noted)

```text
Stripe / PaymentIntent / Checkout / webhooks     — not started; user has chosen Stripe Checkout
                                                    (hosted redirect) as the approach, blocked on
                                                    the user providing test-mode API keys
payment persistence / payments database          — none; makePayment is stateless
real plan-based pricing                          — amount_minor/currency still hardcoded in
                                                    browseterm-server's /create-payment regardless
                                                    of plan_id
idempotency enforcement/deduplication            — logged only, not checked/rejected (see above)
subscriptions/entitlements tie-in to payment      — subscription plan gating exists for resume
                                                    (see browseterm-server's resume_container),
                                                    but purchasing a plan doesn't yet actually
                                                    change the user's subscription row
refunds, retries, reconciliation, DLQ            — not started
double-entry ledger                              — design recommended (2026-08-29,
                                                    progress_made.md), not implemented; depends on
                                                    the Stripe webhook landing first as the trigger
mTLS enforcement                                 — cert material exists, not actually required by
                                                    the server yet (see TLS section above)
metrics/tracing beyond structured logs+request_id — not started
```

## Testing that exists today

- `payment-gateway`: unit tests for `PaymentGatewayAPIServicerImpl` (mocked context), including a
  test asserting `idempotency_key` is logged.
- `browseterm-server`: unit tests for `PaymentService` (mocked gRPC stub) covering the
  success/UNAVAILABLE/other-RPC-error paths; an integration test for the `create_payment` HTTP
  handler; an e2e test confirming an unauthenticated `POST /create-payment` is redirected to
  `/login` and never reaches `PaymentService` at all.

---

# Task: Add Payment gRPC Service v0 to Browseterm

We are adding a new internal microservice called **payment-service** to Browseterm.

This is **infrastructure/setup only**. Do not implement Stripe, database persistence, idempotency, subscriptions, refunds, ledger logic, or real payment processing yet.

The goal of this version is:

```text
Frontend button
    ↓
Browseterm Server / existing authenticated API
    ↓
gRPC over TLS
    ↓
Payment Service
    ↓
Hardcoded SUCCESS response
    ↓
Browseterm Server
    ↓
Frontend displays success
```

The payment service must follow the **same architectural, Kubernetes, gRPC, TLS, cert-manager and dev/prod conventions already used by ContainerMaker**.

---

# 1. Inspect Existing ContainerMaker Implementation First

Before making changes, inspect the repository and determine exactly how ContainerMaker currently handles:

* gRPC `.proto` definitions
* generated gRPC code
* gRPC server startup
* gRPC clients
* Kubernetes Deployment
* Kubernetes Service
* internal DNS
* ports
* health probes if present
* cert-manager Certificates
* development certificates
* production certificates
* CA/trust configuration
* mounted TLS Secrets
* client certificates
* server certificates
* environment-specific manifests/Helm values
* NetworkPolicies if present
* configuration/environment variables
* Makefile/scripts used for protobuf generation
* deployment scripts
* frontend → backend → gRPC flow where relevant

**Reuse the existing conventions.**

Do not introduce a separate certificate architecture if ContainerMaker already establishes one.

---

# 2. Payment Service

Create a standalone **payment-service**.

For v0 it should contain only:

```text
gRPC server
Payment RPC
hardcoded response
TLS configuration
health/startup wiring as appropriate
```

No database.

No Redis.

No Stripe.

No Kafka.

No payment state machine yet.

---

# 3. gRPC Contract

Create a payment protobuf following the repository's existing proto organization.

Conceptually:

```proto
service PaymentService {
  rpc Payment(PaymentRequest) returns (PaymentResponse);
}
```

The request should support the information coming from the UI/backend.

Use suitable protobuf types and naming conventions already present in the project.

Suggested logical fields:

```text
user_id
plan_id
amount_minor
currency
request_id
```

`amount_minor` means the integer minor currency unit:

```text
₹499.00 → 49900 paise
$5.99   → 599 cents
```

For this first version, the values can originate from a hardcoded UI plan.

The response can conceptually contain:

```text
payment_id
status
message
```

Return hardcoded values such as:

```text
payment_id = "pay_test_001"
status = "SUCCESS"
message = "Payment request accepted"
```

Match existing protobuf enum/string conventions where appropriate.

---

# 4. Authentication Boundary

Do **not** make payment-service authenticate browser sessions directly.

Existing Browseterm authentication remains responsible for the user session.

Flow:

```text
Browser
    │
    │ existing Browseterm session
    ▼
Browseterm Server
    │
    ├── validate existing session
    ├── resolve authenticated user_id
    │
    └── call Payment Service through gRPC
```

The browser must **not be able to supply an arbitrary trusted `user_id`**.

`user_id` passed into payment-service should come from the authenticated Browseterm server context.

Do not add another Redis session-validation implementation inside payment-service.

---

# 5. gRPC TLS

Communication between Browseterm and payment-service must use TLS following the same pattern as ContainerMaker.

Cert-manager is **already installed and configured**.

Do not reinstall cert-manager.

Add whatever payment-service Certificate resources, Secrets, SANs/DNS names, mounts and trust configuration are required to mirror ContainerMaker.

We need both:

```text
development certificates
production certificates
```

Use the project's existing development and production Issuer/ClusterIssuer conventions.

Do not invent new issuers unless absolutely necessary.

---

# 6. Certificate Requirements

Determine the actual Kubernetes Service DNS name based on the repository's namespace conventions.

It will likely resemble:

```text
payment-service
payment-service.<namespace>
payment-service.<namespace>.svc
payment-service.<namespace>.svc.cluster.local
```

Ensure the server certificate contains the DNS identities required by the existing gRPC TLS architecture.

Follow ContainerMaker exactly regarding:

* server cert
* client cert if mutual TLS is used
* CA bundle
* Secret names
* volume mounts
* certificate paths
* certificate rotation

If ContainerMaker uses **mTLS**, payment-service must use mTLS as well.

If ContainerMaker uses server-authenticated TLS only, mirror that instead.

Do not weaken the existing security model.

---

# 7. Kubernetes Deployment

Create the payment-service Deployment following existing application conventions.

It should include the appropriate:

* image
* container name
* gRPC port
* TLS Secret mounts
* environment/configuration
* resources if the repo has defaults
* liveness/readiness/startup probes if appropriate
* labels/selectors
* namespace
* securityContext if normally used
* imagePullPolicy consistent with the project

Do not redesign unrelated infrastructure.

---

# 8. Kubernetes Service

Create an internal Kubernetes Service for payment-service.

It should expose the gRPC endpoint only as required for internal Browseterm communication.

Conceptually:

```text
Browseterm Server
        │
        │ TLS gRPC
        ▼
payment-service:<grpc-port>
```

Do not expose payment-service publicly through an Ingress for the current version.

Stripe webhooks will be handled later.

---

# 9. Browseterm gRPC Client

Add a Payment Service client to the existing Browseterm server.

Follow the same abstraction/pattern used by the ContainerMaker gRPC client.

It should:

* connect using Kubernetes service discovery
* use the generated protobuf client
* establish secure TLS communication
* validate the payment-service certificate
* provide client certificate if current architecture uses mTLS
* support the same dev/prod certificate differences as ContainerMaker
* use a reasonable request deadline/timeout
* cleanly translate gRPC errors into the existing API error structure

Avoid creating gRPC channels repeatedly per request if the existing architecture uses a reusable channel/client.

---

# 10. Request ID Propagation

The existing Browseterm request ID/correlation mechanism should be propagated.

Flow:

```text
Frontend request
    ↓
Browseterm request_id
    ↓
gRPC metadata / PaymentRequest
    ↓
Payment Service logs same request_id
```

Do this using whichever metadata/context pattern already exists in the project.

We want to eventually correlate:

```text
Frontend/API logs
Payment Service logs
future Stripe operations
```

for the same request.

---

# 11. Browseterm HTTP API

Add the smallest appropriate HTTP endpoint to the existing Browseterm server.

Conceptually:

```http
POST /api/payment
```

or follow the repository's existing URL conventions.

The route must use existing Browseterm authentication.

Example UI payload:

```json
{
  "plan_id": "developer",
  "amount_minor": 49900,
  "currency": "INR"
}
```

For this v0 implementation, these values may be hardcoded because actual plans do not exist yet.

However:

**Do not treat browser-provided amounts as authoritative in future architecture.**

Add a comment/TODO explaining that real pricing will eventually be server-side and resolved from `plan_id`.

For this first infrastructure test, hardcoded values are acceptable.

---

# 12. Frontend

Add a minimal payment test UI using the existing frontend conventions.

Add a button such as:

```text
Test Payment
```

or place it wherever payment/subscription controls logically belong.

Clicking the button should:

```text
1. Call Browseterm HTTP API
2. Existing session authenticates the request
3. Browseterm calls payment-service using secure gRPC
4. payment-service returns hardcoded SUCCESS
5. Browseterm returns result
6. UI displays the response
```

Example result:

```text
Payment successful
Payment ID: pay_test_001
```

Keep this intentionally simple.

No Stripe UI.

No card fields.

No redirect.

No checkout page.

---

# 13. Expected End-to-End Architecture

```text
┌──────────────────────┐
│      Browser UI      │
│                      │
│   [ Test Payment ]   │
└──────────┬───────────┘
           │
           │ HTTPS + existing session
           ▼
┌──────────────────────┐
│  Browseterm Server   │
│      FastAPI         │
│                      │
│ Validate session     │
│ Resolve user_id      │
│ Generate/propagate   │
│ request_id           │
└──────────┬───────────┘
           │
           │ secure gRPC
           │ same TLS pattern as ContainerMaker
           ▼
┌──────────────────────┐
│   Payment Service    │
│                      │
│ Payment()            │
│                      │
│ Returns:             │
│ pay_test_001         │
│ SUCCESS              │
└──────────────────────┘
```

Certificate lifecycle:

```text
                 cert-manager
                     │
          ┌──────────┴──────────┐
          ▼                     ▼
 Browseterm client cert   Payment server cert
      if required           + CA trust
          │                     │
          └──────── mTLS ───────┘
```

Again: mirror ContainerMaker rather than assuming mTLS if its existing setup differs.

---

# 14. Development and Production

Payment-service must work in both existing environments.

Inspect how environment separation currently works.

Support the equivalent of:

```text
development
production
```

for:

* certificate resources
* issuer selection
* service DNS names
* Secret names
* configuration
* deployment manifests/Helm values
* gRPC target
* CA/client/server certificate mounting

Do not duplicate large manifests if the repo currently handles this through Helm values/overlays/templates.

Follow the existing approach.

---

# 15. Testing

Add appropriate tests where practical.

At minimum verify:

### gRPC unit/service test

```text
Payment(valid test request)
→ SUCCESS
→ pay_test_001
```

### API integration path

```text
Authenticated Browseterm request
→ Payment Service
→ SUCCESS
```

### Authentication

```text
Unauthenticated browser request
→ rejected by Browseterm
→ payment-service never called
```

### Payment Service unavailable

```text
Payment Service down
→ Browseterm returns controlled error
→ request does not hang indefinitely
```

### TLS

Verify Browseterm can connect with the generated development certificates.

Also make sure a client without the required trust/client certificate cannot connect if the existing architecture uses mTLS.

---

# 16. Kubernetes Verification

Provide commands to verify:

```bash
kubectl get deployment
kubectl get pods
kubectl get svc
kubectl get certificate
kubectl get certificaterequest
kubectl get secret
```

Provide a way to inspect the certificate SANs if necessary.

Also provide commands for:

```text
payment-service logs
Browseterm logs
cert-manager logs if issuance fails
```

---

# 17. Do Not Implement Yet

Explicitly leave these for later:

```text
Stripe
PaymentIntent
Checkout
webhooks
payment database
plans database
subscriptions
entitlements
idempotency
payment states
refunds
retries
reconciliation
DLQ
ledger
double-entry accounting
Kafka
payment metrics
OpenTelemetry
```

We will add these incrementally after the infrastructure path works.

---

# 18. Documentation

Update relevant project documentation with:

```text
Payment Service
purpose
port
service DNS
proto location
certificate resources
dev/prod certificate differences
how Browseterm connects
how to generate protobuf files
how to build image
how to deploy
how to test the payment button
```

Do not rewrite unrelated documentation.

---

# 19. Before Modifying Anything

First produce a short implementation plan containing:

```text
Existing ContainerMaker pattern discovered
Files that will be created
Files that will be modified
Certificate resources that will be added
How dev certificates work
How prod certificates work
How Browseterm currently creates secure gRPC clients
How payment-service will mirror that design
```

Then implement.

If the existing repository structure contradicts any assumption in this prompt, **follow the repository's established architecture and explain the difference rather than forcing this design.**

---

# Definition of Done

This phase is complete when:

```text
1. payment-service exists as a standalone gRPC server.
2. Payment RPC accepts a request.
3. Payment RPC returns a hardcoded SUCCESS.
4. Payment service runs as a Kubernetes Deployment.
5. Payment service has an internal Kubernetes Service.
6. cert-manager successfully issues the required development certificate(s).
7. equivalent production certificate resources/configuration exist.
8. Browseterm establishes secure gRPC communication with payment-service.
9. Existing Browseterm authentication protects the HTTP endpoint.
10. Authenticated user_id is propagated server-side.
11. request_id is propagated to payment-service.
12. Frontend payment button triggers the complete flow.
13. UI displays the hardcoded success response.
14. Payment service is not publicly exposed.
15. No real payment logic has been introduced yet.
```

Do not proceed into Stripe/payment functionality after reaching this point. Stop and report the completed architecture, files changed, commands required to deploy/test it, and any architectural decisions discovered from the existing ContainerMaker implementation.


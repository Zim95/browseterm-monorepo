# Single-node k3s — local + prod (why, and how)

BrowseTerm runs on a **single-node k3s cluster** — the *same* one locally (a Multipass VM on your Mac)
and in production (a self-owned cloud VM or Raspberry Pi). This doc says why we picked that, how to
stand it up (`scripts/setup.k3s.sh`), and how internet/egress works on it.

---

## 1. Why single-node k3s (and not docker-desktop / EKS)

**Goal:** one deployment that works identically in local and prod, on hardware we own.

- **docker-desktop can't enforce NetworkPolicy.** Its built-in CNI accepts our per-tenant
  NetworkPolicies and ignores them — so the entire §7 network-isolation effort is unverifiable there.
  **k3s ships an embedded netpol controller (kube-router)**, so the policies actually enforce. This is
  the single biggest reason for the switch.
- **EKS is off-limits.** The AWS clusters belong to an employer; BrowseTerm is a personal side project,
  so using them would be both an AUP issue and an IP-ownership risk. Prod must be self-owned.
- **k3s is a real, CNCF-conformant Kubernetes** — light enough for one VM or a Pi, but not a toy. So a
  single distro (k3s) covers **both** local and prod, and "same deployment both places" is true by
  construction (same CNI, same default CIDRs, same behaviour).

**Single node** is deliberate for prod v1: no HA, one point of failure — fine for a side project /
small user count, and the per-tenant ResourceQuota/LimitRange keep one box from tipping over. HA k3s
(multiple servers + embedded etcd) is a later step, only once there are users.

## 2. Why we disable k3s's bundled bits

k3s bundles **Traefik** (ingress) and **servicelb** (load balancer). We install k3s with **those two
disabled** (`--disable traefik --disable servicelb`) and bring our own:

- **ingress-nginx** (not Traefik) — our terminal streaming relies on nginx-specific ingress annotations
  (`nginx.ingress.kubernetes.io/proxy-read-timeout`, `nginx.org/websocket-services`) that keep the
  socket-ssh **WebSocket** alive. Re-implementing those on Traefik is avoidable risk.
- **MetalLB** (not servicelb) — matches the existing `setup.sh`; works fine on a single node. (On a
  single cloud node you *could* simplify to servicelb; not required.) MetalLB's IP pool must be on the
  VM's subnet — set `METALLB_POOL=192.168.64.200-192.168.64.250` (the Multipass `192.168.64.x` network).

> **KEEP k3s's `local-path` (do NOT `--disable local-storage`).** It's the default StorageClass, and
> the datastores need dynamic provisioning: **MinIO's PVC** (and any PVC without a matching static PV)
> stays unbound and the pod Pending without it. (The *snapshot* local-PVC path is retired — MinIO owns
> snapshots — but that's unrelated to k3s's `local-path` provisioner, which the datastores rely on.)

Keeping our own stack means the existing manifests and `setup.sh` deploy unchanged. Two env.mk values
must match the k3s cluster: `METALLB_POOL` (above) and `REDIS_DATA_DIR` must be an **absolute** path
(e.g. `/data`) — a relative value makes Redis's `hostPath` PV mount fail.

## 3. How to stand it up

```bash
./scripts/setup.k3s.sh          # provisions the VM + single-node k3s + wires kubectl
# then:
./scripts/setup.sh              # deploys BrowseTerm (ingress-nginx + MetalLB + MinIO + services)
```

`setup.k3s.sh` (idempotent) does: launch a Multipass VM → verify it has internet → install k3s (bundled
bits disabled) → wait for Ready → pull the kubeconfig, rewrite the server IP to the VM's IP, merge it
as the **`browseterm-k3s`** context → prove pods can reach the internet. Override defaults via env
(`VM`, `CPUS`, `MEM`, `DISK`, `K3S_VERSION`).

Handy: `multipass shell browseterm-k3s` · `multipass stop browseterm-k3s` · `multipass delete --purge browseterm-k3s`.

## 4. Internet + the egress rule (important)

There are **two** independent layers here:

**(a) Baseline internet — does the cluster reach the internet at all?**
Yes, by default. A Multipass VM gets outbound internet via NAT through your Mac, and k3s pods get it via
Flannel's masquerade. `setup.k3s.sh` proves both: the VM (k3s install downloads from `get.k3s.io`) and a
throwaway pod (`wget` to the internet). The only common breaker is a **host VPN/corporate firewall**
mangling the VM's NAT — if the pod check fails, that's usually why.

**(b) The `allow-egress-internet-deny-internal` NetworkPolicy — what user pods may reach.**
Once k3s enforces netpols, this rule governs tenant pods: it allows egress to `0.0.0.0/0` **except** the
cluster's pod/service CIDRs — i.e. "the internet, but not other tenants / Postgres / Redis / MinIO."

> **⚠️ The CIDR catch.** Those `except` ranges come from `POD_CIDR` / `SERVICE_CIDR`, which still default
> to **docker-desktop's** values (`10.1.0.0/16`, `10.96.0.0/12`). **k3s uses `10.42.0.0/16` (pods) and
> `10.43.0.0/16` (services).** With the wrong (docker-desktop) values on k3s:
> - **Internet egress still works** — excepting `10.1/10.96` (which don't exist on k3s) doesn't block real
>   internet. So basic deploy + terminal internet access verify fine *without* changing anything.
> - **Internal isolation is WRONG** — the rule fails to carve out the real internal ranges (`10.42/10.43`),
>   so a tenant pod could reach Postgres/other tenants. **A tenant-isolation test would (correctly) fail.**
>
> So: verify the deploy + internet **first** (CIDRs don't matter for that). **Before validating tenant
> isolation, set `POD_CIDR=10.42.0.0/16` and `SERVICE_CIDR=10.43.0.0/16` in `env.mk`.**

## 5. CPU architecture (arm64) — and when multi-arch matters

Container images are CPU-arch-specific (an arm64 binary can't run on x86, and vice-versa). On an
**Apple-Silicon Mac** your images build **arm64**, and the Multipass VM is **arm64** too, so your current
images run in the local VM **unchanged** — no multi-arch needed.

Multi-arch (`docker buildx`, `linux/amd64,linux/arm64`) becomes necessary **only when the deploy target's
arch differs from your build arch** — e.g. building on arm64 but deploying to an **x86 cloud VM**. A
**Raspberry Pi is arm64**, so a Pi needs no multi-arch either. Decide this when you pick the prod box.

> Related gotcha: the `snapshot_job` builds a Docker image from the user's filesystem *at save time*, on
> whatever node runs it — so **saved images are arch-locked** to that node's arch. On a single-node
> cluster that's always one arch, so resume is fine; just don't move a saved image across arches.

## 6. Prod is the same script

Production is the *same* single-node k3s — run k3s (bundled bits disabled) on a self-owned cloud VM
(e.g. Hetzner CX22, ~€4/mo) or a Raspberry Pi, then the same `setup.sh`. The only legitimate
local-vs-prod differences: the `env.mk` values (creds/hosts/domain) and **TLS** (real domain +
Let's Encrypt in prod; self-signed / none locally).

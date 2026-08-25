# Claude Setup State
Stage: Full stack deployed to K3s and healthy. All 7 pods Running/1-1 (browseterm-server
scaled to 2/2 by HPA). Ingress external IP determined (192.168.252.200). Stale /etc/hosts
lines identified; ONE command given to user to fix them. Awaiting user to run it, then
proceeding to terminal E2E + save/snapshot E2E.
Status: IN_PROGRESS (waiting on user /etc/hosts edit, not blocked otherwise)

Fixes made this session (config-only, no submodule code edits):
- redis_ha REDIS_DATA_DIR Mac-vs-VM hostPath bug: see prior entry (kept for history) - changed
  REDIS_DATA_DIR to /tmp/browseterm-redis-data + pre-created dir inside VM via multipass exec.
- Transient issues during build-images.sh/deploy.k3s.sh run (NOT config bugs, self-resolved,
  noted for awareness only): browseterm-server image push failed 4x then succeeded on attempt
  5 (Docker Hub push flakiness); after full deploy, kubectl briefly got "no route to host" to
  the K3s API server (VM load spiked to 22 during builds) - resolved itself within ~30s;
  browseterm-server pod crashed once at startup with "could not translate host name
  browseterm-pg-service" (CoreDNS not ready yet) - self-healed on k8s restart; container-maker
  pod hung in ContainerCreating for 9+ min (image pull stalled during the network blip) - fixed
  by `kubectl delete pod` to force the Deployment to retry the pull, which then succeeded in
  ~90s. No config/script changes needed for any of these - all transient/self-healing.

Verified:
- Docker Desktop started, daemon up, registry authenticated as zim95 (credsStore=desktop)
- env.mk constructed; all secrets present (PG/Redis generated, MinIO matches manifest, OAuth
  real creds from /Users/reetunamah/browseterm/oauthsecrets)
- scripts/gen-env.sh run successfully; all 10 generated per-submodule env files gitignored
- Known gap (out of scope, not fixed): POD_CIDR/SERVICE_CIDR not plumbed to container-maker
  deployment env for k3s (only affects NetworkPolicy tenant isolation, not base function)
- Root = /Users/reetunamah/browseterm/browseterm-monorepo (git, branch main==origin/main, clean)
- Submodule HEADs == standalone sibling clone HEADs, all clean - no code changed this session
- Stale extra tree at /Users/reetunamah/projects/browseterm - untouched, correctly ignored
- deploy.k3s.sh (resumed, no --fresh) completed exit 0: namespace, gVisor RuntimeClass,
  ingress-nginx, MetalLB, MinIO, Postgres, DB schema/seed/NOTIFY triggers, DB secret, Redis,
  cert-manager CronJob+manual job+certs ready, all 6 images (cert-manager, container-maker,
  browseterm-server, socket-ssh, status-monitor, snapshot-job) built+pushed to docker.io/zim95,
  container-maker/browseterm-server/socket-ssh/status-monitor all deployed and rolled out
- kubectl get pods -n browseterm: browseterm-pg 1/1, browseterm-redis 1/1, minio 1/1,
  container-maker 1/1, socket-ssh 1/1, status-monitor 1/1, browseterm-server 2/2 (HPA) - all
  Running, no CrashLoopBackOff
- Ingress: browseterm-server-ingress (host browseterm.local.com) + socket-ssh-ingress (host
  socketssh.local), both class nginx, both ADDRESS 192.168.252.200
- HTTP smoke test: curl -H "Host: browseterm.local.com" http://192.168.252.200/ -> 302
  (login redirect) - frontend/server reachable and responding correctly
- socket-ssh: curl GET hangs/times out - EXPECTED, it's a raw ws-upgrade-only server with no
  HTTP GET handler (confirmed via server logs showing no request handler configured); not a
  routing bug, will be exercised properly by real WS E2E test later
- ICMP ping to 192.168.252.200 fails (filtered) but HTTP works fine - not an issue, just no ICMP

Current blocker:
- USER ACTION NEEDED (non-blocking to my progress, but required before E2E login test):
  /etc/hosts lines 15-16 are stale from old docker-desktop setup (192.168.0.3/192.168.0.4).
  Gave user this exact command to run themselves:
  sudo sed -i '' -e '15s/.*/192.168.252.200  browseterm.local.com/' -e '16s/.*/192.168.252.200  socketssh.local/' /etc/hosts

OAuth creds: real Google+GitHub creds in env.mk (from oauthsecrets file). NOTE: that file's
AUTH_REDIRECT_BASE_URI had :9999 (old docker-desktop convention); I used
http://browseterm.local.com (no port, K3s ingress model) instead. IF the OAuth apps' registered
redirect URIs still have :9999, login will fail with redirect_uri_mismatch until user updates
them in their provider console to:
  http://browseterm.local.com/google-login-redirect
  http://browseterm.local.com/github-login-redirect
Will find out for certain during OAuth E2E test (next step after /etc/hosts fix).

Next action:
- Once user confirms /etc/hosts updated (or I re-check the file myself and see it changed):
  verify DNS resolution + full page load in browser context is not possible for me directly,
  so I will curl-verify http://browseterm.local.com/ and http://socketssh.local/ resolve to
  192.168.252.200 via the actual hostname (not IP+Host header) as a proxy check, then hand off
  to user for the actual browser OAuth login step (unavoidable interactive browser action per
  mission), then continue verifying create-terminal -> gVisor pod -> WS/SSH -> commands ->
  disconnect/reconnect -> delete, then save/snapshot E2E.

Repo sync:
- monorepo submodules == standalone siblings (all main, clean) - unchanged this session, no
  code edits made to any submodule/standalone repo

Files changed:
- SETUP_TODO.md, CLAUDE_STATE.md (created/updated), env.mk (created, gitignored)

Environment:
- arch: arm64
- VM/IP: browseterm-k3s @ 192.168.252.2 (Ubuntu 24.04, 4cpu/8G/40G)
- kubectl context: browseterm-k3s (active)
- namespace: browseterm (deployed, healthy)
- METALLB_POOL: 192.168.252.200-192.168.252.250
- ingress external IP: 192.168.252.200 (confirmed via kubectl get svc -n ingress-nginx)
- required hosts mapping: 192.168.252.200 -> browseterm.local.com, socketssh.local (command
  given to user above; lines 15-16 of /etc/hosts, replacing stale 192.168.0.3/192.168.0.4)

Secrets still externally required:
- none currently blocking - OAuth creds present; only remaining risk is possible redirect URI
  mismatch in the provider console (see OAuth creds note above), to be confirmed at E2E time

Important findings:
- README K3s section confirms scripts/setup.k3s.sh + scripts/deploy.k3s.sh --fresh is the
  current recommended path (matches mission)
- deploy.k3s.sh requires kubectl context EXACTLY "browseterm-k3s" (hard preflight check)
- MinIO is the only storage backend now (README section 5); STORAGE_LAYER=minio in env.mk
- build-images.sh's docker-login shim avoided needing REPO_PASSWORD (Desktop already
  authenticated); individual submodule build.sh scripts (e.g. cert-manager's) print a cosmetic
  "Cannot perform an interactive login from a non TTY device" error but proceed fine since the
  credential store handles auth - confirmed non-fatal in practice
- Docker Hub pushes can be flaky under load (browseterm-server needed 5 attempts); K3s API
  server can briefly become unreachable ("no route to host"/TLS handshake timeout) when the VM
  is under heavy build load (load avg hit 22 on a 4-cpu VM) - both self-resolved without
  intervention except one `kubectl delete pod` to unstick a pod whose image pull stalled during
  the blip

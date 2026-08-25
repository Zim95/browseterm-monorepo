# BrowseTerm K3s Setup — Progress (2026-08-21 → 2026-08-24)

## STANDING CONVENTION — read before making any commit in this project
**Never add a `Co-Authored-By: Claude ...` trailer, a `Claude-Session:` line, or
any other AI-attribution text to a commit message in this project** (this
overrides the default commit-message template in Claude Code's own tool
instructions — that default does not apply here). The user explicitly asked
for this (2026-08-24): visible AI co-authorship in a repo's GitHub Contributors
list causes recruiters to immediately reject their profile when reviewing it.
**Verified 2026-08-24 exactly which commits already have this problem**
(`git log main --grep="anthropic.com" -i` in each repo): `browseterm-monorepo`
(1 commit, `a937b678`), `browseterm-server` (1 commit, `4623515`),
`browseterm-dockerfiles` (1 commit, `725c9461`) — all three from one earlier
session (`session_01UHNgF1gFBdZCUqbuu4Y67X`), all already pushed to `main`.
`container-maker`, `browseterm-db`, `socket-ssh`, `browseterm_workload` have
**zero** such commits despite many real commits made across this whole
multi-day session — the trailer was inconsistently added session-to-session,
not on every commit. Going forward (this note), no new commits will add it.
**Retroactive removal: done.** The user amended/rewrote those 3 commits
themselves (outside this session) and force-pushed — verified clean afterward
(`git log main --grep="anthropic.com" -i` now empty in all 3 repos, and local
`main` matches `origin/main` with no divergence in any of them, confirming the
force-push landed). The only remaining piece is GitHub's own Contributors-graph
cache catching up to the rewritten history, which can lag after a force-push —
being handled outside this session, not something to chase further here. If
Claude still shows up in a repo's Contributors list after this, it's very
likely just that cache lag, not a sign the rewrite didn't take — re-check
`git log --grep="anthropic.com" -i` on that repo's `main` before assuming
otherwise.

## Where things stand (as of 2026-08-24 early afternoon — root cause of "disk I/O contention" finally found)
**The recurring "host disk I/O contention" documented all across this multi-day
session was misdiagnosed.** It is NOT Time Machine or Spotlight (both were
"leading suspects but not conclusively pinned down" in every earlier writeup) —
it's **host memory oversubscription causing heavy macOS swapping**. Confirmed via
`sudo fs_usage -w -f filesys 1`: the dominant disk activity during a contention
episode is `PgIn[S]` (page-in) against `/System/Volumes/VM/swapfileN`, not any
backupd/mdworker file access. Confirmed via `vm_stat`/`sysctl vm.swapusage`/`top`:
swap was 93% full (14.3GB used / 15.36GB total) and the Multipass VM's host-side
`qemu-system-aarc` process alone was RSS 15GB — on a Mac with ~7.5GB physical RAM
(`multipass info` shows the VM's own *guest-side* usage is a modest 2.1GB out of
its 7.7GB allocation; the bloat is in QEMU's host-side footprint, likely from the
15.2GB backing disk image being memory-mapped and counted toward RSS). Chrome
(many helper processes, several hundred MB–1.5GB each) was also a large
contributor on top of that. **This fully explains why episodes recurred and
worsened despite two targeted fixes applied this session** (Time Machine
exclusion via `tmutil addexclusion` on `/var/root/Library/Application Support/
multipassd`, confirmed via `tmutil isexcluded` → `[Excluded]`; and a
`.metadata_never_index` marker file dropped in that same directory after
`mdutil -i off` errored "unknown indexing state" even with Full Disk Access
granted, confirming that path isn't a distinct indexable volume) — **neither
fix addresses the real cause**, so don't expect them to prevent recurrence; keep
them (harmless, and do stop the VM's own disk image from bloating a real Time
Machine backup) but don't rely on them. **Next session: check swap pressure
(`sysctl vm.swapusage`, `top -l 1 -o mem`) before touching the cluster at all,
and free RAM (close Chrome tabs/apps, or `multipass restart browseterm-k3s` to
reset QEMU's host-side RSS) if swap is anywhere near full** — this is now the
first thing to check, ahead of the old iostat/backupd playbook below (which
still correctly identifies *that* something host-side is wrong, just not *what*).

**Also found and fixed live this session: a real concurrency bug in
`container-maker`'s shared Kubernetes client.** `KubernetesResourceManager.client`
(`container-maker/src/resources/__init__.py`) is a single class-level
`CoreV1Api()` singleton shared by every resource manager (`PodManager`,
`NamespaceManager`, `JobManager`, etc.) across container-maker's threaded gRPC
server. `PodManager.run_command`/`run_command_with_stream`
(`container-maker/src/resources/pod_manager.py`) use `kubernetes.stream.stream()`
for pod-exec, which works by monkey-patching the underlying `ApiClient.request`
method to route through the websocket handshake code path for the duration of
the call, then restoring it in a `finally` block. Because the client is shared
across threads, if an exec-handling thread is ever killed mid-call (very
plausible given this session's repeated disk-I/O-driven pod evictions/SIGKILLs),
the `finally` restore never runs and the shared client's `request` method stays
permanently swapped to the websocket path — breaking every subsequent *plain*
REST call (confirmed live: `NamespaceManager.get()`'s `read_namespace()` failed
twice in a row with `websocket._exceptions.WebSocketBadStatusException:
Handshake status 200 OK` — a real 200 response from the K8s API being
misinterpreted as a failed websocket upgrade). This breaks the **Save button
too**, not just the reaper (both call the same `NamespaceManager.get()` early in
`KubernetesContainerManager.save()`). Confirmed the diagnosis by restarting the
`container-maker` deployment (`kubectl rollout restart deployment/container-maker`)
mid-episode — this resets the in-memory client state — and a retried reaper run
immediately got past the same call that had failed twice before the restart.
**Not yet fixed in code** — the correct fix is to stop sharing a single
`ApiClient`/`CoreV1Api` instance across threads doing pod-exec, e.g. construct a
fresh `CoreV1Api()` inside `run_command`/`run_command_with_stream` for the
`stream()` call instead of reusing `cls.client`. Worth doing before the next
real incident, since a killed exec thread is a "when," not "if," given this
project's disk-contention history. **Workaround if it recurs before the code fix
lands**: `kubectl rollout restart deployment/container-maker -n browseterm`.

## Where things stand (as of 2026-08-24 late morning)
**Reaper CronJob now deployed to the cluster** (was previously code-only). Created
`browseterm_workload/reaper/env.mk` (gen-env.sh doesn't fan one out for this
submodule yet — built it by hand from the root env.mk + the same
`CONTAINER_MAKER_HOST=container-maker-service`/`PORT=50052` values
`browseterm-server` already uses, since `browseterm-db-credentials` and
`container-maker-service-certs` secrets already existed in-cluster). Ran
`make dev_setup` from `browseterm_workload/reaper/` — ServiceAccount/Role/
RoleBinding/CronJob all applied cleanly (`zim95/reaper:latest` already existed on
Docker Hub from an earlier session, no rebuild needed).

**Hibernation test started but currently blocked by disk I/O contention.**
Simulated idleness on the one real running terminal (`namah_ssh_ubuntu_test`,
container id `473f769c-4e5f-48ca-9a33-b572434bab63`, pod
`namah-ssh-ubuntu-test-pod-1787379278`) via direct SQL
(`UPDATE containers SET last_active_at = now() - interval '8 days' WHERE id=...`),
then manually triggered a reaper run instead of waiting for the hourly schedule
(`kubectl create job reaper-manual-test-1 --from=cronjob/reaper -n browseterm`).
That job's pod has been stuck in `ContainerCreating` for 15+ minutes pulling its
own small (~343MB) image — **not a hung pull, host disk I/O contention recurring
yet again**, same signature as documented below (`kubectl describe` hit a TLS
handshake timeout outright), but this time it did **not self-resolve after 10-15
min like earlier "brief" episodes** — VM loadavg climbed from ~5 to ~14 across
three checks 5 minutes apart instead of declining. **This is now the third
contention episode in one session** (two earlier this morning during the initial
health check, both under 5 min; this one ongoing 15+ min and worsening) — treating
the recurring-risk note below as confirmed, not hypothetical.
**Asked the user to grant Terminal.app Full Disk Access** (System Settings →
Privacy & Security → Full Disk Access) so the previously-blocked
`sudo tmutil addexclusion -p "/var/root/Library/Application Support/multipassd"`
can finally run — **in progress as of this writing, waiting on the user to
complete the GUI step**; the hibernation test (job `reaper-manual-test-1`, still
present in the cluster) will resume once either the exclusion is applied or
contention naturally clears, whichever comes first.

## Where things stand (as of 2026-08-24 early morning)
Full stack is deployed and running on a single-node K3s cluster (Multipass VM
`browseterm-k3s` @ 192.168.252.2). **Full terminal E2E verified working** (OAuth →
create → Pending→Running → WebSocket → SSH as UID-0 login user → package installs
work → idle sessions survive) and **save/snapshot E2E verified working** (Save →
snapshot → MinIO → Job → Docker build/push → DB update → SSE to UI) as of the
2026-08-22/23 sessions. All code across all repos touched through 2026-08-23
(monorepo + `browseterm-dockerfiles`/`browseterm-server`/`container-maker`/
`socket-ssh`/`browseterm_workload`) was committed and pushed by that point.

**This session's core fix — a save could get permanently stuck showing "Saving…"
forever, now fixed and deployed.** Root cause: if a snapshot Job's pod is killed
outright (node eviction, OOM, the same host disk I/O contention documented below),
the Job's own process never gets to run its except-block DB write, so `save_status`
is stuck at `Running` with nothing left to ever resolve it — the frontend was
correctly, faithfully displaying a spinner for a save that would never finish.
Fixed with a **save-status reconciler** now running as a background thread inside
`container-maker` (checks the real Kubernetes Job state per stuck row rather than
guessing a timeout — see `container-maker/src/resources/save_reconciler.py`),
plus a real bug found along the way in `browseterm-db`'s `ContainerOps.update()`
that silently dropped any field explicitly set to `None` (breaking `save_error`
clearing). Both fixed, unit-tested (20 new passing tests across the two repos,
run against a throwaway local Postgres + fully mocked k8s client — see git log for
`browseterm-db`/`container-maker`), deployed to the cluster, and **confirmed live**:
the reconciler thread starts, connects to Postgres, and its sweep loop runs clean
with no errors. **Not yet observed recovering a real stuck save end-to-end** — the
one row that demonstrated the bug this session was fixed manually via direct SQL
*before* the reconciler was deployed, so there's currently nothing stuck to prove
the recovery path against live; a fresh save that gets orphaned again (or a
deliberately-forced one, e.g. killing a snapshot Job's pod mid-run) is needed to see
it in action. All 4 affected repos (`browseterm-db`, `container-maker`,
`browseterm-server`, `socket-ssh`) + the monorepo submodule pointers are committed
and pushed — see "Code changes made" below for exact commits.

**Also fixed this session: HPA pinned to 1 replica everywhere.** Directly observed
HPA scaling `browseterm-server` up to 4 replicas *during* a disk-I/O contention
episode (health-check timeouts read as CPU/memory pressure), which added more
scheduling/restart load to the same starved 4-core node rather than adding real
capacity — worsening exactly the problem it was reacting to. `browseterm-server-hpa`
and `socket-ssh-hpa` are now both pinned `minReplicas: 1, maxReplicas: 1` in the
source YAMLs (not just live-patched) until this runs on real multi-node capacity.

**Host disk I/O contention recurred this session** (same pattern as documented
below — Mac disk0 at 200-550 MB/s, `backupd`/Spotlight `mdworker_shared` active,
`kubectl` TLS handshakes timing out, CoreDNS itself restarting from health-check
timeouts) and took **over 35 minutes** to settle this time (previously self-resolved
in a couple minutes) — this is worth taking seriously as a recurring operational
risk, not a one-off. Attempted `tmutil addexclusion`/`mdutil -i off` on Multipass's
VM disk directory (`/var/root/Library/Application Support/multipassd`) to stop
Time Machine/Spotlight from churning through it, but `tmutil` needs Full Disk
Access granted to Terminal.app first (System Settings → Privacy & Security → Full
Disk Access) — **not yet done, user needs to grant this via GUI then retry**;
`mdutil` errored "unknown indexing state" on that path (may not be a distinct
indexable Spotlight volume, not chased further). **First thing to check next
session:** is disk I/O calm (`iostat -d 1 3` near ~40MB/s idle baseline, no
`backupd`/`mdworker_shared` churning)? If not, see the detection playbook further
down before touching the cluster.

**Not yet started: hibernation/reaper testing and pod-crash-simulation testing**
— explicitly requested, explicitly deferred to tomorrow by the user (see "Pending"
below for the existing investigation/test plan) — the reaper CronJob exists in code
(`browseterm_workload/reaper/`) but was never deployed to this cluster.

- App: http://browseterm.local.com
- Socket: ws://socketssh.local
- Both resolve via `/etc/hosts` → 192.168.252.200 (ingress-nginx LoadBalancer IP,
  MetalLB pool 192.168.252.200-250)
- kubectl context: `browseterm-k3s`, namespace `browseterm`
- `container-maker`'s `pyproject.toml` pins `browseterm-db` as a **git dependency**
  (`rev = "main"`), and `poetry.lock` further pins it to a **resolved commit SHA**
  — pushing a `browseterm-db` fix to GitHub is NOT enough by itself for
  `container-maker`'s next Docker build to pick it up; must also run
  `poetry update browseterm-db` inside `container-maker/` to refresh
  `poetry.lock`'s `resolved_reference` before rebuilding. Learned the hard way this
  session (first rebuild silently shipped the old `browseterm-db` despite the fix
  already being on GitHub).

## What we did today
1. Built the aggregated root `env.mk` from scratch (Postgres/Redis passwords
   generated, MinIO creds matched to the hardcoded dev manifest, real Google/GitHub
   OAuth creds pulled from `~/browseterm/oauthsecrets`), fanned out via
   `scripts/gen-env.sh` to all 10 submodules.
2. Provisioned the K3s VM (`scripts/setup.k3s.sh`), corrected `METALLB_POOL` to the
   VM's actual subnet (192.168.252.x, not the doc default 192.168.64.x).
3. Ran `scripts/deploy.k3s.sh`. Hit and fixed one real bug along the way:
   - **Redis PV bug**: `redis_ha`'s setup script does `mkdir` on the *invoking host*
     (a docker-desktop-era assumption), but the K8s hostPath PV needs the dir on the
     K3s *node* (a separate VM under Multipass). Fixed by setting
     `REDIS_DATA_DIR=/tmp/browseterm-redis-data` and pre-creating that path inside
     the VM directly. Config-only fix, no script edits.
4. All images built and pushed to `docker.io/zim95/*`; all services
   (container-maker, browseterm-server, socket-ssh, status-monitor) deployed and
   rolled out successfully. A couple of transient Docker Hub push failures and a
   few brief K3s API/VM connectivity blips happened over the course of the day
   (under heavy build/pull load) and always self-resolved within seconds to a
   couple minutes — not config issues, just needed a retry. If you hit
   `no route to host` / `TLS handshake timeout` / `multipass exec` timeouts, check
   `multipass exec browseterm-k3s -- cat /proc/loadavg` and just retry once it's
   back down (well under the VM's 4 cores).
5. Determined ingress external IP (192.168.252.200) and gave the user the exact
   `/etc/hosts` command to fix two stale docker-desktop-era entries. User ran it.
6. **Bug #1 — OAuth login bounced back to /login after a successful Google login.**
   Root cause: `browseterm-server/infra/deployment/deployment.yaml` (the prod
   manifest K3s uses) hardcoded `COOKIE_SECURE=true`/`COOKIE_SAMESITE=strict`,
   which only works behind HTTPS. Our local ingress is plain HTTP, so the browser
   silently dropped the session cookie after every login (the session itself was
   being created correctly in Redis the whole time — confirmed via direct Redis
   inspection). Fixed properly, not just patched: templated `${COOKIE_SECURE}` /
   `${COOKIE_SAMESITE}` into the manifest like every other config value in that
   file, threaded through `deployment-setup.sh` (new positional args 25/26),
   `Makefile`'s `prod_setup` target, and `gen-env.sh`, with real values living in
   `env.mk` (`false`/`lax` locally; a real HTTPS prod deploy would set
   `true`/`strict` in its own `env.mk` — no code change needed for that). **Verified
   fixed** — user logged in successfully after this.
7. **Bug #2 — "Error creating container": gRPC TLS handshake failure
   (CERTIFICATE_VERIFY_FAILED) between browseterm-server and container-maker.**
   Root cause: `cert-manager`'s job mints two separate CA/leaf cert bundles into
   two different secrets (`container-maker-service-certs` for prod,
   `container-maker-development-service-certs` for dev — confirmed via differing
   SHA-256 fingerprints). `container-maker`'s deployment (via `prod_setup`, which
   is what K3s uses) hardcodes the prod-named secret for its own server identity,
   but `env.mk`'s `CONTAINER_MAKER_CERTS_SECRET_NAME` pointed browseterm-server's
   client trust bundle at the dev-named one instead. Fixed by pointing `env.mk` at
   `container-maker-service-certs` to match what container-maker actually uses.
   **Verified fixed** — container creation succeeded after this.
8. User asked whether HPA got removed and pushed back on weakening prod manifests
   for local convenience. Confirmed HPA/PDB were never touched (still live,
   `browseterm-server-hpa` correctly scaled back to 1/1 after build load passed).
   Explained the templating approach doesn't weaken the prod manifest — a real
   HTTPS deploy gets identical secure behavior via its own `env.mk`. User confirmed:
   keep prod manifests + templated values (current approach), don't switch to
   `development.yaml` for local (that manifest has no HPA/PDB at all).
9. **Bug #3 — terminal pod reaches Running but the UI status stayed stuck on
   "creating"/"pending".** Root cause: `status_monitor` DID correctly update the DB
   (`containers.status` → `RUNNING`, confirmed directly in Postgres) and the
   Postgres `NOTIFY` trigger DID fire, but `browseterm-server/src/status_listener.py`
   crashed handling it — `_handle_status_change` (and identically
   `_handle_save_status_change`) called `logger.info(..., extra={"name": ...})`,
   and `"name"` collides with Python's built-in reserved `LogRecord.name` attribute,
   raising `KeyError` and aborting before the update ever reached the SSE broadcast
   to the browser. Fixed both call sites (renamed the extra-dict key to
   `"container_name"`), rebuilt + pushed the `browseterm-server` image, forced the
   K3s node to re-pull it (had to manually `crictl rmi` the stale `:latest` on the
   node since `imagePullPolicy: IfNotPresent` won't re-check a reused tag). **Verified
   fixed** — a real terminal creation went Pending→Running in the UI correctly.
10. **Bug #4 — WebSocket connection to the terminal failed outright ("failed to
    connect to websocket server").** Root cause: same "prod config assumes HTTPS"
    pattern as bug #1. `socket-ssh` validates the WS handshake's `Origin` header
    against an allowlist; its prod deployment uses `ALLOWED_ORIGINS_PROD`, which
    `gen-env.sh` had hardcoded to `https://${INGRESS_HOST}`. Our actual origin is
    `http://browseterm.local.com`, so every handshake was rejected
    (`socket-ssh` logs: `"Rejected connection from disallowed origin"`). Fixed by
    deriving `ALLOWED_ORIGINS_PROD` from `AUTH_REDIRECT_BASE_URI` (the app's real
    scheme+host) instead of hardcoding a scheme — self-corrects for a real HTTPS
    prod env.mk too. **Verified fixed** — WS connected and an interactive SSH
    session was established (`*** SSH CONNECTION ESTABLISHED ***`), commands ran.
11. **Bug #5 — inside a working SSH session, `sudo apt-get install vim` (and even
    plain `apt-get install`) failed**: `sudo: sudo must be owned by uid 0 and have
    the setuid bit set` / permission denied on the dpkg lock. Traced this all the
    way down (file perms on the real sudo binary were correct — `4755 root:root` —
    so it wasn't a filesystem issue) to a **permanent, by-design gVisor limitation**:
    gVisor's sentry does not implement setuid-on-exec at all
    ([google/gvisor#5299](https://github.com/google/gvisor/issues/5299)) — a
    deliberate part of its security model ("a child can never gain more privilege
    than its parent"), not a bug that will get patched. The entrypoint already did
    `usermod -aG sudo $SSH_USERNAME`, which can't help — sudo's own binary
    self-check fails before it ever checks group membership. Since `SSH_USERNAME`
    is a personalized per-user login name generated by the frontend (not just
    "ubuntu"), the fix preserves that while eliminating the need for privilege
    escalation entirely: in `browseterm-dockerfiles/ubuntu_setup/ubuntu.entrypoint.sh`,
    the login user is now created as a **UID-0 alias** (`useradd -u 0 -o`) — same
    personalized username/home dir, genuinely root, so package installs work
    directly with no escalation needed — plus a `sudo` passthrough shim at
    `/usr/local/bin/sudo` (ahead of the real one in `$PATH`) so `sudo <cmd>` keeps
    working identically for anyone who types it out of habit. Image rebuilt and
    pushed (`zim95/ssh_ubuntu:latest`), node's cached copy cleared via
    `crictl rmi`. **NOT YET VERIFIED** — the terminal that was live-tested predates
    this image, so a brand new terminal is needed to confirm. **Do this first
    tomorrow.** Security note for awareness: every terminal session's login user is
    now root *inside its own gVisor-sandboxed pod* — isolation between different
    users is unaffected (still enforced by the pod/gVisor/per-user-namespace
    boundary), there's just no longer an in-container non-root/root distinction for
    a single user's own session.
12. Cleaned up the leftover test terminal from earlier debugging: deleted the pod
    (`namah-ssh-ubuntu-test-pod-1787335065`) from K8s and soft-deleted its DB row
    (`containers.deleted_at` set, matching the app's own soft-delete convention —
    no hard row delete). Explained to the user exactly how the app's real two-step
    delete flow works (`KubernetesContainerManager.delete` in container-maker:
    pod → service → ingress, hierarchical, then a separate lingering-namespace
    sweep that skips per-user namespaces; browseterm-server's own two-step API is
    `POST /delete-container-in-k8s` then `POST /delete-container-in-db`) so the
    manual cleanup mirrored it.
13. (Aside, off-project) Quit a few idle Mac apps (Notes, Calendar, System Settings,
    Activity Monitor) to free memory, per request — Chrome/Terminal/WhatsApp and the
    K3s VM/this session were left untouched.

## Code changes made (not yet committed)
`browseterm-server/` (monorepo submodule checkout):
- `infra/deployment/deployment.yaml` — COOKIE_SECURE/COOKIE_SAMESITE templated
- `scripts/deployment/deployment-setup.sh` — accepts 2 new positional args
- `Makefile` — `prod_setup` target passes the 2 new args
- `src/status_listener.py` — fixed the reserved-key logging bug (2 call sites)

`browseterm-dockerfiles/` (monorepo submodule checkout):
- `ubuntu_setup/ubuntu.entrypoint.sh` — UID-0-alias login user + sudo shim (bug #5)

Config-only, monorepo root: `env.mk` (COOKIE_SECURE/COOKIE_SAMESITE added,
CONTAINER_MAKER_CERTS_SECRET_NAME corrected), `scripts/gen-env.sh` (fans the 2 new
cookie vars into browseterm-server's env.mk; ALLOWED_ORIGINS_PROD now derived from
AUTH_REDIRECT_BASE_URI instead of hardcoded https://).

**Not yet synced**: the standalone sibling clones at
`/Users/reetunamah/browseterm/browseterm-server` and
`/Users/reetunamah/browseterm/browseterm-dockerfiles` are on the same base commits
but do NOT have these changes (monorepo submodule working trees only, uncommitted).
Needs reconciling before calling this done.

**Noise to ignore / do not commit as-is**: `browseterm-db` shows 13 deleted
migration files + 1 new consolidated one. This is expected, by-design behavior of
`browseterm-db/init.py`'s `--fresh` path (`migrator.reset_migrations()` then
`migrator.revision('Initial migration')`), not something either of us did
deliberately or a bug — but don't commit it, it's a throwaway artifact of the local
fresh-init and would happen again identically for anyone else running `--fresh`.
`git checkout` it before any real commit in that repo.

## What we did today (cont'd, 2026-08-22 morning)
14. **Bug #6 — "Submission Error: Unexpected token '<'" when creating a terminal.**
    Root cause: container-maker's `POD_UPTIME_TIMEOUT` (default 80s in
    `container-maker/src/resources/resource_config.py:79`, used by
    `pod_manager.py`'s `poll_status`) was shorter than the real pod startup time.
    The user pod's `V1Container` spec never set `image_pull_policy`
    (`pod_manager.py:889-900`), so with the `:latest` tag Kubernetes defaulted it
    to `Always` — every terminal creation re-checked/re-pulled
    `zim95/ssh_ubuntu:latest` from Docker Hub from scratch, taking ~88-105s on
    this VM. Container-maker gave up at 80s and threw `TimeoutError`, which
    surfaced as a 500, and on retry nginx's own 60s proxy timeout fired first and
    returned an HTML 504 page; the frontend's `handleFormSubmit`
    (`browseterm-server/templates/static/js/terminals.js:890+`) calls `.json()`
    on the response without a content-type check, so parsing the HTML threw
    `SyntaxError: Unexpected token '<'`. The pod itself was actually fine and
    became `Running` shortly after container-maker had already given up — leaving
    an orphaned pod with no matching `kubernetes_id`/`ip_address` in the DB. Fixed
    by bumping `POD_UPTIME_TIMEOUT` to 180.0 and explicitly setting
    `image_pull_policy="IfNotPresent"` on the user pod spec (a real image update
    is still picked up via the documented `crictl rmi` step). Rebuilt + pushed
    `zim95/container-maker:latest`, node picked up the new digest automatically
    this time (`IfNotPresent` on container-maker's own deployment did notice the
    tag change). **Verified the fix landed** by grepping the running pod's
    `/app/src/resources/*.py` for the new values — **not yet verified against a
    real terminal creation**, that's the next thing to test. Cleaned up two
    orphaned pods and one orphaned DB row (`namah_ssh_ubuntu_test`,
    `kubernetes_id`/`ip_address` both NULL) left over from the failed attempts.

## Code changes made (not yet committed) — cont'd
`container-maker/` (monorepo submodule checkout):
- `src/resources/resource_config.py` — `POD_UPTIME_TIMEOUT` 80.0 → 180.0
- `src/resources/pod_manager.py` — user pod spec now sets
  `image_pull_policy="IfNotPresent"` explicitly (was previously unset, defaulting
  to `Always` for the `:latest` tag)

## What we did today (cont'd)
15. **Bug #7 — fresh terminal connects via WebSocket fine but SSH itself fails:
    "Error: All configured authentication methods failed".** Root cause: a
    side-effect of yesterday's bug #5 fix. `socket-ssh` authenticates
    exclusively by password (`socket-ssh/src/socketSSH/socketSSHClient.js` →
    ssh2's `Client.connect()`, no `privateKey` ever set), and Ubuntu's
    `openssh-server` default `PermitRootLogin prohibit-password` blocks
    *password* auth for any UID-0 account regardless of username — which the
    login user now is (bug #5 made it a UID-0 alias so sudo/apt-get work under
    gVisor). Confirmed directly on a live pod: `id namah_shrestha` →
    `uid=0(root)`, and `/etc/ssh/sshd_config` had `PermitRootLogin` left
    commented out (never touched anywhere in `browseterm-dockerfiles/`), so it
    fell back to that default. Fixed by appending `PermitRootLogin yes` to
    `/etc/ssh/sshd_config` at the end of
    `browseterm-dockerfiles/ubuntu_setup/ubuntu.entrypoint.sh` (right before
    `sshd -D` starts) — consistent with the already-accepted security model that
    this account's root-ness is confined to its own gVisor-sandboxed pod.
    Rebuilt + pushed `zim95/ssh_ubuntu:latest`, cleared the node's cached copy.
    **Not yet verified** — needs a fresh terminal (old one predates the fix) and
    the user was asked to delete the stale one through the UI itself (also
    exercises the still-unverified real delete flow) then create a new one and
    try connecting.

## Code changes made (not yet committed) — cont'd
`browseterm-dockerfiles/` (monorepo submodule checkout):
- `ubuntu_setup/ubuntu.entrypoint.sh` — appends `PermitRootLogin yes` to
  `/etc/ssh/sshd_config` before starting sshd (bug #7, on top of bug #5's
  UID-0-alias change)

## What we did today (cont'd, again)
16. **Bug #8 — "Save failed: 500 ... invalid literal for int() with base 10:
    'browseterm'" on the first real save/snapshot attempt.** Root cause found to
    be much bigger than the error message suggested: container-maker's *entire*
    deployed env-var block from `REPO_PASSWORD` onward was shifted by one
    position — not just `DB_PORT`. `container-maker/env.mk` has
    `REPO_PASSWORD=` (empty — no Docker Hub password needed locally), and
    `container-maker/Makefile`'s `prod_setup`/`dev_setup` recipes passed
    `$(REPO_PASSWORD)` **unquoted** among 11 other positional args to
    `k8s-development-setup.sh`. Make expands an empty variable to nothing (not
    an empty string token), so that shell word vanished entirely and every
    argument after it silently shifted one position left. Confirmed via
    `kubectl get deploy container-maker -o yaml`: not just `DB_HOST`/`DB_PORT`
    were swapped, but `INGRESS_HOST`, `STORAGE_LAYER`, `MINIO_ENDPOINT`,
    `MINIO_BUCKET`, `MINIO_SECURE`, `DB_USERNAME` were all one slot off too
    (`DB_DATABASE` ended up empty, having nothing left to shift into it) — e.g.
    live `MINIO_SECURE` held the Postgres hostname, live `INGRESS_HOST` held the
    string `"minio"`. This meant container-maker's direct Postgres/MinIO access
    (used only by the save/snapshot path, not pod creation/polling which goes
    through the k8s API + gRPC instead) has likely been broken since whenever
    this deployment was first applied — explains why "Save/snapshot E2E entirely
    untested" sat unverified for so long. Fixed by quoting every `$(...)` in
    both Makefile recipes (`"$(REPO_PASSWORD)"` etc.), matching the setup
    script's own `${9:-}`-style expectation that each position exists even when
    empty. Checked the sibling services (`browseterm-server`, `socket-ssh`) —
    neither references `REPO_PASSWORD` in their setup calls, so this was
    isolated to `container-maker`. Re-ran `make prod_setup` from
    `container-maker/`; **verified fixed** by exec'ing into the newly-rolled pod
    directly (by exact pod name, not `deployment/container-maker` — that
    selector kept resolving to the still-terminating old pod during rollout and
    gave a false negative on the first check) and confirming all 9 env vars now
    hold their correct values. **Not yet verified against a real Save click** —
    that's the next thing to test; no cleanup needed first, the terminal being
    saved is a valid running container, only the save operation itself failed.

## Code changes made (not yet committed) — cont'd
`container-maker/` (monorepo submodule checkout):
- `Makefile` — quoted every positional arg in `dev_setup`/`prod_setup` recipes
  (bug #8: an empty unquoted `$(REPO_PASSWORD)` was silently dropping a shell
  word and shifting 8 other env vars by one position in the live deployment)

## What we did today (cont'd, yet again)
17. **Bug #8 follow-up — after the shift-by-one fix, Save then failed with
    "REPO_NAME or REPO_PASSWORD is not set".** Not a bug, a real missing
    credential: `container-maker/src/resources/pod_manager.py:409` requires
    both before it will build+push a snapshot image (used only for the
    save/snapshot Job's `docker login` against Docker Hub, in
    `browseterm_workload/snapshot_job/src/snapshot_builder.py:210` — never
    needed for image *pulls*, which stay public/unauthenticated). Root
    `env.mk`'s `REPO_PASSWORD` had always been left blank. Asked the user how
    they wanted to provide it; user pointed to `~/browseterm/dockercreds`
    (repo=username=zim95, a real Docker Hub account password rather than a
    Personal Access Token — flagged that a PAT is Docker Hub's recommended
    credential for this kind of automation, per `tests/README.md:55-56` in
    container-maker, but user chose to proceed with the password from that
    file as-is). Set `REPO_PASSWORD` in the root `env.mk`, ran
    `./scripts/gen-env.sh` to fan it out (confirmed it landed correctly in
    `container-maker/env.mk`), re-ran `make prod_setup`, and verified on the
    new pod that both `REPO_NAME`/`REPO_PASSWORD` are now set (checked
    presence only, didn't echo the value back). **Not yet verified against a
    real Save click** — that's next.

## What we did today (cont'd, yet again x2)
18. **Bugs #5/#7 confirmed fixed via real usage**: user connected to a
    brand-new terminal, landed as root (`root@namah-ssh-ubuntu-test-pod-...#`),
    and `socket-ssh` logs since 06:15 (post bug #7 fix) show clean
    "SSH shell acquired successfully" on every session — the
    "All configured authentication methods failed" error only appears in logs
    from *before* the fix (05:27ish). No more action needed on these two.
19. Save/snapshot E2E is now progressing well past where it used to fail:
    filesystem snapshot created (~52s for a small pod) → uploaded to MinIO →
    snapshot Job created and started (currently pulling the 1.11GB
    `zim95/snapshot-job:latest` image on the node, same "first pull is slow on
    this VM" pattern as bugs #6/#8 — not a new issue, just needs time).
20. **Bug #9 — user asked "why does my connection close automatically,
    is it my network?"** It wasn't network-related: `socket-ssh` never sends
    any WebSocket ping/pong keepalive (confirmed: zero matches for
    `ping`/`pong`/`timeout`/`keepalive` anywhere in `socket-ssh/src`), and
    `socket-ssh-ingress` had no `proxy-read-timeout`/`proxy-send-timeout`
    annotations, so it fell back to nginx-ingress's default 60s idle timeout.
    Every logged session disconnect (23s-101s range, across many sessions
    today, not just during Save) fit this pattern exactly. Fixed by adding
    `nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"` and
    `proxy-send-timeout: "3600"` to the Ingress annotations in both
    `socket-ssh/infra/deployment/deployment.yaml` (prod, used here) and
    `socket-ssh/infra/development/development.yaml` (dev, same issue, fixed
    for consistency even though unused locally). Applied via
    `cd socket-ssh && make prod_setup`; **verified live** —
    `kubectl get ingress socket-ssh-ingress -o jsonpath='{.metadata.annotations}'`
    shows both set to 3600. This raises the ceiling to 1h but doesn't add a
    real keepalive — a long-idle-then-active session could still be flaky if a
    single gap exceeds 1h; a proper WS ping/pong in `socket-ssh` would be the
    more robust long-term fix if this resurfaces.

## Code changes made (not yet committed) — cont'd
`socket-ssh/` (monorepo submodule checkout):
- `infra/deployment/deployment.yaml` — added `proxy-read-timeout`/
  `proxy-send-timeout: "3600"` annotations to `socket-ssh-ingress` (bug #9)
- `infra/development/development.yaml` — same fix on the dev-path ingress

## What we did today (cont'd, yet again x3)
21. **Bug #8 fully verified — save/snapshot E2E now works end to end.** The
    Job that was mid-pull at last check completed all 8 steps cleanly:
    unpack snapshot tar -> generate Dockerfile -> `docker build` -> tag ->
    `docker login` (now succeeds with real creds) -> push to
    `docker.io/zim95/...` -> cleanup local images -> record success in DB.
    Final DB state: `save_status='Succeeded'`,
    `saved_image='zim95/namah-ssh-ubuntu-test-pod-1787379278-image:latest'`.
    (Minor leftover cosmetic issue, not fixed: `save_error` still holds the
    *previous* failed attempt's error text even though this attempt succeeded
    — the snapshot Job's success path never clears the old error column. Not
    user-visible since the frontend only reads `save_error` when
    `save_status==='Failed'`, but worth a follow-up cleanup.)
22. **Bug #10 — user reported the Save button resets to its default state on
    page reload, even mid-save, misleadingly implying the save never
    started.** Root cause: the DB's `save_status`/`saved_image`/`save_error`
    were never missing (`browseterm-db`'s `Container.to_dict()` always
    included them, and `list_user_containers`/`get_container` in
    `browseterm-server/src/db_ops/container_db_ops.py` surfaced them fine) —
    the bug was narrowly in `browseterm-server/src/template_handlers.py`'s
    `terminalpage` route, which manually rebuilt a `terminal_info` dict
    field-by-field for the page template and simply never copied those three
    fields across. On the frontend, `terminalpage.js`'s `setSaveSpinner()` was
    only ever called from the click handler and the live SSE stream
    (`setupSaveStatusStream()`, itself working correctly and unaffected) —
    nothing seeded the button's state from the initial page-load data even if
    it had been present. Fixed both: added `saveStatus`/`savedImage`/
    `saveError` to the `terminal_info` dict in `template_handlers.py`
    (~line 108), and added a check in `terminalpage.js`'s `loadTerminalInfo()`
    that calls `setSaveSpinner(true)` when `terminalInfo.saveStatus` is
    `'Pending'` or `'Running'` on load - the existing SSE subscription then
    naturally resolves it to Succeeded/Failed whenever that actually happens,
    same as it already does for saves started in the current session. Traced
    the full data path end-to-end first (`Container.to_dict()` ->
    `ContainerOps` -> `container_db_ops.py` -> template context -> `tojson` in
    `terminalpage.html:141` -> `window.terminalInfo` -> `getTerminalInfoFromTemplate()`)
    to confirm no other link was broken. Rebuilt + pushed
    `zim95/browseterm-server:latest`, redeployed **after** bug #8's save had
    already succeeded (per user's explicit instruction to not disrupt the
    in-flight save). **Not yet verified in the browser** — reload the
    terminal page next time a save is in progress (or right after this one)
    and confirm the button correctly shows "Saving…" instead of resetting.

## Code changes made — cont'd (ALL of the below, plus everything above, is now
## committed AND pushed to GitHub on every repo's `main` branch — verified via
## `git log origin/main..main` showing empty on all 5 repos as of session end)
`browseterm-server/` (monorepo submodule checkout):
- `src/template_handlers.py` — `terminal_info` dict now includes `saveStatus`/
  `savedImage`/`saveError` (bug #10)
- `templates/static/js/terminalpage.js` — `loadTerminalInfo()` now seeds the
  save button's spinner state from `terminalInfo.saveStatus` on page load
  instead of only ever setting it from a same-session click or SSE event
  (bug #10)
- `app.py` — static files now served with `Cache-Control: no-cache` via a
  `RevalidateStaticFiles` subclass (bug #12)

## What we did today (2026-08-22 afternoon/evening → 2026-08-23)
23. **Bug #10 verified fixed, but revealed bug #12** — user reloaded mid-save and
    still saw the Save button reset. Investigation showed the server-side fix
    (bug #10) was genuinely deployed correctly (byte-for-byte `md5sum` match
    between what curl fetched over the network and what was in the running
    pod's filesystem). Root cause was **browser caching**: `StaticFiles` sends
    no `Cache-Control` header at all, so browsers fall back to RFC 7234 §4.2.2
    heuristic caching and can keep serving a stale JS file for hours after a
    redeploy without even sending a conditional request — a real fix can look
    like it "didn't take" purely from browser-side caching. Fixed by wrapping
    `StaticFiles` in `browseterm-server/app.py` with a `RevalidateStaticFiles`
    subclass that sets `Cache-Control: no-cache` on every response — forces
    revalidation (`If-None-Match`/`If-Modified-Since`) on every load without
    losing the caching benefit (a 304 is still cheap when unchanged). Rebuilt,
    pushed, redeployed; **verified via `curl -sI`** showing the header live.
24. **Simplified bug #8's Job-name-collision fix**: user asked why we were
    "just applying retries" instead of avoiding the collision outright. Agreed
    — replaced the delete-then-recreate-with-polling approach (which had its
    own race: Foreground deletion is asynchronous, so it had to poll up to 10s
    for the old Job to actually disappear before it was safe to create the
    new one) with a **unique Job name per save attempt**
    (`{pod_name}-snapshot-job-{8 hex chars}` via `uuid.uuid4().hex[:8]`,
    `container-maker/src/resources/job_manager.py`) — sidesteps the collision
    entirely instead of racing around it. Confirmed via grep that nothing else
    in the codebase looks up the Job by its old deterministic name. Kept the
    suffix short (not a full timestamp) since the Job controller auto-labels
    its Pods with `job-name=<this>` and K8s label values cap at 63 chars.
    Rebuilt, pushed, redeployed, verified live.
25. **Real outage: "why is browseterm down even though pods are up?"** — a
    snapshot Job from earlier Save testing had been stuck **Running for 5+
    hours** (should take minutes). Its logs showed the first attempt failed
    the Docker Hub push with `unauthorized: authentication required`
    (transient), Kubernetes auto-retried it (`backoff_limit=2`), and on that
    retry a plain `tar -xzf` of a 120MB file — normally seconds — took **over
    2 hours** between log lines under node I/O contention. That silently
    starved the VM: `browseterm-server`'s health checks started timing out
    (`context deadline exceeded` → `connection refused`), kubelet restarted
    those pods, the HPA scaled `browseterm-server` up to 4 replicas trying to
    compensate, adding still more load to an already-starved 4-core VM. "Pods
    up" didn't mean "responsive" — deleted the stuck Job (`kubectl delete
    job`), confirmed the app immediately returned to normal (302 in ~0.1-0.3s
    consistently, down from multi-second/timing-out). Also answered a
    standing question: **no port-forwarding anywhere** — `ingress-nginx` runs
    as a real `LoadBalancer` Service, MetalLB assigns it 192.168.252.200 on
    the VM's own subnet, `/etc/hosts` maps the two hostnames straight to that
    IP; traffic is genuinely routed, browser → that IP → nginx-ingress → the
    backend Service, which is also *why* a starved VM can take the whole app
    down rather than just one forwarded tunnel dying.
26. **Bug #13 — root cause of why the Job pods weren't dying automatically.**
    User asked directly. Two stacked gaps: (a) `browseterm_workload/
    snapshot_job/src/snapshot_builder.py`'s `run_command()` had
    `timeout: Optional[int] = None` — a hung command (the 2-hour `tar -xzf`
    above) would wait forever; two other calls (`tag_image`, `cleanup_images`)
    had the same gap. (b) The Job spec only set `backoff_limit`/
    `ttl_seconds_after_finished`, neither of which helps a pod that's still
    "running" but stuck — both only act once the Job reaches a terminal
    state. Fixed both layers: made `timeout` a **required** parameter on
    `run_command` (can't silently regress), gave the three previously-open
    calls explicit timeouts (untar 5min, tag 60s, cleanup 2min — build/push
    already had 25min each, login already had 30s), and added
    `active_deadline_seconds=3900` (65min, sized against the worst-case sum of
    all per-step timeouts, ~58.5min) to the Job spec in `job_manager.py` as a
    hard backstop of last resort. Rebuilt+pushed both `snapshot-job` and
    `container-maker`, redeployed, verified live.
27. **Follow-up audit of the whole snapshot Job found 3 more real issues**,
    fixed together per user's request to "address all the issues":
    - **Image re-pull on every save**: the Job's container never set
      `image_pull_policy`, defaulting to `Always` for the `:latest` tag — every
      single save re-checked/re-pulled the ~1.1GB `snapshot-job` image from
      Docker Hub. Set to `IfNotPresent` (matches the pattern already used for
      the terminal pod and container-maker's own deployment).
    - **Self-inflicted timeout mismatch**: `SNAPSHOT_JOB_TIMEOUT_SECONDS`
      (container-maker's own wait loop, 30min — pre-existing) was *shorter*
      than the `active_deadline_seconds` (65min) just added in #26 — so
      container-maker would give up and report failure to the user at 30min
      even though the Job was still legitimately allowed to keep running for
      another 35. Same "caller abandons a still-running async operation"
      pattern as bug #6. Raised to 4200s (70min) so the Job's own deadline is
      the one that actually fires first.
    - **No resource requests/limits** on the Job's pod at all, despite running
      `privileged=True` for a Docker daemon — a real contributor risk given
      the whole incident in #25 was VM resource starvation. Added modest
      requests/limits (250m CPU / 256Mi request, 1 CPU / 1Gi limit) sized
      against the `DEFAULT_TIER` ceiling already used for user pods; confirmed
      generous headroom by reading the actual generated Dockerfile — it's a
      trivial `FROM scratch` + `COPY . /`, not a real compile.
    All three in `container-maker/src/resources/job_manager.py` and
    `resource_config.py`. Built, pushed to Docker Hub (`digest
    sha256:dbddd91f...`), committed and pushed to git. **Not yet redeployed to
    the cluster** — the VM went unresponsive to disk I/O contention (see
    "Where things stand" above) right as this was about to be rolled out.

## Code changes made — this round (container-maker, pushed to git + Docker Hub,
## deploy still pending per "Where things stand"):
- `src/resources/job_manager.py` — unique Job name per attempt (bug #8
  follow-up, #24 above), `active_deadline_seconds` backstop (#26),
  `image_pull_policy="IfNotPresent"` + resource requests/limits (#27)
- `src/resources/resource_config.py` — `SNAPSHOT_JOB_TIMEOUT_SECONDS` 1800→4200
  (#27), new `SNAPSHOT_JOB_CPU_REQUEST`/`_MEMORY_REQUEST`/`_CPU_LIMIT`/
  `_MEMORY_LIMIT` constants (#27)

`browseterm_workload/` (monorepo submodule checkout):
- `snapshot_job/src/snapshot_builder.py` — `run_command`'s `timeout` param is
  now required, not optional; `untar`/`tag`/`cleanup` calls given explicit
  timeouts (bug #13, #26 above)

## What we did today (2026-08-23 evening → 2026-08-24 early morning)
28. **User reported the Save button was stuck in "loading" forever** (a real
    terminal, not a test scenario). Investigated the DB directly rather than
    assuming a frontend bug: `save_status='Running'` with no matching
    Kubernetes Job anywhere in the cluster (`kubectl get jobs` empty), and
    `container-maker`'s current pod had zero save-related log lines in its
    entire lifetime — meaning the Job that set `Running` (only the Job's own
    process ever does that, right before it starts unpacking the snapshot)
    had run under an *earlier* container-maker pod instance and then vanished
    without ever writing `Succeeded`/`Failed`. Caught the live cause red-handed:
    the cluster was *at that moment* in the same host disk I/O contention
    pattern documented earlier this session (VM loadavg 10+, `NodeNotReady`
    firing for every pod) — the Job's pod was almost certainly evicted mid-run.
    A killed process cannot record its own death; nothing was left to ever
    resolve the row. Manually reset that one row to `Failed` via direct SQL to
    unblock the user immediately (**note for future sessions: don't do this
    again once the reconciler below exists** — let it recover things itself so
    the fix is actually exercised, per explicit user instruction this session).
29. **Found a second, independent bug while diagnosing bug #28's stale error
    text**: the recovered row still showed an *ancient* error message from a
    much earlier failed attempt even though `Running` should have cleared it.
    Traced to `browseterm-db/browseterm_db/operations/container_ops.py`'s
    `ContainerOps.update()` — it silently drops any field in the update `data`
    dict whose value is `None`, but callers (`_set_save_status` in
    browseterm-server, `update_save_status` in the snapshot Job) explicitly
    pass `save_error=None` *meaning* "clear this column to NULL". Audited every
    `ContainerOps(...).update(...)` call site in the repo before fixing — none
    relied on the buggy None-skips-field behavior (one caller already stripped
    `None` upstream via Pydantic `exclude_none=True`), so removing the guard
    from the update-data loop (kept on the filters loop, where it's correct)
    was safe everywhere.
30. **Designed and built the save-status reconciler** (bug #28's real fix) —
    see "Where things stand" above for the design rationale (Job-state-based,
    not a duration guess) and file locations. Key pieces: `ContainerOps.
    find_stuck_saves()` (new, mirrors the existing `find_idle_containers`
    pattern used by the reaper) returns all Pending/Running rows;
    `JobManager.find_snapshot_job_for_container()` (new) looks up a save's Job
    by a new `container-id` label stamped on Job creation (Jobs previously had
    no way to be found by container id, only by their own unique-per-attempt
    name); `save_reconciler.py` (new) contains the decision table and a
    `run_loop()` swept every `SAVE_RECONCILER_INTERVAL_SECONDS` (90s,
    env-overridable) via a daemon thread started in `container-maker/app.py`'s
    `serve()`. User specifically pushed back on a naive timeout ("timeouts can
    vary cluster to cluster") — confirmed that instinct is right and designed
    around it: the only duration-based check left is a generous grace period
    for the narrow "Pending but the Job doesn't exist *yet*" window (Job
    creation genuinely happens a little after the Pending write), everything
    else asks Kubernetes for ground truth instead of guessing.
31. **Wrote and ran real tests before deploying, not just eyeballing the
    diff.** `browseterm-db`: spun up a throwaway local Postgres via Docker
    (isolated from the K3s cluster, removed after), ran the *real* integration
    suite against it — 17/17 pass including 2 new tests (explicit-None clears
    `save_error`; `find_stuck_saves` returns only Pending/Running). 
    `container-maker`: 14 new mocked unit tests (Job label lookup incl.
    newest-wins-over-a-lingering-TTL'd-Job tie-break; the reconciler's full
    decision table — orphaned Running, terminally-failed Job, active Job left
    alone, Pending within/past grace, a bad k8s API call skipping the row
    without killing the loop) — all pass. Found and fixed one *pre-existing*
    stale test (`test_create_snapshot_job_env.py` asserted the old
    deterministic Job name, predating an earlier session's unique-name-per-
    attempt fix) while running the full suite; found 3 *pre-existing*,
    unrelated failures in `test_stream_command_to_file.py` (fail in total
    isolation too, different code path — pod-exec streaming) and correctly
    left those alone as out of scope.
32. **Deploy hit a real gotcha**: `container-maker`'s first rebuild silently
    shipped the *old* `browseterm-db` even after the fix was pushed to GitHub,
    because `poetry.lock` pins git dependencies to a resolved commit SHA, not
    "follow the branch" — confirmed by directly probing the built image's
    installed package (`hasattr(ContainerOps, 'find_stuck_saves')` → `False`).
    Fixed by running `poetry update browseterm-db` inside `container-maker/`
    to refresh the lock file, then rebuilding — verified `True` before pushing
    to Docker Hub. Also hit two more instances of the known "transient Docker
    Hub push failure/hang, just retry" pattern from earlier sessions (one
    push hung for 37 minutes with zero progress and had to be killed rather
    than waited out — worth noting this specific failure mode doesn't always
    self-resolve if just left alone).
33. **Host disk I/O contention recurred** right as the redeploy needed
    `kubectl` — same signature as documented earlier this session, but took
    over 35 minutes to settle this time (previously a couple minutes),
    oscillating 200-550 MB/s on the Mac's disk0 rather than trending cleanly
    down. Did **not** hammer `kubectl`/`multipass exec` into it (per the
    existing playbook) — checked `iostat`/`ps aux | grep backupd|mdworker`
    periodically instead and waited. Along the way found CoreDNS itself had
    restarted 47 times with its own health checks timing out — same root
    cause rippling into cluster DNS, which is why the newly-deployed
    reconciler's early sweeps failed with `could not translate host name
    "browseterm-pg-service..."` (not a bug in the reconciler — it's designed
    to log-and-retry exactly this kind of transient failure without dying,
    and that's exactly what it did; confirmed clean sweeps once DNS recovered).
34. **User asked directly whether adding VM cores would help** ("we cannot
    exceed 1 replica" / "should we increase cores"). Explained why not: the
    VM's internal load average (8-12 on a 4-vCPU budget) is very likely
    iowait, not CPU-bound compute, given everything else observed (etcd
    multi-minute writes, TLS-handshake-specific timeouts, not general
    slowness) — more vCPUs doesn't buy more disk bandwidth on the one shared
    physical SSD, and would leave the Mac itself fewer cores to actually get
    Time Machine/Spotlight *done*. Also flagged switching to Docker Desktop
    wouldn't dodge this either — it's also just a VM on macOS, same
    architecture, same problem. Real fix identified: exclude Multipass's VM
    disk directory from Time Machine + Spotlight (see "Where things stand" —
    blocked on Full Disk Access, not yet done).
35. **User separately noticed HPA had scaled `browseterm-server` to 4
    replicas** with 2 pods showing 10 and 13 restarts and 2 more actively
    crash-looping, asked whether that was "the actual problem" — confirmed
    yes, very plausibly compounding (not necessarily the sole root cause of
    the disk contention itself, but definitely adding scheduling/restart load
    to an already-starved node). Live-patched both HPAs (`browseterm-server`,
    `socket-ssh`) to `minReplicas=maxReplicas=1` immediately, watched
    `browseterm-server` actually converge from 4 pods down to 1 healthy pod,
    then made it permanent in both services' source `deployment.yaml` (was
    only a live `kubectl patch` at first) — see "Where things stand" above.
36. **All changes committed and pushed**, monorepo submodule pointers synced:
    - `browseterm-db` (`main`, commit `0fca020`): the `ContainerOps.update()`
      None-fix + `find_stuck_saves()` + the 2 new integration tests.
    - `container-maker` (`main`, commit `c34b3e6`): the save reconciler +
      Job labeling/lookup + `poetry.lock` bump + all new/fixed tests.
    - `browseterm-server` (`main`, commit `ed8a607`): HPA pinned to 1 in
      `infra/deployment/deployment.yaml`.
    - `socket-ssh` (`main`, commit `fb1a9d6`): same HPA pin.
    - `browseterm-monorepo`: submodule pointers bumped for all 4 above, plus
      `OBSERVABILITY.md`/`TODOPLAN.md` doc updates (see below).
    Docker images rebuilt+pushed and redeployed to the cluster for
    `container-maker` only (the one with a runtime behavior change);
    `browseterm-server`/`socket-ssh`'s HPA change took effect via the earlier
    live `kubectl patch`, no image rebuild needed for a YAML-only change —
    **the source YAMLs are now the source of truth, but note a future
    `make prod_setup` re-run on these two is what actually re-applies the
    committed YAML; the live cluster state and the git state agree right now,
    but only because both paths were done this session.**
37. **Updated `OBSERVABILITY.md`/`TODOPLAN.md`** with a detailed, actionable
    tracing rollout plan (prerequisite ordering, gRPC/detached-Job context
    propagation specifics, an explicit acceptance test tied to this session's
    real incidents, Tempo-vs-Jaeger resolved as Tempo) — see those files
    directly, not reproduced here per this file's own "don't duplicate,
    point at the canonical doc" convention.

## What we did today (2026-08-24 late morning — new session)
38. **Checked disk I/O contention per the pickup instructions before touching
    anything** — found it mild-to-moderate at first (VM loadavg ~10, `kubectl get
    pods` timed out once then succeeded on retry), asked the user whether to wait,
    proceed, or fix root cause first; user chose to wait. It settled within ~5 min
    (loadavg dropped to 1.04), so proceeded with the day's plan.
39. **Deployed the reaper CronJob to the cluster for the first time** (previously
    code-only, per the "Not yet started" note above). Built
    `browseterm_workload/reaper/env.mk` by hand (not fanned out by `gen-env.sh`
    for this submodule) using `NAMESPACE=browseterm`, `REPO_NAME=zim95`,
    `IDLE_THRESHOLD_SECONDS=604800` (1 week default), and the same
    `CONTAINER_MAKER_HOST=container-maker-service`/`PORT=50052`/
    `CERTS_SECRET_NAME=container-maker-service-certs` values `browseterm-server`
    already uses against the same secrets (confirmed both `browseterm-db-credentials`
    and `container-maker-service-certs` already exist in-cluster). Ran
    `make dev_setup` from `browseterm_workload/reaper/` — ServiceAccount, Role,
    RoleBinding, and the hourly CronJob all applied without error.
    `zim95/reaper:latest` already existed on Docker Hub from an earlier session
    (confirmed via `docker manifest inspect`), so no rebuild was needed.
40. **Started the hibernation test** per the plan already written up under
    "Pending" below: simulated 8 days of idleness on the one real running
    terminal (`namah_ssh_ubuntu_test`, id `473f769c-4e5f-48ca-9a33-b572434bab63`)
    via direct SQL on `last_active_at` (confirmed this is safe — nothing else
    overwrites it while the terminal page is closed), then triggered a manual
    run (`kubectl create job reaper-manual-test-1 --from=cronjob/reaper`) instead
    of waiting for the hourly schedule.
41. **Hit a third disk I/O contention episode this session, worse than the
    first two.** The manual reaper job's pod stalled in `ContainerCreating`
    pulling its own small (~343MB) image; `kubectl describe` on it hit a TLS
    handshake timeout outright. Followed the existing playbook exactly (checked
    `iostat`/VM loadavg/`backupd`+`mdworker_shared` process count instead of
    retrying kubectl into it) across three checks ~5 min apart — unlike the
    first two episodes today (both self-resolved within ~5 min), this one
    trended **worse**, not better: VM loadavg climbed 4.95 → 12.71 → 13.83,
    disk0 oscillating 224-372MB/s throughout. Concluded this confirms the
    existing "recurring operational risk, not a one-off" framing rather than
    contradicting it.
42. **Proactively surfaced the still-pending Full Disk Access fix instead of
    continuing to wait it out a third time** — asked the user directly given
    contention had now been continuous 15+ min and trending worse; user chose
    to grant it. Gave the exact GUI steps (System Settings → Privacy & Security
    → Full Disk Access → add Terminal.app) and is waiting on the user to
    complete that before running the previously-blocked
    `sudo tmutil addexclusion -p "/var/root/Library/Application Support/
    multipassd"`. **Not yet done** — this is where the session left off.

## What we did today (2026-08-24, later — crash_states review + save-flow fixes)
43. **User supplied a `crash_states` file** (13 generic save-pipeline crash
    points — before/during/after each stage of claim → snapshot → upload →
    build → push → finalize → respond → duplicate-request) and asked which are
    handled in this codebase. Traced each against real code (not the planning
    docs, which can be stale) across `container-maker`, `browseterm_workload/
    snapshot_job`, `browseterm-server`, `browseterm-db`. Result: 6 fully
    implemented, 1 not needed by design (the HTTP response is decoupled from
    completion entirely — SSE + page-reload reseeding cover it), 3 partial
    (crash-safe but leak storage or redo unnecessary work on retry — no
    multipart/partial-object cleanup in MinIO, no artifact-reuse-on-retry), and
    2 real gaps: **no MinIO↔DB reconciliation/GC** (an orphaned upload with no
    matching DB state is never discovered or cleaned up — still open, not
    addressed this session) and **no server-side save idempotency lock** (two
    concurrent Save requests for the same container could race two Jobs against
    the same row) — **user explicitly decided this second one does not need
    fixing**: resaving is legitimate even if a save is already in flight, since
    the container's contents may have changed since the last attempt.
44. **User asked how the "RUNNING but Job doesn't exist" case is actually
    detected** (poll vs push, timeout, does the button know). Confirmed by
    reading the code directly (not just re-describing prior notes): this is
    already handled entirely by the existing save reconciler (see 2026-08-24
    early-afternoon entry above) — no client-side polling anywhere. The
    Postgres `container_save_status_change_trigger` fires on **any** `UPDATE`
    to `save_status` regardless of writer (confirmed in the trigger's own SQL,
    `browseterm-db/browseterm_db/migrations/versions/
    e5f6a7b8c9d0_add_save_status_notify_trigger.py`), so the reconciler's plain
    SQL write is indistinguishable from a normal Job write at the NOTIFY→SSE
    layer — `terminalpage.js`'s already-open `/container-status-stream`
    connection picks up a reconciler-caused `Failed` exactly like any other.
45. **Designed (not yet implemented) a "last save" status widget** per user
    request: a box next to the Save button showing last successful save date
    (`last_saved_at`, already exists as a column, already success-only —
    matches requirement as-is, just not yet exposed to the frontend), current
    status, and a new `last_save_checkpoint`-style field (last *attempt*
    timestamp, success or fail, distinct from the success-only date) —
    responsive on mobile. Scoped the work (DB migration + NOTIFY trigger
    payload + `terminal_info` dict + SSE message + frontend widget in
    `.terminal-footer`) but **deferred implementation** in favor of the
    concurrency questions below — pick this up next.
46. **User asked pointed architecture questions that led to a real, previously
    undocumented finding**: how does a Job know which container it belongs to
    (answer: a `container-id` label, `job_manager.py:205`, looked up via
    `label_selector`, not the Job's own name); is a thread spawned per save;
    is the reconciler a separate Job (**no** — a single daemon thread inside
    the same container-maker process, `app.py:65`, started once, not a
    Kubernetes Job/CronJob — don't confuse with the reaper, which genuinely is
    a CronJob). Pressed on "does this look safe with concurrent users," which
    surfaced a **real, unaddressed capacity bug**: `container-maker` is a
    synchronous `grpc.server(ThreadPoolExecutor(max_workers=10))` (`app.py:
    37-38`, never overridden in the deployment) shared across every RPC type
    cluster-wide, and `PodManager.save_image`/`SaveUtility.save_image` used to
    call `JobManager.wait_for_job_completion` **synchronously inline** —
    polling every 5s (`job_manager.py:262`) for up to `SNAPSHOT_JOB_TIMEOUT_
    SECONDS` = 4200s/70min — meaning a single save could occupy 1 of only 10
    total gRPC worker threads for up to 70 minutes, with `container-maker`
    itself running as a single replica (no HPA). ~10 concurrent saves could
    have exhausted the whole pool and stalled every user's create/delete/exec
    requests cluster-wide. Logged as a new Pending item with full citations
    before fixing (see below) — this was NOT previously documented anywhere in
    this file or `TODOPLAN.md`.
47. **Fixed the finding from #46, same session, on user's go-ahead.** In
    `container-maker/src/resources/pod_manager.py`'s `SaveUtility`: `save_image`
    now creates the snapshot Job, computes the (deterministic, repo-prefixed)
    `image_name` immediately — it doesn't depend on the build finishing, since
    the tag isn't content-addressed — and returns right away, instead of
    blocking on `wait_for_job_completion`. The wait, plus the crash-recovery
    `_update_pod_image` patch that used to follow it, now run on a dedicated
    `threading.Thread` (new classmethod `SaveUtility._wait_and_patch_pod_image`,
    daemon, one per save, named `save-finalize-{pod_name}`) — off the shared
    10-thread gRPC pool entirely. That thread never raises to a caller (there
    isn't one): on a Job failure/timeout it just logs and skips the patch,
    since the Job's own process already records `Failed` in the DB on a
    graceful failure, and the save reconciler catches an ungraceful one — no
    new failure-reporting path was needed. Verified nothing downstream depends
    on the RPC blocking: `browseterm-server`'s `save_container_in_k8s` already
    discards the gRPC response content and only reacts to it raising
    (`containers_service.py:330-351`), and the proto's `image_name` field is
    satisfied by the same deterministic value either way. Also added
    `job_name`/`job_namespace_name` to `save_image`'s return dict (previously
    just `image_name`) so any caller that *does* need a synchronous guarantee
    (a test, say) can explicitly `JobManager.wait_for_job_completion(...)`
    itself. **Test changes**: rewrote `tests/unit/resources/
    test_save_image_crash_recovery.py` — the old test asserted the pod-image
    patch happened synchronously inside `save_image`, which is no longer true;
    split into testing `save_image`'s wiring (via a synchronous `threading.Thread`
    stand-in, to avoid real-thread timing races) and `_wait_and_patch_pod_image`
    directly in isolation (success path patches; a Job failure is swallowed
    and does NOT patch) — 5 tests, all passing. Also caught and fixed a real
    regression in `tests/k8s/integration/resources/test_crash_hibernate_flow.py`
    (needs a live cluster, not run this session, but the logic gap was real):
    its hibernate/resume test called `PodManager.save()` then immediately used
    the returned image to recreate a pod — safe when `save()` blocked until the
    push finished, broken once it doesn't. Fixed by having the test explicitly
    `JobManager.wait_for_job_completion(...)` using the new returned
    `job_name`/`job_namespace_name` before resuming, mirroring how production
    actually gates resume (on `save_status` reaching `Succeeded` in the DB, via
    the Job's own direct write — never on this call's return timing, so
    production itself was never at risk from this change, only this one
    test's assumption). Full unit suite run: 57 tests, 3 failures — all 3 are
    the same pre-existing, unrelated `test_stream_command_to_file.py` failures
    already documented earlier in this file (different code path, pod-exec
    streaming) — nothing newly broken. **Not yet rebuilt/pushed/deployed to the
    cluster or committed to git** — code + tests only so far.
48. **User separately asked whether snapshot Jobs self-terminate** ("They
    cannot linger around. They will not let other pods come up.") — confirmed
    yes, already fully in place from an earlier session, re-verified directly
    in `job_manager.py`'s Job spec: `restart_policy="Never"` +
    `backoff_limit=2` (pod-level retry cap), `active_deadline_seconds=3900`
    (65min hard wall-clock cap across all retries combined — this is what
    actually prevents a hung Job from occupying node capacity indefinitely and
    blocking other pods from scheduling, which is exactly what happened in the
    2026-08-23 "real outage" incident documented above before this existed),
    and `ttl_seconds_after_finished=3600` (1h auto-delete of the Job+pod object
    once it reaches a terminal state, so finished Jobs don't pile up). No
    action needed — this was a re-confirmation, not a new fix.
49. **Closed out the crash-recovery/wait design discussion with the user's
    explicit sign-off.** Walked through why `_update_pod_image` needs real
    Kubernetes API access and can't be replaced by a DB-only write: the DB's
    `saved_image` column only drives the explicit hibernate→resume path
    (app-level, reads the DB, creates a new pod); it has no effect on kubelet's
    own automatic crash-restart-in-place, which consults only the live Pod
    object's spec already in the Kubernetes API server, with zero DB awareness
    — so pre-arming that spec via a real K8s patch is the only way an in-place
    crash restarts from the latest snapshot rather than the base image. Also
    reconfirmed `wait_for_job_completion` never touched the DB at all (the Job
    writes `save_status`/`saved_image` directly, independent of any wait) —
    its only job, before and after today's fix, is gating that one K8s patch.
    Considered and explicitly rejected having the snapshot Job perform the
    patch itself (would eliminate the wait entirely) because it would require
    granting Kubernetes API access to the one workload that's both
    `privileged=True` and processes arbitrary user-generated content through
    `docker build` — a security boundary intentionally kept in place
    (`automount_service_account_token=False`, confirmed via grep: no
    `kubernetes` import anywhere in `browseterm_workload/snapshot_job`). **User
    agreed**: keep the current design (item #47's dedicated per-save
    background thread in container-maker, off the shared gRPC pool) as-is —
    no further changes needed here.

## What we did today (2026-08-25 — save-status UI widget)
50. **Built the "last saved / last attempt / status" widget the user asked
    for**, next to the Save button — pure reflection of DB state, no new
    logic. Corrected the design mid-flight: the user initially sketched a
    "last resolution timestamp" field (item #45), but re-derived the simpler
    right answer themselves once pressed on it — `updated_at` can't be reused
    (it changes on every row write, including unrelated ones like the
    activity heartbeat), `last_saved_at` already exists and needs no new
    column, and what's actually missing is a **"last attempt started"**
    timestamp, written in exactly **one place** (when `save_status` is set to
    `Pending`) rather than the four scattered success/failure call sites the
    original design would have needed. Confirmed with the user before
    implementing ("This would cover the case I suggested right? If so,
    proceed.").
    - **`browseterm-db`**: new nullable `containers.last_save_attempted_at`
      column (`models/containers.py`, `to_dict()`); two new hand-written
      migrations chained onto head `b1c2d3e4f5a6` — `c2d3e4f5a6b7` (add the
      column) and `d3e4f5a6b7c8` (`CREATE OR REPLACE` the existing
      `notify_container_save_status_change()` trigger function to include
      `last_saved_at`/`last_save_attempted_at` in its NOTIFY payload, trigger
      itself untouched). `ContainerSaveStatusChangePayload`
      (`common/pg_listener.py`) extended with both fields. Tests updated
      (`tests/test_pg_listener.py`).
    - **`browseterm-server`**: `_set_save_status` (`api_handlers.py`) gained a
      `stamp_attempt` flag, passed `True` only from `save_container`'s
      PENDING write — the single point a save is ever initiated.
      `template_handlers.py`'s `terminal_info` dict and `status_listener.py`'s
      SSE message both now carry `lastSavedAt`/`lastSaveAttemptedAt` (or
      snake_case equivalent for SSE), so the widget seeds correctly on page
      load and updates live without a reload, riding the existing NOTIFY→SSE
      pipeline for free (same mechanism already used for the spinner).
      `tests/integration/containers/test_resume_container.py` and
      `tests/integration/status_listener/test_save_status_listener.py`
      updated/extended.
    - **Frontend**: new `.save-status-info` box in `.terminal-footer`
      (`terminalpage.html`), hidden entirely until a terminal has any save
      history; responsive (`terminalpage.css`) — wraps/stacks full-width above
      the button at the existing 768px breakpoint, stacks its own three rows
      vertically at 480px. `terminalpage.js`'s new `renderSaveStatusInfo()` is
      called both on page load (`loadTerminalInfo()`) and on every SSE
      `save_status_change` event (`setupSaveStatusStream()`, previously only
      handled Succeeded/Failed for the spinner — now renders on every status,
      including Pending, so "Last attempt" updates the moment a save starts).
    - **Verified against a real, correctly-migrated Postgres**, not just
      mocks: spun up a throwaway `postgres:16` in Docker, ran the actual
      migration chain via `Migrator.upgrade()` (NOT `init.py --fresh` —
      see the mistake below), confirmed the column and the updated trigger
      function body live in the database, then ran both repos' full test
      suites. `browseterm-db`: 88/89 pass (1 pre-existing unrelated failure,
      an auth-error-message assertion mismatched to this Postgres's default
      user, nothing to do with this change). `browseterm-server`: 85/88 pass
      (3 pre-existing unrelated failures: a pydantic type-validation bug in
      `authentication_helpers.py`, and two test files importing config
      constants — `CONTAINER_MAKER_CLIENT_CERT_ENV_VAR`/`_KEY_ENV_VAR` — that
      don't exist in `src/common/config.py`; none touched by this change).
    - **Self-inflicted near-miss, worth remembering**: ran `init.py --fresh`
      first to get a clean throwaway DB, forgetting that script unconditionally
      calls `Migrator.reset_migrations()` (deletes every file in
      `migrations/versions/`) regardless of any `--fresh` flag actually being
      parsed — it doesn't take one, the flag was silently ignored. This wiped
      the two brand-new migration files, which — unlike the already-documented
      "don't commit the squash noise" gotcha from an earlier session — were
      never committed, so `git checkout` couldn't recover them. Recreated both
      from this session's own transcript (no work actually lost), restored the
      13 legitimately-tracked original migrations via `git checkout`, deleted
      the throwaway squashed `Initial migration` autogenerate, and re-verified
      clean. **Lesson for next time**: never run `init.py`/`init.py --fresh`
      against a DB you want to keep, and especially not while an uncommitted
      migration exists on disk — for testing a migration chain against a
      throwaway Postgres, drive `Migrator(db_config, MIGRATIONS_DIR).upgrade()`
      directly instead, which applies the real chain without touching any
      files.
    - **Not yet rebuilt/pushed/deployed/committed** — code + tests only.
      `container-maker` does NOT need any changes for this feature (it never
      writes `last_save_attempted_at`); `browseterm_workload/snapshot_job`
      doesn't either, for the same reason ("attempt" means started, written
      once by `browseterm-server`, not resolved by the Job). Before deploying:
      run the real migration against the live cluster DB, and — per the
      already-documented `poetry.lock` git-dependency gotcha — run
      `poetry update browseterm-db` in `browseterm-server` (and in
      `container-maker`, for unrelated pending changes) before rebuilding
      either image, or the new column/payload fields silently won't be picked
      up.
51. **Next up, per the user**: with this widget in place, resume the
    interrupted **hibernation test** and start **crash-simulation testing**
    (both already scoped under "Pending" below) — the widget gives
    visibility into save state during both, which was part of the point of
    building it now rather than after.
52. **User confirmed hibernation works** (2026-08-25): logged in, found the
    container already hibernated by the reaper's own unattended hourly
    schedule (not triggered manually this session — verified directly via
    `kubectl logs` on the completed reaper Job), resumed it via the UI, and
    the file created before hibernation was there. Also confirmed the
    save-status widget renders correctly live. Also confirmed (2026-08-24,
    carried in from the earlier session) that the value actually stored in
    Postgres for this status is the enum member name `HIBERNATED`
    (uppercase), not the `.value` string `"Hibernated"` used at the API/JSON
    layer — SQLAlchemy's `Enum` stores member names by default; worth
    remembering before ever querying `containers.status` directly via `psql`.
53. **Long design conversation on pod-crash-vs-pod-loss recovery, landed on a
    real fix.** Walked through, in order: why `kubectl exec ... kill -9 -1`
    (not `kubectl delete pod`) is the correct way to simulate an in-container
    crash for testing; whether the pod object itself can be lost outright
    (yes — confirmed this project's own repeated `NodeNotReady`/disk-I/O/
    memory-pressure eviction history earlier this session is exactly that
    failure mode, not hypothetical); whether these pods self-heal on loss (no
    — `PodManager.create()` makes a bare, unowned `Pod`, no ReplicaSet/
    Deployment/StatefulSet controller, confirmed nothing reconciles a desired
    count for it); whether wrapping them in a `ReplicaSet` would fix this
    cleanly (mechanically yes, but audited the real cost first rather than
    assume: confirmed pod-name is the *primary* lookup key with **no**
    fallback in `PodManager.get`/`delete`/`poll_container_readiness`/
    `_update_pod_image`/`ExecUtility.run_command`, unlike the one narrow
    exception in the save flow — `find_container_pod`, `containers.py:125`
    — and, more importantly, that a self-healing controller directly
    conflicts with hibernate's *current* delete-the-pod mechanism, which
    would just get undone by the controller within seconds). **Rejected the
    ReplicaSet/StatefulSet path** as disproportionate to the problem and
    landed on reusing `status_monitor` — already a single, cluster-wide,
    event-driven (K8s watch API, not polling) watcher covering every
    `browseterm/managed=user-pod` pod across all namespaces, confirmed by
    reading its actual source (`browseterm_workload/status_monitor/src/
    pod_watcher.py`) rather than assuming. It already had full DB write
    access and already saw every `DELETED` event live; it just discarded
    that event, only clearing its own in-memory dedup cache.
    **User pushed back hard, correctly, on an over-engineered first draft**:
    the initial plan reordered the reaper's hibernate flow (write DB status
    before deleting the pod, to avoid a race where an in-flight hibernate
    looks identical to a crash) — user pointed out hibernate already works,
    asked why touch it. Re-derived the simpler answer: the danger was
    specific to the recovery *action* being auto-**resume** (disruptive,
    could undo a deliberate hibernate/delete mid-flight); switching the
    recovery action to marking the row **HIBERNATED** instead makes the race
    harmless by construction — if a real hibernate's own write lands
    moments later, it's the same target value; if an explicit delete's hard
    delete lands moments later, the row (and this write) are gone before
    anyone sees it. **No changes needed to the reaper or the delete flow at
    all.** This also avoids extracting `resume_container` into a
    listener-callable function or wiring any new cross-service call —
    resuming a `HIBERNATED` container already works today exactly as
    verified in item #52, unchanged.
54. **Implemented and committed, same session.** Two independent fixes:
    - **`container-maker`** (`src/resources/job_manager.py`): snapshot Job
      `backoff_limit` 2 → 0, per explicit user instruction — **no automatic
      Job retries**. Root concern raised directly: a failed save was
      silently creating up to 2 extra Job pods (none cleaned up until
      `ttl_seconds_after_finished`, 1h), compounding node resource pressure
      under repeated failure — exactly the condition (disk/memory pressure)
      already most likely to cause a save to fail in this cluster's history.
      A failed save already surfaces clearly via `save_status=Failed` +
      the save-status widget, and re-clicking Save already works safely
      (unique Job name per attempt, no collision) — retry is now a
      deliberate user action, never automatic.
    - **`browseterm_workload/status_monitor`**: new `mark_lost_if_running`
      (`src/db_ops.py`) — a single atomic conditional `UPDATE ... WHERE
      id=X AND status='Running'` (not read-then-write, no race window) that
      flips a row to `HIBERNATED` only if it's still `Running` at the
      instant this runs. Wired into a new `_handle_deleted` (`src/
      pod_watcher.py`, extracted from the watch loop for direct
      testability, mirroring the existing `_handle_pod` split) called
      unconditionally on every `DELETED` event, per the harmless-by-
      construction reasoning in item #53 — deliberately does **not** try to
      distinguish expected vs. unexpected pod loss beforehand, since there's
      no reliable signal to do so at that instant anyway, and it doesn't
      need one. `reconcile_and_watch`/`main.py` updated to pass the new
      callback alongside the existing status-write one. 8 new/updated unit
      tests across `test_pod_watcher.py`/`test_db_ops.py`, all passing
      (17/17 in the full suite) — fully mocked, no live cluster/DB needed
      for this logic. **Net effect**: a pod that vanishes without kubelet
      ever getting to report a terminal phase first (node eviction,
      resource-pressure eviction — anything other than the container
      merely crashing, which already self-heals via `restart_policy:
      Always` and never reaches this code path at all) now gets marked
      `HIBERNATED` instead of leaving the row silently stuck saying
      `Running` forever with no pod behind it and no way to recover except
      manual DB surgery. Recovery is the existing, already-verified (item
      #52) resume-from-`saved_image` flow — nothing new needed there.
    - Both committed (container-maker `de81bb0`, browseterm_workload
      `47850bb`, monorepo pointer bump `7e32220`), clean of any AI
      attribution per the standing convention above. **Not yet
      deployed/rebuilt/pushed to Docker Hub or run against the live
      cluster** — next step before calling this verified is an actual live
      crash test (`kubectl exec ... -- kill -9 -1` doesn't exercise this
      path at all, since that's an in-container crash, not a pod loss —
      need to actually delete/evict a pod out from under a `Running` row,
      e.g. `kubectl delete pod` directly this time, specifically *because*
      this fix is what's supposed to make that survivable now) and confirm
      the row flips to `HIBERNATED` and resume recreates it correctly.
55. **Deployed all three item-#54-adjacent fixes to the live cluster, and found +
    fixed a real, actively-ongoing incident along the way.** User asked "why
    are there two pods for our user" — investigation found
    `namah-ssh-ubuntu-test-pod-1787379278` (3 days old) and
    `...1787633648` (fresh, from an earlier resume) both carrying the same
    `browseterm/container-id` label — an orphan the reaper's hibernate should
    have deleted but never did. Traced via `container-maker` logs: the
    reaper's save step kept failing (the same gRPC-thread/backoff_limit=2 bug
    item #46/#47 already fixed but hadn't deployed yet), and with no
    `backoffLimit` set on the reaper's own Job, Kubernetes' default of 6
    meant every failure restarted the ENTIRE sweep from scratch via
    `restartPolicy: OnFailure` — caught **live**, a reaper pod 30+ minutes in
    with 2 restarts, still hammering the same doomed container, very likely a
    real contributor to the severe load spikes fought throughout this
    session. Deleted the runaway Job immediately, fixed
    `browseterm_workload/reaper/infra/deployment/deployment.yaml` with
    `backoffLimit: 0` (same "no automatic retries, next hourly tick is the
    real retry" reasoning as item #54's snapshot-Job fix), committed
    (`89ad2c3`), deleted the orphan pod. Then rebuilt+pushed+redeployed all
    three: `container-maker` (image `sha256:97455fba...`), `status_monitor`
    (image `sha256:0cc8876a...`), reaper's manifest re-applied. Node went
    briefly `NotReady` and `k3s` itself hit `activating` (mid-restart, not
    just slow) during this from the load — waited it out rather than push
    through, confirmed `Ready` before continuing. Both `container-maker`'s
    and `status_monitor`'s image pulls **genuinely hung** (not host
    contention — load was healthy, Docker Hub rate-limit checked and nowhere
    close to the 100/hour anonymous cap) and needed a force-delete + retry
    each; `status_monitor` needed two retries, the second unstuck by a direct
    manual `crictl pull` on the node. **Verified working after deploy**: the
    next scheduled reaper run completed cleanly in 54s (`Complete`, no
    restarts) — first live evidence the reaper fix holds. A real user Save
    click was traced end-to-end through fresh logs and confirmed following
    the new code path correctly (`"waiting for snapshot job to complete"`
    logged with `request_id: "-"`, i.e. running on the new dedicated
    background thread, off the gRPC request's context) — save itself was
    still finishing as of this writing, not yet confirmed to a final
    Succeeded/Failed.
56. **Added subscription-plan gating to resume**, implementing the design
    validated (not built) two items ago. Found `TODOPLAN.md`'s claim that
    `is_user_within_container_limit` already exists in `browseterm-db` is
    **stale/inaccurate** — grepped, it doesn't exist anywhere; built the
    checks fresh instead, on top of what *does* already exist and already
    works: `SubscriptionType` (`max_containers`, `cpu_limit_per_container`/
    `memory_limit_per_container`/`storage_limit_per_container`) and
    `browseterm-server`'s `get_user_current_subscription_plan` (already
    wired into login via `process_user_info`, auto-creates a free plan for
    any user with none). `resume_container` (`api_handlers.py`) now runs two
    checks before touching k8s:
    - **Concurrency**: `_count_active_containers` counts the user's other
      `Pending`/`Running`/`Resuming` containers (deliberately not
      `Hibernated` — hibernating is exactly how a user is meant to free a
      slot) and blocks with 409 if resuming would exceed `max_containers`.
    - **Spec compatibility**: `_exceeds_tier_spec` compares the container's
      own recorded `cpu_limit`/`memory_limit`/`storage_limit` against the
      current plan's per-container allowance, using
      `kubernetes.utils.quantity.parse_quantity` (already available
      transitively, no new dependency) — blocks with 409 if the container
      was created/saved under a higher tier than the user currently has.
      Fails open (skip that comparison) on an unparseable value rather than
      incorrectly blocking — needed for the Pro tier's seed data, which uses
      the literal placeholder string `"Configurable"`.
    Both checks fail open entirely (log + allow) if the subscription lookup
    itself throws — a payments-system hiccup must never block a user from
    recovering their own workspace. Confirmed this is genuinely safe by
    running the pre-existing `resume_container` tests unmodified: they don't
    mock the new subscription call, it throws on their fake non-UUID
    `user_id`, and all 9 still passed exactly as before — proving fail-open
    works as designed, not just in theory. Because crash-recovered
    containers are marked `HIBERNATED` and recovered through this exact same
    endpoint (item #53's design decision), both checks apply there
    automatically with zero special-casing. 15 new unit/integration tests
    added (`test_resume_container.py`); full suite 102 tests, same 3
    pre-existing unrelated failures as always, nothing new broken. Committed
    (`cfacb52`). **Not yet deployed** — code + tests only, same as most of
    this session's other work until explicitly asked to ship it.
57. **Deployed items #54/#56: `container-maker`, `status_monitor`, and
    `browseterm-server` all rebuilt+redeployed live.** Both `container-maker`'s
    and `status_monitor`'s pulls genuinely hung again (not host contention —
    confirmed load healthy, Docker Hub rate-limit checked, nowhere near the
    100/hour anonymous cap) and needed a force-delete + retry each, matching
    the established "hung pulls need to be killed, not waited out" pattern.
    A real Save was traced end-to-end through fresh logs afterward and
    **confirmed genuinely `Succeeded`** in the DB — the first live proof this
    session that a save completes correctly on the new container-maker code.
58. **User reported the save-status widget still not updating and the button
    still spinning after the redeploy.** Investigation found a real, actively
    live bug distinct from anything above: `browseterm-server`'s `status_
    listener.py` (already running this session's widget code) was crashing on
    **every single** `save_status_change` broadcast —
    `AttributeError: 'ContainerSaveStatusChangePayload' object has no
    attribute 'last_saved_at'` — because its `poetry.lock` still pinned the
    old `browseterm-db` commit from before those fields existed. Root cause:
    `browseterm-db`'s new migration/commit had only ever been committed
    locally, never pushed, so `poetry update` had nothing newer to find.
    Fixed in order: pushed `browseterm-db` (`16f36f1`) to GitHub; ran the
    real migration against the **live cluster DB** via `kubectl port-forward`
    + `Migrator.upgrade()` (not `init.py`, per the established lesson) — hit
    and fixed a live `alembic_version` mismatch along the way (the DB's
    bookkeeping pointed at a revision (`5d314ed78bd6`) absent from this
    session's local migration files; user identified the cause: **concurrent
    payments-related migration work happening in another terminal/session**
    against the same live DB). Verified no schema/tables were lost (`\dt`
    showed only the expected 7 tables, no unexplained ones) before manually
    stamping `alembic_version` to the last common ancestor and re-running —
    **flagged clearly to the user that two sessions independently touching
    the same live DB's migration bookkeeping is a real coordination hazard
    going forward**, even though this specific instance turned out benign.
    Then `poetry update browseterm-db` in `browseterm-server`, rebuilt,
    redeployed (needed a force-delete + retry too). Confirmed fixed: no
    errors in the new pod's logs.
59. **User then hit a `403 Forbidden: exceeded quota` error resuming a
    hibernated container.** Investigation found this project's actual
    highest-severity live bug this session, distinct from every earlier fix:
    **the reaper's hibernate has never actually deleted a pod, ever.**
    `_hibernate_one` passed the DB's own `id` as `deleteContainer`'s
    `container_id`, but `KubernetesContainerHelper.check_pod`
    (`container-maker/src/containers/containers.py:61`) matches `container_id`
    against the pod's own **Kubernetes UID** (`pod['pod_id']`), not the DB id
    — the exact convention `browseterm-server`'s own delete endpoint already
    documents in a comment ("the frontend sends 'container_id' but it's
    actually the kubernetes_id (pod UID)"). Passing the DB id meant
    `check_pod` never matched, `delete_pod` was silently never called, and
    `KubernetesContainerManager.delete()` **still unconditionally returned
    `{'status': 'Deleted'}` regardless of whether anything was found** — so
    every hibernate this whole project's history "succeeded" and moved the
    row to `HIBERNATED` while the pod kept running untouched. Live evidence:
    the user's container had **two live pods simultaneously**
    (`...1787633648`, 5h50m old, the real one with the actual saved data, and
    `...1787650618`, 67m old, a leftover from an incomplete resume) sharing
    one label, with **all three** of that container's accumulated Service
    objects load-balancing SSH connections randomly between them — plus a
    stuck `RESUMING` status and a doubly-stale `ip_address` pointing at
    neither. This is exactly the same *class* of pod-identity risk flagged
    much earlier in the ReplicaSet/ID-resolution design conversation, now
    caught concretely causing real damage. **Fixed**
    (`browseterm_workload/reaper/src/reaper.py`): pass `row['kubernetes_id']`
    to `deleteContainer` instead, with an explicit isolated failure (not a
    silent pass-through) if a row has none. `saveContainer` is unaffected —
    it already takes the DB id correctly and resolves the pod internally by
    name+label. 5 unit tests (2 new: the exact regression, and the
    missing-`kubernetes_id` edge case), all passing. **Manually unblocked the
    live user immediately**: deleted the orphaned pod + its leftover Service,
    corrected the DB row (`status` back to `RUNNING`, `ip_address` and
    `associated_resources` corrected to the surviving pod only) — quota
    confirmed back to 1/2 CPU, 1/2 pods. Committed (`86032fd`), pushed,
    **and deployed live** (image rebuilt+pushed, force-delete+retry needed
    on the pull again).
60. **User asked to tidy up the raw error message shown for cases like #59's
    quota error** (`_InactiveRpcError` dump: nested "Reason: None" x3, raw
    Kubernetes JSON body, `HTTPHeaderDict` noise) — traced to `api_handlers.py`
    doing `f"Error resuming container: {str(e)}"` (and the equivalent for
    create) with no cleanup of the underlying gRPC/K8s exception text.
    **Deferred, not implemented** — user asked to wrap up and clear the
    session before this was built. Pick up next session: add a small helper
    that recognizes the Kubernetes quota-exceeded shape (parse the embedded
    JSON body's `message` field, or match on `"exceeded quota"`/`code":403`)
    and substitutes a clean, actionable message, falling back to a generic
    clean message for anything else rather than ever showing the raw
    nested exception text to a user.
61. **All work from this whole session committed, pushed, and submodules
    synced**, per explicit user request before clearing the session.
    `browseterm-db`, `container-maker`, `browseterm-server`, and
    `browseterm_workload` all pushed to their GitHub `main` branches; the
    monorepo's own submodule pointers bumped and pushed to match (`git
    submodule status` clean, no `+` prefixes). All committed cleanly per the
    standing no-AI-attribution convention at the top of this file.

## Pending / not yet verified
- [x] ~~Grant Terminal.app Full Disk Access~~ — **done this session**: user
      granted it, `sudo tmutil addexclusion -p "/var/root/Library/Application
      Support/multipassd"` ran successfully (confirmed via `tmutil isexcluded` →
      `[Excluded]`), and a `.metadata_never_index` marker file was also dropped
      in that directory after `mdutil -i off` kept erroring "unknown indexing
      state" even with FDA (that path isn't a distinct indexable volume — not
      pursued further). **Turned out neither was the real fix** — see the new
      top "Where things stand" entry: the actual cause is host memory
      oversubscription/swapping, not Time Machine or Spotlight. Keep both
      changes (harmless), but don't expect them to prevent recurrence.
- [ ] **Fix the container-maker shared-client concurrency bug** (see "Where
      things stand" above) — `PodManager.run_command`/`run_command_with_stream`'s
      use of `kubernetes.stream.stream()` on the shared `KubernetesResourceManager
      .client` singleton can permanently break every other manager's plain REST
      calls (confirmed: broke `NamespaceManager.get()`, which is on the critical
      path for both the Save button and the reaper) if an exec-handling thread
      gets killed mid-call. Fix: use a dedicated `CoreV1Api()` instance for the
      `stream()` call instead of `cls.client`. Not yet fixed in code — restarting
      `container-maker` is the workaround if it recurs.
- [x] ~~container-maker's save RPC blocks a shared gRPC worker thread for the
      entire save duration~~ — **found and fixed same session** (2026-08-24,
      item #46/#47 above). `SaveUtility.save_image` no longer calls
      `JobManager.wait_for_job_completion` inline inside the gRPC handler; it
      creates the Job, computes the deterministic image name, and returns
      immediately, handing the wait + crash-recovery pod-image patch to a
      dedicated background thread outside container-maker's fixed 10-thread
      gRPC pool. Code + tests done (5 unit tests updated/added, all passing;
      one real regression caught and fixed in the not-yet-runnable
      `test_crash_hibernate_flow.py` integration test along the way). **Not
      yet rebuilt/pushed to Docker Hub, redeployed to the cluster, or
      committed to git** — do that next, then verify with a real Save click
      that the gRPC call returns fast and the spinner/crash-recovery patch
      still resolve correctly end-to-end.
- [ ] **Check host memory/swap pressure before touching the cluster, every
      session from now on** (`sysctl vm.swapusage`, `top -l 1 -o mem`) — this is
      now the actual root cause of the long-running "disk I/O contention"
      mystery (see top "Where things stand" entry), superseding the old
      iostat/backupd-focused playbook further down this file (which still
      correctly detects *that* something's wrong, just misattributed *what*).
- [ ] **Observe the save reconciler actually recover a real stuck save
      end-to-end** — deployed, unit-tested, and confirmed connected/running
      clean this session, but the one row that demonstrated the original bug
      was fixed manually via SQL *before* the reconciler existed, so its
      orphan-recovery path (as opposed to its decision logic in isolation)
      hasn't been watched happen live. Trigger a fresh save and, ideally,
      deliberately kill the snapshot Job's pod mid-run
      (`kubectl delete pod <snapshot-job-pod> -n browseterm --force`) to
      force the exact orphaned-Running scenario, then confirm the row flips
      to `Failed` within ~90s without any manual DB intervention.
- [ ] **Hibernation/reaper testing** — **reaper is now deployed** (2026-08-24
      late morning; `browseterm_workload/reaper/env.mk` created by hand, `make
      dev_setup` applied ServiceAccount/Role/RoleBinding/CronJob cleanly, image
      already existed on Docker Hub). Test is **in-flight but blocked**: idleness
      simulated via SQL on `namah_ssh_ubuntu_test`
      (id `473f769c-4e5f-48ca-9a33-b572434bab63`), manual run triggered
      (`kubectl create job reaper-manual-test-1 --from=cronjob/reaper -n
      browseterm`), but that job's pod has been stuck `ContainerCreating` due to
      the disk I/O contention documented above — **not yet confirmed whether the
      reaper actually hibernated the container**. Pick this up by checking
      `kubectl get pods -n browseterm | grep reaper-manual-test-1` and its logs
      first once contention clears; only create a fresh manual job if that one
      genuinely failed rather than just being stuck on image pull. Original
      investigation findings (from an earlier subagent, still accurate):
      - Reaper source: `browseterm_workload/reaper/` — `src/reaper.py`'s
        `Reaper.run()` queries idle containers, then per-container: gRPC
        `saveContainer` → gRPC `deleteContainer` (both via container-maker,
        mTLS) → `mark_hibernated` sets `containers.status = HIBERNATED`.
        Idle threshold column is **`last_active_at`** on `containers`
        (`browseterm-db/browseterm_db/models/containers.py:92`); default
        threshold is `IDLE_THRESHOLD_SECONDS` = 1 week, configurable via env
        var of the same name on the CronJob.
      - **How to simulate idleness for a test**: contrary to the reaper's own
        README, `socket-ssh` does NOT stamp `last_active_at` — it's actually
        bumped by `browseterm-server`'s `POST /container-activity`
        (`api_handlers.py:439`), called by a 90s-throttled heartbeat in
        `terminalpage.js` that only fires while the browser tab is open with
        live WS traffic. **Safe to simulate**: with the terminal page closed,
        `UPDATE containers SET last_active_at = now() - interval '8 days'
        WHERE id=...` directly via SQL — nothing will overwrite it in the
        background.
      - Resume/wake flow: `resume_container` in `browseterm-server/src/
        api_handlers.py:354` — sets `status=RESUMING`, recreates the pod via
        `create_container_in_k8s` using `saved_image` (falls back to the base
        image if never saved), then `status=RUNNING` on success or `FAILED`
        on any exception.
      - Deploy manifest: `browseterm_workload/reaper/infra/deployment/
        deployment.yaml` — ServiceAccount + Role (secrets get/list only,
        no pod verbs — deletion is delegated to container-maker) + CronJob
        (`schedule: "0 * * * *"`, hourly). Needs `browseterm-db-credentials`
        Secret, `NAMESPACE`, `IDLE_THRESHOLD_SECONDS`,
        `CONTAINER_MAKER_HOST`/`PORT`, `CONTAINER_MAKER_CERTS_SECRET_NAME`.
        Deploy via `cd browseterm_workload/reaper && make dev_setup`
        (needs `env.mk` — check whether `gen-env.sh` already fans one out for
        this submodule, or whether it needs adding there first).
      - **Test plan once deployed**: set `last_active_at` far in the past via
        SQL on a real running terminal → either wait for the hourly CronJob
        tick or trigger a manual `kubectl create job --from=cronjob/... ` run
        → confirm `containers.status` → `HIBERNATED` and the pod is gone
        → confirm resume-from-UI recreates it from `saved_image`.
- [ ] **Pod crash simulation testing — two distinct scenarios now, test both**
      (requested, not yet started; item #53/#54 above changed what the
      second one should do):
      1. **In-container crash** (process dies, pod object survives): use
         `kubectl exec <pod> -n <namespace> -- kill -9 -1` (SIGKILL
         everything in the pod), as the existing integration test does
         (`container-maker/tests/k8s/integration/resources/
         test_crash_hibernate_flow.py`). User pods have no explicit
         `restart_policy` (`container-maker/src/resources/pod_manager.py`),
         defaults to `Always` — kubelet restarts the container in place, pod
         phase stays `Running` throughout, DB `status` never changes (this is
         correct, not a gap — there's no separate "Crashed" status in this
         app's model, and there doesn't need to be). Confirm: kubelet
         auto-recovers with no explicit resume step, and check whether an
         in-flight SSH session shows a clean disconnect/reconnect or hangs
         silently (still an open question, never actually observed either
         way).
      2. **Pod loss** (the object itself disappears — node eviction,
         resource pressure, or directly via `kubectl delete pod` <pod> -n
         <namespace>` to simulate it manually): **this now has a real,
         implemented recovery path as of item #54** —
         `status_monitor` should flip `containers.status` to `HIBERNATED`
         within moments (via `mark_lost_if_running`), and resuming from the
         UI should recreate it from `saved_image` exactly like a normal
         hibernate/resume. **Not yet verified live** — everything here was
         validated with mocked unit tests only, never run against the real
         cluster. This is the actual next test to run: delete a real
         `Running` container's pod directly, watch `containers.status` in
         Postgres flip to `HIBERNATED`, then resume it from the UI and
         confirm it comes back correctly.
- [x] ~~Minor cleanup: stale `save_error` surviving a status change~~ — this
      WAS a real, live bug (not a stale data point as previously assumed):
      `ContainerOps.update()` silently dropped explicit `None` values, so
      `save_error=None` writes never actually cleared the column. Fixed this
      session (bug #29/#31 above), verified via a real integration test
      against a live Postgres.
- [ ] Consider rotating `~/browseterm/dockercreds`'s Docker Hub credential to a
      Personal Access Token instead of the real account password, since that's
      now what `container-maker`/the snapshot Job use for automated `docker
      login`/push (not urgent, user made an informed choice to proceed with
      the password as-is)
- [ ] `browseterm-db` still shows the migration-squash noise from `--fresh`
      init (13 deleted + 1 new consolidated migration) — `git checkout` it
      before any real commit in that repo, don't commit as-is (unchanged from
      earlier sessions; this session's `browseterm-db` commit staged only the
      two specific files actually changed, not `git add -A`, so this noise
      was NOT swept in — still worth cleaning up if it resurfaces, just
      confirmed not currently a live problem)
- [ ] Observability: no logs/metrics/traces infrastructure exists anywhere in this stack
      yet (only structured logs + request-ID correlation) — separate `make observability`
      target, out of scope so far, not attempted. Full plan (Loki/Prometheus/Tempo/Grafana,
      phased rollout, per-service work, tracing step-by-step + acceptance test) lives in
      `OBSERVABILITY.md`, referenced from `TODOPLAN.md` §2 — read that before starting,
      don't re-derive it here.

## Pickup instructions for Claude (start here next session)
1. **Read this file fully first** — it's the up-to-date summary; `CLAUDE_STATE.md`/
   `SETUP_TODO.md` at the monorepo root have more granular blow-by-blow detail
   from earlier sessions if needed, but this file supersedes them for current
   state.
2. **First check: did the user finish granting Terminal.app Full Disk Access
   and did the `tmutil addexclusion` command get run?** (See the top "Where
   things stand" entry and the first "Pending" item.) If not done yet, that's
   the immediate next step — do it before resuming testing, since a third
   contention episode this session ran 15+ min and trended worse rather than
   self-resolving, and this fix directly addresses that root cause.
3. **Check whether the VM's disk I/O contention has settled**:
   `kubectl get nodes --request-timeout=20s`. If it still times out, don't
   assume a cluster problem — check the Mac's own disk activity first
   (`iostat -d 1 3`, `ps aux | grep -iE "backupd|mdworker"`) before touching
   anything in the cluster.
4. **Resume the in-flight hibernation test** (reaper is now deployed — see
   "Where things stand" and the updated "Pending" item): check
   `kubectl get pods -n browseterm | grep reaper-manual-test-1` and its logs
   first before creating a new manual job — it may have completed once
   contention cleared. Confirm `containers.status` for id
   `473f769c-4e5f-48ca-9a33-b572434bab63` flipped to `HIBERNATED` and its pod
   is gone, then test the resume-from-UI flow to recreate it from
   `saved_image`.
5. Then move to **pod-crash-simulation testing** (test plan already written up
   under "Pending" above) — also **watch for a real save going into
   `Pending`/`Running`** during either test and let the save reconciler
   demonstrate itself naturally if one gets stuck, or deliberately force it
   per the "Pending" item above if the opportunity doesn't come up organically
   — this session's core fix hasn't been observed recovering a real stuck
   save yet.
6. Every time you fix something, verify it against the real running app
   (browser or an actual API call, or a direct `psql`/`kubectl exec` check),
   not just "the config looks right" — this has been true of literally every
   bug found across this whole multi-day session.
7. When hibernation and crash-sim testing are both done, and the remaining
   minor cleanup items are resolved (or explicitly deferred), write the
   mission's final completion report (local app URL, socket URL, K3s context,
   VM IP, ingress external IP, `/etc/hosts` mapping, terminal E2E result, save
   E2E result, hibernation result, crash-sim result, remaining blockers) —
   hasn't been written yet, there's always been one more thing in flight.
8. Keep updating this file as you go, same style: don't diary-append forever —
   periodically fold older "What we did today" entries' *conclusions* into
   "Where things stand" and trim detail that's no longer actionable, so a cold
   read stays fast even as the file grows across many sessions.

## Environment quick-reference
- VM: `browseterm-k3s` @ 192.168.252.2 (Ubuntu 24.04, 4 CPU / 8GB / 40GB)
- Ingress external IP: 192.168.252.200 (real routed LoadBalancer via MetalLB,
  **not** `kubectl port-forward` — traffic genuinely flows browser → that IP →
  nginx-ingress → the backend Service)
- `/etc/hosts`: `192.168.252.200  browseterm.local.com` and
  `192.168.252.200  socketssh.local`
- Core pods in namespace `browseterm` (count varies with HPA — `browseterm-server`
  and `socket-ssh` both autoscale 1-10 on CPU/memory)
- Useful when the VM acts up: `multipass exec browseterm-k3s -- cat /proc/loadavg`,
  `multipass exec browseterm-k3s -- sudo k3s crictl images` /
  `sudo k3s crictl rmi <image>` (to force a repull after pushing a new image —
  `imagePullPolicy: IfNotPresent` won't otherwise notice a reused `:latest` tag).
  A `crictl rmi`/`kubectl rollout restart` that reports a `DeadlineExceeded`
  error often still completes async in the background anyway — check
  `kubectl get pods` before assuming it failed and retrying.
- **Two distinct kinds of "the cluster seems stuck", tell them apart**: (1)
  brief CPU contention (multiple docker builds running, HPA scale-up) —
  usually self-resolves within seconds to a couple minutes, `/proc/loadavg`
  elevated but *declining* between checks; (2) **host-level disk I/O
  contention** (seen once this session, driven by something on the Mac itself
  — Time Machine/Spotlight were the leading suspects but not conclusively
  pinned down) — k3s's embedded datastore logs multi-minute SQL writes,
  `kubectl`/`multipass exec` time out on the TLS handshake specifically (not
  just "slow"), and it does NOT resolve in a couple minutes. Check
  `iostat -d 1 3` and `ps aux | grep -iE "backupd|mdworker"` on the Mac itself
  to tell #2 apart from #1 — don't keep retrying cluster commands into #2, it
  won't help and just adds more load; wait for host disk activity to drop.
- A stuck/hung Kubernetes Job (e.g. snapshot Job with no command timeout, now
  fixed) can silently starve the whole VM for hours and take the entire app
  down even though every pod shows `Running` — "pods up" isn't the same as
  "responsive". If the app is unreachable despite healthy-looking pods, check
  `kubectl get jobs -n browseterm` for anything with an unexpectedly long
  `DURATION` before looking anywhere else.

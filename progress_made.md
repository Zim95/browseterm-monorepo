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

## SESSION RECAP + PICKUP POINT (2026-09-10 session, written on explicit request so the next
## session can pick this up without re-deriving it) — READ THIS FIRST, then the detailed
## "Where things stand" entries immediately below go deeper on any one item.

**Where this session started**: device-based (OAuth Device Authorization Grant) login for the
Desktop app didn't exist yet - that was the very first ask. **Where it ended**: login works
end-to-end for Google (GitHub is wired up too but blocked on the account owner enabling "Device
Flow" on the GitHub OAuth App - a manual console step, not code), the local k3d cluster's Setup
button deploys a genuinely working local stack, terminal creation is quota-based instead of
subscription-based, and a long chain of real, previously-undiscovered bugs across almost every
local-stack component got found and fixed along the way - see below for the full list. Nothing
was committed to git this entire session (this project's standing "only commit when explicitly
asked" rule) - see the "Uncommitted changes, by repo" list at the end of this entry before
starting anything new, so work isn't accidentally lost or double-done.

### What got built
- **OAuth Device Authorization Grant login** (`browseterm-server` Cloud endpoints `/auth/device/
  start`+`/auth/device/poll`, `browseterm-desktop`'s login flow rewritten around them) - replaces
  the old system-browser-+-loopback design entirely (deleted, not kept as a fallback) because that
  design needed Local reachable to log in at all, which needed a cluster, which needed login first
  - a real chicken-and-egg this breaks. Google works for real (live-verified against the actual
  Google API). GitHub (`GithubDeviceAuthService`) is fully wired up in code but will 502 until the
  GitHub OAuth App has Device Flow enabled - tracked, not blocking.
- **`BROWSETERM_CLOUD_INTERNAL_API_TOKEN` and the token in `~/.browseterm/cloud_internal_api_token`
  file** (not an env var you export every launch) - `desktop/config.py` reads the file, falls back
  to the env var only as an override.
- **Device-quota-based terminal creation** (per explicit request: no more subscription-based
  `max_containers` gating). Cloud's `POST /containers` already did the real device-quota
  reservation (P12/P13, pre-existing, just discovered this session) - the actual fix was deleting
  the *separate* subscription-tier check in Local (`is_user_within_container_limit`, now gone
  entirely) that ran before Cloud's own check ever got a chance. The create-terminal form now
  shows real remaining quota ("/ N cores", "/ N GiB"), lets typing directly into the fields (no
  more `readonly`), and disables Create when a value is out of bounds - both live and re-checked
  once more right before submitting.
- **Subscriptions commented out** (nav link + route, per "we don't need subscriptions for now") -
  backend plan-gating logic elsewhere (`resume_container`) deliberately untouched.
- **Profile page shows "Current Device"** instead of "Current Plan" - needed a new Cloud endpoint
  (`GET /internal/users/{user_id}/active-device`) since Local has no device Bearer token of its
  own to ask the Bearer-gated `/devices` route directly.
- **Setup now installs ingress-nginx** (removing k3s's bundled Traefik first) - it never did this
  before at all; `browseterm.local.com` was completely unreachable until this was added, on any
  cluster Setup ever created. Idempotent + self-healing (a cluster that already exists from before
  this fix corrects itself on the next Setup click, no Teardown needed).
- **Pod monitor re-scoped to the actual always-on local-stack workloads** (container-maker,
  socket-ssh, browseterm-server, status-monitor, minio, ingress-nginx) after actually reading each
  component's real manifest, not going from memory - cert-manager/reaper/snapshot-job are
  CronJob/Job-spawned, not always-on, and were wrongly included before. Restart button added,
  gated on a real crash-signal check (`CrashLoopBackOff`/`ImagePullBackOff`/etc.), not merely
  "not Running" (which flickered during completely normal Setup startup).
- **CORS added to Cloud, then corrected** after the user caught the first version was wildcard
  (`allow_origins="*"`, applying to the *entire app*, not just the one route that needed it) -
  now scoped to the one real browser origin (`http://browseterm.local.com`, derived from
  `BROWSETERM_LOCAL_CALLBACK_URL`, not invented). This existed because P10 (an earlier session)
  had the browser connect directly to Cloud's SSE stream, and nobody revisited Cloud's own
  "CORS deliberately not added" decision from P07 when that shipped.

### Real bugs found and fixed (each one live-verified against the running pods/database, not just
### "should work now")
1. **`browseterm-server` (Local's actual Deployment name) was CrashLoopBackOff** -
   `psycopg2.OperationalError` connecting to a placeholder `"unused"` Postgres host. Root cause:
   the deployed image predated a real commit (`4fefb08`, P10) that removed the code needing
   Postgres at all - `local_stack.py`'s placeholder values were correct for current source, wrong
   for the stale image actually running. Fixed by rebuilding from current source.
2. **Same exact bug class, three more times**: `status_monitor` (predated `d13c48e` P09),
   `container-maker` (predated `229c044`), `socket-ssh` (predated `7a357bf` P11) were ALL running
   images built before their own respective "migrate off direct Postgres/Redis access onto
   Cloud's API" commits. Each rebuilt from current source and redeployed.
3. **Every local-stack component that calls Cloud's API was also missing `hostAliases`** (only
   `browseterm-server-local`'s manifest had it). On this single-Mac two-cluster dev setup,
   `browseterm.cloud.com` resolves inside `browseterm-k3s-local`'s own pods to whatever the Mac's
   own `/etc/hosts` maps it to (127.0.0.1, for the developer's browser) - not the real Cloud
   cluster - so every such call got "Connection refused" against its own loopback. Fixed for
   `status_monitor`/`reaper` (sourced-env.mk deploy path) and `container-maker`/`socket-ssh`
   (positional-arg deploy scripts, needed threading `CLOUD_INGRESS_HOST`/`_IP` through their own
   Makefiles+scripts+manifests, not just a live patch).
4. **`/etc/hosts`'s `socketssh.local` entry has been pointing at `192.168.252.200`** - a real IP,
   but from the *original* Multipass-VM-based k3s cluster this project used months before the
   current k3d-based one - **this whole session**, unrelated to any of the fixes above. This is
   why "SSH connect hangs": confirmed via socket-ssh's own logs that **zero** connection attempts
   ever reached the pod, even after fix #2/#3 above. Not auto-fixed (needs `sudo`) - the user was
   given the exact command and is expected to have run it, but this has **not been confirmed
   working from their side yet** - see "What's NOT yet confirmed" below.
5. **CORS was never configured on Cloud at all**, and P10 (an earlier session) made the browser
   call Cloud's SSE endpoint directly without anyone revisiting that. This is why a terminal's
   status appeared stuck on "Pending" in the UI even though the database and every backend service
   had already correctly moved it to "Running" in 1-3 seconds - confirmed by querying Postgres
   directly. Fixed (see above), then corrected again after the user caught the first fix being
   wildcard-scoped.
6. **The create-terminal +/- buttons stopped working** - a real regression from this session's own
   earlier subscription->quota rewrite (three separate leftover references to deleted
   `this.cpuConfigurable`-style fields, one of which silently hardcoded the actually-submitted
   CPU/Memory/Storage values back to 1/1/2 regardless of what the UI showed). Found via grep on
   the freshly-deployed pod's own files, not assumption. Fixed.
7. **The "Welcome to BrowseTerm!" login notification wasn't showing.** Not fully "removed" as the
   user suspected - P07 (earlier session) legitimately deleted the whole intermediate page the old
   "Logging in via Google..." message ran on, since that page can't exist in the new
   Cloud-owns-OAuth architecture. But the backend's own `auth_result=success` redirect param was
   already correct and simply never read by anything - `home.html` (confirmed the ACTUAL page
   users see; `home.js` is dead code only loaded by an internal test harness) now reads it.
8. **`local_stack.check_prerequisites()`'s own `/etc/hosts` check was too weak** to have ever
   caught bug #4 - it only checked whether the hostname string appeared anywhere in the file, not
   that it actually pointed at `127.0.0.1`. Replaced with a check that parses real lines and
   requires the first column to be `127.0.0.1` for that hostname.

### What's NOT yet confirmed (the actual next step for whoever picks this up)
The user was given this exact command to run (needs `sudo`, this app must never run it
unprompted):
```
sudo sed -i '' 's/^192.168.252.200  socketssh.local/127.0.0.1\tsocketssh.local/' /etc/hosts
```
...and a 6-step test plan (run the command -> verify with `grep socketssh.local /etc/hosts` ->
fully close/reopen the browser tab, not just reload -> create a terminal, watch the quota display
-> confirm it goes Pending->Running LIVE without a manual refresh (tests the CORS fix) -> click
Play/Connect and confirm SSH actually connects (tests the `/etc/hosts` fix). **As of this entry,
there is no confirmation from the user that they ran the command or that either fix actually
worked end-to-end from their side.** If a new session starts and this hasn't been mentioned yet,
that's the first thing to ask about - don't assume either fix is confirmed working just because
the code/live-pod verification above was thorough for the SERVER side of each bug.

### Uncommitted changes, by repo (nothing committed all session - `git status --short` as of this
### entry)
- **browseterm-server** (Cloud): `app.py`, `infra/cloud/cloud.yaml`, `scripts/cloud/cloud-setup.sh`,
  `src/authentication/provider_oauth_service.py`, `src/cloud/device_handlers.py`,
  `src/cloud/oauth_handlers.py`, `src/common/config.py`, 3 test files.
- **browseterm-server-local**: `app.py`, `src/api_handlers.py`, `src/cloud_client/client.py`,
  `src/containers/containers_helpers.py`, `src/containers/containers_service.py`,
  `src/template_handlers.py`, `templates/{base,home,profile,terminals}.html`,
  `templates/static/css/terminals.css`, `templates/static/js/{profile,terminals}.js`, new
  `tests/integration/containers/test_device_quota.py`.
- **browseterm-desktop**: `README.md`, `main.py`, most of `desktop/*.py` except `local_stack.py`/
  `cluster_manager.py` which are new+untracked (pre-existing from before this session, per the
  entries below), `desktop/web/*`, `tests/test_desktop.py`, new `tests/{test_api_cluster,
  test_cluster_manager,test_config,test_local_stack}.py`; `desktop/loopback_server.py` and
  `tests/test_loopback_server.py` deleted.
- **container-maker**: `infra/k8s/deployment/deployment.yaml`,
  `scripts/k8s/deployment/k8s-development-setup.sh` (hostAliases plumbing).
- **socket-ssh**: `Makefile`, `infra/deployment/deployment.yaml`, `scripts/deployment/setup.sh`
  (hostAliases plumbing).
- **browseterm_workload**: `reaper/infra/deployment/deployment.yaml`,
  `status_monitor/infra/deployment/deployment.yaml` (hostAliases). Also shows modified `.pyc`
  cache files under `status_monitor/` - harmless bytecode artifacts, not real changes, safe to
  ignore (arguably worth a `.gitignore` entry at some point, not done here).
- **browseterm-monorepo**: `env.mk.example`, `scripts/gen-env.sh` (the `SERVER_GOOGLE_DEVICE_*`
  fan-out from earlier in this session), this file.

### Test status as of this entry
Cloud 193/193. Local 125/125 (2 pre-existing, documented-elsewhere collection failures excluded).
Desktop 92/92. All live-verified against the actual running pods/database at each step, not just
green test suites in isolation.

## Where things stand (as of 2026-09-10, truly the final entry — user immediately caught that the CORS fix above was itself sloppy: wildcard origin on the whole app, not scoped to the one real caller. Fixed properly.)
**User: "Ohh no this is a security flaw. We are not supposed to do this. How do we fix this?"**
- reacting to the `allow_origins="*"` default just shipped. Right call, and worth being precise
about exactly what was wrong rather than just swapping in a fix: `CORSMiddleware` applies to the
**entire app** once added via `app.add_middleware` - there's no built-in per-route scoping in
Starlette - so the wildcard didn't just open `/events/stream`, it opened every endpoint on Cloud
to being read by JavaScript on any origin on the internet. `allow_credentials=False` genuinely
does prevent the classic *credentialed*-wildcard-CORS account-takeover pattern (p07.md section 58
- no ambient cookie can ride along), but that's not the only exposure: the SSE token is carried in
a URL query string, which is exactly the kind of value that leaks into `Referer` headers, access
logs, and browser history - a wildcard origin means any page that ever got hold of a leaked token
(through no fault of Cloud's own request handling) could read the stream from anywhere, not just
from `browseterm.local.com`.

**Fixed by scoping to the one real caller instead of removing CORS entirely** (removing it would
just reintroduce the original stuck-Pending bug) - `BROWSETERM_CORS_ALLOWED_ORIGINS` now defaults
to an origin **derived from `BROWSETERM_LOCAL_CALLBACK_URL`** (`http://browseterm.local.com`, the
one origin this project already treats as trusted/known, not a new value invented for this) rather
than `"*"`, still overridable via env var for a real multi-origin deployment. Also dropped
`allow_headers=["*"]` down to `CORSMiddleware`'s own default (the CORS-safelisted header set) -
`EventSource` sends no custom headers at all, so there was nothing that ever needed the wildcard
there either; tightened everything to exactly what's actually used, not what happened to be
convenient to write. **Live-verified the fix actually closes the hole, not just that the code
looks right**: `curl` with `Origin: http://browseterm.local.com` gets back
`access-control-allow-origin: http://browseterm.local.com` (echoed, not `*`); the identical
request with `Origin: http://evil.example.com` gets **no CORS header back at all** - a browser
correctly refuses to let that page's JS read the response. New
`TestCorsAllowedOriginsIsNeverWildcardByDefault` (2 tests: default is the derived Local origin and
explicitly asserts `'*' not in` the list; an explicit override is still respected) specifically so
this exact mistake can't silently land again in a future session without a test failing. 193/193
Cloud tests passing (was 191, +2). Rebuilt and redeployed `zim95/browseterm-server-cloud:latest`
once more.

**Not done this session**: the user has not yet re-tested end to end after the `/etc/hosts` fix
(needs their own `sudo` action) and this CORS correction together; the GitHub OAuth App's Device
Flow toggle; nothing committed to git.

## Where things stand (as of 2026-09-10, continued the final time this session — the REAL remaining causes of "stuck Pending" and "SSH hangs": Cloud has never had CORS, which broke silently the day P10 made the browser call it directly; and /etc/hosts's socketssh.local entry has been pointing at a dead Multipass-VM IP this whole session, unrelated to anything fixed today)
**User, after the previous round of fixes: "the ssh terminal is still stuck. And new terminals
are still stuck on pending."** Did not assume the earlier fixes were incomplete - checked the
actual live state first. `psql` directly against Cloud's Postgres showed **both** of this
session's test containers already sitting at `status = RUNNING`, updated within 1-3 seconds of
creation each time, container-maker/status_monitor logs showed the full Pending->Running pipeline
completing cleanly and instantly. **The backend has been correct this whole time** - both
remaining symptoms turned out to be two completely separate, real, previously-undiscovered bugs
on the client side.

**Root cause #1 - "stuck Pending" in the UI**: `terminals.js`/`terminalpage.js`'s `EventSource`
connects **directly from the browser** to Cloud's `GET /events/stream`
(`http://browseterm.cloud.com:9999`) for live status pushes - a genuine cross-origin request from
`browseterm.local.com`. Checked `p.md`'s own explicit, dated CORS decision: **"CORS: deliberately
not added... audited whether any browser JavaScript needs to call Cloud directly - it doesn't"**
- true when P07 was written. P10 (added later, per this file's own earlier entries) introduced
exactly the direct-browser-to-Cloud call that audit said didn't exist, and nobody revisited the
CORS decision when P10 shipped. Without `Access-Control-Allow-Origin`, the browser silently
refuses to deliver the SSE payload to the page's JS - `loadTerminals()`'s own initial fetch (a
plain same-origin-relayed call through Local, not through this broken path) is the only thing
that ever showed the real status, so only a manual page reload ever worked, never the live push.
Fixed: new `CORSMiddleware` on Cloud (`app.py`), a new `BROWSETERM_CORS_ALLOWED_ORIGINS` config
(same dev-permissive `"*"` convention as `BROWSETERM_ALLOWED_HOSTS`) - `allow_credentials=False`
is deliberate and load-bearing, not just a default, since `/events/stream` authenticates via a
query-string token, never a cookie, which is exactly what makes a wildcard origin safe here
(p07.md section 58 warns against *credentialed* wildcard CORS specifically, not wildcard alone).
191/191 Cloud tests still passing; rebuilt and redeployed `zim95/browseterm-server-cloud:latest`.

**Root cause #2 - "SSH connect hangs"**: checked `/etc/hosts` directly rather than assuming this
session's container-maker/socket-ssh fixes were insufficient - `socketssh.local` has been mapped
to `192.168.252.200` this **entire session**, a real but completely unrelated leftover from the
original Multipass-VM-based k3s cluster this project used months ago (that IP was the old
MetalLB pool address, documented in this file's very first entries) - `browseterm.local.com`
already correctly points at `127.0.0.1` (the current k3d cluster's port-mapped ingress), but
`socketssh.local` was never updated to match. Confirmed via socket-ssh's own logs: **zero**
connection attempts had ever reached the pod, even after this session's stale-image/hostAliases
fixes - the browser's WebSocket was dialing a dead address before ever reaching this project's
current cluster at all, so those earlier fixes were real and necessary but could never have been
sufficient on their own. Not fixed automatically - editing `/etc/hosts` needs `sudo`, so the user
was given the exact `sed` command to run themselves.

**Also hardened `local_stack.check_prerequisites()` against this exact bug class recurring
silently**: `_etc_hosts_has()` only checked whether the hostname string appeared anywhere in the
file at all - a stale entry pointing at the wrong IP entirely satisfied that check just as well as
a correct one, which is exactly how root cause #2 went unnoticed for so long. Replaced with
`_etc_hosts_maps_to_loopback()`, which parses each real (non-comment) line and requires the first
column to actually be `127.0.0.1` for that hostname - a commented-out line or a line pointing
anywhere else now correctly fails the check. Updated the error message accordingly: it no longer
suggests a blind `>> append` (which would never fix a wrong *existing* line - /etc/hosts resolves
top-down, so a correct line appended below a wrong one still loses to it, a bug class this project
has hit and documented before), instead giving a `sed`-based in-place fix per hostname. 4 new/
changed tests (`test_etc_hosts_maps_to_loopback_rejects_wrong_or_commented_entries` (parametrized:
wrong IP, commented out), `..._accepts_a_real_loopback_entry`) - captured the real function
before the file's autouse fixture monkeypatches it for every other test, since these two need the
genuine implementation. 92/92 desktop tests passing (was 89, +3 net after the rename).

**Not done this session**: the user has not yet re-tested after the CORS fix + `/etc/hosts` fix
(the latter needs their own `sudo` action first); the GitHub OAuth App's Device Flow toggle;
nothing committed to git.

## Where things stand (as of 2026-09-10, continued once more yet again — container-maker and socket-ssh were BOTH on stale, pre-migration images with the same missing-hostAliases gap as status_monitor/reaper; this is what "SSH connect hangs" and part of the pending-container noise actually was. Quota is now shown per-resource ("/ N cores"/"/ N GiB"), fields are typable, and a final quota check runs at Create time too.)
**User: "container stays pending" + "when we hit play, the ssh page hangs, connect does not
work."** Investigated both from live pod state and logs rather than guessing. `container-maker`'s
`save_reconciler` was still failing with the exact same `psycopg2.OperationalError: could not
translate host name "None"` signature as every other stale-image bug this session -
`git log --oneline` confirmed the checked-out source is already past `229c044 Migrate off direct
Postgres access onto Cloud's internal container API`, so this was the deployed image predating
that commit, not a source bug (4th occurrence of this exact bug class this session, after
browseterm-server-local, status_monitor, and now this). Separately, `socket-ssh` was logging
`[ioredis] Unhandled error event: ECONNREFUSED` on every request - grepping its actual current
source (not just `src/`, the whole repo) turned up **zero** ioredis/Redis references anywhere,
and `git log` showed HEAD is past `7a357bf P11: remove direct Redis access - consume ws_tokens
via Cloud's API instead`. Same bug, 5th occurrence. This fully explains the SSH connect hang:
socket-ssh's current code needs `BROWSETERM_CLOUD_API_URL` to validate a one-time ws_token before
a connection can proceed, so **it would have needed the hostAliases fix too even if it hadn't
also been on a stale image** - container-maker and socket-ssh were the two components flagged
three entries ago as "confirmed to have the same missing-hostAliases gap, not fixed yet since
they use `make prod_setup`'s positional-arg scripts instead of a sourced env.mk" - that follow-up
was overdue and this is what surfaced it.

**Fixed both properly this time**, not just live-patched: added `CLOUD_INGRESS_HOST`/
`CLOUD_INGRESS_HOST_IP` as new trailing optional positional args to both components' own
`deployment-setup.sh`-style scripts (`container-maker/scripts/k8s/deployment/
k8s-development-setup.sh`, `socket-ssh/scripts/deployment/setup.sh`) and their Makefiles'
`prod_setup` targets, added the identical `hostAliases` block to both manifests, and threaded
`cloud_ingress_host_ip` through `desktop/local_stack.py`'s `_deploy_container_maker`/
`_deploy_socket_ssh` (already resolved once per `deploy()` run, just never passed to these two
specifically before). Rebuilt both images from current source (`zim95/container-maker:latest`,
`zim95/socket-ssh:latest` - both `IfNotPresent`, so a plain `k3d image import` sufficed, no
registry push needed this time) and patched the live Deployments' `hostAliases` directly (a
strategic merge patch only touches the field specified - confirmed container-maker's earlier
`USER_POD_RUNTIME_CLASS` gvisor-strip patch survived untouched). Verified against the fresh pods
by exact pod name (not the `-l app=` label selector, which briefly mixed in the old pod's own
tail output during rollout and looked like the fix hadn't taken - a real false alarm worth
remembering): container-maker now gets a clean `200 OK` from `/internal/containers/stuck-saves`
on startup, socket-ssh's new pod logs show nothing but a clean "WS server listening" with zero
ioredis lines.

**Also finished the create-terminal form polish, per explicit ask**: each CPU/Memory/Storage
control now shows "/ N <unit>" next to the +/- buttons (`cpuQuota`/`memoryQuota`/`storageQuota`
spans, updated live in `configureResourceControl`) - cores for CPU, **GiB for storage** (the user
guessed MiB; corrected to GiB since `storage_limit` is already submitted with a `Gi` suffix
alongside memory, so GiB is what's actually consistent with what gets requested, not an arbitrary
choice). Removed `readonly` from all three inputs so typing a number directly now works, same as
the +/- buttons. `handleFormSubmit` now runs one more `isWithinDeviceQuota` check (a new shared
helper, also used by `updateSubmitButtonState`) immediately before ever calling the backend and
shows a "Not Enough Quota" notification if it fails - Cloud's own `create_container` reservation
check remains the real, final authority regardless.

Full desktop suite 89/89 (call-order test tolerated the new `cloud_ingress_host_ip` arg to
`_deploy_container_maker`/`_deploy_socket_ssh` without needing changes - it already used a
generic `lambda *a` for those two). Local suite 125/125 unchanged (no test coverage for the
mechanically-generated deploy scripts or the manifest hostAliases blocks - covered by the live
verification above instead). Rebuilt and redeployed `zim95/browseterm-server:latest` once more
for the terminals.html/js/css changes.

## Where things stand (as of 2026-09-10, continued once more again — +/- buttons fixed (a real regression from the previous quota-UI pass), Create Terminal button now live-validates against device quota, quota refreshes after each create instead of going stale)
**User: "the increment/decrement buttons are not working... they don't update the UI."** Root
cause: a genuine regression from this session's own earlier subscription->device-quota rewrite of
`terminals.js`. Three separate leftover references to the deleted `this.cpuConfigurable`/
`memoryConfigurable`/`storageConfigurable` fields survived the rewrite, each silently `undefined`
(always falsy) now:
1. `setupNumberInputs()` gated attaching the +/- click listeners on `this.cpuConfigurable` etc. -
   since that's now always falsy, **the listeners were never attached at all**, so the buttons
   were inert regardless of `disabled` state.
2. `TerminalsUtilities.adjustNumber(input, change, min=1, max=30)` had a hardcoded default
   `max=30` never actually overridden by any call site - even after fixing #1, +/- would have
   ignored the real per-device max set on the input's own `.max` attribute.
3. **The worst one, found last**: `handleFormSubmit`'s actual submitted values -
   `const cpuValue = this.cpuConfigurable ? parseInt(formData.get('cpu')) : 1` (and the memory/
   storage equivalents) - meant that even with a working slider showing the right number, **the
   value actually sent to Cloud on submit was hardcoded back to 1/1/2 regardless of what the user
   picked**. Found by grepping the freshly-deployed pod's own file for `cpuConfigurable` after the
   first "fix" and redeploy - it still had 1 match, which is what surfaced this.

Fixed all three: listeners now always attach (a `disabled` button/input already correctly
suppresses interaction - no need to gate whether a handler exists at all); `adjustNumber` now
reads `min`/`max` straight from the input element's own current attributes (kept in sync by
`configureResourceControl`) and dispatches a synthetic `input` event after changing the value
(needed since setting `.value` programmatically doesn't fire one on its own); the three submitted
values are now always read straight from the form, unconditionally.

**Also implemented, per explicit ask, not just the bug fix**: "Create button will only be enabled
when the user's CPU, Memory, and Storage are within the remaining limits." New
`updateSubmitButtonState()` checks all three inputs against their own live min/max on every
`input` event (typing or +/- both fire it now) and disables Create Terminal if any is out of
bounds - Cloud's own reservation check in `create_container` remains the real, authoritative
enforcement regardless of what the button shows. **Also closed the "known gap" flagged two
entries ago**: device quota was only ever fetched once at initial page load, so creating one
terminal wouldn't reduce what the form showed as available next time without a full page reload.
New `GET /device-quota` (`src/api_handlers.py:get_device_quota`, session-authenticated, thin
proxy to the same `CloudClient.get_active_device` call `template_handlers.py:terminals` already
used at render time) lets the browser re-check without reloading - called both when the
create-terminal modal opens and immediately after a terminal is successfully created (the same
moment Cloud actually reserved that usage against the device). 2 new tests
(`test_device_quota.py`). 125/125 passing (was 123, +2). Rebuilt and redeployed
`zim95/browseterm-server:latest` twice this pass (once for the button/listener fix, once more
after finding the submitted-value bug) - confirmed via `kubectl exec ... grep` on the live pod
that zero `*Configurable` references remain before calling it done.

## Where things stand (as of 2026-09-10, continued once more — terminal creation is now gated by device quota, not subscription; the real quota-enforcement mechanism turned out to already exist in Cloud, just shadowed by a Local-side subscription check)
**"Creating terminals should no longer be limited by the subscription - it should be based on the
remaining quota of the device/node, deducted per pod."** Investigated before writing anything:
Cloud's `POST /containers` (`browseterm-server/src/cloud/container_handlers.py::create_container`)
**already does exactly this** - a real, already-built P12/P13 feature this session didn't know
about until reading the handler - it validates requested cpu/memory/storage against the target
device's `available = allocated - used` capacity, reserves usage against the device BEFORE
creating the container row, and releases the reservation if the row-create then fails. `device_id`
can even be omitted (P13): Cloud auto-resolves the caller's currently-`ACTIVE` device, the same
"at most one ACTIVE device per user" invariant `_demote_other_devices` already enforces elsewhere.
None of that needed to change.

**The actual blocker was one layer up, in Local**, which called this already-correct Cloud
endpoint but gated reaching it on a *separate*, purely subscription-based check first:
`containers_service.py::create_container_in_db` called `is_user_within_container_limit(user_id)`
- a `max_containers` count check against the user's subscription tier, unrelated to actual
resource availability - and raised before Cloud's own device-quota logic ever ran. Removed that
call entirely (not commented - this one is being replaced by a better mechanism, not temporarily
hidden) and deleted `is_user_within_container_limit` itself along with its now-dead imports
(`get_user_current_subscription_plan`, `GetUserSubscriptionPlanModel`, `list_user_containers`,
a stray pre-existing `from ast import Dict` that had nothing to do with `ast` at all) - confirmed
via grep it had exactly one caller anywhere in the repo before deleting.

**The create-terminal form's CPU/Memory/Storage inputs had the identical problem one level up
in the UI**: `terminals.js` disabled/enabled each control based on whether the user's subscription
tier had that resource marked `"configurable"` (an all-or-nothing per-tier feature flag, not a
numeric bound - the actual HTML `max` was a flat, meaningless `30` regardless of plan or device).
Replaced with real device-quota bounds: reused the `GET /internal/users/{user_id}/active-device`
endpoint built earlier this session (originally for Profile's "Current Device") - Local's
`template_handlers.py::terminals` now fetches the active device and passes its
`available_cpu`/`available_memory_bytes`/`available_storage_bytes` down; `terminals.js` sets each
input's `max` to the real remaining quota (bytes converted to whole GB, floored so the UI can
never suggest more than Cloud would actually accept) and enables all three controls unconditionally
- no more subscription-tier gating on whether they're even touchable. Below the minimum (e.g. no
device, or quota already exhausted), the control disables with "Not enough device quota remaining"
instead of the old "Only available to X subscription" messaging. Cloud's own reservation logic
remains the real enforcement regardless of what the UI shows - this only makes the shown bound
truthful. **Known, deliberately-accepted gap**: the quota shown is fetched once at page load, not
re-fetched when the create-terminal modal opens - creating one terminal then immediately opening
the modal again in the same page session could show a briefly-stale (too-high) max; Cloud's
real-time check still catches it safely either way, just as a rejected create instead of a
pre-disabled control. Left as a known follow-up rather than adding a new live-refresh endpoint
under an already very large session.

Full suite still 123/123 (no test ever covered `is_user_within_container_limit` - confirmed by
grep before and after, zero references anywhere once removed). Rebuilt and redeployed
`zim95/browseterm-server:latest` live to `browseterm-k3s-local` (same build+import+restart
pattern used all session).

**Not done this session**: refreshing device quota when the create-terminal modal opens (see
above); container-maker/socket-ssh's own missing hostAliases (flagged earlier this session, still
outstanding); the GitHub OAuth App's Device Flow toggle; a real human login+Setup+Teardown
click-through; nothing committed to git.

## Where things stand (as of 2026-09-10, continued yet again — welcome notification restored, real "stuck in Pending forever" root-caused and fixed (status_monitor stale image + missing Cloud hostAliases), subscriptions commented out, Profile shows Current Device)
**"Why aren't login notifications showing up, did we remove them?"** - checked git history rather
than guessing: P07 (`d7731fa`) genuinely DID delete two real notification call sites
(`oauth_callback.js`'s whole 182-line file, entirely removed) as a **necessary** side effect of
Cloud becoming the sole OAuth authority - the intermediate page they ran on literally cannot exist
in the new architecture (Local's `/auth/callback` is now an invisible server-to-server redeem +
redirect, no client-rendered page in between for a "Logging in via Google..." message to run on
at all). But the **"Welcome to BrowseTerm!" success notification specifically was recoverable**:
`api_handlers.py`'s `auth_callback` already redirects a successful login to `/?auth_result=success`
- that query param was just never read by anything. `home.html` (the actual production page -
confirmed `home.js` is dead code, only ever loaded by the internal `js_test.html` harness, never
the real page) now checks for it on load and fires `window.notifications.success(...)`, then
strips the param via `history.replaceState` so a refresh doesn't re-show it. "Logging in via
Google..." itself is honestly not recoverable in the old form - flagged to the user why, not
silently dropped.

**Added an "Open in Browser" button next to Teardown** (`desktop/api.py:Api.open_browser`,
`webbrowser.open` against `local_stack.INGRESS_HOST` - reused rather than reintroducing the
`BROWSETERM_LOCAL_URL` config constant removed earlier this session), shown only when
`cluster_exists`.

**"Terminal creation stuck in Pending forever" - fully root-caused and fixed, three real bugs
deep:**
1. The pod itself was never actually the problem - `container-maker` logs showed it reaching
   `Running` in ~25s, completely normally.
2. `status_monitor` (which watches pod phase changes and reports them to Cloud) was running a
   **stale image** - `git log` showed the current source is 2 commits past `d13c48e P09: migrate
   status_monitor off direct Postgres access onto Cloud's internal status API`, but the deployed
   image was still crashing with `psycopg2.OperationalError: could not translate host name
   "None"` - the exact same stale-image bug class as the `browseterm-server` crash found earlier
   this session, just in a different component. Rebuilt from current source and **pushed to Docker
   Hub for real** (`zim95/status-monitor:latest`, this manifest uses `imagePullPolicy: Always`
   unlike browseterm-server's `IfNotPresent`, so a local `k3d image import` alone wouldn't have
   stuck - a registry push was actually required this time).
3. Fixing #2 surfaced a **second, previously-invisible bug**: with the stale-image crash out of
   the way, status_monitor could finally reach its own "report to Cloud" step - which then failed
   with "Connection refused". Root cause: on this single-Mac two-cluster dev setup,
   `BROWSETERM_CLOUD_API_URL`'s hostname (`browseterm.cloud.com`) resolves inside
   `browseterm-k3s-local`'s own pods to whatever the **Mac's own `/etc/hosts`** maps it to
   (`127.0.0.1`, for the developer's browser) - Docker Desktop's DNS forwarding inherits the host's
   own hosts file. Connecting to `127.0.0.1:9999` from *inside a pod* means that pod's own
   loopback, not the Mac's - nothing listens there. `browseterm-server-local`'s own manifest
   already has a `hostAliases` override for exactly this (SETUP-LOCAL.md's own documented fix,
   using `host.docker.internal`'s real IP), but confirmed by grep that **status_monitor, reaper,
   container-maker, and socket-ssh manifests all lack it** - browseterm-server-local's own
   `_deploy_browseterm_server_local` was the only local_stack.py deploy step ever wired to receive
   `cloud_ingress_host_ip`. Added the identical `hostAliases` block to status_monitor's and
   reaper's manifests (the two "sourced env.mk" deploys, cheap to fix) and threaded
   `cloud_ingress_host_ip` through both `_deploy_status_monitor`/`_deploy_reaper` in
   `local_stack.py`. **container-maker and socket-ssh have the identical gap, confirmed, not fixed
   this session** - they use `make prod_setup`'s positional-arg deployment-setup.sh scripts
   instead of a sourced env.mk, a bigger multi-file change (manifest + Makefile + script per repo)
   deliberately left as a flagged follow-up rather than done blind under an already-large turn.
   **Live-verified the actual fix, not just the code**: patched the live secret/manifest,
   restarted, watched status_monitor's own logs go from `Connection refused` to real `200 OK`
   responses against Cloud, ending in `"updated container status" ... status: "Running"` for the
   exact container that had been stuck - the literal bug report, fixed and confirmed end-to-end,
   not just "should work now."

**Subscriptions commented out, per explicit "we don't need subscriptions for now"**: the
`/subscriptions` nav link (`base.html`, Jinja `{# #}` comment) and its route registration
(`app.py`, following the exact same commenting convention `create-payment` already used one line
below it) - backend quota/plan-gating logic (`resume_container`, etc.) deliberately untouched,
this only hides the UI entry points. `/payment` is already normally unreachable without a plan
selection from `/subscriptions` first, so no separate change needed there.

**Profile page: "Current Plan" replaced with "Current Device", per explicit request.** This needed
a genuinely new capability, not just a template edit: Local holds no device Bearer token (that
credential belongs to Desktop alone, p07.md section 16), so it had no way to ask Cloud "which
device is this user's active one." New Cloud endpoint `GET /internal/users/{user_id}/active-device`
(`device_handlers.py`, same internal-token-gated trusted-SYSTEM-caller pattern as every other
`/internal/*` route, queries `DeviceOps.find_one({"user_id": ..., "status": DeviceStatus.ACTIVE})`
- "active" is exactly the existing "at most one ACTIVE device per user" invariant
`_demote_other_devices` already enforces elsewhere, so there's never an ambiguous answer). New
`CloudClient.get_active_device(user_id)` in Local; `template_handlers.py:profile` now fetches it
(fails open to `None` on any Cloud error, matching the project's own established convention) and
passes it to `profile.html`/`profile.js` (renamed `currentPlan`->`currentDevice` throughout,
shows `device_name` or "No active device"). 3 new Cloud tests
(`TestGetActiveDeviceInternal`). Both Cloud (191/191) and Local (123/123, 2 pre-existing unrelated
collection failures excluded per the P07 commit's own documented convention) test suites green.

**All of the above rebuilt and redeployed live**: `zim95/browseterm-server-cloud:latest` (new
endpoint) and `zim95/browseterm-server:latest` (welcome notification, subscriptions, profile) via
the same `docker build` + `k3d image import` + restart pattern used all session;
`zim95/status-monitor:latest` via a real Docker Hub push (see above, `imagePullPolicy: Always`
required it). All three confirmed `1/1 Running` post-redeploy.

**Not done this session**: container-maker/socket-ssh's own missing hostAliases (flagged, not
fixed - see above); the GitHub OAuth App's Device Flow toggle; a real human login+Setup+Teardown
click-through; nothing committed to git.

## Where things stand (as of 2026-09-10, continued yet again — a bigger real gap found: Setup never installed ingress-nginx at all, so browseterm.local.com was completely unreachable)
**User asked to open `browseterm.local.com` and it 404'd outright** ("404 page not found", the
exact plain-text Go `net/http` default handler string) - not the app returning a 404, something
in front of it was. Root-caused by checking, not guessing: `kubectl get pods -n ingress-nginx`
on `browseterm-k3s-local` returned **"No resources found"** - `local_stack.py`'s `deploy()` never
installed ingress-nginx at all, on any Setup run, ever. Confirmed by grep: zero mentions of
"ingress-nginx" anywhere in `local_stack.py` outside of a hostname string. Meanwhile
`kube-system` had a live `traefik` helmchart/pod/svclb - k3s's own bundled default, which
`cluster_manager.create_cluster()` never disables at cluster-creation time - squatting on host
port 80 and answering with its own default-backend 404 for every request, Ingress resources
(`browseterm-server-ingress`, correctly configured, right backend/endpoint) sitting there
unused. This is exactly the "k3s's bundled Traefik squats on ports 80/443" gotcha
SETUP-LOCAL.md step 2 already documents and gives the fix for - it had just never been ported
into `local_stack.py`'s automation, only ever done by hand in earlier sessions against
now-deleted clusters.

**Fixed live immediately** (`kubectl delete helmchart traefik` + apply the exact ingress-nginx
manifest URL/version SETUP-LOCAL.md step 2 specifies + wait for its rollout) so
`browseterm.local.com/login` serves the real login page right now (verified `curl` 200, then
opened it in the browser). **Fixed in code so this can't recur**: new
`local_stack._ensure_ingress_nginx()`, called as the very first step of `deploy()` (before even
`_ensure_namespace()`) - idempotent (checks whether `ingress-nginx-controller` already exists
first, so a second Setup click against an already-provisioned cluster doesn't redundantly
re-apply/re-wait), and self-healing for a cluster that already exists from before this fix (no
Teardown needed - the very next Setup click fixes it, since `deploy()` runs unconditionally
every time regardless of whether `create_cluster()` actually created anything this time).
Placed in `local_stack.deploy()` rather than `cluster_manager.create_cluster()` deliberately, for
exactly that self-healing property - a fix living only in `create_cluster()` would only ever
protect a cluster created after the fix landed, never one already sitting there broken. Also
fixed `check_prerequisites()`'s own error message, still stale from before this session's earlier
CLOUD_INTERNAL_API_TOKEN fix (said "set it as an environment variable" as the only option, when
the local-file fallback is now the primary mechanism). 4 new tests
(`test_ensure_ingress_nginx_skips_everything_when_already_installed`/`..._installs_when_missing`,
plus `test_deploy_calls_every_step_in_dependency_order` updated for the new first step). 88/88
passing (was 86).

**Not done this session**: same outstanding items as before (GitHub OAuth App's own Device Flow
toggle, a real human login+Setup+Teardown click-through - the browser is now at least reachable
for that; verifying the rest of the local-stack pods actually work end to end through the real
Ingress rather than just being `Running`; nothing committed to git).

## Where things stand (as of 2026-09-10, continued again — real Setup crash found+fixed (stale image), login page now matches the real web login page + copy-code button, restart button no longer flickers during normal startup)
**Real bug hit live by the user actually clicking Setup, not a hypothetical**: `browseterm-server`
(the Deployment `browseterm-server-local`'s own manifest creates, on `browseterm-k3s-local`) was
stuck in `CrashLoopBackOff` - `kubectl logs` showed `psycopg2.OperationalError: could not
translate host name "unused" to address` inside `status_listener.py`'s `PGListener.connect()`.
Root-caused by actually reading both sides rather than assuming: `desktop/local_stack.py`'s
`_deploy_browseterm_server_local`/`_ensure_db_placeholder_secret` deliberately pass placeholder
`POSTGRES_HOST=unused` etc, with a comment saying these are "never actually used for a real
Postgres connection in the V2 local-cluster architecture" - **true of the current source**
(`browseterm-server-local`'s own `app.py` confirms in its own P10 comment: "the old
status_listener_service... is removed - the browser now connects directly to Cloud's own
GET /events/stream"), **but false of whatever image was actually deployed**. `git log` on
`browseterm-server-local` confirmed HEAD is 5 commits past the P10 removal commit
(`4fefb08`) - the deployed `zim95/browseterm-server:latest` on Docker Hub simply predates it,
because `local_stack.py`'s Setup flow only ever runs `make prod_setup` (apply manifests), it never
builds or pushes this component's image itself - nothing in this project's automated Setup path
was ever responsible for keeping that image current. **Fixed by rebuilding from the real current
source** (`docker image build -f infra/deployment/Dockerfile.deployment`, confirmed via `git log`
this checkout has no divergence from `origin/main` first) and `k3d image import`ing it into
`browseterm-k3s-local` (`IfNotPresent` pull policy picks it up without a registry push, same
pattern used for Cloud's own image all session) - deleted the crashing pod, its ReplicaSet
recreated it against the fresh image, confirmed `1/1 Running`, 0 restarts, clean startup logs, real
`GET /login` traffic served. **Not a Desktop-code bug** - `local_stack.py` itself needed no change,
this was a stale-artifact problem, the kind that will recur any time `browseterm-server-local`'s
source moves ahead of what's actually pushed to Docker Hub without a corresponding rebuild+push -
worth remembering next time Setup fails against a Docker-Hub-pulled image with a stack trace that
looks like it's calling code the current source doesn't have.

**Login page now visually matches the real web login page**, per explicit ask. Read
`browseterm-server-local/templates/{login.html,static/css/login.css}` for the actual colors/
layout/spacing (`#A8FBD3` page background, white card, stacked full-width buttons, `#4285f4`/
`#24292e` button colors, hover lift+shadow) and matched them exactly in
`desktop/web/login_start.html` - **except** the icon source: the web page pulls Font Awesome from
`cdnjs.cloudflare.com`, which this app's login window has no business depending on just to render
a button, so the Google "G" and GitHub Octocat marks are inlined as SVG instead (both official,
widely-embedded public brand assets, not proprietary/confidential - no visual difference from the
web page's plain single-tone icons). `app.py`'s `_show_device_code`/`_show_login_error` updated
for the restructured `#codeRow` wrapper element.

**Added a copy-to-clipboard button next to the device code**, per explicit ask - a small button
using `navigator.clipboard.writeText()`, with a brief checkmark-icon confirmation on click. Pure
front-end addition, no Python-side change needed.

**Restart button: fixed the exact flicker-during-Setup problem the user asked about.** Root cause
confirmed by checking: `showRestart` was `pod.phase !== 'Running'`, which is true for a
completely healthy pod still in `Pending`/`ContainerCreating` on its way up during a normal ~30-90s
Setup run - the button was appearing and disappearing for pods that were never actually broken.
Replaced with real failure-signal detection: new `cluster_manager._is_crashing(phase, statuses)`
checks `phase == "Failed"` and each container's `state.waiting.reason` against a real crash-reason
set (`CrashLoopBackOff`/`ImagePullBackOff`/`ErrImagePull`/`InvalidImageName`/
`CreateContainerConfigError`/`CreateContainerError`/`RunContainerError`) or
`state.terminated.reason == "Error"` - a bare `Pending`/`ContainerCreating`/`PodInitializing` pod
with no such reason present is correctly never flagged. `list_pods()` now returns a `crashing`
field per pod; `app.js`'s `showRestart` reads it directly instead of re-deriving from phase. 6 new
tests (`test_is_crashing_false_during_normal_startup`/`test_is_crashing_true_on_real_failure_
signals`, parametrized) plus the two pre-existing exact-dict-equality `list_pods()` tests updated
for the new field. 86/86 passing (was 77).

**Not done this session**: same outstanding items as before (GitHub OAuth App's own Device Flow
toggle, a real human login+Setup+Teardown click-through, nothing committed to git).

## Where things stand (as of 2026-09-10, continued — GitHub device flow added, two-button login UI, pod-monitor audit + restart button, code-style cleanup, CLOUD_INTERNAL_API_TOKEN fix)
**Code-style pass on this session's own new code, per explicit user ask** ("multiple try/except
blocks -> one try with multiple excepts", "if/elif chains -> dictionaries"), applied only where it
doesn't lose real information: `device_auth_poll` (Cloud) is now one try wrapping the whole
pipeline with ordered `except json.JSONDecodeError`/`ValidationError`/`DeviceRegistrationError`/
`Exception` clauses (safe specifically because these are genuinely disjoint types - a bare `except
Exception` used for two *different* narrow purposes, e.g. "bad JSON" vs "process_user_info
failed", can't be merged without losing which one actually happened, so `json.JSONDecodeError` was
given its own clause rather than folded into the catch-all). Its four sequential `if error ==
...` branches became one `_POLL_ERROR_RESPONSES` dict lookup. Desktop's `_run_login_flow` merged
its two try/excepts (both only ever raise `CloudClientError`, so merging loses nothing) into one
try/except/finally, and its expired/denied/fallback `if` chain became a `_POLL_TERMINAL_ERROR_
MESSAGES` dict lookup (the `complete`/`pending` branches stayed as real `if`s - they do
break/continue, which a dict can't express without contorting into a dict-of-callbacks, judged not
worth it for two branches). Both suites re-verified green after (188 Cloud, then 75 Desktop after
the sections below).

**Pod monitor: re-verified against the actual manifests rather than trusting the 2026-09-05
entry's memory of them, per explicit instruction** ("find out how many pods and jobs need to stay
running... do not monitor [triggered-only] jobs"). Extracted every `kind:`/`name:` pair from each
component's real prod manifest (`awk` over `container-maker`/`socket-ssh`/
`browseterm-server-local`/`browseterm_workload/{status_monitor,cert-manager,reaper,snapshot_job}`/
minio's manifest) instead of assuming: **cert-manager and reaper are both CronJobs** (not
Deployments - the 2026-09-05 entry's own inclusion of cert-manager was wrong under this
"always-on only" rule, corrected here), **snapshot_job has no persistent manifest in prod at all**
(container-maker spawns it as a one-off Job per save, confirming the 2026-08-30 finding), and
**minio is a Deployment** (`minio.yaml`) **plus a one-shot `minio-createbucket` Job** that runs
once at deploy time. Final `MONITORED_WORKLOAD_PREFIXES` (`desktop/cluster_manager.py`):
container-maker, socket-ssh, browseterm-server (browseterm-server-local's real Deployment name),
status-monitor, minio, ingress-nginx - cert-manager/reaper/snapshot-job deliberately excluded
(triggered-only, an "up/down" read means nothing for a pod meant to complete and disappear). New
`_EXCLUDED_WORKLOAD_PREFIXES = ("minio-createbucket",)` handles the one real collision: minio's
own pod name and its bucket-creation Job's pod name both start with `"minio-"`, so the prefix
match alone can't tell them apart. Extracted the combined decision into a new
`is_monitored_pod(name)` function shared by `list_pods()` and the tests, so test and production
logic can't drift apart. 4 new/changed tests in `test_cluster_manager.py`.

**Restart button, built this same session** (user's follow-up: audit the list first, "after this
build it"). Design: since every monitored workload is now a Deployment (no CronJobs left in the
list), restart is just `kubectl delete pod <name>` - the owning ReplicaSet recreates it
immediately, no pod -> ReplicaSet -> Deployment ownership lookup needed. New
`cluster_manager.restart_pod(namespace, name)`, `Api.restart_workload_pod` (returns the same shape
as `list_cluster_pods` so the UI re-renders from one response), and a per-row "Restart" button in
the pod table (`app.html`/`app.js`/`app.css`) shown only when a pod's phase isn't `Running`. 4 new
tests across `test_cluster_manager.py`/`test_api_cluster.py`.

**GitHub device flow, implemented in full** (per explicit instruction: "for now, only google will
work, setup everything for github as well but it will fail due to wrong credentials"). New
`GithubDeviceAuthService` (`browseterm-server/src/authentication/provider_oauth_service.py`) -
same shape as `GoogleDeviceAuthService`, but reuses the *existing* `GITHUB_CLIENT_ID`/`SECRET`
(GitHub's device flow is a per-app toggle, "Enable Device Flow", not a separate client type the
way Google's is) and its token endpoint needs no client secret at all (a real simplification over
Google's flow, confirmed against GitHub's own docs, not an oversight). Registered in
`DEVICE_FLOW_SERVICES = {"google": ..., "github": ...}`. This will 502 live until the account
owner turns on "Enable Device Flow" in the GitHub OAuth App's own settings (tracked separately,
matching the user's "let's fix github later" from the earlier session) - `device_auth_start`
already turns a provider `start()` failure into a clean 502, so nothing new needed there. Two new
Cloud tests (`TestDeviceFlowServices`, `test_github_provider_uses_github_service`) plus fixed two
pre-existing tests that were asserting `"github"` itself was unsupported (now false) and had
started making a **real, unmocked network call to github.com** as a side effect (caught by
actually reading the test failure output, not assumed) - switched to a genuinely nonexistent
`"facebook"` provider instead. Desktop side: `login_start.html` now shows two buttons ("Log in
with Google" / "Log in with GitHub"); `Api.start_login`/`DesktopApp._handle_start_login`/
`_run_login_flow` all thread a `provider` argument through end to end to
`start_device_login`/`poll_device_login`. Fixed several tests whose `on_start_login=lambda: None`
placeholders would now TypeError (the callback takes an arg now) - only one of them
(`test_start_login_callback_invoked`) actually exercises the call, so only it needed a real
assertion change; the rest just needed their lambda's arity fixed. New
`test_run_login_flow_threads_the_clicked_provider_through` locks in that clicking GitHub actually
reaches both `start_device_login` and `poll_device_login` with `"github"`, not a hardcoded
`"google"`. 188 Cloud / 75 Desktop passing.

**Both repos redeployed live** with all of the above: rebuilt `zim95/browseterm-server-cloud:latest`
from the standalone `~/browseterm/browseterm-server` checkout, `k3d image import`ed into
`browseterm-k3s`, `kubectl rollout restart`ed (no new env vars needed for GitHub specifically -
`GITHUB_CLIENT_ID`/`SECRET` already existed on the live Secret from the original P07 setup).

**Fixed the `BROWSETERM_CLOUD_INTERNAL_API_TOKEN is not set` error the user hit clicking Setup.**
Root cause: this is real, intentional, load-bearing config (`local_stack.check_prerequisites()`
refuses to deploy the local stack without it, exactly matching SETUP-LOCAL.md step 5's own
warning that Local's every internal-API call otherwise silently 401s) - not a bug, just a value
that was never exported into the shell the desktop app gets launched from. Retrieved Cloud's real
live value (`kubectl get secret browseterm-internal-api-token -n browseterm -o jsonpath=...` on
`k3d-browseterm-k3s`) and gave it to the user as the exact `export` command to run before
`python main.py`. Also found and fixed real staleness in `browseterm-desktop`'s own docs while in
there: `README.md` still fully described the pre-device-grant login flow (WebView loads Local's
real `/login` page, references a `BROWSETERM_LOCAL_URL` env var that no longer exists anywhere in
the codebase) and `main.py`'s docstring made the same claim - both rewritten to describe the
actual device-grant flow and the real env vars (`BROWSETERM_CLOUD_API_URL`,
`BROWSETERM_CLOUD_INTERNAL_API_TOKEN`) this app now needs.

**User then rejected the export-it-yourself fix outright**: "the app should have this thing baked
in, I should not be exporting this before running it." Replaced it with a local-file fallback
instead, same `~/.browseterm` directory `STATE_FILE` already uses (never inside a git repo at all,
so unlike a repo-local secret there's no `.gitignore` rule that needs to keep being right).
`desktop/config.py`'s `BROWSETERM_CLOUD_INTERNAL_API_TOKEN` now reads the env var first, falling
back to `~/.browseterm/cloud_internal_api_token` (0600, mirrors `DesktopState.save()`'s own
permission convention) via the new `_read_local_cloud_internal_api_token()` - the env var still
works as a one-off override, but day-to-day nothing needs exporting. Wrote Cloud's real live token
into that file this session (`kubectl get secret browseterm-internal-api-token -n browseterm -o
jsonpath=... | base64 -d`, this app never writes the file itself - set up once by hand, same as
Cloud's own `env.mk` secrets) and verified `poetry run python -c "from desktop.config import
BROWSETERM_CLOUD_INTERNAL_API_TOKEN"` loads it correctly with the env var deliberately unset. 2
new tests (`tests/test_config.py`, a file that didn't exist before). README updated again to
match. 77/77 passing (was 75 - this file plus its 2 tests).

**Not done this session**: the GitHub OAuth App's own "Enable Device Flow" console toggle (account
owner's to do, same as before); actually clicking through a real login+Setup+Teardown cycle in the
live Desktop app (still needs a human at a real Google/GitHub consent screen - see the entry
below). Nothing in either repo was committed to git this session either (same standing
"only commit when explicitly asked" convention).

## Where things stand (as of 2026-09-10 — OAuth Device Authorization Grant (Google) implemented end-to-end and live-verified; this is Desktop's login flow now, breaking the login/cluster chicken-and-egg)
**Implemented option 3 from the 2026-09-05 chicken-and-egg entry below**: Desktop login now uses
the OAuth Device Authorization Grant (RFC 8628) against Google, exactly like `gh auth login`, so
it never needs `browseterm-server-local` reachable at all. GitHub device flow is explicitly out
of scope this session (needs its own OAuth-console follow-up - user chose to defer it) - only
"google" is wired up. Google console setup (a genuinely separate "TVs and Limited Input devices"
OAuth client, `SERVER_GOOGLE_DEVICE_CLIENT_ID`/`SECRET` in the root `env.mk`) was completed by the
user in the prior session; this session extracted the downloaded credentials JSON, stored it
through the normal `env.mk` -> `gen-env.sh` fan-out (adding `GOOGLE_DEVICE_CLIENT_ID`/`SECRET` to
`browseterm-server/env.mk`'s generation, same as the existing `GOOGLE_CLIENT_ID` convention), and
deleted the plaintext JSON the user had dropped in the monorepo root (untracked, uncovered by any
`.gitignore` rule - a real leak risk via a future `git add -A`).

**Cloud (`browseterm-server`)**: new `GoogleDeviceAuthService` (`src/authentication/
provider_oauth_service.py`) - `start()` calls Google's `/device/code` endpoint with the new
device-flow client (no secret needed at this step), `poll()` calls the standard token endpoint
with `grant_type=urn:ietf:params:oauth:grant-type:device_code` and always returns Google's raw
response (pending/slow_down/expired/denied are normal non-200 responses with an `error` field per
RFC 8628, not transport failures), `fetch_user_info()` reuses the existing userinfo call/
transform. Two new handlers in `src/cloud/oauth_handlers.py`: `device_auth_start` (`POST
/auth/device/start`, public) and `device_auth_poll` (`POST /auth/device/poll`, public but
possession-gated on a live `device_code`). Deliberately reuses every existing P07 building block
rather than inventing a parallel path: `process_user_info` (find-or-create user),
`RegisterDeviceRequest`/`_register_or_activate` (register-or-reactivate device), and
`DeviceTokenManager.issue_token` (mint the same per-device Bearer token the old bootstrap-redeem
path minted) - a device logged in this way is indistinguishable from one bootstrapped the old
way. No `HandoffManager` hop is needed or used: Desktop is already the one polling directly, with
nothing in between to hand a code to. 12 new tests in `tests/integration/cloud/
test_oauth_handlers.py` (`TestDeviceAuthStart`/`TestDeviceAuthPoll`), same "mock the boundary"
convention as the existing tests in that file. Full suite: 186/186 passing.

**Desktop (`browseterm-desktop`)**: `desktop/app.py`'s login flow rewritten - the old
system-browser-+-loopback-server design (still described in git history/the module's old
docstring) is fully retired, not kept as a fallback: `desktop/loopback_server.py` and its test
deleted outright, `BROWSETERM_LOCAL_URL`/`_backend_reachable`/`_connection_error_html` all removed
from `desktop/app.py` and `desktop/config.py` since login no longer touches Local at all -
verified nothing else in the app referenced them first. `_resolve_start_kwargs`/`_go_to_login_start`
simplified accordingly (no more pre-login Local-reachability gate). New `_run_login_flow`: calls
`cloud_client.start_device_login()`, shows the returned `user_code` in the WebView
(`login_start.html` gained a `#deviceCode` element) and opens `verification_uri` in the system
browser, then polls `cloud_client.poll_device_login()` on the provider's own `interval` (bumping
it by 5s on a `slow_down` response, per RFC 8628 section 3.5) until `status` is `complete`/
`expired`/`denied`/`error`, or the provider's own `expires_in` elapses. Two new functions in
`desktop/cloud_client.py` (`start_device_login`/`poll_device_login`) calling Cloud's two new
routes; `redeem_device_bootstrap` is left in place (Cloud's endpoint still exists) but is no
longer called by anything in this app outside its own direct tests. `test_full_desktop_login_flow_
round_trip` in `tests/test_desktop.py` rewritten for the new flow (mocks a pending-then-complete
poll sequence instead of simulating a loopback HTTP hit). Full suite: 69/69 passing.

**Live-verified against the real Cloud cluster and the real Google API, not just unit tests**:
patched the live `browseterm-oauth-credentials` Secret in `browseterm-k3s`'s `browseterm`
namespace with the two new keys (additive `kubectl patch --type=merge`, existing keys
untouched); added the two new `optional: true` env entries to `infra/cloud/cloud.yaml` (`optional`
specifically so a not-yet-patched Secret would degrade to device-login 401ing rather than
crash-looping the pod - see the P20 crash-loop incident this project already hit once from a
manifest change interacting badly with live state). **Did not run `make setup`/`cloud-setup.sh`
for this** - the standalone `~/browseterm/browseterm-server` checkout's env.mk (copied over from
the monorepo submodule checkout's generated one, since the standalone checkout - where all this
session's code edits were made - had no env.mk at all) is missing
`SNAPSHOT_REGISTRY_REPO_PREFIX`/`EXPECTED_KUBE_CONTEXT`/`BROWSETERM_LOCAL_CALLBACK_URL`/
`BROWSETERM_ALLOWED_HOSTS`/`CLOUD_INGRESS_HOST` entirely; running the full envsubst'd `make setup`
would have blanked those out on the live Deployment - a real regression risk, avoided by using a
targeted `kubectl set env deployment/browseterm-server-cloud --from=secret/
browseterm-oauth-credentials --keys=GOOGLE_DEVICE_CLIENT_ID,GOOGLE_DEVICE_CLIENT_SECRET` instead
(only touches those two env entries, triggers its own rollout). **This env.mk gap is pre-existing,
not introduced this session, and is worth fixing before anyone next runs a full `make setup` from
that checkout** - flagged here rather than fixed, since reconstructing the missing values wasn't
this session's task. Built the Cloud image straight from the standalone checkout (`docker image
build -f infra/cloud/Dockerfile.cloud`, tag `zim95/browseterm-server-cloud:latest`), `k3d image
import`ed it into `browseterm-k3s` (`IfNotPresent` pull policy on the Deployment means the
rollout picks up the freshly-imported content under the same tag without a registry push, same
"no registry push needed" pattern documented in the 2026-08-31 P07 entry below), then ran the
`kubectl set env` above, which triggered the rollout - confirmed `1/1 Running`, confirmed via
`kubectl exec ... grep` that the new pod's `oauth_handlers.py` actually contains
`device_auth_start`/`device_auth_poll` and that `GOOGLE_DEVICE_CLIENT_ID`/`SECRET` are actually
present in its environment. Then hit both new routes for real over HTTP against
`http://browseterm.cloud.com:9999`: `POST /auth/device/start` returned a **real** Google
`user_code`/`verification_uri`/`device_code` (not a mock), and `POST /auth/device/poll` against
that real `device_code` correctly returned `{"status": "pending"}` - i.e. Google's real
`authorization_pending` response, mapped correctly.

**Not done this session, left for the user to drive interactively next** (needs a human approving
a real Google login, which this session can't do): actually launching the Desktop app, clicking
"Log in", approving the code at `google.com/device` with a real Google account, and confirming the
app lands on the Device page with a Keychain-stored token - only the Cloud half of that round trip
has been live-verified so far, not the Desktop-app-in-a-real-WebView half. After that succeeds,
the user's own stated next step is testing the Cluster section's Setup/Teardown against the
already-existing live `browseterm-k3s-local` cluster (created in an earlier P07-era session, still
present - `k3d cluster list` shows it `1/1` right now) - worth noting before clicking Setup that
this cluster already exists outside of `cluster_manager.py`'s own bookkeeping, so Teardown-then-
Setup is the more meaningful first test of the button pair, not Setup alone. **Nothing this
session was committed to git** in either `browseterm-server` or `browseterm-desktop` (per this
project's "only commit when explicitly asked" convention) - both repos currently have this
session's changes sitting uncommitted in their standalone `~/browseterm/*` checkouts.

## Where things stand (as of 2026-09-04 — Desktop app's Cluster section built: resource sliders, k3d setup/teardown, pod monitoring)
**Implemented the resource-allocation UI that `browseterm-desktop/desktop/device_info.py`'s own
docstring had flagged as a known gap** ("no resource-allocation UI exists yet... offering the
machine's full detected capacity" as a placeholder) and that
`FINAL_BROWSETERM_V2_IMPLEMENTATION_PLAN.md` section 9 specs explicitly ("User configures:
allocated_cpu, allocated_memory_bytes, allocated_storage_bytes... Cloud validates allocation <=
physical capacity"). Added a **Cluster** section to the Device page, below the existing device-spec
card, per the user's request: three sliders (CPU cores / Memory GB / Storage GB, bounded by the
machine's detected totals from `device_info.detect_hardware()`), a single Setup/Teardown button,
a live status badge, and a polling pod table.

**New `browseterm-desktop/desktop/cluster_manager.py`**: shells out to `k3d`/`docker`/`kubectl`
(matching this project's existing convention everywhere else — see
`browseterm-monorepo/SETUP-LOCAL.md` — rather than adding a Kubernetes Python client dependency).
`create_cluster`/`delete_cluster` target the exact same `browseterm-k3s-local` cluster name and
`-p "80:80@loadbalancer"` mapping SETUP-LOCAL.md's manual procedure uses, so a cluster created via
this button is indistinguishable from one a developer creates by hand, and the doc's own manual
build/deploy steps still work against it unmodified. **Real constraint discovered**: k3d's CLI has
no per-cluster CPU limit flag at all (only `--servers-memory`/`--agents-memory`, which map straight
onto the Memory slider) — CPU is capped after cluster creation via `docker update --cpus` on each
node container (k3d's nodes are plain Docker containers labelled `k3d.cluster=<name>`), applied as
best-effort (a failure here doesn't tear down an otherwise-successful cluster create, since the
cluster is already usable regardless of whether the CPU cap itself lands). `list_pods()` uses
`kubectl --context k3d-browseterm-k3s-local get pods -A -o json`, returning `[]` rather than
erroring when the cluster doesn't exist yet.

**`desktop/api.py`** gained `cluster_status`/`setup_cluster`/`teardown_cluster`/`list_cluster_pods`.
Allocation defaults to half of detected capacity the first time the Cluster section is ever read on
a machine (leaves headroom for the host OS), then persists in `DesktopState`
(`allocated_cpu`/`allocated_memory_gb`/`allocated_storage_gb`, new fields in
`desktop/state.py`) — a per-machine preference, deliberately not cleared on logout (only
`device_id`/`device_name` are), since it's about this Mac's own resource split rather than which
account is currently signed in. Whether the cluster itself is up is **never cached** — every
`cluster_status()` call re-checks live via `cluster_manager.cluster_exists()` — so a cluster
deleted outside the app (e.g. a manual `k3d cluster delete`) is never misreported as still running
the next time the page loads. On `setup_cluster`, the chosen allocation is also pushed to Cloud via
the existing `CloudClient.update_device()` (already-existing method, previously unused by this
app) as a best-effort call — silently skipped if the device isn't yet activated, and a Cloud-side
failure never blocks the local cluster from coming up, same fail-open pattern already used
elsewhere in this project (e.g. `resume_container`'s subscription check).

**`device_info.py` changed**: dropped the `allocated_cpu`/`allocated_memory_bytes`/
`allocated_storage_bytes` keys it used to hardcode to 100% of detected totals — allocation is now a
stateful user preference assembled in `api.py`, not a hardware-detection concern, so
`detect_hardware()` returns only the physical totals now.

**UI**: sliders are disabled while the cluster is up (resizing a live k3d cluster's Docker resource
limits isn't attempted — Setup/Teardown is the only supported transition, matching what the button
itself implies); the pod table polls `list_cluster_pods()` every 5s only while the cluster exists,
starting/stopping automatically as Setup/Teardown resolve.

**Tests**: 12 new (`tests/test_cluster_manager.py` mocks `subprocess.run` directly to cover
`cluster_manager`'s own k3d/docker/kubectl invocations without needing real CLI tools or a real
cluster; `tests/test_api_cluster.py` mocks `cluster_manager` itself to cover `Api`'s allocation
defaulting/persistence/Cloud-sync logic in isolation, with `DesktopState.save` monkeypatched to a
no-op in every test so nothing touches this machine's real `~/.browseterm/desktop_state.json`).
Full suite: 41/41 passing (`poetry run pytest tests/`).

**Same-session regression found and fixed live: removing `allocated_*` from `detect_hardware()`
(above) broke first-time login itself.** `desktop/app.py::_run_login_flow` reuses
`detect_hardware()`'s output directly as the request body for `redeem_device_bootstrap` -->
Cloud's `POST /devices` (`browseterm-server/src/cloud/device_data_models.py`'s
`RegisterDeviceRequest`) — and that model declares `allocated_cpu`/`allocated_memory_bytes`/
`allocated_storage_bytes` as **required**, not optional, so every login attempted after this
session's earlier edit failed at registration with 3 pydantic "Field required" errors (caught live
by the user testing a real login, not by the test suite — none of the existing tests exercise
`redeem_device_bootstrap` through `app.py`'s real code path with real `detect_hardware()` output).
Fixed by giving `DesktopState` a new `ensure_allocation_defaults(hardware)` method (defaults to
half of detected capacity and persists, exactly once, the first time either call site needs a
value — a no-op after that) and having both `app.py`'s new `_registration_payload()` (built
specifically to fix this) and `api.py`'s `cluster_status()` call it, so the value Cloud registers a
brand-new device with and the value the Cluster section's sliders first show are guaranteed to be
the same one, computed in exactly one place (`device_info.default_allocation`, also new). Full
suite re-run clean after the fix, including one pre-existing test
(`test_full_desktop_login_flow_round_trip`) whose `detect_hardware()` stub had to be filled out
with real `total_cpu`/`total_memory_bytes`/`total_storage_bytes` values to match — it had been
passing before only because nothing downstream previously read those fields.

## Where things stand (as of 2026-09-05, continued — Setup now actually deploys the local stack, not just a bare cluster)
**Per the user's explicit go-ahead ("Yes I want the setup to actually deploy these. Keep the code
ready. I will make the changes for the deadlock and we can start")**, built the real deployment
automation and wired it into the Setup button, so it stands up a genuinely working Local control
plane rather than an empty cluster. New `browseterm-desktop/desktop/local_stack.py`, called from
`api.py`'s `setup_cluster` right after `cluster_manager.create_cluster`.

**Did the manifest research first, not from memory** — dispatched a fact-finding fork to read the
actual `infra/deployment/` manifests, Makefiles, and setup scripts for all 7 components that need
real deployment (container-maker, socket-ssh, browseterm-server-local, status_monitor, cert-manager,
reaper, minio — snapshot_job confirmed to need nothing, it's spawned dynamically by container-maker
as a Job at save-time, no deployment manifest of its own exists), then independently re-verified the
exact Makefile target names myself before writing any code, since the fork's summary flagged a real
naming inconsistency worth confirming firsthand: `status_monitor` and `reaper` have **no
`prod_setup` target at all** — only `dev_setup` (which, despite the name, applies the real
prod-style `infra/deployment/deployment.yaml`, not a dev manifest).

**Design decision: reuse each repo's own `make prod_setup`/`dev_setup` target via subprocess,
rather than re-implementing envsubst/kubectl-apply logic in Python.** SETUP-LOCAL.md's own manual
procedure already *is* these exact make targets — reusing them keeps this module automatically in
sync with any future change to those scripts, instead of maintaining a second implementation that
could silently drift. Two real exceptions found and handled: `status_monitor`'s and `reaper`'s own
`dev_setup` scripts `source env.mk` directly (confirmed by reading both scripts) rather than taking
values as script arguments, so those two specifically get a real `env.mk` file written into their
repo checkout before `make dev_setup` runs; every other component's Makefile does `include env.mk`
too (would hard-error if the file doesn't exist at all) but takes its real values as `make
VAR=value` command-line overrides instead, so those just get an empty placeholder file touched into
existence first.

**One real landmine found by actually reading the manifest instead of assuming**: container-maker's
prod `deployment.yaml` hardcodes `USER_POD_RUNTIME_CLASS=gvisor` as a **literal string**, not an
envsubst placeholder — correct for the single-node k3s PROD host (`setup.k3s.sh` installs
`runsc`/registers the RuntimeClass there), but a k3d-in-Docker local cluster has no gVisor
RuntimeClass at all, so every workspace pod container-maker tried to create would fail to schedule
with "RuntimeClass not found." Since this can't be overridden via envsubst (it's not a
`${VAR}`), `local_stack.py` applies a `kubectl patch` immediately after `make prod_setup` to blank
the value back out — container-maker's own `pod_manager.py` already treats an empty value as "omit
the field entirely" (`resource_config.py`: `os.getenv(...) or None`), exactly what its own
dev/docker-desktop manifest already does. Real, deliberate consequence, documented in code: local
workspace pods run unsandboxed (node-default runc) rather than gVisor-isolated — judged acceptable
since the local cluster is single-tenant (only the machine's own owner ever uses it), unlike the
shared PROD cluster this protection actually matters for.

**One value this session's code cannot invent, by design**: `BROWSETERM_CLOUD_INTERNAL_API_TOKEN`
must be byte-identical to Cloud's own `CLOUD_INTERNAL_API_TOKEN` (SETUP-LOCAL.md step 5's own
warning, re-confirmed in `browseterm-server-local/infra/deployment/deployment.yaml`'s own inline
comment — every internal-token-gated Local→Cloud call, i.e. session validate, container CRUD,
catalog, sse-tokens, silently 401s without it). New `desktop/config.py` entry with no default;
`local_stack.check_prerequisites()` refuses to deploy anything — checked **before**
`cluster_manager.create_cluster()` even runs, not after — if it's unset, so a doomed config fails
in milliseconds instead of after a ~90s cluster-create cycle. The same prerequisite check also
verifies `/etc/hosts` has both `browseterm.local.com` and `socketssh.local` pointing at 127.0.0.1
(SETUP-LOCAL.md's own manual step) — checked, never silently written, since editing `/etc/hosts`
needs `sudo` and this app must never do that unprompted.

**Deploy order implemented exactly as the manifests' own references dictate** (namespace →
`browseterm-internal-api-token` + placeholder `browseterm-db-credentials` Secrets → minio →
cert-manager CronJob, triggered once via a one-off `kubectl create job --from=cronjob/` and waited
on to actually complete, since container-maker's Secret doesn't exist until that job mints it →
`host.docker.internal`'s IP resolved live via `docker run --rm alpine getent hosts ...` for
browseterm-server-local's cross-cluster `hostAliases` → container-maker → socket-ssh →
browseterm-server-local → status_monitor → reaper, the last of which is templated with the real
`device_id` from `DesktopState`, already known post-login by the time this button is reachable at
all — resolving reaper's own previously-documented "device doesn't exist yet at deploy time" gap
for free, simply because deployment now happens *after* login instead of at raw cluster-creation
time). Every `kubectl create <resource>` uses the same `--dry-run=client -o yaml | kubectl apply
-f -` idempotent-apply pattern SETUP-LOCAL.md itself already uses for namespace creation (done as
two chained Python subprocess calls, no shell pipe), so re-clicking Setup against an
already-partially-deployed cluster is safe, not a duplicate-resource error.

**Known limitation, not fixed this session**: if `local_stack.deploy()` fails partway (e.g. the
token was wrong), the k3d cluster itself still exists, so the button flips to "Teardown" — there's
no UI affordance yet to retry just the local-stack deploy without tearing down and recreating the
whole cluster first (wasteful if e.g. minio/cert-manager already succeeded). The error message does
surface in the Cluster section's error box either way. `REPO_PASSWORD`/`DOCKER_HUB_REPO_NAME` are
also new required-if-you-want-Save-to-work config (default blank/`"zim95"`) — same
already-established project convention of Save failing gracefully without it while the terminal
itself still works.

**Tests**: 15 new in `tests/test_local_stack.py` — `deploy()`'s own step ordering (mocking each
internal step function and asserting call order, since mocking every subprocess call across a
7-component pipeline would be unmaintainable), plus individual coverage of `check_prerequisites`,
`_make`'s env.mk-touching/variable-passing, `_write_env_mk`, the gvisor-strip patch's exact JSON,
the cert-manager CronJob trigger-and-wait, and `host.docker.internal` IP resolution — each mocked
at the `subprocess.run` boundary, same pattern as `test_cluster_manager.py`. `api.py`'s existing
cluster tests updated with an autouse fixture no-op'ing `local_stack` by default (mirroring how
`cluster_manager` itself is already mocked there), plus 3 new tests confirming the wiring: deploy
is called with the real device_id after cluster creation, a prerequisites failure prevents cluster
creation from being attempted at all, and a deploy failure surfaces in the returned status while
correctly still reporting the cluster itself as up. Full suite: 74/74 passing.

**Still blocked on, unchanged from the entry above**: none of the three login-deadlock fixes are
implemented yet — the user is pursuing the OAuth Device Authorization Grant route and is doing the
Google/GitHub console setup themselves before this resumes.

## Where things stand (as of 2026-09-05 — login/cluster chicken-and-egg surfaced; pod monitor scoped to the real local-stack workloads)
**The user, testing the Cluster section above, spotted a real, pre-existing architectural deadlock
this feature only made visible, not one it introduced.** Login requires Local
(`browseterm-server-local`, which serves `/login`) to be reachable
(`desktop/app.py::_backend_reachable`/`_resolve_start_kwargs`) — but Local has no standalone run
mode; per `SETUP-LOCAL.md` it only ever runs as a Kubernetes Deployment inside the very
`browseterm-k3s-local` cluster the new Setup button creates, and that button only lives on the
post-login Device page. No cluster → Local unreachable → can't log in → can't reach the button
that creates the cluster. Worse than that on closer trace: even the *redirect callback* after a
successful Google/GitHub OAuth currently depends on Local's own `/auth/callback` recognizing the
desktop-port cookie and bouncing the system browser to the loopback server (`app.py`'s module
docstring) — so Local sits in the login critical path twice over, not just for serving the initial
page.

**Discussed three ways to break the cycle, nothing implemented yet pending the user's choice**:
(1) add a "bootstrap Local" action to the existing pre-login connection-error page that runs the
k3d-create + deploy steps before login, so the Cluster section stays post-login as a
monitoring/reconfig panel; (2) decouple Local's own web server from Kubernetes entirely (run it as
a plain process/container the desktop app launches directly, reserving k3d purely for workspace
pods, matching `newplan.md`'s flow diagram more literally); (3) switch login itself to the OAuth
**Device Authorization Grant** (RFC 8628 — the `gh auth login`/`docker login` pattern: a
`user_code` + a generic verification URL, no redirect URI, no loopback server at all), which would
remove Local from the login path entirely since the desktop app would talk only to Cloud (and
Google/GitHub) to authenticate. **User is pursuing option 3**: registering a new Google OAuth
client of type "TVs and Limited Input devices" (device flow isn't available on the existing Web
application client type — a genuinely separate client_id/secret) and enabling GitHub's "Device
Flow" toggle on the existing OAuth App (no new GitHub app needed, same client_id). Not yet
implemented on either the Cloud or Desktop side — blocked on the user completing that console
setup first.

**Pod monitor scoped down to only the real local-stack workloads, per the user's explicit list**:
container-maker, socket-ssh, browseterm-server-local, status_monitor, cert-manager, reaper,
snapshot_job, minio, ingress-nginx — not k3s/k3d's own system pods (coredns, svclb-*,
local-path-provisioner, etc.) that would otherwise dominate a freshly created cluster's pod list.
Dispatched a research pass across all 9 components' actual manifests first rather than guessing
naming conventions, which surfaced two real wrinkles: container-maker/socket-ssh/
browseterm-server-local each exist as *either* a bare-named Deployment (prod-style manifest) or a
`-development`-suffixed one (dev-style manifest) depending on which was actually applied to a given
cluster (confirmed both variants are live possibilities — `SETUP-LOCAL.md` itself documents using
the *prod-style* manifest for browseterm-server-local specifically, to avoid its dev manifest's
`HOST_DIR` hostPath requirement); and cert-manager/reaper are CronJobs whose spawned Job pods carry
no `app`-style label at all. Implemented as a pod-name PREFIX match (`desktop/cluster_manager.py`'s
new `MONITORED_WORKLOAD_PREFIXES`) rather than a namespace or label selector, since a bare prefix
like `"browseterm-server"` matches both naming variants without needing to know which one is
actually deployed, and also matches label-less CronJob pods. Also confirmed for the user, by
reading the actual code rather than assuming: pod monitoring is plain `subprocess.run` calls to the
`kubectl`/`k3d`/`docker` CLIs (no `kubernetes` Python client dependency, no `Popen`/streaming) —
`list_cluster_pods()` does one fresh `kubectl get pods -A -o json` per call, polled every 5s from
`app.js`'s `setInterval`, nothing persistent or watched.

**Tests**: 15 new/changed in `tests/test_cluster_manager.py` — the pre-existing
`test_list_pods_parses_ready_and_restart_counts` no longer asserts a `kube-system` pod passes
through (it must now be filtered), a new test asserts k3s system pods are excluded while a
`-development`-suffixed pod passes, and a parametrized test locks in that every one of the 9
components' real naming variants (bare and `-development`, plus CronJob-spawned job-pod names)
matches `MONITORED_WORKLOAD_PREFIXES`. Full suite: 56/56 passing.

**Not done / explicitly out of scope this session**: whether "Setup" should now actually deploy
these 9 components (not just create the bare k3d cluster it does today) is an open question raised
by the user's message but not yet confirmed as in-scope — flagged back to them rather than assumed,
since automating that is a much larger lift (per-component env.mk/secrets, image build/import, and
a real apply ordering — postgres/redis → minio → cert-manager → container-maker → payment-gateway
→ socket-ssh → browseterm-server-local → status_monitor/reaper/snapshot_job cronjobs, per
`SETUP-LOCAL.md`'s own "Next: bringing up the rest" section) than the filtering/monitoring work
done this session. Also not done: any of the three login-deadlock fixes above (blocked on the
user's Google/GitHub console setup for option 3).

**Not done / explicitly out of scope this session (2026-09-04 entry)**: Setup only creates the bare k3d cluster, not
the full local stack (`container-maker`/`socket-ssh`/`payment-gateway`/`browseterm_workload`) —
SETUP-LOCAL.md's own "Next: bringing up the rest" section already documents that as a separate,
not-yet-automated, multi-repo manual process, and the user's ask was specifically "setup the local
k3d cluster," not "deploy the whole app." Not live-verified against a real k3d/docker install this
session (no cluster was actually created/torn down) — the next real test is clicking Setup for real
and confirming `k3d cluster list`/`docker ps`/the pod table all agree.

## Where things stand (as of 2026-08-30 — hibernate/resume/reaper status confirmed via code; payment-gateway architecture documented; capacity-measurement methodology written up in cost.md)
**Answered a round of user questions about hibernate/resume/reaper by re-reading the actual code**
(not from memory of this file's own summary — this file's account, and the underlying repos, had
both moved since the questions were last answered):
- **Resume quota check: implemented.** `browseterm-server/src/api_handlers.py:449`'s
  `resume_container` gates every resume against the user's current subscription plan two ways —
  active-container count vs. `max_containers`, and whether the container's own stored resource
  spec still fits the current plan tier (covers a downgrade since last saved). Both fail open on a
  subscription-lookup error (never block recovery over a billing hiccup). **Still open,
  deliberately deferred** (documented previously, re-confirmed unchanged): no guard that the row's
  `status` is actually `HIBERNATED` before recreating a pod.
- **Hibernate does delete the pod — confirmed twice over**, both from code and from a live git
  history dig: the reaper's flow is save → wait for a confirmed terminal `save_status` → delete the
  pod (Service and Ingress too, see the 2026-08-29 PAYMENTS.md-writing entry's Kubernetes-object
  findings, though that entry is about payment-gateway not the reaper) → mark `HIBERNATED`.
- **"Did we fix the issue with reaper not deleting pods?" — yes, real bug, found and fixed, did
  not resolve itself.** This session's local `browseterm_workload` checkout was itself 5 commits
  behind `origin/main` (the same stale-checkout pattern documented 2026-08-29 — fetched and
  fast-forwarded before answering, per the standing lesson). The fix, `86032fd` (2026-08-25):
  `_hibernate_one` was passing the container's **database row ID** to `deleteContainer`, but
  container-maker's pod lookup (`check_pod`) matches on the pod's actual **Kubernetes UID**, not
  the DB ID — so the match never happened, `delete_pod` was silently never called, and the API
  still reported `{'status': 'Deleted'}` regardless. **Every hibernate that had ever run left the
  pod alive and orphaned** while the DB row happily flipped to `HIBERNATED`. Surfaced live when a
  hibernated-then-resumed container ended up with both the old and new pod running simultaneously
  (double quota usage, SSH randomly routing to either one). Fixed by passing
  `row['kubernetes_id']` instead; 5 passing unit tests including a regression test for this exact
  scenario. A separate, later fix (`ebd1332`, also already merged) additionally made the reaper
  wait for a **confirmed** `save_status=Succeeded` before ever deleting, closing the earlier
  (2026-08-27) data-loss risk documented below. Both fixes are live in the deployed reaper image;
  the CronJob is currently running cleanly on its hourly schedule.

**Documented payment-gateway's actual current architecture** into
`browseterm-monorepo/PAYMENTS.md`'s new "Current Architecture (as-built, 2026-08-29)" section
(written the same day as the previous entry above, but recorded here since it wasn't yet folded
into this file's own summary) — full request-flow diagram, the exact proto contract including the
now-added `idempotency_key` field, and one real finding worth repeating here: **TLS between
browseterm-server and payment-gateway is server-authenticated only, not enforced mutual TLS**,
despite both sides having full client-cert material mounted — `payment-gateway/app.py::serve()`
calls `grpc.ssl_server_credentials(...)` without `require_client_auth=True`, and the `CLIENT_KEY`/
`CLIENT_CRT` env vars set in its Deployment manifest are never read anywhere in its own code.
Flipping this to real mTLS is a small, well-understood follow-up, not done yet.

**Wrote a full capacity-measurement methodology into `~/browseterm/cost.md`'s new "Claude
Response" section**, in response to the user's cost.md brief (design-the-experiment only, no
pricing, no code changes, no fabricated numbers) — motivated by the user's stated plan to
**probably disable payments and run free-tier-only**, needing to know the minimum resources that
requires. Two parallel read-only investigations fed this: one against the live k3s cluster
(`kubectl get/describe/top`, no state changed), one tracing `container-maker`/`socket-ssh`/
`browseterm_workload`/`browseterm-server` source to answer the "does one browser tab = one pod"
question definitively (**no** — confirmed multiple terminal tabs are multiple SSH sessions into
one existing pod, not multiple pods) and to trace hibernation's exact Kubernetes-object lifecycle
(Pod+Service+Ingress all deleted; only an external Docker-registry image persists — this is
**outside k8s's own resource accounting entirely**, meaning the real cost lever at this scale is
how aggressively idle workspaces get hibernated, not the per-workspace resource limit itself).

**The single most load-bearing finding from that investigation**: doing the arithmetic on
already-configured values (not a live load test) shows the **platform's own fixed pods already
consume 3.5 of this node's 4 CPU-limit-cores** before any user workspace exists at all — adding
just **one** Free-plan workspace (1 CPU limit) pushes total CPU limits to 4.5/4 = **112%**, which
matches the live `kubectl describe node` "Allocated resources: CPU limits 112%" reading exactly
(there was exactly one workspace pod running at inspection time — the calculation and the live
number cross-validate each other). At the full beta ceiling (5 concurrent Free-plan workspaces),
CPU/memory **requests** (what the scheduler actually checks) still fit comfortably, but memory
**limits** would exceed the node's ~7.73GiB allocatable — CPU-limit oversubscription risks
throttling (compressible, degraded but not fatal), memory-limit oversubscription risks an actual
OOM kill (non-compressible, potentially fatal to an unrelated process on the node). Neither has
actually been observed under real load yet — both are flagged as UNKNOWN requiring a specific
follow-up experiment (read `/sys/fs/cgroup/cpu.stat` during a real CPU-bound task in a workspace;
run a genuine 5-concurrent-user load test), not treated as a confirmed problem.

**Other concrete gaps surfaced by this pass** (flagged only, nothing changed, per the user's
explicit "do not modify production resource limits yet" instruction): `browseterm-pg` and
`browseterm-redis` are bare Pods (not even Deployments) with **zero resource requests/limits
set at all** — the shared, stateful, single-instance backbone of the entire app can currently
consume unbounded memory. A **live config-drift**: the deployed `socket-ssh-hpa` reports
`minReplicas=1, maxReplicas=1` (no real scaling range active), but `socket-ssh`'s own checked-out
`infra/deployment/deployment.yaml` declares `maxReplicas: 10` — unresolved which one is stale, a
question for a human, not a guess. 4 orphaned stale Services and 2 unbound static PVs found sitting
around from past resume/recreate cycles, costing nothing today but unaccounted-for cruft. **No
Prometheus/Grafana/kube-state-metrics/cAdvisor exists anywhere in this cluster** — only
`metrics-server`/`kubectl top` (confirmed working, but snapshot-only, no history/percentiles/
throttling counters) — the methodology's own recommendation was a minimal CSV-polling script
using existing `kubectl top`/cgroup reads, not a full observability stack, matching the beta's
5-user scale.

## Where things stand (as of 2026-08-29 — Payments UI built and deployed; a parallel-session divergence was found and merged; Stripe Checkout chosen as the next step)
**Built the Payments UI page from `plan.md`'s "Payments UI" section**: a `/payment` route in
`browseterm-server` (hidden from the sidebar, reached only via redirect from `/subscriptions`'
"Select Plan" button) showing a Plan/Price/Currency/GST/Total breakdown card and a Pay button,
styled to match the rest of the app (mint/blue-grey palette, light+dark mode, responsive). GST is
computed client-side at a flat 18% for now (region/discount logic explicitly deferred per
`plan.md`, which says this will vary by country and needs a technique the user hasn't specified
yet). Amounts stay in rupees for now — the paise/minor-unit storage migration `plan.md` mentions
is explicitly future work, not done this session. The idempotency key `plan.md` calls for is
generated client-side once per checkout attempt (`crypto.randomUUID()`, `payment.js`) and reused
across retries, sent to `/create-payment` as `idempotency_key`, but **deliberately never rendered
in the UI** — `plan.md` is explicit about this ("we'll monitor it via Grafana instead").

**Mid-session discovery: a separate, parallel line of work had already pushed 6 commits ahead to
`origin/main` for `browseterm-server`** (plus 2 on `browseterm-db`, 1 on `payment-gateway-spec`,
1 on `payment-gateway`) that this session's standalone `browseterm-server` checkout never saw,
because work started without first running `git fetch`. That parallel work covered much of the
same ground independently — its own `/payment` page, its own fix for a `user_info.id` bug (see
below), a full idempotency-key wire-through to `payment-gateway` via a new proto field, a
last-saved/last-attempt/status widget next to the terminal page's Save button, resume-flow
subscription-plan gating, and cleaned-up user-facing exception text — and had already been fully
migrated into the live Postgres schema (`last_save_attempted_at` column + updated NOTIFY trigger,
confirmed present via `psql`). Reconciled by `git stash`-ing this session's local changes, then
`git merge --ff-only origin/main` (a clean fast-forward, since this session's HEAD was an ancestor
of origin's), then dropping the stash once confirmed everything in it was superseded. Standing
lesson reinforced: **always `git fetch && git log HEAD..origin/main` before starting work in any
of this project's repos** — this is now saved as a durable cross-session note (see the top of this
file's convention and Claude's own memory), since the project's submodule-based monorepo checkout
and the standalone repo clones under `~/browseterm` can independently diverge and get pushed to by
different sessions.

**Two real bugs found and fixed in the merged code, both now live**:
1. `request.state.user_info` is a plain `dict` (set from Redis session data), but
   `create_payment` and `get_container_info` (`browseterm-server/src/api_handlers.py`) accessed it
   as `request.state.user_info.id` instead of `['id']` — this is exactly the `'dict' object has no
   attribute 'id'` error the user hit live on the Pay button. Fixed in both places.
2. The parallel session's payment page rendered `Idempotency key: <code>...</code>` directly in
   the DOM (`payment.js`) — a direct violation of `plan.md`'s explicit "do not show the idempotency
   key in the UI" instruction. Removed the markup and its CSS.

**Per user feedback, the payment page's visual format was then reverted to this session's original
design** rather than the parallel session's — the parallel version's HTML referenced
`.details-card`/`.buy-btn` CSS classes that are defined in `profile.css`/`subscriptions.css`, but
`payment.html` only loads `payment.css`, so those classes were never actually styled on that page
(a real, if minor, bug — unstyled card/button). The current `payment.html`/`payment.css`/
`payment.js` are self-contained (define their own `.payment-card`, `.detail-item`, `.pay-btn`
etc.), keep the idempotency-key generation/submission wired in (still never rendered), and add a
"← Back to plans" link in the header.

**Discussed Stripe integration and a double-entry ledger, neither implemented yet** (deliberately
— see Pending below): the user chose **Stripe Checkout** (hosted redirect) over Stripe Elements or
staying non-Stripe. Planned architecture, not yet built: `payment-gateway`'s `makePayment` RPC
would create a Stripe Checkout Session (via the `stripe` Python SDK) and return its URL instead of
a hardcoded `SUCCESS`; `browseterm-server` passes that URL back to the browser; `payment.js`
redirects via `window.location.href`; new `/payment/success` and `/payment/cancel` routes handle
the return trip; a Stripe webhook (`checkout.session.completed`, signature-verified) is the actual
source of truth for "payment succeeded" (not the redirect alone), and is also the right trigger
point for ledger writes. The session's own client-generated idempotency key maps directly onto
Stripe's native `Idempotency-Key` header on the Checkout Session creation call — no redesign
needed there. **Blocked on**: the user providing a Stripe account's test-mode API keys
(publishable + secret, eventually a webhook signing secret) — nothing here can be built/tested
against placeholder keys. For the ledger: recommended a `ledger_transactions` (one row per payment
event) + `ledger_entries` (≥2 debit/credit rows per transaction, must sum to zero per currency)
schema in `browseterm-db`, written atomically only when the Stripe webhook confirms a charge (not
at Checkout Session creation, since that's just intent) — e.g. for a ₹500 plan + ₹90 GST: credit
`revenue` ₹500, credit `tax_payable` ₹90, debit `cash_stripe` ₹590, with a separate entry once
Stripe deducts its fee. This most naturally lives in `payment-gateway` (or a future dedicated
billing service), not `browseterm-server`.

**Deployed**: rebuilt and pushed both `zim95/browseterm-server:latest` and
`zim95/payment-gateway:latest` (the latter to pick up `payment-gateway-spec`'s new
`idempotency_key` proto field and a "log it on makePayment" change, so the Grafana verification
`plan.md` asks for is actually possible). Both deployments restarted and confirmed
`1/1 Running`/successfully rolled out; verified directly against the live pod (`kubectl exec` +
`grep` on the served template/JS files, not just "looks right in the diff") that the final
`payment.js` contains the restored format markers and does *not* contain the removed
`idempotency-hint`/`details-card payment-card` bugs, and that `terminalpage.html` contains the
`saveStatusInfo` save-status widget div. **One redeploy hit a real, if transient, infra issue**:
this session ran a browseterm-server build/push concurrently with the standalone deploy work,
and separately the host machine appears to have gone idle/asleep for several hours mid-session —
on resume, the node briefly showed `NotReady` (unreachable-taint scheduling failures, probe
timeouts) and one pod got stuck in `ContainerCreating` for 4+ hours with no `Pulled` event ever
firing. Deleting the stuck pod (safe — it's a Deployment-managed replica, not stateful) let the
ReplicaSet recreate it fresh once the node came back, which then started and became ready in
under a minute. This is the same class of issue as the host-resource-contention lessons already
documented in "Pickup instructions" below (item 2) and "Environment quick-reference" — **reinforce
it, it recurred**: avoid overlapping heavy docker builds/pushes on this Mac, and after any long
idle gap in a session, check `kubectl get nodes` before trusting any in-flight rollout status.

## Where things stand (as of 2026-08-27 — reaper/save race fixed and deployed; idle-hibernate test finally closed out)
**Found and fixed a real bug in the reaper's hibernate flow: it could delete a pod before
confirming the pod's own save had actually succeeded.** Root cause: an earlier session's fix to
stop `SaveUtility.save_image` from blocking one of container-maker's fixed 10 gRPC worker threads
for a save's full duration (see the 2026-08-24 entry below, item #47) made the `saveContainer`
RPC return as soon as container-maker **creates** the snapshot Job, not once it **finishes**. The
reaper's own hibernate flow (`browseterm_workload/reaper/src/reaper.py`) was never updated for
that change — its own inline comment still claimed the RPC "blocks until the snapshot Job
finishes" — so it proceeded straight to `deleteContainer` almost immediately after triggering a
save, regardless of whether the build+push later succeeded or failed. Caught live: manually
triggered the reaper against a container with `last_active_at` backdated past the idle threshold;
the snapshot Job's `docker build` failed 3/3 attempts (`Cannot connect to the Docker daemon`), yet
the reaper still deleted the pod and marked the row `HIBERNATED`, reporting the whole run as a
clean success (`hibernated: 1, failed: 0`). No data was actually lost this particular time (the
container's `last_saved_at` was only 87s before it went idle, and the failed rebuild died at the
build step, before it could overwrite the still-valid, previously-pushed image tag) — but the
mechanism was a real, general data-loss risk on any hibernate with genuinely unsaved changes, not
just a contention-triggered edge case.

**Fixed** (`browseterm_workload/reaper/src/reaper.py` + `src/db_ops.py` + `src/config.py`): the
reaper now polls the container's `save_status` (new `wait_for_save_terminal` helper) until it
reaches a terminal state before ever calling `deleteContainer`. Only a confirmed `Succeeded`
proceeds to delete; a `Failed` status, or an unresolved timeout (`REAPER_SAVE_WAIT_TIMEOUT_SECONDS`,
default 4500s — comfortably above container-maker's own 4200s outer save ceiling), leaves the pod
running and the row `RUNNING` untouched, to be retried on the reaper's next sweep — same
"no-automatic-retries, the next real tick is the retry" convention already used elsewhere in this
project. 5 new unit tests (15/15 passing). Committed (`browseterm_workload` `ebd1332`, monorepo
pointer `ce8a38a`), rebuilt, pushed to Docker Hub (`zim95/reaper:latest`,
`sha256:e4e87e6eda28...`) — **no manual redeploy/`crictl rmi` step was needed**, since the
reaper's CronJob Job template already uses `imagePullPolicy: Always`, so the very next Job it
spawns (scheduled or manual) picks up the new image automatically. **User re-ran the idle-hibernate
test against the fixed image and confirmed it now works correctly** — this closes out the third
and final leg of the original crash/hibernation test plan (in-container crash and pod loss were
already confirmed live in the prior session; idle/reaper-triggered hibernate is now confirmed too).

**Two related gaps were found along the way and deliberately left unfixed, per the user's explicit
"stop chasing edge cases, we'll figure things out once it's in production" direction (2026-08-27) —
revisit only if either actually resurfaces live, and capture evidence (`kubectl describe`,
`dockerd.log`) before anything gets garbage-collected next time:**
- **`resume_container` (`browseterm-server/src/api_handlers.py`) has no server-side check that a
  container's `status` is actually `HIBERNATED` before creating a brand-new pod for it** — it just
  reads the row, runs the subscription/quota checks, and unconditionally calls
  `create_container_in_k8s`, then overwrites `kubernetes_id`/`ip_address`/`status` to point at the
  new pod. Today the only thing preventing this from being called against an already-`RUNNING`
  container (which would silently orphan the original pod — same *class* of bug as the reaper's
  earlier wrong-id delete bug, just entering through a different door) is the frontend choosing not
  to show a Resume button outside `HIBERNATED` — never confirmed as an airtight guarantee. Not
  fixed this session; the reaper fix above already makes the specific "save failed → still shows
  as resumable" path unreachable (a failed save now leaves `status=RUNNING`, so no Resume button
  would even appear), so this is a defense-in-depth gap, not a currently-live path to a real bug.
- **`snapshot_job`'s `docker` daemon startup has no readiness check at all**
  (`browseterm_workload/snapshot_job/infra/deployment/entrypoint.sh`: backgrounds `dockerd`, sleeps
  a flat 5 seconds, then proceeds regardless of whether the daemon's socket actually exists). This
  is a real bug on its own merits. Whether it's *the* root cause of the one observed build failure
  above is genuinely unconfirmed — that failure happened 110 seconds after the pod started, well
  past the 5-second window, which means `dockerd` most likely failed to start at all (crashed, or
  got stuck) rather than merely being slow; distinguishing "host disk-I/O contention broke dockerd's
  own storage-driver init" from "the Job's 1 CPU/1Gi resource limit OOM-killed the daemon" from
  something else entirely would need `kubectl describe`/`dockerd.log` captured from that exact pod,
  which had already been garbage-collected (1h TTL) by the time this was investigated. Not fixed
  this session.

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

## What we did today (2026-08-25, continued — concurrency fix, error cleanup, VM restart)
62. **Fixed the last unfixed item from the Pending list: container-maker's
    shared Kubernetes client concurrency bug.** `ExecUtility.run_command`/
    `run_command_with_stream`/`stream_command_to_file`
    (`container-maker/src/resources/pod_manager.py`) now each construct a
    dedicated `CoreV1Api()` instance for their `kubernetes.stream.stream()`
    call instead of reusing the shared `KubernetesResourceManager.client`
    singleton — a killed exec thread can no longer leave the shared client's
    `request` method permanently monkey-patched to the websocket path (which
    previously broke `NamespaceManager.get()`, on the critical path for both
    the Save button and the reaper). Side effect: this also fixed 3
    pre-existing failing unit tests in `test_stream_command_to_file.py` (they
    were failing because `cls.client` is `None` outside a real cluster, which
    a freshly-constructed `CoreV1Api()` doesn't hit). Full unit suite re-run
    clean (45+ tests, only pre-existing unrelated `browseterm_db`-not-installed
    import errors in this local venv, nothing new broken). Committed
    (`2a98c19`), pushed, rebuilt, pushed to Docker Hub
    (`sha256:2f69ed4d15c9...`), node's cached copy cleared via `crictl rmi`,
    redeployed — **verified live**: new pod running the new digest, save
    reconciler + gRPC server started cleanly.
63. **Implemented the deferred item #60 (raw K8s/gRPC error text shown to
    users).** New `clean_k8s_error_message()` (`browseterm-server/src/common/
    utils.py`) extracts the human-readable `message` field from a Kubernetes
    ApiException's embedded JSON body when present, substitutes a short
    actionable message for a quota-exceeded case specifically, and otherwise
    falls back to a clean generic message — never the raw nested-exception/
    `HTTPHeaderDict` text. Wired into all three except-blocks in
    `ContainerService.create_container_in_k8s`/`delete_container_in_k8s`/
    `save_container_in_k8s` (`containers_service.py`) that used to do
    `f"...: {str(e)}"` straight into the `HTTPException` detail shown to the
    user — covers `resume_container` too, since resume calls
    `create_container_in_k8s` under the hood. New unit tests
    (`tests/unit/common/test_clean_k8s_error_message.py`, 5 tests) plus a new
    case in `test_save_container_service.py`; full local suite otherwise
    unchanged (same pre-existing unrelated import-error failures as always,
    documented below). Committed (`281d269`), pushed, rebuilt, pushed to
    Docker Hub (`sha256:f4c961f102c9...`), redeployed — **verified live** (new
    pod running the new digest; picked up automatically via a pod restart
    during the VM cycle in item 64, no manual `crictl rmi` needed this time).
    **Not yet exercised against a real quota-exceeded error in the browser**
    — the cleanup is unit-tested and deployed, but nobody has actually
    triggered a 403-quota resume/create since it went live to see the clean
    message render end-to-end.
64. **Hit, and recovered from, the worst disk/memory contention episode yet
    — while two `docker build`+`push`es (container-maker, browseterm-server)
    ran concurrently for the redeploy above.** Host swap climbed to 90%+
    (10.4GB/11.26GB, then macOS grew swap to 12.29GB and it kept climbing),
    VM `/proc/loadavg` hit **37.73** (previous session's worst was ~14),
    `kubectl` timed out on the TLS handshake, and — new this session — even
    `multipass exec ... cat /proc/loadavg` itself timed out and a **graceful
    `multipass restart` failed outright** (`failed to obtain exit status for
    remote process 'sudo systemctl stop ssh': timed out after 5000 ms`) — the
    VM was too starved to even respond to the SSH command needed to shut
    itself down cleanly. **Confirmed host disk activity was the smoking gun,
    not just swap accounting**: `iostat -d 1 3` showed disk0 at 294-328 MB/s
    against a documented ~40MB/s idle baseline, live evidence of heavy paging
    in progress, not just a stale high-water mark. Asked the user how to
    proceed; user chose **force-stop** (`multipass stop --force
    browseterm-k3s`, which doesn't need the guest to respond) over waiting it
    out or manually freeing Chrome memory. **This worked cleanly**: force-stop
    succeeded immediately, swap dropped 90%→75% just from `qemu-system-aarch64`
    exiting, `multipass start` brought the VM back in under a minute, and once
    up its own `/proc/loadavg` was `0.24` and host swap kept draining (75%→45%
    over the following minutes). k3s's API server took a short extra beat to
    accept connections after the VM was `Running` again (`ServiceUnavailable`
    on the first few `kubectl get nodes` — expected, not a new problem; just
    waited it out rather than treating it as a fresh incident). **New lesson
    for the recurring-contention playbook**: if a graceful `multipass restart`
    itself times out trying to reach the guest, that's a signal the host is
    too starved for the normal graceful path — go straight to `multipass stop
    --force` rather than retrying `restart`, since force-stop doesn't depend
    on the guest responding at all. **All pods survived the force-stop/restart
    cycle intact** (not deleted, just their containers restarted in place by
    kubelet — confirmed via `status_monitor`'s own reconcile-on-startup log
    line correctly reporting the user's test pod as still `Running` and NOT
    flipping its DB row to `HIBERNATED`, since nothing was actually lost, only
    restarted — a nice incidental live confirmation that the reconciler
    doesn't misfire on this kind of event). This episode is added as further
    confirmation of the swap-oversubscription root cause identified in the
    top "Where things stand" entry above (not a new distinct cause) — the
    trigger this time was specifically *concurrent* Docker builds, worth
    avoiding running two heavy local builds at once on this Mac going forward.

## What we did today (2026-08-25, continued — Redis ACL outage, false-FAILED bug, data loss incident)
65. **Ran the pod-loss live test from the Pending list, using `kubectl delete
    pod` (default grace period) on the real running test container.** This
    surfaced two real, previously-undiscovered bugs at once, documented as
    items 66-67 below, and — critically — **caused real, unrecoverable data
    loss**: the pod being deleted had ~1h47m of unsaved work (last successful
    save `10:42:03`, pod deleted `~12:29`) that was never checked before the
    delete. The pod's filesystem was ephemeral; that window's changes are
    gone. **Lesson for any future live pod-loss/crash test on a real
    container (not a disposable one): always check `last_saved_at` against
    now, and confirm with the user, before deleting/force-deleting a pod that
    might hold unsaved work** — "test container" naming doesn't mean
    disposable if a person is actively using it.
66. **Bug #14 — a graceful `kubectl delete pod` on one of these pods can
    surface a false `FAILED` status**, even though nothing actually failed
    (this can happen on an entirely successful reaper hibernate or explicit
    delete too, not just a manual test). Root cause: `status_monitor`'s
    `_handle_pod` (`browseterm_workload/status_monitor/src/pod_watcher.py`)
    wrote every observed pod phase verbatim to the DB, including terminal
    phases. Every managed user pod defaults to `restart_policy: Always`
    (never set explicitly in `container-maker/src/resources/pod_manager.py`),
    so the ONLY way one can ever report a terminal phase (`Failed`/
    `Succeeded`) is during actual pod teardown — an ordinary in-container
    crash always gets restarted in place by kubelet instead, keeping the pod
    `Running` throughout. A terminal phase therefore means exactly what a
    `DELETED` event means ("this pod is going away"), just observed a moment
    earlier in the teardown sequence — but it was racing ahead of, and
    sometimes winning against, the deliberate hibernate/delete/
    `mark_lost_if_running` writes that were supposed to be authoritative.
    **Fixed**: `_handle_pod` now routes `Failed`/`Succeeded` phases through
    the exact same guarded "only if still Running" `on_lost` callback
    `_handle_deleted` already used, instead of writing a literal status. 3 new
    unit tests (21/21 passing). Committed (`fbbee13`), pushed, rebuilt, pushed
    to Docker Hub (`sha256:e46e60e7bbd8...`), redeployed — **verified live**
    (new pod running the new digest, reconcile-on-startup clean).
67. **Bug #15 — real production outage: Redis ACL user is never persisted,
    so ANY Redis pod restart takes every login down cluster-wide.** Surfaced
    live when the user tried to log in shortly after the VM force-stop/
    restart in item 64 and got `Error creating session: invalid
    username-password pair or user is disabled`. Root cause:
    `browseterm-redis` is a bare `Pod` (`redis_ha/redis_single/
    redis-single.yaml`) started with no `--requirepass`/`--aclfile`/ACL
    config at all — the `browseterm` ACL user
    (`REDIS_USER`/`REDIS_PASSWORD` in `env.mk`, consumed by every other
    service as `REDIS_USERNAME`/`REDIS_PASSWORD`) was only ever created by a
    **one-off `redis-cli ACL SETUSER` command run manually during setup**
    (`redis_ha/scripts/development/redis_single/redis_single.setup.sh`), and
    Redis never writes ACL state to disk unless explicitly told to. Any
    restart (crash, node reboot, a VM cycle like item 64's) silently reverts
    Redis to just the passwordless `default` user — confirmed directly via
    `redis-cli ACL LIST` showing only `default` present. **Immediately
    unblocked the user** by manually re-running the `ACL SETUSER` commands
    against the live pod. **Fixed properly**: `redis-single.yaml` now starts
    `redis-server` with `--aclfile /data/users.acl` (same PVC as the RDB/AOF
    data, so it survives pod recreation), and the setup script now runs
    `ACL SAVE` after creating the user so the file actually gets written.
    Committed (`2dae1ba` — note: this repo's submodule checkout was in a
    **detached HEAD**, unlike every other repo touched this session; the
    first commit landed disconnected from any branch until caught via
    `git status`/`git branch -a` and fast-forwarded onto `main` by hand —
    worth checking `git status` for "HEAD detached" before committing in any
    submodule going forward, not just assuming `git commit` always lands on
    `main`). Pushed. **Applied live and verified the fix actually holds**:
    deleted+recreated the `browseterm-redis` pod twice in a row (first
    attempt correctly failed fast — Redis refuses to start with `--aclfile`
    pointed at a file that doesn't exist yet; created an empty
    `/data/users.acl` via a disposable `busybox` pod mounting the same PVC,
    confirmed the existing AOF/RDB data was untouched, then recreated Redis
    clean), created the ACL user + `ACL SAVE`, deleted+recreated the pod a
    **second** time with zero manual steps afterward, and confirmed
    `redis-cli ACL WHOAMI` still authenticated as `browseterm` with no
    re-run of any setup command — the persistence genuinely holds now.
    `browseterm-server` reconnected cleanly (no more session-creation errors
    in its logs). **Also note**: `redis_single.setup.sh` reads
    `REDIS_DATA_DIR` from the invoking shell's environment, but the
    Makefile's `dev_redis_single_setup` target doesn't pass it as an argument
    (only `NAMESPACE`/`REDIS_USER`/`REDIS_PASSWORD` are) — running `make
    dev_redis_single_setup` without first `export`ing `REDIS_DATA_DIR`
    yourself silently falls back to the script's own `$(pwd)/data` default,
    which very nearly overwrote the live PV's `hostPath` with the wrong path
    (caught safely only because a `PersistentVolume`'s `hostPath` is
    immutable post-creation, so Kubernetes rejected the apply outright rather
    than silently repointing it) — not fixed in code this session (low
    urgency: the failure mode is a hard rejection, not silent corruption),
    but worth remembering to `export REDIS_DATA_DIR=...` before ever running
    that target directly rather than through some wrapper that sets it.
68. **Resumed `namah_ssh_ubuntu_test` from the server side, since the user
    couldn't get to a Resume button in the UI for a `FAILED` container**
    (the UI's resume path is presumably only wired to show for `HIBERNATED`
    — not confirmed in the frontend code, just observed). First corrected
    the row `FAILED` → `HIBERNATED` via direct SQL (matching what item 66's
    fix should have produced had it been deployed before the item 65 test),
    then actually performed the resume itself — deliberately by re-running
    `resume_container`'s exact logic (same `ResourceLimits`/
    `CreateContainerK8SRequest` construction, same `ContainerService
    .create_container_in_k8s(..., image_name_override=row['saved_image'])`
    call, same DB write of `kubernetes_id`/`ip_address`/
    `associated_resources`/`status=RUNNING` after) rather than reimplementing
    pod creation by hand from raw `kubectl` — copied a one-off script into
    the running `browseterm-server` pod and ran it with the app's own venv
    (`/app/.venv/bin/python`) and `PYTHONPATH=/app`, so it reused the exact
    same code path, certs, and config the real endpoint uses. **Verified**:
    new pod `Running`, DB row `RUNNING` with the new `kubernetes_id`/
    `ip_address`, sshd startup logs show `"User ... already exists (restored
    container)"` confirming the snapshot's filesystem state came back.
    Reusable pattern for any future "resume without the user's browser
    session" need.
69. **User then ran all three pending live tests themselves (with this
    session driving each one), same day, right after their own save
    succeeded — all three now confirmed live, closing out the
    "Pod crash simulation testing" pending item above.**
    - **In-container crash** (`kubectl exec ... -- kill -9 -1`, via `sh -c`
      since the standalone `/usr/bin/kill` binary — not the shell builtin —
      rejected the `-1` argument with `failed to parse argument: '(null)'`;
      the shell builtin `kill` handles it fine): pod restart count went
      1→2, phase stayed `Running` the entire time, DB `status` never
      changed, and `status_monitor` logged nothing at all (no phase change
      was ever reported by Kubernetes for kubelet's in-place restart under
      `restart_policy: Always`, so there was nothing to dedup past). Exactly
      the predicted self-healing behavior.
    - **Pod loss** (graceful `kubectl delete pod` — deliberately the same
      action that produced the false-`FAILED` result pre-fix, to prove the
      fix specifically): checked `last_saved_at` against now first (5 min
      gap, nothing changed since) before running it this time. Result: DB
      `status` → `HIBERNATED` (not `FAILED`), pod fully gone from the
      namespace, and `status_monitor`'s logs show `"terminal phase observed;
      routed through guarded hibernate write"` for the `Failed` phase
      Kubernetes reported during teardown — item 66's fix confirmed working
      exactly as designed, on the very scenario that exposed the bug.
    - **Save** — user hit Save independently on the resumed container;
      confirmed `Succeeded` (`save_status`, `last_saved_at` current), and
      separately confirmed the save-status widget itself behaves correctly
      end-to-end: the button keeps its loading/spinner state while a save is
      in progress and stops exactly when the save resolves, matching the
      original design intent from item 50's widget work.
    Container resumed again afterward (from the `HIBERNATED` pod-loss
    state) to leave it in a working `RUNNING` state at session end.
70. **Session wrap-up, user's own words**: "Looks like we are good." Only
    the reaper/idle-hibernate scenario (of the original 3-part crash/hiber­
    nation test plan) remains untested live — explicitly deferred to next
    session. After that, the user's stated next focus is **payments**, not
    further crash/hibernation work — see `PAYMENTS.md` at the monorepo root
    for whatever standing plan already exists there (not reproduced here).

## What we did today (2026-08-26 → 2026-08-27 — reaper idle-hibernate test closed out)
71. **Also produced this session (separate request, not part of the reaper work): a from-scratch
    engineering-accomplishments writeup for the user's resume/LinkedIn**, built by directly
    inspecting the actual implementation across every repo (not from this file's narrative alone)
    via 6 parallel research passes, one per major subsystem. Written to
    `/Users/reetunamah/browseterm/resume_result.md` (outside this monorepo, at the parent
    `~/browseterm` level) — not reproduced here, read it directly if it needs updating later.
72. **Simulated idleness on the one real running terminal again**
    (`namah_ssh_ubuntu_test`, id `473f769c-4e5f-48ca-9a33-b572434bab63`) via
    `UPDATE containers SET last_active_at = now() - interval '8 days'`, matching the
    already-documented, already-safe test pattern. Checked `save_status`/`last_saved_at` against
    now first, per the standing lesson from the item-65 data-loss incident — clean, nothing at
    risk.
73. **The reaper's own hourly schedule had silently missed 3 consecutive ticks** (19:00/20:00/21:00)
    by the time this was checked — `LAST SCHEDULE` on the CronJob was 3h+ stale, `Active Jobs: <none>`.
    Cluster events from the same window showed token-refresh timeouts, an unreachable metrics API,
    and HPA `Unauthorized` errors — the same host memory-oversubscription/swap-thrashing signature
    documented earlier in this file, almost certainly also stalling the CronJob controller's own
    scheduling loop, not a bug in the reaper or its manifest. Missed CronJob ticks are not backfilled
    by Kubernetes by default. Triggered a manual run instead of waiting for a fourth possible miss
    (`kubectl create job reaper-manual-hibernate-test --from=cronjob/reaper`).
74. **That manual run is what surfaced the real bug documented in the new top "Where things stand"
    entry above**: the snapshot Job's `docker build` failed 3/3 attempts under live host contention
    (disk0 300-450MB/s against a ~40-53MB/s idle baseline, confirmed via `iostat`; swap 90%+ full),
    yet the reaper still deleted the pod and marked the container `HIBERNATED`, logging the run as a
    clean success. Traced end-to-end via `kubectl logs`/`psql` across the reaper, container-maker,
    and the snapshot Job's own pod (its logs were still available at the time — later garbage
    collected before a deeper follow-up investigation, a lesson for next time: pull `kubectl describe`
    and full logs from a failing Job's pod immediately, before its TTL expires).
75. **Fixed, tested, deployed** — see the top "Where things stand" entry for the exact design
    (poll `save_status` to a terminal state before ever deleting; leave the pod running on anything
    but a confirmed `Succeeded`). Rebuilt+pushed the image; confirmed no extra redeploy step was
    needed since the reaper's Job template already pulls `imagePullPolicy: Always`.
76. **User re-ran the idle-hibernate test against the fixed image and confirmed hibernate now works
    correctly** — closing out the last untested leg of the original 3-part crash/hibernation plan.
77. **Discussed, but explicitly deferred (not fixed), two adjacent gaps** found while reasoning
    through the fix's edge cases with the user — see the top "Where things stand" entry for both:
    `resume_container`'s missing server-side `HIBERNATED`-status guard, and `snapshot_job`'s
    entrypoint having no real `dockerd` readiness check (only a root cause left genuinely
    unconfirmed, not just deprioritized). **User's explicit direction**: stop chasing edge cases for
    now — "we'll figure things out once it's out in production." Both are logged under Pending
    below rather than pursued further this session.
78. **Session wrap-up**: this file updated, all pending work across every repo committed and pushed,
    monorepo submodule pointers synced (`git submodule status` clean, no `+`/`-` prefixes) — per
    explicit user request before moving on. Next focus, per the user, is getting the platform ready
    for production rather than continuing to hunt for more edge cases; revisit the two deferred
    items above only if they actually resurface live.

## What we did today (2026-08-29 — Payments UI built and deployed, parallel-work merge, Stripe decision)
79. **Built `browseterm-server`'s `/payment` page** per `plan.md`'s "Payments UI" section:
    Plan/Price/Currency/GST/Total breakdown card + Pay button, reached via redirect from
    `/subscriptions`, styled to match the rest of the app. See the top "Where things stand" entry
    for full detail — not repeated here.
80. **Found this session's standalone `browseterm-server` checkout was 6 commits behind
    `origin/main`** because work started without `git fetch`ing first — a separate, parallel
    session (working through the `browseterm-monorepo` submodule checkout) had already pushed a
    more complete version of the same feature set. Reconciled via `git stash` + `git merge
    --ff-only origin/main` rather than duplicating; also fast-forwarded `browseterm-db` (2 commits
    behind — the `last_save_attempted_at` migration, already applied to the live Postgres),
    `payment-gateway-spec` (1 commit — the `idempotency_key` proto field), and `payment-gateway`
    (1 commit — logs `idempotency_key` on `makePayment`).
81. **Fixed two real bugs surfaced by that merge**: `request.state.user_info.id` accessed a
    `dict` as if it were an object (should be `['id']`) in `create_payment` and
    `get_container_info` — this was the live `'dict' object has no attribute 'id'` error the user
    hit on the Pay button; and the merged payment page rendered the idempotency key directly in
    the DOM, violating `plan.md`'s explicit "don't show it" instruction. Both fixed.
82. **Per user feedback ("I liked the UI we just had"), reverted the payment page's HTML/CSS/JS
    to this session's original self-contained design** rather than keeping the parallel session's
    version, after finding the parallel version's markup referenced CSS classes
    (`.details-card`/`.buy-btn`) that were never actually loaded on that page (a real bug — the
    card/button would have rendered unstyled). Kept the parallel version's idempotency-key
    generation/submission logic wired into the restored markup; added the "← Back to plans" link
    the user also asked for.
83. **Discussed Stripe integration and a double-entry ledger design with the user** (see top
    "Where things stand" entry for the full recommendation) — user chose Stripe Checkout (hosted
    redirect) over Stripe Elements. Neither is implemented yet; both are blocked/deferred, see
    Pending below.
84. **Rebuilt and redeployed both `browseterm-server` and `payment-gateway`** to Docker Hub and
    the cluster, verified live via `kubectl exec` + `grep` against the actual served files (not
    just the source diff). One redeploy hit a multi-hour `ContainerCreating` stall after the host
    appears to have gone idle for several hours mid-session (node briefly `NotReady` on resume) —
    recovered by deleting the stuck pod and letting the ReplicaSet recreate it once the node was
    back; no data loss, just a delayed rollout. Full detail in the top "Where things stand" entry.
85. **Wrote this session's summary into this file** per explicit user request ("add everything to
    progress_made.md, we will resume from there afterwards") — see items 79-84 and the top
    "Where things stand" entry above.

## What we did today (2026-08-30 — hibernate/resume/reaper Q&A, payment-gateway architecture doc, cost.md capacity methodology)
86. **Answered three user questions about hibernate/resume/reaper by re-reading the current code**
    (this session's local `browseterm_workload` checkout was itself found 5 commits behind
    `origin/main` — fetched and fast-forwarded first, per the standing "always fetch before
    answering/working" lesson from 2026-08-29): (a) the resume quota/tier check is implemented
    (`resume_container`); (b) hibernate does delete the pod (confirmed in `container-maker`'s
    `KubernetesContainerManager.delete()`); (c) the "reaper not deleting pods" issue was a real,
    live bug — `_hibernate_one` passed the DB row id instead of the pod's Kubernetes UID to
    `deleteContainer`, so the pod lookup never matched and every past hibernate silently failed to
    remove the pod while still marking the DB row `HIBERNATED` — found and fixed (`86032fd`,
    2026-08-25), it did not resolve itself. Full detail in the top "Where things stand" entry.
87. **Wrote payment-gateway's current, as-built architecture into
    `browseterm-monorepo/PAYMENTS.md`** (a new "Current Architecture (as-built, 2026-08-29)"
    section, kept alongside the original task spec as historical context) at the user's request —
    full request-flow diagram, exact proto contract, Kubernetes deployment/service shape, and one
    real finding: TLS between browseterm-server and payment-gateway is server-authenticated only
    today, not enforced mTLS, despite both sides having client-cert material mounted.
88. **Wrote a full capacity-measurement methodology into `~/browseterm/cost.md`'s new "Claude
    Response" section**, answering the user's detailed cost.md brief (design-the-experiment only —
    no pricing, no code/resource-limit changes, no fabricated numbers), motivated by the user's
    stated plan to probably disable payments and run free-tier-only, needing the minimum resources
    that requires. Backed by two parallel read-only investigations (live cluster inspection via
    `kubectl get/describe/top`; source-code trace of `container-maker`/`socket-ssh`/
    `browseterm_workload`/`browseterm-server`) plus one arithmetic step combining both, all clearly
    labeled by how each number was obtained (measured/configured/calculated/inferred/unknown) per
    the brief's own explicit rules. Full detail, including the headline finding (platform-fixed
    pods alone already push CPU limits to 112% before any user workspace exists, cross-validated
    against the live node reading) and the concrete gaps found (unbounded Postgres/Redis, a
    socket-ssh HPA config drift, orphaned Services/PVs, no Prometheus/Grafana/cAdvisor anywhere),
    is in the top "Where things stand" entry — not fully repeated here, read `cost.md` directly for
    the complete benchmark matrix and NEXT ACTIONS list.

## What we did today (2026-08-30, later — started Browseterm V2 Cloud/Local split, P01: `devices` table)
89. **Began implementing `FINAL_BROWSETERM_V2_IMPLEMENTATION_PLAN.md`** (new, checked in at
    `~/browseterm/FINAL_BROWSETERM_V2_IMPLEMENTATION_PLAN.md`) — the plan to split the single k3s
    cluster into a Cloud k3s (durable state: Postgres/Redis/OAuth) and a Local k3s running on the
    user's Mac (ContainerMaker, Socket-SSH, status_monitor, reaper, workspace pods). This is a
    deliberately incremental plan (`p01.md` through `P25`); this entry covers **P01 only**, per the
    plan's own execution rule ("do not implement this whole plan at once — for each task, inspect
    actual code, change only task scope, stop, report").
90. **P01 — added the `devices` table to `browseterm-db`** (standalone checkout at
    `~/browseterm/browseterm-db`, confirmed up to date with `origin/main` before starting, per the
    standing fetch-first lesson): new `Device` SQLAlchemy model (`browseterm_db/models/devices.py`)
    with a `DeviceStatus` enum (`ACTIVE`/`INACTIVE`/`REVOKED` — not specified verbatim by the plan,
    chosen to fit the existing `registered_at`/`last_seen_at`/`revoked_at` columns it asked for), a
    `users.devices` relationship (`cascade="all, delete-orphan"`, matching the existing
    `containers`/`orders`/`subscription` pattern), a `DeviceOps` class mirroring `ContainerOps`'s
    conventions (bulk filter-based `update`/`delete`, `UniqueConstraint('user_id', 'device_name')`
    exactly as the plan's optional constraint suggested), both registered in `all_models.py`/
    `all_operations.py`, a hand-written Alembic migration (`e1f2a3b4c5d6`, on top of the actual
    current head `d3e4f5a6b7c8` — traced by hand from `down_revision` chains since a bare `alembic
    heads` isn't runnable without the poetry env) and 8 new tests in `tests/test_device_ops.py`
    (creation/field verification, FK-invalid-user rejection, the per-user unique device-name
    constraint, same name across two different users, find/update, and user-delete cascade).
    Nothing beyond P01 scope was touched (no `containers.device_id`, no `container_snapshots`, no
    auth/server/K8s changes) — that's P02+.
91. **Found and fixed a real, pre-existing gap in `Migrator.reset_database()`** while verifying:
    its hardcoded `DROP TABLE`/`DROP TYPE` lists were never updated when the `images` table was
    added, so on a real Postgres instance an `images` table used by one test run silently survives
    a `reset_database()` call and breaks the *next* run's `CREATE TABLE images` with
    `DuplicateTable` — reproduced directly by running the real (non-test) `versions/` migration
    chain end-to-end against a scratch local Postgres. Added `images` (alongside the new `devices`
    table and `devicestatus` enum) to `reset_database()`'s drop lists so the reset function actually
    resets. This is in the same function P01 already needed to touch for `devices`, not a separate
    refactor. Also had to add `'devices'` to the three hardcoded `required_tables` lists in
    `tests/test_migrations.py::test_c_migrations` — an existing test that asserts the *exact* set of
    tables Alembic creates, so adding any new table mechanically requires updating it or the test
    fails; this is not a design change, just keeping that assertion in sync with the schema.
92. **No local/CI Postgres was available in this environment** — `~/browseterm/browseterm-db` had
    no `.env` and nothing was listening on 5432. Stood up a scratch Postgres 15 in Docker
    (`docker run --name browseterm_db_test_pg ... -p 55432:5432`, `POSTGRES_DB=browseterm_test`)
    and wrote a `.env` (gitignored, not committed) pointing `TEST_DB_*`/`DB_*` at
    `localhost:55432`. Installed the project with `poetry env use python3.11 && poetry install`
    (the repo pins `python = ">=3.11,<3.12"`; the Mac's default `python3` is 3.14, which has no
    prebuilt `psycopg2`/etc wheels compatible with this project — `brew`-installed `python3.11` at
    `/opt/homebrew/bin/python3.11` is what poetry's venv was pointed at). **Left both the Docker
    container and the `.env` in place** (session-local, harmless, gitignored) since P02 onward will
    keep needing the same real-Postgres test setup — a future session picking up P02+ in this repo
    can just `docker start browseterm_db_test_pg` (or `docker ps` to check it's already running)
    instead of re-deriving this whole setup.
93. **Full test run result**: 96/97 tests pass across the entire `browseterm-db` suite
    (`python -m unittest discover -s ./tests/ -p "test_*.py"`), including all 8 new device tests, all
    of `test_user_ops.py`/`test_container_ops.py` (checking the new `users.devices` relationship and
    model registration didn't regress anything), and `test_migrations.py::test_c_migrations` (which
    now expects `devices` in the created-table set). The one failure,
    `test_migrations.py::test_b_mock_unsuccessful_connection`, is **pre-existing and unrelated to
    this work** — it hardcodes port `5432` (not read from `.env`) and expects a real Postgres server
    to be reachable there so it can assert a specific "database does not exist" error string; in
    this sandbox nothing listens on the standard port at all (only the scratch container on 55432
    does), so it fails on a `Connection refused` instead. Confirmed via `git diff` that this test's
    body was never touched by this session's changes.
94. **Next step for a future session**: P02 — add `containers.device_id` (nullable FK to
    `devices.id`, `ON DELETE SET NULL`, index, relationship, serialization, migration, tests) per
    the same plan file's Section 22. Do not implement P03+ in the same pass — the plan's own rule
    (Section 21) is one task at a time, inspect-change-test-stop-report each time.

## What we did today (2026-08-30, later still — P02: `containers.device_id`)
95. **P02 — added `containers.device_id`** in `~/browseterm/browseterm-db` (same standalone
    checkout as P01; confirmed the actual on-disk P01 `Device`/`Container` implementation before
    starting, per this task's explicit instruction to treat the repo, not the plan document, as
    authoritative — it matched what P01 had built). A `P02.md` task brief (mirroring P01's own
    `p01.md`) didn't exist in the repo; asked the user, who confirmed deriving it from the plan's
    Section 22 P02 bullets was correct, and that a status-tracking doc should exist going forward
    — created `~/browseterm/IMPLEMENTATION_STATE.md` for that (a P01/P02/... status table + brief
    per-task notes; full narrative detail stays here in `progress_made.md`, this new file is just
    the status view, so future sessions have one place to check "what's done" without reading this
    whole diary).
96. **Changes**: `containers.device_id` — nullable UUID FK to `devices.id`,
    `ON DELETE SET NULL`, `idx_container_device_id` index, a `device_ref` relationship on
    `Container` mirroring the existing `image_id`/`image_ref` pattern exactly (same naming
    convention, same "FK column named `X_id`, relationship attribute named `X_ref`" shape), and
    the reverse `Device.containers` relationship mirroring `Image.containers`. `device_id` is
    serialized in `Container.to_dict()`. `ContainerOps` (`_convert_filter_value`/
    `_convert_update_value`/`_convert_insert_value`, plus `insert()`/`insert_many()`) got
    `device_id` wired through the same way `image_id` already was. New hand-written migration
    `f2a3b4c5d6e7_add_device_id_to_containers.py` on top of P01's head `e1f2a3b4c5d6` (head is now
    `f2a3b4c5d6e7`). Deliberately did **not** give `Device.containers` an ORM cascade (unlike
    `User.devices`'s `cascade="all, delete-orphan"`) — deleting a device must only clear
    `device_id` on its containers, never delete the containers, and that's exactly what the FK's
    `ON DELETE SET NULL` does at the database level regardless of whether the delete SQL comes from
    `session.delete()` or a bulk `query.delete(synchronize_session=False)`.
97. **4 new tests** in `tests/test_container_ops.py::TestContainerDeviceAssociation`: a container
    created without `device_id` defaults to `NULL`; creating one with a valid `device_id`
    associates it and it's findable via `container_ops.find({"device_id": ...})`; creating one with
    a nonexistent `device_id` fails (FK violation); deleting a device sets `device_id` to `NULL` on
    its containers without deleting the containers. Verified against the real (non-test)
    `versions/` migration chain too: reset → upgrade → inspect `containers` columns (has
    `device_id`) → downgrade -1 → inspect again (column and FK gone, `devices`/`images`/etc tables
    untouched) → re-upgrade clean.
98. **Test run**: 100/101 pass across the full suite (`python -m unittest discover -s ./tests/ -p
    "test_*.py"`) — the same single pre-existing, environment-only failure as P01
    (`test_migrations.py::test_b_mock_unsuccessful_connection`, hardcodes port 5432, unrelated to
    this work, untouched by this session). Reused the scratch Postgres container
    (`browseterm_db_test_pg`, port 55432) and `.env` set up during P01 rather than re-deriving them.
99. **Next step for a future session**: P03 — audit and fix current resource ownership/IDOR gaps
    (get/list/update/delete/save/resume/activity/terminal/container-info endpoints; server derives
    user identity from auth, never trusts a supplied `user_id`/`device_id`/`container_id`; add
    cross-user rejection tests) per the plan's Section 22 P03 and Section 17 (Security). This one is
    in `browseterm-server`, not `browseterm-db` — check that repo is up to date with `origin/main`
    before starting, same fetch-first convention as always. See `IMPLEMENTATION_STATE.md` for the
    current status table.

## What we did today (2026-08-30, later still — P03/P04/P05 committed+pushed; P06: repository split + Desktop Resource MVP)
100. **Committed and pushed P01-P05 work that had been sitting uncommitted.** `browseterm-db`'s
    P01/P02 changes (`devices` table + `containers.device_id`) and `browseterm-server`'s P03
    (ownership/IDOR fixes), P04 (Cloud skeleton), P05 (Device Cloud API) were all still in the
    working tree, never committed — `git log` on both repos showed HEAD several commits behind
    what `p.md`/`IMPLEMENTATION_STATE.md` already documented as done. Split each task's changes
    into its own commit (one for P01+P02 combined in `browseterm-db`; separate P03/P04/P05 commits
    in `browseterm-server`, plus one honest commit for pre-existing unrelated `templates/payment.*`
    polish that predated P03) and pushed both repos' `main` to `origin` before touching anything
    else, so the repository-split work below started from a clean, coherent history.
101. **P06 — repository boundary correction.** The plan's P04/P05 had `browseterm-server` carrying
    two entrypoints (`app.py` = old combined local+auth+container app, `cloud_app.py` = Cloud
    skeleton/Device API) as migration scaffolding — not the real target architecture. Corrected
    this into two physically separate repos:
    - **`browseterm-server`** (existing repo, history preserved) — trimmed to Cloud-only:
      `cloud_app.py` renamed to `app.py` (now the only entrypoint); removed `src/api_handlers.py`,
      `template_handlers.py`, `status_listener.py`, `src/containers`, `src/payments`,
      `src/data_models`, container/image DB ops, OAuth-issuance-specific auth modules, templates,
      dev/prod k8s manifests, and their tests (all moved to Local, not deleted); kept `src/cloud/*`
      and the `authenticate_session` decorator + its transitive user/subscription DB-lookup
      dependents (Cloud's Device API already needs these per P05, and Cloud legitimately owns
      direct `users`/`subscriptions` Postgres access). `pyproject.toml` trimmed to
      fastapi/uvicorn/redis/browseterm-db only. 33/33 tests pass.
    - **`browseterm-server-local`** (brand-new repo, `github.com/Zim95/browseterm-server-local`,
      public, `main`) — a clean-initial-commit extraction of everything else: the untouched local
      browser server (OAuth login, container/workspace CRUD with P03's fixes intact, SSE,
      payments, ContainerMaker/Socket-SSH integration, templates), plus two genuinely new modules
      that never touch `browseterm_db`/`POSTGRES_*`/`REDIS_*`: `src/cloud_client/` (the sole
      Local→Cloud HTTPS boundary, wrapping P05's Device API; auth is an interim pre-P07 session
      cookie, since Cloud and Local still share one Redis) and `desktop/` (Mac-only `rumps`
      menu-bar Desktop Resource MVP — hardware detection via `sysctl`/`shutil`, allocation
      validation as defense-in-depth, device register/update/heartbeat handling P05's real
      non-idempotent 409-on-duplicate semantics, report-only local server/k3s health, Open
      Browseterm). 159/160 tests pass (1 failure is the same pre-existing unrelated
      `test_process_user_info_success` documented since P03). Chose a clean initial commit over a
      history-preserving split because the Local-owned files were scattered across the tree and
      `session_manager.py`/`authentication_helpers.py` had to be *duplicated* into both repos
      (Cloud's Device API and Local's existing routes both need the same session-validation code
      pre-P07), which a subtree split can't express. Full audit table (every `browseterm_db`/
      `DB_CONFIG`/`POSTGRES_*`/`REDIS_*` occurrence, which future Pxx task removes it) is in
      `~/browseterm/CURRENT_TASK_STATE.md` and `~/browseterm/p.md`'s P06 section — Local is NOT
      yet fully off direct central-DB access (that's intentional, documented debt for
      P07/P10/P12/P13, not an oversight).
102. **Monorepo sync**: bumped the `browseterm-db` and `browseterm-server` submodule pointers to
    the commits pushed above, and added `browseterm-server-local` as a new submodule
    (`.gitmodules` updated). This entry plus the `.DS_Store`/`PAYMENTS.md` changes already sitting
    uncommitted in this repo were committed together.
103. **Next step for a future session**: P07 — Cloud OAuth/session migration (server-side OAuth
    `state`, Cloud Redis session issuance, one-time Local handoff, Local session exchange, session
    refresh, correct logout). This is what finally lets `browseterm-server-local` drop its direct
    Redis/Postgres session dependency and gives Desktop a real device-scoped credential instead of
    the interim `BROWSETERM_SESSION_COOKIE` env var. See `~/browseterm/p.md`'s P06 section and
    `FINAL_BROWSETERM_V2_IMPLEMENTATION_PLAN.md` Section 22 P07 before starting.

## Pending / not yet verified
- [ ] **`browseterm-pg` and `browseterm-redis` have zero resource requests/limits set** (found
      2026-08-30 during the cost.md capacity investigation) — both are bare Pods, not even
      Deployments, and can currently consume unbounded memory. Deliberately not fixed this
      session (cost.md's brief explicitly said don't modify production resource limits during the
      measurement-design phase) — this is listed as NEXT ACTION #5 in `cost.md`'s Claude Response
      section: give both real limits before running any 5-concurrent-user load test, so an OOM
      event's root cause isn't muddied by an unrelated unbounded neighbor.
- [ ] **`socket-ssh-hpa` live config drift** (found 2026-08-30) — the deployed HPA reports
      `minReplicas=1, maxReplicas=1` (no real scaling range active), but `socket-ssh`'s own
      checked-out `infra/deployment/deployment.yaml` declares `maxReplicas: 10`. Needs a direct
      human answer (was the live HPA deliberately pinned down, or is it stale?) before it's relied
      on for any capacity/load-test conclusion — not something to guess or silently reconcile.
- [ ] **Capacity-measurement benchmark matrix designed but not yet run** (`cost.md`'s Claude
      Response section, 2026-08-30) — the actual numbers (per-workspace/per-terminal CPU+memory,
      CPU throttling under load, 5-concurrent-user behavior) still need real experiments; see that
      file's own "NEXT ACTIONS" list for the exact order (clean platform baseline first, then a
      minimal `kubectl top`+cgroup polling script since no Prometheus/Grafana exists, then
      single-workspace scenarios, then the 5-user scenarios). This is the direct path to answering
      the user's actual question ("minimum resources for 5 free-tier-only users").
- [ ] **4 orphaned stale Services + 2 unbound static PVs found in the cluster** (2026-08-30,
      `cost.md` investigation) — leftover from past workspace resume/recreate cycles and from an
      earlier PV/PVC setup respectively. Cost nothing today (no compute/traffic to them) but are
      unaccounted-for cruft; low priority, clean up opportunistically rather than urgently.
- [ ] **payment-gateway TLS is not actually mutual** (found 2026-08-30 while writing
      `PAYMENTS.md`'s architecture section) — `grpc.ssl_server_credentials(...)` is called without
      `require_client_auth=True`, so the client cert `browseterm-server` presents is never
      verified, even though full mTLS-capable cert material exists and is mounted on both sides.
      Fix is a one-line `require_client_auth=True` plus reading the already-mounted `CLIENT_KEY`/
      `CLIENT_CRT` env vars in `payment-gateway`'s own code — not done, not urgent (internal-only
      traffic, ClusterIP, no public exposure), but should not be assumed to already be enforced.
- [ ] **Stripe Checkout integration** — user chose this over Stripe Elements (2026-08-29). Not
      started: needs the user to provide a Stripe account's test-mode publishable + secret keys
      (and eventually a webhook signing secret) before any of `payment-gateway`'s `makePayment` →
      Stripe Checkout Session creation, the `/payment/success`/`/payment/cancel` routes, or webhook
      handling can be built/tested. See the 2026-08-29 "Where things stand" entry for the planned
      architecture (webhook is the source of truth, not the redirect; our idempotency key maps to
      Stripe's own `Idempotency-Key` header).
- [ ] **Double-entry ledger** — design recommended (2026-08-29, see "Where things stand"):
      `ledger_transactions` + `ledger_entries` tables in `browseterm-db`, written atomically only
      on Stripe webhook confirmation, most naturally owned by `payment-gateway`. Not implemented —
      blocked behind the Stripe decision above (no real money-movement event to hang ledger writes
      off yet).
- [ ] **GST/region/discount logic is still a flat 18%-if-INR placeholder** (`payment.js`,
      `computeBreakdown`) — `plan.md` explicitly flags that this will vary by country and that
      discounts will exist eventually, and says "I will post techniques to add those things in
      place" — don't build region/discount logic speculatively, wait for that follow-up.
- [ ] **Amounts are still stored/displayed in rupees, not paise** — `plan.md` calls out moving to
      minor-unit (paise) storage for clean currency conversion via a future third-party API, but
      says this is separate future work, not part of the UI change done this session. Note the
      gRPC layer (`payment_types.proto`'s `amount_minor`) already uses minor units end-to-end;
      only `browseterm-db`'s `subscription_types.amount` (a `DECIMAL(10,2)` in rupees) and the
      frontend's display math would need to change.
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
- [x] ~~Fix the container-maker shared-client concurrency bug~~ — **fixed,
      deployed, and verified live 2026-08-25** (item #62 above). Each of the
      three exec methods now uses a dedicated `CoreV1Api()` instance instead
      of the shared `cls.client`.
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
- [x] ~~Hibernation/reaper testing~~ — **fully confirmed 2026-08-26/27, closing out
      the last untested leg of the original 3-part crash/hibernation plan** (the
      other two, in-container crash and pod loss, were already confirmed 2026-08-25).
      Along the way, found and fixed a real bug: the reaper could delete a pod
      before its own triggered save had actually finished/succeeded (see the top
      "Where things stand" entry for the full story and the fix) — the idle-hibernate
      test is what surfaced this live. After the fix was deployed, the user re-ran
      the test and confirmed hibernate now works correctly end-to-end. Original
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
- [ ] **`resume_container` has no server-side check that a container is actually
      `HIBERNATED` before creating a new pod for it** (`browseterm-server/src/
      api_handlers.py`) — found 2026-08-27 while reasoning through the reaper fix's
      edge cases, not fixed. Today the only thing preventing a double-pod/orphan
      scenario is the frontend not showing a Resume button outside `HIBERNATED` —
      never confirmed as airtight. **Explicitly deferred per user direction**
      ("stop chasing edge cases, we'll figure things out once it's in production")
      — revisit only if it actually surfaces live; the fix would be a simple guard
      at the top of `resume_container` rejecting with a clear error unless
      `row['status'] == HIBERNATED`.
- [ ] **`snapshot_job`'s entrypoint has no `dockerd` readiness check**
      (`browseterm_workload/snapshot_job/infra/deployment/entrypoint.sh` backgrounds
      `dockerd`, sleeps a flat 5 seconds, then proceeds regardless) — found 2026-08-27
      while investigating why a snapshot build failed during the reaper test above,
      not fixed. Real bug on its own merits, but whether it's *the* root cause of
      that specific failure is genuinely unconfirmed — the failure happened 110s
      after pod start (well past the 5s window), and the pod was garbage-collected
      before `kubectl describe`/`dockerd.log` could be pulled. **Explicitly deferred**,
      same reasoning as above. If it recurs: capture the failing pod's full state
      *before* its TTL expires, then fix the entrypoint to poll for the docker socket
      with a real timeout instead of a fixed sleep.
- [x] ~~Pod crash simulation testing — two distinct scenarios~~ — **both
      confirmed live 2026-08-25 (item 69 below), after item 66's fix was
      deployed.** In-container crash (`kill -9 -1`): pod restart count
      incremented, phase stayed `Running` throughout, DB status never
      changed, `status_monitor` logged nothing (no phase change to react
      to) — exactly as designed. Pod loss (graceful `kubectl delete pod`,
      the same action that produced the false-FAILED bug pre-fix): DB status
      correctly went to `HIBERNATED`, pod fully gone from the namespace,
      `status_monitor` logs show the terminal `Failed` phase being caught
      and routed through the guarded hibernate write rather than written
      raw. Resumed successfully afterward (item 69). **Still open**: whether
      an in-flight SSH session shows a clean disconnect/reconnect or hangs
      silently during an in-container crash — never directly observed
      either way, low priority.
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
2. **Check host swap/memory pressure before touching the cluster**
   (`sysctl vm.swapusage`, `top -l 1 -o mem`) — this is the confirmed root
   cause of every "disk contention" episode across this project's history
   (see top "Where things stand" entry), and it recurred as recently as
   2026-08-25 (item 64) specifically from running two concurrent local
   `docker build`s. **Never run two heavy local builds at once on this Mac.**
   If `multipass exec`/`kubectl` are timing out and a graceful `multipass
   restart` itself times out trying to reach the guest, go straight to
   `multipass stop --force browseterm-k3s` then `multipass start` rather than
   retrying restart — this is proven to work (item 64) and doesn't depend on
   the guest responding at all.
3. **The full 3-part crash/hibernation test plan is now closed out** (in-container
   crash, pod loss, and idle/reaper-triggered hibernate — see item 69 and the
   2026-08-26/27 entries above). **User's explicit direction as of 2026-08-27:
   stop hunting for more edge cases in this area — "we'll figure things out once
   it's out in production."** Two known-but-unfixed gaps are logged under
   Pending (`resume_container`'s missing `HIBERNATED` guard,
   `snapshot_job`'s missing `dockerd` readiness check) — do not proactively chase
   either; only revisit if one actually surfaces live, and if so capture full
   evidence (`kubectl describe`, logs) from the failing pod *before* its TTL
   expires, unlike this session's dockerd investigation.
4. **The Payments UI (`plan.md`'s "Payments UI" section) is now built and deployed** (2026-08-29 —
   see the top "Where things stand" entry). **The concrete next step is Stripe Checkout
   integration** — the user chose hosted Stripe Checkout over Stripe Elements; this is blocked on
   the user providing Stripe test-mode API keys, so ask for those before writing any Stripe code.
   A double-entry ledger design is recommended but also not started, and depends on the Stripe work
   landing first (ledger entries get written on webhook confirmation). See `PAYMENTS.md` at the
   monorepo root for whatever earlier standing plan exists there too (not reproduced here; read it
   fresh rather than assuming this file's summary is complete).
4a. **Before starting any work in this project, `git fetch` every repo you're about to touch and
   check `git log HEAD..origin/main`** — this session lost time duplicating a payments-page/bugfix
   effort that a parallel session had already pushed further ahead, purely from skipping this
   check (2026-08-29, see "Where things stand"). The project's submodule-based monorepo checkout
   and the standalone repo clones under `~/browseterm` can independently diverge.
4b. **The user is considering disabling payments and running free-tier-only** (2026-08-30) — before
   that decision, they need real minimum-resource numbers, not the calculated/inferred ones this
   session produced. `~/browseterm/cost.md`'s "Claude Response" section has the full measurement
   methodology and a "NEXT ACTIONS" list — if asked to continue this thread, start there rather
   than re-deriving the plan, and follow that file's own ordering (clean platform baseline first,
   then build the small polling script it describes, then single-workspace scenarios, then 5-user
   scenarios). Do not skip straight to a 5-user load test before Postgres/Redis have real resource
   limits (Pending list) — an OOM under load would be ambiguous about which unbounded pod caused it.
5. Every time you fix something, verify it against the real running app
   (browser or an actual API call, or a direct `psql`/`kubectl exec` check),
   not just "the config looks right" — this has been true of literally every
   bug found across this whole multi-day session.
6. Keep updating this file as you go, same style: don't diary-append forever —
   periodically fold older "What we did today" entries' *conclusions* into
   "Where things stand" and trim detail that's no longer actionable, so a cold
   read stays fast even as the file grows across many sessions.

## Environment quick-reference

**SUPERSEDED as of 2026-08-31 (see "What we did today" entry below) — this Multipass-VM section
describes an architecture iteration that is no longer what's running.** The user confirmed the
actual current setup is two `k3d` clusters, `k3d-browseterm-k3s` (Cloud) and
`k3d-browseterm-k3s-local` (Local) — Docker containers, not a Multipass VM; no MetalLB (k3d's own
port-mapped loadbalancer + ingress-nginx instead); `/etc/hosts` now points
`browseterm.local.com`/`browseterm.cloud.com` at `127.0.0.1`, not `192.168.252.200`. No committed
script builds these `k3d` clusters yet (they were stood up manually this session) — see the P07
entry below and each repo's own README "Dev Setup" section for the current `k3d`-based
instructions, including the Traefik-port-conflict gotcha. Left the old section below intact
rather than deleting it, in case the Multipass path is ever revived, but do not trust it as
current state without verifying `kubectl config get-contexts` first.

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

## What we did today (2026-08-31 — P07 Cloud-owned authentication, implemented + deployed +
validated end-to-end)

108. **Started from a support request, not a planned task**: user reported the `browseterm-desktop`
    app (built the same session, see prior entries) showing a blank green screen with no login
    buttons. Root-caused through several layers: (1) the app's own reachability check was working
    correctly and already showing a clear "can't reach the server" error card — the real issue was
    one level down; (2) `browseterm.local.com` resolved but timed out; (3) Docker Desktop's own VM
    had actually crashed (`com.docker.virtualization: Process terminated unexpectedly`, consistent
    with this project's long-documented swap-pressure pattern — swap was at ~89% throughout this
    session); (4) after restarting Docker, the two `k3d` clusters the user said should exist
    (`k3d-browseterm-k3s`, `k3d-browseterm-k3s-local`) were completely gone — `k3d cluster list`
    empty, zero `k3d-*` containers — the VM crash wiped Docker's container/volume state entirely,
    not just paused it.
109. **Recreated both `k3d` clusters** (`browseterm-k3s` -p 9999:80@loadbalancer,
    `browseterm-k3s-local` -p 80:80@loadbalancer — ports match `browseterm-server`/
    `browseterm-server-local`'s own existing URL conventions) with **no surviving script,
    volume, or config to reconstruct from** — verified via `docker volume ls`/`docker network ls`
    (empty), grep across every repo + `.zsh_history` (nothing). The only prior deploy script found
    (`browseterm-monorepo/scripts/setup.sh`) is stale: it assumes a single `docker-desktop`
    cluster + MetalLB and deploys `browseterm-server` (Cloud) into the same namespace as
    container-maker/socket-ssh/payment-gateway — i.e. it predates the P06 Cloud/Local repository
    split and doesn't reflect the two-cluster topology at all. User confirmed by direct
    instruction: Cloud cluster = `browseterm-server`+Postgres+Redis; Local cluster =
    `browseterm-server-local`+container-maker+socket-ssh+workloads (the latter two + payment-
    gateway/workloads deliberately not deployed this session — see item 111).
110. **User then pointed at a new spec file, `~/browseterm/p07.md`** ("AUTHORITATIVE
    IMPLEMENTATION SPECIFICATION", supersedes prior P07 instructions) and asked for it to be
    implemented, deployed, validated, committed/pushed, and documented — all in the same request.
    Implemented in full across all three repos: Cloud OAuth start/callback/state (Redis, GETDEL
    single-use), one-time handoff (`local_login` + `device_bootstrap` purposes), per-device Bearer
    credentials (SHA-256-hashed in Redis, one token per device, independently scoped/revocable),
    Device API migrated from session-cookie to Bearer-device-token auth, `browseterm-server-local`
    stripped of all OAuth code/secrets (deleted `oauth_service.py` outright, fixed a real
    pre-existing bug where `logout()` never passed `session_id` through so the Redis session
    survived "logout" indefinitely), `browseterm-desktop` migrated off the P06 interim
    `BROWSETERM_SESSION_COOKIE` mechanism onto a macOS-Keychain-stored device token obtained via a
    one-time bootstrap. TrustedHost added to Cloud; CORS deliberately not added (documented — no
    browser JS ever calls Cloud directly). Full technical writeup, including every Redis key
    convention/TTL, is in `p.md`'s "P07 — Cloud-Owned Authentication" section (that's the
    authoritative reference now, not this entry) — `CURRENT_TASK_STATE.md` has the shorter
    checkpoint version. Tests: Cloud 87/87, Local 96/96, Desktop 9/9 (all passing before deploy).
111. **Deployed and validated live** — real infra work, not just "kubectl apply and hope": found
    and fixed a genuine `k3d` gotcha (k3s's bundled Traefik, not disabled at cluster-creation time,
    was squatting on host ports 80/443 via its own `svclb`, leaving ingress-nginx's `svclb` stuck
    `Pending` on both clusters — fixed via `kubectl -n kube-system delete helmchart traefik`, now
    documented in both `browseterm-server`'s and `browseterm-server-local`'s READMEs); fixed a
    stale `/etc/hosts` duplicate the user's own `sudo sed` attempt left behind (two
    `browseterm.local.com` lines, the old `192.168.252.200` one still shadowing the new
    `127.0.0.1` one since `/etc/hosts` resolves top-down — caught and had the user delete the
    stale line rather than silently editing a system file myself twice). Built+deployed
    `browseterm-server` (Cloud) via `k3d image import` (no registry push needed) against fresh
    Postgres/Redis (`postgres_ha`/`redis_ha`'s existing single-instance scripts, reusing the
    already-provisioned `PG_PASSWORD`/`REDIS_PASSWORD` from the monorepo's aggregated `env.mk`),
    schema initialized via `browseterm-db/init.py` through a port-forward. Built+deployed
    `browseterm-server-local` (Local) the same way. **Verified against real, live infrastructure,
    not mocks**: `curl http://browseterm.cloud.com:9999/healthz` → Postgres/Redis both `ok`;
    `http://browseterm.local.com/login` renders the new plain `/auth/google`/`/auth/github` links;
    hitting `/auth/google` on Local correctly chains through Cloud's `/auth/google/start` all the
    way to Google's *real* OAuth consent screen with the correct `client_id` and the new
    `/auth/google/callback` redirect URI (same for GitHub); handoff/device-bootstrap endpoints
    correctly 401 on invalid/missing credentials. The one remaining external step — **the new
    `http://browseterm.cloud.com:9999/auth/{google,github}/callback` redirect URIs need to be
    added to the actual Google Cloud Console / GitHub OAuth App settings** — is the account
    owner's to do; until then a real human login hits `redirect_uri_mismatch` at the very last
    step, after everything this session built has already been proven correct.
112. **Committed and pushed all three repos separately** (`browseterm-server` `1b0b957`,
    `browseterm-server-local` `d7731fa`, `browseterm-desktop` `04091fe`), then synced this
    monorepo's submodule pointers to match (see this commit).

## Pending / not yet done (added 2026-08-31, P07 session)
- [ ] **Register the new OAuth callback URLs** with Google/GitHub (external, account-owner-only —
      see item 111). Nothing in these repos is blocked on it; it only blocks a real human login.
- [ ] **container-maker, socket-ssh, payment-gateway, and `browseterm_workload` were not deployed**
      to either new `k3d` cluster this session — deliberately deferred (unrelated to P07, building
      +deploying ~4 more services is a separate substantial effort). Local's login/OAuth/handoff/
      device-bootstrap flow doesn't need them; anything that does (actual terminal creation, etc.)
      will 404/timeout until they're deployed too.
- [ ] **No committed script builds the two `k3d` clusters from scratch** — they were created with
      ad-hoc `k3d cluster create` commands this session (see item 109's port mappings), not a
      checked-in setup script. A future `browseterm-k3s-local`-as-easy-Mac-cluster script (flagged
      as not-yet-done since the P06 addendum, still true) should probably absorb this.
- [ ] **Device token scopes are issued but not individually enforced** (`["device:read",
      "device:update", "device:heartbeat"]` — any valid token can currently do all three; see
      p.md's P07 section's "Explicitly Out of Scope").
- [ ] **No device-revoke HTTP endpoint** — storage (`DeviceTokenManager.revoke_token`) supports it,
      P05 never had one either, out of P07's stated scope.

## What we did today (2026-08-31, later still — P07 follow-up, SETUP docs, P08 clarified, P09 implemented)

113. **P07 follow-up: session refresh + a real logout CSRF bug.** User asked a design question
    about session refresh/SSE architecture (see this session's design discussion, not reproduced
    here); while answering it, realized the original plan's P07 scope explicitly listed "session
    refresh" as its own item, missed in the first P07 pass. Added `POST /auth/refresh`
    (`browseterm-server-local`) and `base.js`'s `SessionRefreshManager` (polls every 10 min,
    redirects to `/login` on a 401). While writing handler-level tests for this (a real coverage
    gap — the first P07 pass never tested `api_handlers.py`'s routes, only `AuthenticationService`'s
    own methods), found that `LogoutManager.handleLogout()` never sent the `X-CSRF-Token` header
    the new CSRF check requires — clicking Logout in the real UI 403'd on `/logout` (session never
    revoked server-side) but still redirected to `/login` regardless, silently looking like it
    worked. Fixed both, redeployed to `browseterm-k3s-local`, verified live. Commit `c4ba7c5`.
114. **`SETUP-CLOUD.md`/`SETUP-LOCAL.md`** added at the monorepo root — the actual, verified
    step-by-step procedure for standing up each `k3d` cluster from nothing (every command in them
    was really run this session, not written from memory). Monorepo `README.md`'s microservices
    list corrected for the P06/P07 split (was still describing `browseterm-server` as handling
    OAuth+sessions+Postgres+Redis directly, no `browseterm-server-local`/`browseterm-desktop`
    entries at all) and the old Docker-Desktop+MetalLB "Development Setup Guide" section flagged
    as superseded rather than silently left looking current. Commit `cfe5dcf`.
115. **P08 clarified, not implemented — it was already done.** User asked "what is P08 and P09"
    mid-session. Checked `FINAL_BROWSETERM_V2_IMPLEMENTATION_PLAN.md`'s actual P08 definition
    ("stand up `browseterm-server-local`: existing UI/templates, Cloud health/session client, no
    Cloud DB/Redis credentials") against what P06 already delivered (see that section above) —
    same thing, already done. The plan's phase numbering and the actual commit history simply
    diverged (P06's repository-boundary correction absorbed what the plan called P08). No code
    changed for P08 specifically; documented in `p.md`'s new "P08" section so this doesn't get
    re-asked/re-attempted later.
116. **P09 — status_monitor Cloud API migration, implemented.** Per the plan's exact P09
    definition ("replace direct DB writes with authenticated Cloud status API, keep pod watcher
    logic unchanged, verify DB trigger/NOTIFY still fires"). New Cloud endpoint `POST
    /internal/containers/{container_id}/status` (internal-token-gated, no `user_id` — status_monitor
    is a trusted cluster-wide system caller, not acting for any specific user) supports an optional
    `expected_status` for an atomic compare-and-swap, reproducing the old `mark_lost_if_running`'s
    exact semantics. `status_monitor`'s `src/db_ops.py` rewritten to call it via a new minimal
    `src/cloud_client.py`; `browseterm_db` removed from its `pyproject.toml` entirely (no Postgres
    credential in this component any more at all). **`src/pod_watcher.py` untouched** — verified by
    running its existing test suite unmodified alongside the rewritten `test_db_ops.py`, all 23
    pass. **Not deployed live** — status_monitor needs container-maker (stamps the pod labels it
    watches for) to have anything to watch, and container-maker is still deferred (see item 111);
    the DB trigger/NOTIFY-still-fires claim is reasoned from the fact that Cloud's new endpoint
    issues the identical SQL `UPDATE` on the same table, not re-verified live — flagged in `p.md`'s
    P09 section as needing a real check once status_monitor is actually deployed. Cloud commit
    `7201dd0`, `browseterm_workload` commit `d13c48e`.
117. Synced this monorepo's submodule pointers for `browseterm-server-local` (`c4ba7c5`),
    `browseterm-server` (`7201dd0`), `browseterm_workload` (`d13c48e`).

## Pending / not yet done (added 2026-08-31, this session)
- [ ] **A live `LISTEN`/`NOTIFY` re-verification for P09** — reasoned but not tested live (see
      item 116) — do this once `status_monitor` is actually deployed alongside container-maker.
- [ ] **`reaper`/`snapshot_job`/`cert-manager` still hold direct `DB_PASSWORD` credentials** — the
      plan's P09 item names only `status_monitor`; migrating the others is a natural follow-up in
      the same shape (new Cloud endpoints + a small `cloud_client.py` each), not attempted here.
- [ ] **P10 (Cloud SSE) and beyond** — see this session's design discussion (browser connects
      directly to Cloud's SSE, reusing the existing one-time-WebSocket-token pattern, rather than
      Cloud relaying to "the active Local instance" — each user's Local runs on their own Mac,
      which has no reliable inbound reachability, confirmed by checking
      `FINAL_BROWSETERM_V2_IMPLEMENTATION_PLAN.md`/`plan.md`/`newplan.md`). Not started.

## What we did today (2026-08-31, later still — P11 implemented)

118. **P11 — Socket-SSH Redis removal, implemented.** New Cloud endpoint `POST
    /auth/websocket-tokens/consume` (`RedisSessionManager.consume_websocket_token`, atomic
    `GETDEL` on `ws_token:*`) - deliberately **public, no internal-service-token check**, unlike
    every other route added in P07/P09: socket-ssh has no shared secret, and holding a valid
    one-time token is itself sufficient authorization (same reasoning as P07's handoff/device-
    bootstrap redemption). `socket-ssh/src/authenticate.js` rewritten to call it via `fetch`
    instead of `ioredis` directly - `ioredis` removed from `package.json` entirely.
    `authenticateRequest`'s signature/return value unchanged, so `server.js` needed zero changes.
    New `tests/authenticate.test.js`, 6/6 pass. Found (via `git status` before editing, this time
    actually checked) that `socket-ssh`'s `origin/main` had 2 commits this session's earlier work
    didn't have (`fb1a9d6` HPA pin, `d4dc6b0` ingress idle-timeout fix, both from routine ops work
    elsewhere) - merged cleanly (`428494c`), no conflicts, both changes coexist correctly in
    `deployment.yaml`. Cloud commit `5689b33`, socket-ssh commit `428494c` (merge).
    **Not deployed live** - same reasoning as P09: socket-ssh's value only shows up with a real
    terminal connection, which needs container-maker (still deferred). Pre-existing, unrelated
    `ssh.test.js`/`server.test.js` collection failures found and left alone (confirmed via
    `git stash` to be identical on a clean pre-P11 checkout - missing `@kubernetes/client-node`
    module and a `readCertificates` export mismatch, neither touches `authenticate.js`/Redis).
119. Synced this monorepo's submodule pointers for `browseterm-server` (`5689b33`), `socket-ssh`
    (`428494c`).
120. **P10 — Cloud SSE, implemented.** Cloud now owns Postgres LISTEN/NOTIFY directly and pushes
    container status/save-status updates to the browser over its own `GET /events/stream`
    (`src/cloud/sse_broadcaster.py`/`sse_handlers.py`, new `SSEBroadcaster` singleton wrapping
    `browseterm_db`'s pre-existing `PGListener` in a background thread via a new FastAPI
    `lifespan`). Auth via a new `sse_token` (query string, `EventSource` can't set headers) that
    resolves only to a session_id - never a client-supplied `user_id`, matching the plan's
    explicit P10 instruction. `browseterm-server-local`'s old `status_listener.py` (an interim
    polling relay against Cloud's `/containers` API) and its `/container-status-stream` endpoint
    are removed entirely - the browser connects to Cloud directly now, with reconnect-triggers-
    full-refetch reconciliation in `terminals.js`.
121. Along the way, found and fixed a real gap: this session's own `~/browseterm/browseterm-db`
    working tree had been silently squashed by an earlier (accidental) run of that repo's
    documented-destructive `python init.py`, dropping 17 real migration files from disk without
    ever committing/pushing the loss (so `git status` against origin looked clean the whole time
    - only `git status --porcelain` right before writing a new migration caught it, showing a
    wall of unexpected local deletions). Restored via `git checkout -- 
    browseterm_db/migrations/versions/` - turned out the real trigger migrations P10 needed
    (`a1b2c3d4e5f6`/`e5f6a7b8c9d0`/`d3e4f5a6b7c8`) already existed in git history, so no
    `browseterm-db` code changes were needed at all. Separately, the live Cloud k3d cluster's
    actual Postgres had never had that real migration chain applied (seeded via the same
    squash-and-recreate path at cluster setup time) - fixed by hand-applying the real trigger SQL
    and correcting `alembic_version` to the real chain's head revision.
122. Verified P10 genuinely end-to-end against the real k3d clusters, not just reasoned about:
    `PGListener` receiving real `pg_notify` payloads from a live `UPDATE`, both Cloud and Local
    redeployed live with clean startup logs, and a full browser-equivalent round trip (real
    Cloud session -> real sse_token -> real `GET /events/stream` -> real DB `UPDATE` -> event
    delivered with the exact field names the frontend already expects). Cloud: 114/114 (14 new).
    Local: 106/106. Commits pushed: `browseterm-server` (`37064db`), `browseterm-server-local`
    (`4fefb08`).
123. **P12 — Cloud workspace metadata/create APIs, implemented.** `POST /containers` now requires
    `device_id`/`cpu_limit`/`memory_limit`/`storage_limit`, validates the device (found + ACTIVE)
    and the request against the device's `allocated - used` capacity, and reserves usage
    (increments `used_cpu`/`used_memory_bytes`/`used_storage_bytes`) before creating the row -
    released back if the insert then fails, matching the plan's own P12 bullet order exactly.
    `POST /containers/{id}/delete` releases a container's reserved resources on success. New
    dependency-free `src/cloud/resource_quantity.py` parses the Kubernetes resource-quantity
    strings (`"500m"`, `"2Gi"`) these fields use, since Cloud still doesn't depend on the
    `kubernetes` client library at all. Hibernate/Resume accounting deliberately not wired up
    this pass (the plan's own P12 checklist only covers the create path; see `p.md` for why).
    129/129 tests (15 new). Verified live end-to-end against the real k3d cluster: registered a
    real device via device-bootstrap, created a container and confirmed `used_cpu`/
    `used_memory_bytes`/`used_storage_bytes` incremented correctly, confirmed an over-capacity
    request gets rejected, deleted the container and confirmed usage released back to the
    device's original capacity exactly. Commit pushed: `browseterm-server` (`be7c7e0`).
124. **P13 — Local create path, implemented.** Cloud's `POST /containers` `device_id` is now
    optional - auto-resolves the caller's currently-ACTIVE device when omitted, since
    `browseterm-server-local` has no established way to learn its own device_id (device
    registration is a `browseterm-desktop`-only concept). `create_container_in_k8s` (Local) now
    best-effort releases the DB row + Cloud resource reservation if the real ContainerMaker/K8s
    call fails - previously that leaked forever and blocked any retry under the same name.
125. Live-verifying P13 (the first request this session actually originating from inside a Local
    pod rather than curl from the host) surfaced two real, previously-invisible deployment gaps
    breaking *every* internal-token-gated Local->Cloud call in this live cluster, not just P13's:
    `browseterm.cloud.com` resolved to `127.0.0.1` from inside a `browseterm-k3s-local` pod (two
    separate k3d clusters on one Mac, each its own Docker bridge network - fixed with a
    `hostAliases` entry pointing at Docker Desktop's `host.docker.internal`), and
    `CLOUD_INTERNAL_API_TOKEN` was never wired into either Local deployment manifest at all
    (silently defaulting to empty string, every internal-token call 401ing) - fixed by adding it
    from the same `browseterm-internal-api-token` Secret Cloud itself reads. Both applied live
    first to finish verifying P13, then committed into the manifests/scripts/README properly.
    Full E2E through a real ContainerMaker/K8s pod stays blocked on container-maker still not
    being deployed (same documented limit as every prior P-item) - confirmed that's genuinely the
    remaining blocker, not a P13 regression, via the pod's own logs showing the request correctly
    reaching Cloud and only failing at `ContainerService.__init__`'s certs lookup.
    Cloud: 131/131 (2 new). Local: 109/109 (3 new). Commits pushed: `browseterm-server`
    (`a967d9a`), `browseterm-server-local` (`8cc7bf3`).
126. **P14 — Resource reconciliation, implemented.** New `status_monitor/src/resource_reconciler.py`
    - a second, independent periodic poller (run alongside `pod_watcher.py`'s real-time watch via
    `asyncio.gather`, deliberately not threaded through it) that lists currently-`Running` managed
    pods every 5 minutes and reports their container_ids to Cloud's new
    `POST /internal/devices/resources/reconcile`. Cloud sums each reported container's parsed
    cpu/memory/storage per device and **overwrites** the cached `used_*` counters P12 introduced -
    repairing drift from a missed release, a retried request, or manual DB surgery. Known,
    deliberate v1 limitation documented in `p.md`: a device whose containers have all stopped
    running isn't reset to zero by this alone (needs the caller to assert which devices it's
    authoritative for, not just which containers are running - genuinely new design surface left
    for a future pass, in the same category as P12's deferred Hibernate/Resume accounting).
    Verified live not just as an echo-back but as a real repair: registered a device, created a
    real container, directly corrupted the device's `used_*` fields in Postgres to simulate real
    drift, called the reconcile endpoint, and confirmed both the response and a direct `SELECT`
    showed the fields correctly restored to the container's actual parsed resource limits.
    Cloud: 137/137 (6 new). status_monitor: 30/30 (7 new). Commits pushed: `browseterm-server`
    (`61b908f`), `browseterm_workload` (`35c3170`).
127. **P15 — Snapshot DB migration, implemented.** New `container_snapshots` table (`ContainerSnapshot`
    model, `SnapshotOps`, mirroring `DeviceOps`'s exact conventions) and
    `containers.next_snapshot_sequence` (the atomic version counter P16 will use) in
    `browseterm-db`. `container_snapshots.container_id`'s FK uses a real DB-level
    `ON DELETE CASCADE` (not just an ORM-level one - `ContainerOps.delete()`'s bulk
    `query.delete()` bypasses ORM cascades entirely, a real gap caught before it shipped). New
    `browseterm_db/common/snapshot_version.py` formats the plan's 5-part dotted-decimal version
    string from the raw integer sequence. Hand-written Alembic migration (down_revision the real
    chain's actual head), applied live to the real Cloud cluster's Postgres and verified via `\d`.
    Also found and documented (README) a pre-existing, unrelated test-suite fragility running
    many `browseterm-db` test files back-to-back via `unittest discover` in one process (confirmed
    via a clean pre-P15 `git stash` still failing the same way) - each file individually, against
    a disposable throwaway Postgres, is the reliable way to verify a change here. 12 new tests.
    Commit pushed: `browseterm-db` (`fd936cd`).
128. **P16 — Snapshot allocation API, implemented.** New Cloud endpoint
    `POST /internal/containers/{container_id}/snapshots/allocate` (same trusted-SYSTEM-caller
    pattern as P09/P14) implements the plan's exact algorithm: reuse an existing
    `(container_id, request_id)` row verbatim if found (idempotent retry), else read-then-write
    `containers.next_snapshot_sequence` (a plain increment - the plan explicitly tolerates
    version-number gaps after crashes) and create a new `Pending` row. New
    `SNAPSHOT_REGISTRY_REPO_PREFIX` builds the flat, UUID-based `image_repository` the plan's
    registry strategy requires. `poetry update browseterm-db` first, to pick up P15's new
    `SnapshotOps`/`ContainerSnapshot`. 143/143 tests (6 new). Hit and fixed a real deploy-tooling
    gap along the way: a `k3d image import` interrupted mid-transfer left the cluster silently
    serving the previous image under the same tag (`docker images` looked correct locally the
    whole time) - caught because the first live call returned FastAPI's own bare
    `{"detail":"Not Found"}`, not this endpoint's JSON error shape, exactly what a genuinely
    absent route looks like. Fixed via a `--no-cache` rebuild + a full, unhurried `k3d image
    import`, confirmed via `kubectl exec ... grep` against the pod's own `app.py` before retrying.
    Then live-verified the real idempotency guarantee (not just the happy path): same
    `request_id` twice returns the identical `snapshot.id`; a different `request_id` correctly
    advances the sequence. Commit pushed: `browseterm-server` (`1e297f1`, includes an earlier
    `312e94f`).
129. **P17 — Snapshot job migration, implemented.** The first P-item since P09 to migrate an
    already-running workload's real DB path (not just add new Cloud surface). New Cloud endpoint
    `POST /internal/containers/{container_id}/snapshots/{snapshot_id}/report` updates both the
    `container_snapshots` row and the owning `containers` row's `save_status`/`save_error` (the
    frontend's SSE feed is driven by `containers`' own trigger, not `container_snapshots`) -
    `saved_image`/`last_saved_at` only ever set on `Succeeded` (plan: "on failure, saved_image
    must remain unchanged"). `snapshot_job` rewritten: allocates (P16) before building, tags with
    the Cloud-allocated versioned reference instead of `latest`, parses the registry digest out
    of its own `docker push` output, reports Running/Succeeded/Failed through Cloud instead of
    writing to Postgres directly - `browseterm-db` dependency removed entirely. New
    `src/cloud_client.py` (mirrors `status_monitor`'s, P09) replaces the deleted `db_ops.py`
    (which also removed `update_saved_image`, found to already be dead code). Deleted three heavy
    real-Postgres-plus-real-Docker integration test files whose whole premise (direct DB access)
    no longer exists; new `test_main.py` covers the new orchestration directly. Cloud: 149/149 (6
    new). snapshot_job: 22/22 net of 3 confirmed pre-existing unrelated failures. This time the
    Cloud redeploy followed P16's own lesson exactly - waited for `k3d image import` to genuinely
    finish before rolling out, confirmed the new route in the pod's `app.py` first - and landed
    clean on the first try. Live-verified the full P16→P17 chain end to end against a real
    device/container: allocate → report Running (confirmed via `GET /containers`) → report
    Succeeded with a digest (confirmed `saved_image`/`last_saved_at` updated correctly).
    `snapshot_job` itself still isn't live-deployed (needs container-maker, same as
    `status_monitor`/`socket-ssh`). Commits pushed: `browseterm-server` (`fd7a2fb`),
    `browseterm_workload` (`c980eec`).
130. **P18 — Reaper migration, implemented.** First P-item where Hibernate's resource-release
    accounting (deferred explicitly in both P12's and P14's write-ups) became load-bearing -
    reaper's whole job is executing exactly that transition. `browseterm-db`'s
    `find_idle_containers` gained an optional `device_id` scope ("the reaper must operate only on
    containers whose device_id is the current device"). Two new Cloud endpoints: a device-scoped
    idle query, and a compound hibernate transition (`status=HIBERNATED`, `device_id=NULL`,
    device resource reservation released via the same `_release_device_resources` helper
    `delete_container` already uses - closing the "Hibernate" half of P12's deferred note).
    `reaper` itself rewritten onto a new `cloud_client.py` (mirrors `status_monitor`'s/
    `snapshot_job`'s own) replacing the deleted `db_ops.py` - the save→confirm→delete→hibernate
    ordering and per-container failure isolation are completely unchanged, only the storage
    boundary moved. New required `DEVICE_ID` config surfaces a real, explicitly documented
    deployment-sequencing gap (a device doesn't exist until Desktop's bootstrap flow has run,
    which happens after this CronJob's manifest would normally be applied) - `main.py` fails fast
    rather than silently scanning nothing. `browseterm-db`: 22/22 (1 new). Cloud: 157/157 (8
    new). `reaper`: 16/16 - its entire pre-existing test suite carried forward with only the
    mocking boundary changed, plus a new `test_cloud_client.py` preserving the deleted
    `test_db_ops.py`'s full `wait_for_save_terminal` polling-behavior coverage. Live-verified the
    full Cloud-side flow end to end against a real device/container: idle-list correctly scoped
    by device, hibernate confirmed via direct Postgres reads to correctly set
    `status=HIBERNATED`/`device_id=NULL`/zero out `used_*` together, not just one piece.
    `cert-manager` is now the only `browseterm_workload` component still holding a direct
    `DB_PASSWORD`. Commits pushed: `browseterm-db` (`2d935cc`), `browseterm-server` (`a369dc6`),
    `browseterm_workload` (`d664d2c`).
131. **P19 — Cross-device resume, implemented.** Closes the "Resume" half of the Hibernate/Resume
    resource-accounting story P12 first flagged as deferred and P18 partially closed (Hibernate's
    release half). New Cloud endpoint `POST /containers/{id}/resume` (user-scoped, not the
    trusted-SYSTEM-caller pattern - Local calls it on a real user's behalf): a compare-and-swap
    transition (`expected_status=HIBERNATED`, the same pattern P09's `update_container_status`
    established) so two concurrent resume attempts for the same container can never both win,
    resolves/validates the resuming device the same auto-resolve-to-ACTIVE-device pattern P13
    uses, reserves that device's capacity from the container's own already-stored resource limits
    (resume never changes size), and confirms the CAS's real outcome by re-reading the row rather
    than trusting `ContainerOps.update()`'s `.success` alone (it reports success even on zero rows
    matched, same semantic preserved everywhere else). `browseterm-server-local`'s
    `resume_container` handler now calls this instead of transitioning RESUMING itself; a new
    `resumed` flag gates what happens on a later pod-start failure - once Cloud's transition has
    succeeded, the rollback reuses the existing P18 hibernate endpoint as-is (already does exactly
    the right thing) rather than a new dedicated "cancel resume" endpoint or the old
    `status=FAILED` marking, which would otherwise leave a dangling device reservation forever.
    While fixing the existing test suite for the new `CloudClient`-based flow, caught an unrelated
    file (`test_ownership_idor.py`) making a genuine, unmocked HTTP call to Cloud from a test
    that predated this change - fixed alongside. Cloud: 164/164 (7 new). `browseterm-server-local`:
    111/111 overall; `test_resume_container.py` itself 25/25 (one test replaced, two new P19-
    specific rollback tests added). Live-verified Cloud's endpoint end to end against a real
    device/container: hibernate → resume with explicit `device_id` → confirmed `status`/
    `device_id`/`used_cpu` all transitioned correctly → a second resume on the same container
    correctly 409'd with no double-reservation → simulated rollback via hibernate confirmed
    `device_id` cleared and `used_cpu` back to `0`. `browseterm-server-local` rebuilt (`--no-cache`)
    and redeployed to `browseterm-k3s-local`, new code confirmed present via `kubectl exec ...
    grep` before considering the deploy done; Local's own `/resume-container` HTTP endpoint was
    not exercised end-to-end (needs container-maker, still deferred since P07). Commits pushed:
    `browseterm-server` (`e19dc21`), `browseterm-server-local` (`003ca6a`).
132. **P20 — Registry verification, implemented.** An audit item, not a build item: verified every
    place a Docker Hub account is baked into an image reference and judged each on its own merits
    rather than blanket-replacing `zim95`. Base-image catalog seed data (`zim95/ssh_ubuntu:latest`
    in `browseterm-db`'s `images.json`) is legitimate and untouched, per the plan's own explicit
    "do not blindly change base-image seed refs" warning. P15's 5-part version tags and P17's
    digest parsing were both already correct. The one real gap: `SNAPSHOT_REGISTRY_REPO_PREFIX`
    was never actually set in Cloud's deployment manifest, silently relying on its code default
    (`"browseterm"`) with nobody having verified that namespace existed on Docker Hub. Asked the
    user rather than guessing; with their explicit authorization, created a real `browseterm`
    Docker Hub Organization (owner: `zim95`) via Docker Hub's Hub API using credentials from
    `~/browseterm/dockercreds`, confirmed live, then wired `SNAPSHOT_REGISTRY_REPO_PREFIX`
    explicitly end to end (`env.mk` → `Makefile` → `cloud-setup.sh` → `cloud.yaml`). Applying that
    manifest change via `make setup` then **crash-looped the live Cloud deployment** - caught and
    fixed within the same turn: the Makefile's `setup` recipe passed `$(VAR)` args to
    `cloud-setup.sh` unquoted, and three genuinely-missing `env.mk` values
    (`BROWSETERM_LOCAL_CALLBACK_URL`/`BROWSETERM_ALLOWED_HOSTS`/`CLOUD_INGRESS_HOST`, a
    pre-existing gap unrelated to P20) each vanished from the actual shell command instead of
    becoming empty args, shifting every later positional argument left by one - `POSTGRES_HOST`
    ended up on the script's own nonexistent-Service fallback default
    (`browseterm-db-service`), and the live Ingress host briefly became the literal string
    `browseterm`. Fixed by quoting every arg in the Makefile (so a missing value can only ever
    break its own slot, never shift what follows) and recovering the three missing `env.mk`
    values from the still-healthy old pod's own live env plus `/etc/hosts` - not invented.
    Re-applied cleanly; confirmed the full deployment (Ingress host, all affected env vars)
    restored correctly, not just the one var this pass set out to add. `snapshot_job` itself still
    isn't live-deployed, so nothing was ever actually pushed through the new org end to end (needs
    container-maker, deferred since P07). Commits pushed: `browseterm-server` (`1acc7bf`
    registry-prefix wiring, `10555d1` Makefile quoting fix), `browseterm-monorepo` (`62b98a1`,
    submodule sync).
133. **P21 — Local infra/security split, implemented.** Important discovery first: `container-maker`
    had diverged 10 commits from what this session tracked, all authored directly by the account
    owner, fixing real live-cluster-observed snapshot/save-Job bugs - meaning **container-maker has
    actually been run and iterated on live**, contradicting this whole session's repeated
    "container-maker still isn't live-deployed" framing for that one component. One of those
    commits was an independently-authored, byte-for-byte-identical fix to the exact same Makefile
    positional-arg-shift bug found in P20; another had already implemented gVisor sandboxing
    correctly for a real single-node k3s PROD host this session has no visibility into. This
    session's own first-draft P21 fix would have wrongly defaulted gVisor OFF (based on checking
    only the local k3d dev clusters, which don't have a `gvisor` RuntimeClass registered) -
    caught via `git stash` + diff-against-origin before anything was pushed, not after. Lesson
    banked: never assume `container-maker` is idle; always re-check divergence immediately before
    editing it specifically. Two real, verified bugs found and fixed after that: (1)
    `POD_CIDR`/`SERVICE_CIDR` defaulted to docker-desktop's Kubernetes ranges, not k3s's real ones
    (verified live against `browseterm-k3s-local`) - meaning the per-tenant NetworkPolicy's "deny
    internal cluster access" carve-out was a complete no-op, letting untrusted user-pod egress
    potentially reach other tenants/Postgres/Redis/MinIO despite the policy's own name; (2)
    container-maker's gRPC server never passed `require_client_auth=True` to
    `ssl_server_credentials`, so despite a full client-cert chain being provisioned end to end, the
    server accepted ANY TLS client regardless of whether it presented one - one-way TLS, not mTLS,
    directly answering the plan's own explicit "do not call it mTLS unless verified" instruction.
    The identical gap in `payment-gateway` was left untouched, per the plan's explicit "DO NOTHING"
    for payments. Also proactively fixed the same Makefile arg-shift bug class in
    `browseterm-server-local` and `socket-ssh` (neither had triggered it yet, but both had it).
    ResourceQuota/LimitRange, tenant RBAC (correctly minimal - no k8s API access for tenant pods
    at all), and MinIO config were all reviewed and found already correct. `container-maker`:
    57/57 (post-pull, unaffected by this pass's two fixes). Neither fix live-redeployed - same
    "container-maker not deployed in this project's k3d clusters" gap as P09/P17/P18. Commits
    pushed: `container-maker` (`1a98ed2`), `browseterm-server-local` (`711768e`), `socket-ssh`
    (`ee847ac`), `browseterm-monorepo` (`b886510`, submodule sync).
134. **P22 — Cloud infra, implemented.** Confirmed the live Cloud PG/Redis are the single-instance
    path (`pg_single`/`redis_single`), correctly matching the plan's "No HA redesign" - not
    something to change. Found and fixed a real, live authentication-persistence bug in Cloud
    Redis: the running pod had NO `--aclfile` flag despite the committed manifest having one (it
    predated that manifest change and was never recreated), so the `browseterm` ACL user existed
    only in Redis's in-memory state with zero disk persistence - `ACL SAVE` even failed outright.
    The next restart for ANY reason would have silently reverted Redis to its unauthenticated
    default user, breaking browseterm-server's Redis connection and briefly leaving the session
    store open to anyone inside the cluster network. Asked the user before touching a live
    stateful service - confirmed to proceed. Recreating hit Redis 7.4's actual boot behavior (it
    aborts startup entirely on a configured-but-missing aclfile, not the softer "starts
    unauthenticated" the setup script's own comment implied) - worked around via a short-lived
    helper pod mounting the same PVC to create an empty file first, then re-ran the ACL setup for
    real. Verified twice via a second full pod recreation that persistence genuinely survives a
    restart now, and confirmed browseterm-server's own `/healthz` reported clean
    `{"postgres":"ok","redis":"ok"}` afterward. Also fixed a stale `REDIS_DATA_DIR` value in
    `redis_ha`'s gitignored `env.mk` that surfaced during the first (safely-rejected) recreate
    attempt. Verified migrations/triggers clean (live `alembic_version` matches the latest
    migration exactly; both P10 NOTIFY triggers present). Verified and documented, rather than
    attempted, a real TLS gap: Cloud's public ingress is plain HTTP today (no cert-manager, no
    ClusterIssuer, `ssl-redirect: false`) - deliberately not fixed this pass, both because the
    referenced "existing cert-manager manifests" the plan expects turned out to be a genuinely
    unfinished doc, and because Let's Encrypt structurally cannot issue a trusted cert for a
    hostname that only resolves via one Mac's `/etc/hosts`, so a real fix isn't achievable in this
    local dev cluster regardless of effort spent. No repo commits this pass (live-fix +
    gitignored-local-config only) beyond the `env.mk` correction.
135. **P23 — Two-cluster bootstrap, implemented.** "Every script checks kube context before
    applying" - verified this genuinely didn't exist anywhere in the project
    (`grep -rln "current-context\|kubectl config"` across every repo's setup scripts returned
    nothing) and added an identical, minimal, optional guard (compares an `EXPECTED_KUBE_CONTEXT`
    arg against `kubectl config current-context`, aborts before applying on a mismatch) to the
    setup scripts for every cluster this project actually targets:
    `browseterm-server/cloud-setup.sh`, `browseterm-server-local`'s dev+prod setup,
    `postgres_ha`/`redis_ha`'s single-instance setup scripts. Verified live that the guard
    actually blocks a mismatched context before touching anything. Second major discovery this
    session while pulling `redis_ha` before editing it (the P21-established "always re-check
    divergence first" discipline): another account-owner commit this session had no knowledge
    of, whose own message says "hit live this session after a **Multipass VM** restart" - proof
    of a SECOND real, independently-operated production target (beyond container-maker's
    single-node k3s host referenced in P21) this session has zero visibility into, where the
    account owner independently hit and fixed the exact same Redis ACL persistence bug this
    session found and fixed on the k3d cluster in P22 - both fixes converged on the identical
    technical answer, made independently. Also caught and fixed a real process mistake in the
    same breath: committing directly inside a `browseterm-monorepo` submodule checkout (instead
    of the standalone clone) landed on a detached HEAD, so `git push` silently reported
    "up-to-date" while the real commit sat orphaned - caught via `git branch -v` immediately
    after, fixed by re-doing the edit through the proper standalone clone and confirming every
    other submodule copy touched this session was NOT similarly affected. No test changes
    (shell-script-only pass). Commits pushed: `browseterm-server` (`1074249`),
    `browseterm-server-local` (`6d782d0`), `postgres_ha` (`34fb57b`), `redis_ha` (`f913cab`,
    also carries the account owner's own ACL-persistence commit), `browseterm-monorepo`
    (`4575f67`, submodule sync).
136. **Live bug fix: "Error listing containers" on browseterm.local.com.** User reported a raw
    Kubernetes 404 (`secrets "container-maker-service-certs" not found`) surfacing to the browser
    when loading the terminal list. Root cause: `ContainerService.__init__` unconditionally read
    container-maker's mTLS cert from its Kubernetes Secret and opened a gRPC channel on every
    instantiation, but 5 of its 8 methods (including `list_user_containers`, the one actually
    hit) are pure DB operations that never touch that channel at all - so a plain "list my
    containers" call required infrastructure (container-maker's certs) it never needed, and
    failed outright since container-maker isn't deployed on this Local k3d cluster. Fixed by
    making the cert read/channel setup lazy (`_ensure_grpc_client()`, called only from inside the
    three methods that actually call container-maker). New
    `tests/unit/containers/test_container_service_lazy_grpc.py` (4 tests, including the exact
    regression: listing succeeds even when the cert read would raise).
    `browseterm-server-local`: 115/115. Rebuilt, redeployed to `browseterm-k3s-local`, confirmed
    live via `kubectl exec ... grep` before considering it done. Commit pushed:
    `browseterm-server-local` (`f8b0468`).
137. **Desktop login moved to the system browser.** User hit an unusual Google verification
    challenge during login through the Desktop app's WebView - root cause: Google (and
    increasingly GitHub) actively block/challenge OAuth from an embedded WebView as a long-
    standing anti-phishing policy, exactly what the original P07 design (WebView loads Local's
    real `/login` directly) hits. Fixed by moving OAuth to the system browser: the WebView now
    shows a small local "Log in" page; clicking it starts a one-shot loopback HTTP server on
    127.0.0.1 and opens Local's login with `?target=desktop&desktop_port=<n>` in the real system
    browser. Zero changes to Cloud's OAuth surface - `target` stays `"local"` the whole way
    through; Local's `auth_provider_redirect` just sets a short-lived, one-shot cookie before
    redirecting to Cloud, and `auth_callback` (same browser tab, cookie survives the round trip)
    mints a device-bootstrap code server-side and redirects to the loopback server with it
    instead of Local's home page. The port is the only caller-supplied value in that redirect,
    strictly validated as a plain TCP port with the host hardcoded to 127.0.0.1, closing off any
    open-redirect concern. `browseterm-server-local`: 123/123 (8 new) + new Jest
    `login.test.js` (4 tests). `browseterm-desktop`: 16/16 (6 new, including a full round-trip
    test of the whole login flow with a real loopback server). Live-verified the HTTP wiring
    directly (cookie-setting, login.js threading the params onto the provider buttons) and via a
    real launch of the app (screenshot confirmed the system browser opened correctly) - full
    OAuth completion handed to the user to verify interactively. Commits pushed:
    `browseterm-server-local` (`9d9847e`), `browseterm-desktop` (`c7d187c`), `browseterm-monorepo`
    (`7fc300e`, submodule sync).
138. **container-maker migrated off direct Postgres access.** User: audit "the entire local
    stack" for direct DB access and replace it with Cloud API calls. Found one remaining holdout
    (every other Local component was already migrated earlier this session or in P11):
    `container-maker`, holding a real Postgres credential directly in two places - `containers.py`'s
    save() self-heal (a drifted kubernetes_id correction) and the save reconciler's stuck-save
    sweep/mark-failed logic. Added three new trusted-SYSTEM-caller Cloud endpoints (`GET`/`POST
    /internal/containers/{id}`, `GET /internal/containers/stuck-saves`) and a new
    `container-maker/src/cloud_client.py` (same shape as status_monitor's/snapshot_job's/
    reaper's own) to replace the direct `ContainerOps` calls. Found and fixed a second, unrelated
    dead-code path along the way: `job_manager.py` was still injecting a DB credentials Secret
    into every snapshot Job's env, even though P17 already removed `browseterm-db` from the Job's
    own image entirely - removed, and in its place discovered a real separate P17 gap
    (`BROWSETERM_CLOUD_API_URL`/`CLOUD_INTERNAL_API_TOKEN` were never actually injected into the
    Job's env at all, meaning the Job's own Cloud API calls would have 401'd every time) - fixed.
    container-maker's manifests/scripts/Makefile updated to match. `browseterm-server`: 176/176
    (12 new). `container-maker`: 59/59, three test files rewritten to mock the Cloud client
    instead of `ContainerOps`. Cloud redeployed live and verified directly (`GET .../stuck-saves`
    returns real data, `GET`/`POST /internal/containers/{id}` correctly 404/200 against a real
    UUID). `container-maker` itself remains not live-deployed to either k3d cluster in this
    project - this migration is correct and ready, not yet exercised end to end through a real
    save. Commits pushed: `browseterm-server` (`8912fea`), `container-maker` (`229c044`),
    `browseterm-monorepo` (`07baaa4`, submodule sync).

## What we did today (2026-09-11 — browseterm-ui-plan.md implemented: quota bug root-caused, Info + Hibernate buttons)

User handed over `~/browseterm/browseterm-ui-plan.md` (three asks) and asked for it to be
implemented, with this log updated once ready for their own validation pass - nothing in this
section has been committed/pushed yet, deliberately, so their review happens against the actual
working tree first.

139. **Plan item 1 — "still says exceeded your plan's quota" on create, root-caused.** Not a
    reverted subscription check (the earlier device-quota migration already fully removed
    `is_user_within_container_limit` from the create path, in both Local and Cloud - re-audited
    both and confirmed clean). The real cause: `container-maker`'s per-user-namespace Kubernetes
    `ResourceQuota`/`LimitRange` (`user_namespace_quota.yaml`, applied once at namespace creation
    and never revisited since) is driven by a `tier` string that has **no gRPC field to ever set
    it at all** - every namespace this project has ever created was silently pinned to the
    `"free"` tier's numbers forever (2 CPU / 2Gi memory / 4 pods total, 1 CPU per container max),
    sized as a billing tier's cheapest plan back when subscriptions gated things, not as the
    generous safety ceiling it needs to be now that Cloud's own device-capacity check
    (`allocated - used`) is the real, intended gate. A legitimately-sized request Cloud approves
    can still get rejected by this independent, much smaller K8s-level ceiling underneath it -
    exactly the reported symptom. Confirmed live, not just in theory: the one real per-user
    namespace in `browseterm-k3s-local` already had `limits.cpu` sitting at `2/2` (fully consumed
    by its two existing test pods) - the next container create would have failed with this exact
    error right now, no further pods needed to reproduce it. Fixed at the source
    (`container-maker/src/resources/resource_config.py`'s `TIERS["free"]`, raised to 16/32 CPU
    request/limit, 16/64Gi memory, 200Gi storage, 12 pods, 8 PVCs, 8 CPU / 32Gi per-container max -
    `"pro"` is dead code with no caller able to select it, left as-is) and **also live-patched**
    the already-existing namespace's `ResourceQuota`/`LimitRange` directly (safe and immediate per
    the manifest's own documented increase-only-takes-effect-immediately semantics - no pod
    eviction risk), so the fix isn't waiting on a namespace that already exists to somehow get
    recreated. Separately fixed the actually-misleading part of the symptom:
    `browseterm-server-local/src/common/utils.py`'s `clean_k8s_error_message` translated ANY
    K8s "exceeded quota" error - including this one - into "You've reached your plan's resource
    limit... upgrade your plan," copy that's actively wrong now that subscriptions are disabled;
    changed to "This device doesn't have enough remaining capacity for this terminal..." (three
    existing tests asserting on the old copy updated to match, not weakened). Also corrected a
    stale doc comment in `app.py` that claimed `create_container` still had plan-gating logic.
    `browseterm-server-local`: 135/135 (2 tests updated). `container-maker`: 59/59 unit
    (unaffected - the changed tests only assert `TIERS["free"]` compares consistently against
    itself, not literal numbers). Image rebuilt (`--no-cache`), `k3d image import`'d, rolled out to
    `browseterm-k3s-local`, confirmed live via `kubectl exec ... grep` (new error copy present, old
    "upgrade your plan" text gone) before considering it done.
140. **Plan items 2 & 3 — Terminal Info button + manual Hibernate button.** New `Info` button
    (every non-loading terminal state) opens a modal showing the container's real resource limits,
    IP/ports, status, and created/last-saved timestamps - wired to the existing, previously
    entirely unused `GET /get-container-info/{id}` endpoint (`api_handlers.get_container_info`
    already existed and already returned everything needed; nothing on the read side had to
    change). New `Hibernate` button (RUNNING containers only) is the manual counterpart to
    `reaper`'s own automatic idle-hibernation - new `POST /hibernate-container`
    (`browseterm-server-local/src/api_handlers.py`) reuses `reaper.py`'s exact safety-critical
    ordering: trigger a real save -> poll until `save_status` reaches a CONFIRMED `Succeeded` (a
    `Failed` or timed-out save must never lead to deleting the pod - matches reaper's own rule
    verbatim, same as its existing test suite for resume enforces for a different flow) -> delete
    the pod -> Cloud's existing compound hibernate transition (`CloudClient().hibernate_container`,
    the same one P19's resume-rollback path already reuses). Synchronous like `resume_container`,
    not backgrounded like `save_container` alone - a failed save here never changes the
    container's own `status`, so there's no SSE event a frontend could wait on for that outcome;
    the frontend instead shows a per-row "Hibernating..." loading state (`hibernatingIds`, mirrors
    the existing `pendingContainers` pattern for creation) for the duration of its own request. On
    success, the container's `status` flips to `HIBERNATED` via Cloud's ordinary write path, so
    the existing generic SSE `status_change` handling already re-renders the row correctly with no
    new event type needed. New `tests/integration/containers/test_hibernate_container.py` (10
    tests): happy path, exact save-then-delete-then-hibernate call ordering (mocked-manager
    pattern, mirrors `test_resume_calls_cloud_before_recreate`), 404/409s (missing container,
    not-RUNNING, no-`kubernetes_id`), a confirmed-FAILED save leaving the pod running, a save that
    never reaches any terminal state within the (patched-tiny-for-the-test) wait window, and
    ownership scoping. `browseterm-server-local`: 135/135 overall. Image rebuilt/redeployed to
    `browseterm-k3s-local` alongside item 139's fix (same rebuild), confirmed live via
    `kubectl exec ... grep` that `/hibernate-container` is actually registered in the running
    pod's `app.py`. Not yet exercised through the real browser UI end to end (clicking Info/
    Hibernate against a real running terminal) - left for the user's own validation pass, as
    requested. No commits pushed anywhere in this session's work (139 or 140) - held pending that
    validation.
141. **Follow-up to item 139 - delete was silently no-op'ing, the real driver of the quota
    exhaustion.** User's own instinct, asked directly: "check if delete works as usual, because
    if delete did not work, that would explain the resource crunch." It didn't. Live proof found
    with zero destructive action: cross-referencing the one real per-user namespace's live pods
    against Postgres's `containers` table turned up a pod (`namah-ssh-ubuntu-test-2-pod-...`,
    `Running`, still consuming its share of the namespace's CPU/memory quota) with **no matching
    DB row at all** - its row had been hard-deleted, but the pod was never actually removed from
    Kubernetes. Root cause: `container-maker`'s `delete()` (`KubernetesContainerHelper.check_pod`)
    resolved the pod to remove by comparing the caller-supplied `container_id` against the pod's
    own live Kubernetes UID - and every caller across the whole project (Local's
    `handleDelete`/`cleanupFailedContainer`/the k8s-creation-failure rollback, this session's own
    new `hibernate_container`, and `reaper`'s automatic idle-hibernation) was supplying the DB
    row's **cached** `kubernetes_id` for that, which is the exact same "historically unreliable...
    can be wrong from creation or stale after a pod is recreated" value `save()`'s own docstring
    already flagged and was fixed to stop trusting, two P-items ago, for the *save* path only -
    delete never got the equivalent fix. Worse: on no match, the old code silently skipped
    `delete_pod` entirely and still returned `{'status': 'Deleted'}` - no exception, no error, the
    DB row genuinely gone, everyone (UI, logs, the user) believing the delete fully succeeded
    while the pod quietly kept running and kept counting against the namespace's `ResourceQuota`
    forever. This is what actually exhausts a namespace's ceiling over time regardless of how
    generous item 139 made the numbers - the leak just takes longer to hit a bigger ceiling.
    Confirmed the mechanism directly and safely (no deletion attempted): exec'd into the live
    `container-maker` pod and read the orphan's own `browseterm/container-id` label
    (`600eca8e-1010-44b3-ab3e-91edf748c56b`) - it matches no row in Postgres at all, while the
    OTHER live pod's same label correctly matches the one surviving row's own id
    (`db9b600e-79e1-4c98-b352-bcb85c20e1ba`), proving the label itself is exactly the reliable,
    permanent identifier this needed all along. Fixed by making `delete()` resolve the pod the
    same principled way `save()` already does - just keyed on a label instead of a DB read, and
    genuinely simpler than save() because of it: new `KubernetesContainerHelper.find_pod_by_db_id`
    matches on the pod's own `browseterm/container-id` label (stamped from the DB id at BOTH
    create and resume time, so it's stable across a pod recreate in a way neither the cached
    `kubernetes_id` nor even the pod's own generated *name* are), needing no Cloud round-trip at
    all - which matters here specifically because Local's own delete flow deletes the DB row
    *before* the background k8s cleanup call, so by the time `delete()` runs the row may already
    be gone; a DB-lookup-based fix (mirroring save()'s own approach literally) would not have
    worked for this call path. New `find_service_for_pod` resolves the associated Service from the
    pod it just found (reusing the pod<->service relationship `ServiceManager` already computes
    for every service's own `associated_resources`) instead of a second independent id guess.
    `delete()`'s `container_id` now means the same thing `save()`'s already does - the DB id, not
    a Kubernetes UID - so every caller of the `deleteContainer` RPC across the whole project had
    to move in lockstep: `browseterm-server-local` (3 frontend call sites in `terminals.js`, the
    `delete_container_in_k8s` handler's comment, and this session's own `hibernate_container`) and
    `browseterm_workload/reaper` (`reaper.py`'s own hibernate-delete call, whose docstring
    previously documented the now-reversed convention as correct - including its own prior
    real-bug story, both rewritten to match). `container-maker`: 69/69 (10 new unit tests -
    `tests/k8s/integration/containers/test_delete_container.py`'s three cluster-only integration
    tests updated to match, not runnable locally since `KubernetesResourceManager` only supports
    `load_incluster_config`). `browseterm-server-local`: 136/136 (1 new regression test on
    `hibernate_container`). `reaper`: 16/16 (its own dedicated regression test flipped to assert
    the corrected direction; still not live-deployed anywhere in this project, per every prior
    P-item touching it). Both `container-maker` and `browseterm-server-local` rebuilt (`--no-cache`)
    and redeployed to `browseterm-k3s-local` alongside item 139/140's images. The live orphan pod
    itself was deliberately left untouched - it has no DB row, so nothing in the app can reach it
    to clean it up through the normal flow, and deleting a live, possibly-still-wanted terminal
    pod without asking first is exactly the kind of action this session doesn't take unilaterally;
    flagged directly to the user instead. No commits pushed - same as items 139/140, held pending
    the user's validation.
142. **Items 139-141 committed and pushed, monorepo synced.** User gave the go-ahead to commit the
    work held pending their validation. Verified each diff against this log's own account of items
    139-141 before staging anything. Commits pushed: `browseterm-server-local` (`de96ea6` - quota
    error copy, Info modal, Hibernate endpoint/button), `container-maker` (`066e2e6` -
    `find_pod_by_db_id`/`find_service_for_pod`, raised free-tier quota), `browseterm_workload`
    (`5e9a18b` - reaper's hibernate-delete now passes the DB id). Left `status_monitor`'s tracked
    `__pycache__/*.pyc` diffs in `browseterm_workload` unstaged - pre-existing tracked bytecode
    churn unrelated to this session's actual changes, flagged to the user rather than committed or
    silently stripped from tracking. Fast-forwarded all three submodule checkouts inside
    `browseterm-monorepo` to their new `origin/main` commits (each was a clean, non-diverged
    fast-forward - re-verified via `git log main..origin/main` before merging, per the P23
    divergence-check discipline) and pushed the pointer bump + this log entry as
    `browseterm-monorepo` (`89255df`).
143. **Started the Cloud Control Plane migration** (`~/browseterm/BROWSETERM_CLOUD_CONTROL_PLANE_MIGRATION.md`,
    a new, separate, much larger architecture doc from the owner - not a continuation of the P-item
    numbering above). Full part-by-part detail lives in `~/browseterm/BROWSETERM_MIGRATION_PROGRESS.md`
    at the workspace root (that file, not this log, is now the authoritative day-to-day tracker for
    this migration - only a summary lands here). Baseline audit (Part 0) found this migration
    substantially overlaps prior work above: device registration, OAuth device-linking, per-device
    Bearer tokens, container CRUD/resume with CAS, and SSE already exist, all over REST/polling
    rather than the new doc's gRPC bidirectional-stream design - the actual gap was gRPC transport,
    a durable command table, and a real headless Device Agent, not the whole system from scratch.
    Completed this session, each with its own tests (all passing, no regressions in any touched
    repo) and pushed to `origin/main`: Part 1 (durable `device_commands`/`device_credentials`
    tables, atomic device activation, quota-reservation and conditional-container-update
    invariants - `browseterm-db`), Part 2 (new public `browseterm-marketing` static site, built by
    a forked subagent), Part 5 (new `browseterm-device-control-spec` repo - the versioned
    Device Control + LocalDeviceAgent protobuf contracts), Part 6 (Cloud's own gRPC server,
    `browseterm-server/grpc_server.py` - deployed as a separate process from the HTTP service),
    Part 7 (new `browseterm-device-agent` repo - the headless local service that is now the sole
    local-to-Cloud communication boundary), Parts 8-11 (CREATE/DELETE/HIBERNATE/RESUME wired
    end-to-end, feature-flagged off by default in `browseterm-server` so the pre-existing
    synchronous paths are untouched until each flag is deliberately enabled), most of Part 12
    (Device Agent's private local API server exists and Cloud handles what it forwards, but
    status_monitor/reaper/snapshot_job/tunnel_registrar themselves are NOT yet rewired to call it -
    real remaining gap, not yet closed), and Part 14 (startup-based active-device activation over
    the gRPC stream, additive alongside the pre-existing REST heartbeat path).
    Explicitly NOT attempted, and why: Part 20 (Contabo deployment) and any DNS change - the doc
    itself requires the owner's direct authorization for both, never assumed. Parts 16-18
    (macOS/Windows/Linux runtime installers) - code not written this session; the doc explicitly
    requires real-hardware verification before any of it can be called done, which this session
    cannot perform. Part 19 (registry credentials) - the doc forbids inventing registry
    credentials or accounts. Part 21 (removing the old Local UI) - correctly blocked on Part 20
    actually being live first. Part 13 (Socket-SSH cutover) and Part 3/4 (moving the browser UI
    onto Cloud) - not started; Part 4's OAuth device-linking flow already substantially exists
    from prior work per the Part 0 audit above, so that part is smaller than the doc assumes.
    Submodule pointers updated for `browseterm-db` and `browseterm-server` (both changed this
    session); three new submodules added for the three new repos above
    (`browseterm-device-control-spec`, `browseterm-device-agent`, `browseterm-marketing`).
144. **Fixed a real Cloudflare deployment bug in `browseterm-marketing`, reported by the owner
    after deploying it themselves.** The deployment was using the repository root as its
    static-assets directory, so the deploy log uploaded `.git`, `.wrangler`, `README.md`,
    `LICENSE` and everything else in the repo alongside the actual site - traced directly to this
    project's own README, which had documented Cloudflare Pages' "Build output directory: /
    (repository root)" for this repo. Fixed in `browseterm-marketing` (`ac8334e`): every website
    file (`index.html`, `faq.html`, `security.html`, `install/`, `assets/`, plus `_headers`/
    `_redirects`, needed for the CSP to keep applying) moved into a new `public/` directory;
    `wrangler.jsonc` added pinning `assets.directory` to `./public` so the bug is structurally
    impossible to reintroduce, not just fixed once; `.wrangler/` added to `.gitignore`; README's
    deploy instructions rewritten to match (Workers static assets via `wrangler deploy`, not the
    old Pages Git-connect flow). Verified locally via `wrangler deploy --dry-run` that only the 11
    files under `public/` are ever read - this session has no Cloudflare credentials at all, so
    the actual redeploy and live 404 checks on `/.git/config` and `/README.md` are the owner's own
    follow-up, not done here. Full detail in `~/browseterm/BROWSETERM_MIGRATION_PROGRESS.md`'s
    "PART 2 — Cloudflare deployment fix" addendum. Submodule pointer for `browseterm-marketing`
    bumped and pushed as `browseterm-monorepo` (`7cdd7db`).
145. **Redesigned `browseterm-marketing`'s theme to match the actual Browseterm Cloud app**, per
    the owner's `uispec.md` (white background, mint-green/blue-violet palette pulled directly from
    `browseterm-server-local/templates/static/css` rather than invented), plus a new hero tagline
    and closing callout carrying the owner's cloud-workspaces motivation copy. `browseterm-marketing`
    (`b4bef71`); submodule pointer synced as `browseterm-monorepo` (`33bde9e`).
146. **Real production deployment - the Contabo cluster went from completely unreachable to
    actually running the migration's Cloud stack.** The owner gave SSH access
    (`deploy@100.86.120.79`/`puhtaeto-prod`, passwordless root via `sudo`) and confirmed DNS was
    live for both public hostnames, then asked which migration parts that newly unblocks. Verifying
    before touching anything found the real state was worse than "DNS is live" suggested:
    `app.browseterm.puhtaeto.com` resolved but had no matching Traefik ingress (404 on a
    self-signed cert), and `api.browseterm.puhtaeto.com` - the host the one running pod was
    actually configured for - no longer resolved in DNS at all. Net effect: Cloud was unreachable
    from either hostname when this started. The running pod was also 8 commits behind
    `browseterm-server`'s `origin/main` (predated Parts 6/7-11/12/14 entirely), no
    `browseterm-control-grpc` deployment existed, and `browseterm-db`'s migrations had never been
    applied to prod Postgres (`alembic_version` was 3 revisions behind head - `device_commands`,
    `device_credentials`, `placement_generation`, the NOTIFY trigger, `container_config_json` all
    missing). One thing was already right: `browseterm` has its own separate database/user on the
    shared Postgres instance, not sharing `ikompare`'s credentials.
    Given the owner's explicit go-ahead for the full push: rebuilt+redeployed `browseterm-server-cloud`
    from current `origin/main`, cut the ingress over to `app.browseterm.puhtaeto.com` (cert-manager
    reissued the Let's Encrypt cert automatically), took a `pg_dump` safety-net backup and then
    applied the pending migrations via a one-off Kubernetes Job, deployed `browseterm-control-grpc`
    (Part 6's server, ClusterIP-only - no public gRPC ingress yet since no real Device Agent exists
    anywhere to test it against), and flipped `DEVICE_COMMAND_CREATE/DELETE/HIBERNATE/RESUME_ENABLED`
    to true (verified first this was safe: the old flag-off path never called Container Maker at
    all, just wrote an orphaned DB row nothing would ever act on - not a regression against
    anything that actually worked). Verified end to end:
    `https://app.browseterm.puhtaeto.com/healthz` returns 200 with a real Let's Encrypt cert.
    Owner action still required: Google/GitHub OAuth console redirect URIs need updating to the
    `app.browseterm.puhtaeto.com` host or login will 401/mismatch - flagged, not something reachable
    from `kubectl`/SSH. Full detail in `~/browseterm/BROWSETERM_MIGRATION_PROGRESS.md`'s "PART 20"
    section (marked partial - registry/HA/observability/backup-schedule still open).
147. **Found and emergency-mitigated a real data-loss bug in the just-enabled Hibernate path,
    then fixed it properly and shipped Save as a first-class feature alongside it.** While
    investigating why a Part 3 fork had dropped the browser's "Save Session" button (the owner
    firmly corrected that drop - "Save is one of the biggest features of reliability... we cannot
    drop it" - see the new pinned-equivalent memory `browseterm-save-is-core-feature.md`), an
    investigation fork found Container Maker's `saveContainer` RPC does not block on the snapshot
    actually finishing - it creates a Kubernetes Job and returns immediately with a *predicted*
    image name, not a confirmation. `browseterm-device-agent`'s `hibernate.py` (already deployed,
    with `DEVICE_COMMAND_HIBERNATE_ENABLED` live in prod per item 146) was deleting the pod on that
    unconfirmed RPC return - a real risk of destroying a customer's pod before its data was
    actually saved. Immediately set `DEVICE_COMMAND_HIBERNATE_ENABLED=false` in prod by hand as a
    stopgap (Create/Delete/Resume unaffected - no real Device Agent had executed a live Hibernate
    yet, so nothing was actually lost) before any code fix existed.
    Fix (survived two mid-task interruptions - an account usage-limit cutoff and the machine
    sleeping mid-response - re-verified fresh at completion rather than trusting pre-interruption
    state): new shared `device_agent/commands/save_execution.py::perform_save()` triggers the
    snapshot then polls a new Cloud endpoint (backed by the same `container_snapshots` row
    `snapshot_job` already reports to) until confirmed `Succeeded`/`Failed`/timeout - never trusts
    the RPC's immediate response. Per the owner's explicit direction ("Save needs to work the same
    way other commands do... send a command to the device agent"; "can hibernate reuse the code
    from save rather than reimplement it?"), both the fixed `hibernate.py` and the new `save.py`
    call this one shared function - `hibernate.py` only deletes the pod + releases quota on a
    confirmed-succeeded outcome, using the real reported image name; `save.py` never touches the
    pod or quota regardless of outcome. `SAVE` is wired as a first-class Device Command end to end
    (proto enum, `browseterm-db` migration, Device Agent handler/dispatch, Cloud endpoint,
    `container_mutation.py`, new `DEVICE_COMMAND_SAVE_ENABLED` flag defaulting false, browser
    button), mirroring Create/Delete/Hibernate/Resume's shape at every layer - also caught
    `servicer.py`'s command-delivery map having no `"Save"` entry, which would have silently
    stranded every SAVE command in Postgres, never delivered over the control stream.
    Alongside this, Part 12 was finished (`status_monitor`/`reaper`/`snapshot_job`/`tunnel_registrar`
    rewired off `CLOUD_INTERNAL_API_TOKEN` onto Device Agent's local API - `snapshot_job` deliberately
    kept its direct Cloud calls for `allocate_snapshot`/`report_snapshot_result`, which need to write
    fields `ReportSnapshotProgress` has no room for; `socket-ssh` deferred to Part 13 since it has no
    gRPC tooling yet) and Part 3 (browser UI - login/terminals/profile/devices - moved from
    `browseterm-server-local` to Cloud, with a real trust-model fix: the new browser routes derive
    `user_id` only from the validated session cookie rather than trusting a body-supplied value).
    All committed and pushed: `browseterm_workload` (`ffa9ef6`), `socket-ssh` (`8bb2473`),
    `browseterm-device-agent` (`dcef9df`), `browseterm-db` (`f248a7d`),
    `browseterm-device-control-spec` (`abb775c`), `browseterm-server` (`4dd7f2b`); submodule
    pointers synced as `browseterm-monorepo` (`9bf3726`).
    **Important gap for whoever picks this up next: none of this item's code is deployed to prod
    yet** - item 146's deployment ran from `browseterm-server`'s `origin/main` at `0e3cb8a` (Part
    14), before any of this item's commits existed. Prod is still running that older image.
    `DEVICE_COMMAND_HIBERNATE_ENABLED` must stay `false` in prod until a fresh
    rebuild+redeploy actually carries this item's fix - re-enabling it against the currently-deployed
    image would re-introduce the exact bug just found. `browseterm-db`'s new SAVE migration
    (`d8e9f0a1b2c3`) is also not yet applied to prod. Full detail (including the corrected Part 10
    write-up and new SAVE addendum) in `~/browseterm/BROWSETERM_MIGRATION_PROGRESS.md`.
148. **Deployed item 147's work to prod for real, then fixed two UI bugs the owner found by
    actually using the live site.** The owner wired up Google's OAuth console redirect URI and
    asked whether anything was pending that needed it - yes: prod was still running the pre-Part-3
    image (`0e3cb8a`), so there was no real `/login` page to exercise the callback against at all.
    Rebuilt+redeployed `browseterm-server-cloud` from current `origin/main` (`4dd7f2b`); it
    crash-looped on the first attempt (`AssertionError: jinja2 must be installed to use
    Jinja2Templates` - Part 3 reintroduced `Jinja2Templates` but never re-added the `jinja2`
    dependency P06 had trimmed out; passed the implementing fork's own local tests only because
    something in that environment already had it installed outside the declared dependency set).
    Fixed (`browseterm-server` `8423a63`), rebuilt, redeployed clean. Applied the SAVE migration
    (`d8e9f0a1b2c3`) to prod too, with a fresh `pg_dump` backup first. `DEVICE_COMMAND_HIBERNATE_ENABLED`/
    `DEVICE_COMMAND_SAVE_ENABLED` deliberately left off per the owner's own choice - ships the code,
    no new lifecycle behavior live yet. Verified end to end: `/login` renders with real Google/GitHub
    buttons wired to `target=cloud`, protected routes correctly redirect when unauthenticated.
    - Owner then found two real bugs by using the live site: the Play button was disabled with no
      visible explanation (the `title` tooltip was already in the code, but a `disabled` button
      doesn't reliably fire hover in every browser, which native tooltips depend on - fixed by
      wrapping it in an always-hoverable `<span>`), and the Save button was on the terminals-list
      container card when it was only ever supposed to be on the individual terminal page. Moved
      the actual `POST /app/containers/{id}/save` trigger from `terminals.js`'s card (deleted
      entirely there - button markup, handler, in-flight state, dead CSS) onto `terminalpage.html`'s
      header (new button, wired in `terminalpage.js`), leaving only the existing read-only
      save-status widget where it was. `browseterm-server` (`01a96b2`).
149. **Rebuilt `browseterm-desktop` from a k3d-based interactive GUI app into a real Multipass+k3s
    local execution plane with a background daemon**, in two forked phases, after the owner asked
    directly whether Device Agent's reconnect-after-sleep design and a real local setup flow could
    be built now - unlike Parts 16-18's original hardware blocker, this machine actually has
    Multipass installed and is real hardware to build and test against.
    - **Phase 1** (`browseterm-desktop` `a65f369`): `cluster_manager.py` rewritten from `k3d`
      (Docker containers - always the dev-only shortcut) to real `multipass launch` + in-VM k3s,
      with the resulting kubeconfig merged into `~/.kube/config` as its own `browseterm` context
      (every "default"-named field renamed first, so it can't collide with Docker Desktop/Colima's
      own "default" context). `local_stack.py` rewritten to deploy the actual current stack instead
      of the pre-migration one it predated (which deployed `browseterm-server` locally and used a
      global `CLOUD_INTERNAL_API_TOKEN` for everything) - namespace/secrets -> MinIO -> cert-manager
      -> Container Maker -> `browseterm-device-agent` (had no build/deploy tooling at all until this
      phase; also needed an RBAC Role/RoleBinding it was missing, since it reads Container Maker's
      certs live via the k8s API) -> status-monitor -> reaper -> Socket-SSH+tunnel-registrar sidecar,
      each step verified against that component's own actual current manifest, not assumed from the
      stale `deploy.k3s.sh` reference script. Device Agent's credential comes from this app's own
      Keychain, written into a k8s Secret at deploy time. `ingress-nginx` dropped entirely - verified
      nothing routes through it now that ngrok is the real exposure path. Both `create_cluster()`
      and `deploy()` gained an `on_step(name, status, detail)` progress callback, not consumed by
      anything yet at this point. 57/57 tests. Found and worked around (not fixed) a real bug in
      `container-maker`'s own `Makefile`: `prod_setup` silently drops 2 of 11 args its script
      accepts.
    - **Phase 2** (`browseterm-desktop` `2814d53`): new headless `desktop/daemon.py`
      (`daemond.py` entrypoint) - the device heartbeat moved here from `app.py` (deleted there
      entirely, so the GUI and daemon can't heartbeat independently and race each other) plus a new
      60s health-check loop: `cluster_manager.vm_state()` -> `start_vm()` if the Multipass VM isn't
      `Running` (the actual "Mac slept, Multipass stopped the VM" recovery - Device Agent's own gRPC
      reconnect backoff, already built in Part 7, handles the rest once its pod is running again),
      then `list_pods()`/`restart_pod()` for anything genuinely crashing. New
      `packaging/com.browseterm.daemon.plist` `launchd` LaunchAgent template
      (`RunAtLoad`+`KeepAlive`) with install/uninstall commands documented in README - deliberately
      not run for real. Phase 1's `on_step` callback now reaches the GUI's WebView live via
      `evaluate_js` (the same mechanism the existing login-code display already used) - a real
      step-by-step Setup progress UI, building rows dynamically rather than hardcoding Phase 1's
      step list. 74/74 tests (57 + 17 new).
    - Both phases: no real Multipass VM created, no `launchctl load` run, nothing touching real
      infrastructure - every test mocks `subprocess`/`multipass exec`, matching this repo's existing
      convention. Committed and pushed (`a65f369`, `2814d53`); submodule pointers synced as
      `browseterm-monorepo` (`bd6f727`, `5d16acc`) - `browseterm-desktop` had actually never been
      initialized as a submodule in this monorepo checkout at all before this session (empty
      directory; `git submodule update --init` fixed it), a pre-existing gap unrelated to this
      session's own changes but only just found and closed here.
    - **Real remaining checkpoint, explicitly not done and not to be done without the owner
      present**: actually creating the Multipass VM, running Setup for real, and registering the
      `launchd` daemon. Everything above is built and unit-tested against mocks only.

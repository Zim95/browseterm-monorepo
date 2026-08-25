# BrowseTerm K3s Setup

## 0. Audit and configuration
- [x] core state/docs reconciled
- [x] repo/submodule/sibling-clone mapping verified
- [x] host prerequisites verified (multipass installed by user)
- [x] root env.mk constructed and validated
- [x] generated per-service env files verified

## 1. K3s
- [x] Multipass VM healthy
- [x] K3s installed
- [x] context browseterm-k3s active
- [x] node Ready
- [x] gVisor/runsc operational
- [x] pod internet egress verified

## 2. Infrastructure
- [x] namespace
- [x] gVisor RuntimeClass
- [x] ingress-nginx
- [x] MetalLB
- [x] MinIO
- [x] Postgres
- [x] DB schema/seed
- [x] NOTIFY triggers
- [x] Redis
- [x] internal mTLS certs

## 3. Images and services
- [x] registry auth verified
- [x] all required images built/pushed
- [x] container-maker deployed
- [x] browseterm-server deployed
- [x] socket-ssh deployed
- [x] status-monitor deployed
- [x] all required pods healthy

## 4. Host access
- [x] ingress external address determined (192.168.252.200)
- [x] exact /etc/hosts line given to user (waiting for user to run it)
- [ ] hostnames resolve after user edit
- [x] frontend responds (curl w/ Host header -> 302 login redirect)
- [~] socket endpoint responds (ws-only server, no HTTP GET handler - expected, will verify via real WS in E2E)

## 5. End-to-end terminal
- [ ] OAuth/login works
- [ ] create terminal works
- [ ] terminal pod Ready under gVisor
- [ ] ws token path works
- [ ] WebSocket -> SSH works
- [ ] interactive command executes
- [ ] disconnect/reconnect works
- [ ] delete terminal works

## 6. Save/snapshot
- [ ] save request starts
- [ ] save status Pending -> Running
- [ ] snapshot payload reaches MinIO
- [ ] snapshot Job runs
- [ ] Docker image build/push succeeds
- [ ] DB saved_image/status updated
- [ ] SSE/UI completion observed
- [ ] ttlSecondsAfterFinished cleanup verified

## Blockers
- none (multipass resolved). USER ACTION NEEDED (not a hard blocker to further automated
  progress, but required before OAuth login E2E can be tested): run this once, in your own
  terminal (needs sudo):
  sudo sed -i '' -e '15s/.*/192.168.252.200  browseterm.local.com/' -e '16s/.*/192.168.252.200  socketssh.local/' /etc/hosts

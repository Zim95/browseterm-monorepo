#!/usr/bin/env bash
# Provision a SINGLE-NODE k3s cluster in a Multipass VM and wire up kubectl.
#
# This replaces docker-desktop as the local cluster. The point: run the SAME single-node k3s both
# locally (this VM) and in prod (a self-owned cloud VM or Raspberry Pi), so the deployment is
# identical and — unlike docker-desktop — NetworkPolicies are actually ENFORCED (k3s ships the
# kube-router netpol controller).
#
# k3s is installed with its bundled Traefik + servicelb + local-storage DISABLED, because we bring
# our own ingress-nginx + MetalLB + MinIO (keeps the existing manifests/setup.sh unchanged).
#
# Idempotent: safe to re-run. After this, run ./scripts/setup.sh to deploy BrowseTerm.
set -euo pipefail

# ── Config (override via env) ──
VM="${VM:-browseterm-k3s}"
CPUS="${CPUS:-4}"
MEM="${MEM:-8G}"                 # single node runs PG + Redis + MinIO + all services + user pods
DISK="${DISK:-40G}"
UBUNTU="${UBUNTU:-24.04}"
K3S_VERSION="${K3S_VERSION:-v1.32.5+k3s1}"
CONTEXT="${CONTEXT:-browseterm-k3s}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"

step() { echo; echo "▶ $*"; }

command -v multipass >/dev/null || { echo "ERROR: multipass not installed (brew install --cask multipass)"; exit 1; }
command -v kubectl   >/dev/null || { echo "ERROR: kubectl not installed (brew install kubectl)"; exit 1; }

# ── 1. Launch the VM (skip if it already exists) ──
if multipass info "$VM" >/dev/null 2>&1; then
  step "VM '$VM' already exists — reusing"
else
  step "Launching VM '$VM' (${CPUS} cpus, ${MEM} mem, ${DISK} disk, Ubuntu ${UBUNTU})"
  multipass launch --name "$VM" --cpus "$CPUS" --memory "$MEM" --disk "$DISK" "$UBUNTU"
fi

# ── 2. Verify the VM has internet (k3s install + image pulls need it) ──
step "Checking the VM has outbound internet"
if multipass exec "$VM" -- bash -c "curl -sfI https://get.k3s.io >/dev/null"; then
  echo "  ✅ VM can reach the internet"
else
  echo "  ⚠️  VM has NO internet — k3s install + image pulls will fail."
  echo "     Usually a host VPN/firewall NAT issue. Fix host networking, then re-run."
  exit 1
fi

# ── 3. Install k3s (bundled Traefik/servicelb/local-storage disabled) ──
if multipass exec "$VM" -- test -f /etc/rancher/k3s/k3s.yaml 2>/dev/null; then
  step "k3s already installed in '$VM' — skipping"
else
  step "Installing k3s ${K3S_VERSION} (Traefik + servicelb + local-storage disabled)"
  # Disable Traefik + servicelb (we bring ingress-nginx + MetalLB). KEEP local-path (the default
  # StorageClass): MinIO/Postgres/Redis PVCs need dynamic provisioning — disabling it leaves MinIO's
  # PVC unbound and the pod Pending.
  multipass exec "$VM" -- bash -c \
    "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='${K3S_VERSION}' \
       INSTALL_K3S_EXEC='--disable traefik --disable servicelb --write-kubeconfig-mode=644' sh -"
fi

step "Waiting for the node to be Ready"
# Poll (don't `kubectl wait --all`: it errors with "no matching resources found" in the split second
# before the node registers, rather than waiting for it to appear).
for i in $(seq 1 60); do
  if multipass exec "$VM" -- sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready "; then
    echo "  ✅ node Ready"; break
  fi
  [ "$i" = 60 ] && { echo "  ⚠️  node not Ready after 180s"; exit 1; }
  sleep 3
done

# ── 3.5 Install gVisor (runsc) + register it with k3s's containerd ──
# WHY: user terminals are untrusted ROOT shells. runc shares the host kernel directly, so a kernel
# CVE → container escape → the whole node + every other tenant. gVisor puts a user-space kernel
# (Sentry) between the container and the host kernel. container-maker stamps user pods with
# `runtimeClassName: gvisor` (USER_POD_RUNTIME_CLASS); this makes that class resolvable on the node.
# The RuntimeClass object itself is applied by deploy.k3s.sh (a cluster resource, not a node one).
# Idempotent: skips the download if runsc is already installed, only (re)writes the containerd
# template + restarts k3s when the runsc runtime block is missing.
step "Installing gVisor (runsc) in '$VM' and registering it with k3s containerd"
multipass exec "$VM" -- sudo bash -s <<'GVISOR'
set -euo pipefail
ARCH="$(uname -m)"   # aarch64 on Apple Silicon, x86_64 on Intel — gVisor publishes both
TMPL=/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl

if command -v runsc >/dev/null 2>&1; then
  echo "  runsc already installed ($(runsc --version | head -1))"
else
  echo "  downloading runsc + containerd-shim-runsc-v1 (${ARCH})"
  URL="https://storage.googleapis.com/gvisor/releases/release/latest/${ARCH}"
  workdir="$(mktemp -d)"; cd "$workdir"
  for f in runsc containerd-shim-runsc-v1; do
    wget -q "${URL}/${f}" "${URL}/${f}.sha512"
  done
  sha512sum -c runsc.sha512 containerd-shim-runsc-v1.sha512
  chmod a+rx runsc containerd-shim-runsc-v1
  mv runsc containerd-shim-runsc-v1 /usr/local/bin/
  cd /; rm -rf "$workdir"
  echo "  installed $(runsc --version | head -1)"
fi

# Register a `runsc` runtime with k3s's bundled containerd via a config template. `{{ template "base" . }}`
# pulls in everything k3s would normally generate; we only append the runsc runtime handler.
if [ -f "$TMPL" ] && grep -q 'runtimes.runsc' "$TMPL"; then
  echo "  containerd template already has the runsc runtime — leaving k3s untouched"
else
  echo "  writing $TMPL with a runsc runtime block"
  mkdir -p "$(dirname "$TMPL")"
  cat > "$TMPL" <<'TOML'
{{ template "base" . }}

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
TOML
  echo "  restarting k3s to pick up the new containerd config (brief blip; it comes back)"
  systemctl restart k3s
fi
GVISOR

step "Waiting for the node to be Ready again after the gVisor/k3s restart"
for i in $(seq 1 60); do
  if multipass exec "$VM" -- sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready "; then
    echo "  ✅ node Ready"; break
  fi
  [ "$i" = 60 ] && { echo "  ⚠️  node not Ready after 180s"; exit 1; }
  sleep 3
done

# ── 4. Confirm NetworkPolicy enforcement is present (the whole reason for k3s) ──
step "k3s node + version"
multipass exec "$VM" -- sudo k3s kubectl get nodes -o wide

# ── 5. Pull the kubeconfig to the host, fix the server IP, name the context ──
VM_IP="$(multipass info "$VM" --format json | python3 -c "import sys,json;print(json.load(sys.stdin)['info']['$VM']['ipv4'][0])")"
step "Wiring kubectl → https://${VM_IP}:6443 as context '${CONTEXT}'"
TMP_KCFG="$(mktemp)"
multipass exec "$VM" -- sudo cat /etc/rancher/k3s/k3s.yaml \
  | sed "s#https://127.0.0.1:6443#https://${VM_IP}:6443#; s#: default#: ${CONTEXT}#; s#name: default#name: ${CONTEXT}#" \
  > "$TMP_KCFG"

mkdir -p "$(dirname "$KUBECONFIG_PATH")"
if [ -f "$KUBECONFIG_PATH" ]; then
  cp "$KUBECONFIG_PATH" "${KUBECONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"   # back up before merge
  KUBECONFIG="${KUBECONFIG_PATH}:${TMP_KCFG}" kubectl config view --flatten > "${TMP_KCFG}.merged"
  mv "${TMP_KCFG}.merged" "$KUBECONFIG_PATH"
else
  cp "$TMP_KCFG" "$KUBECONFIG_PATH"
fi
rm -f "$TMP_KCFG"
kubectl config use-context "$CONTEXT"

# ── 6. Prove pods (not just the VM) get internet — the egress path the terminals need ──
step "Verifying in-cluster pod internet egress"
kubectl run netcheck --image=busybox:1.36 --restart=Never --command -- sh -c "wget -qO- -T5 https://get.k3s.io >/dev/null && echo OK || echo FAIL" >/dev/null 2>&1 || true
kubectl wait --for=condition=ready pod/netcheck --timeout=60s >/dev/null 2>&1 || true
sleep 2
if kubectl logs netcheck 2>/dev/null | grep -q OK; then echo "  ✅ pods can reach the internet"; else echo "  ⚠️  pod internet check inconclusive — inspect: kubectl logs netcheck"; fi
kubectl delete pod netcheck --ignore-not-found >/dev/null 2>&1 || true

cat <<EOF

✅ Single-node k3s is up.
   Context : ${CONTEXT}  (kubectl config use-context ${CONTEXT})
   API     : https://${VM_IP}:6443
   VM      : multipass shell ${VM}   |   stop: multipass stop ${VM}   |   delete: multipass delete --purge ${VM}

Next:
  1. Point your image builds + deploy at this cluster (context '${CONTEXT}').
  2. Run ./scripts/setup.sh to deploy BrowseTerm (ingress-nginx + MetalLB + MinIO + services).
     NOTE: setup.sh currently expects the 'docker-desktop' context — it only WARNS, so it still runs.
  3. Isolation testing needs the k3s CIDRs (pods 10.42.0.0/16, services 10.43.0.0/16) set in env.mk —
     do that before validating tenant isolation (internet egress works regardless; see the doc).
EOF

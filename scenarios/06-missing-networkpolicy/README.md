# Scenario 06 — Missing NetworkPolicies (Flat Network)

| | |
|---|---|
| **Vuln class** | Network segmentation |
| **Difficulty** | ⭐⭐ Medium |
| **Backends** | kind ⚠️ (attack works; enforcement needs a policy CNI)  AKS ✅ |
| **Namespace** | `netpol-missing` |
| **MITRE ATT&CK for Containers** | [TA0008 Lateral Movement](https://attack.mitre.org/tactics/TA0008/), [T1046 Network Service Discovery](https://attack.mitre.org/techniques/T1046/) |

## What it is
A sensitive, unauthenticated Redis backend and an unrelated frontend share a
namespace with **no NetworkPolicy**. Kubernetes default networking is flat: every
pod can reach every other pod and Service across the whole cluster.

## Why it matters
Once an attacker gets code execution in *any* pod (see Scenario 08), a flat
network lets them scan and pivot to databases, internal APIs, and the control
plane. Network segmentation is the blast-radius control that turns one popped pod
into a contained incident instead of a cluster-wide breach.

## Deploy just this scenario
```powershell
kubectl apply -f scenarios/06-missing-networkpolicy/manifest.yaml
```

## Exploit walkthrough
```powershell
$fe = kubectl -n netpol-missing get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}'
kubectl -n netpol-missing exec -it $fe -- sh
```
Inside the frontend (which has no business talking to the DB):
```bash
# Reach the "internal" DB directly across the flat network:
redis-cli -h backend-redis -p 6379 ping         # PONG -> reachable
redis-cli -h backend-redis -p 6379 set pwned 1
redis-cli -h backend-redis -p 6379 keys '*'     # read/modify data at will

# Discover other services cluster-wide:
nslookup kubernetes.default.svc.cluster.local
for p in 6379 80 443 5432 27017; do nc -z -w1 backend-redis $p && echo "open:$p"; done
```

## What success looks like
The frontend reads/writes the Redis backend it should never reach — proving there
is no segmentation between workloads.

## Detection
- **Falco**: *"Unexpected outbound connection"* style rules if tuned; NetworkPolicy
  logs on Calico/Cilium (Hubble) show allowed flows that shouldn't exist.
- **kubescape**: "Ingress and Egress blocked" / "Workloads with no NetworkPolicy".

## Remediation
Apply a **default-deny** policy, then allow only required flows. This file
(`fix-networkpolicy.yaml`, apply manually to test) does that:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-all, namespace: netpol-missing }
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-frontend-dns, namespace: netpol-missing }
spec:
  podSelector: { matchLabels: { app: frontend } }
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
```
After this, `redis-cli -h backend-redis ping` from the frontend must **time out**.

### ⚠️ Making enforcement real on kind
kind's default **kindnet CNI ignores NetworkPolicy** — the fix above deploys but
won't block anything. To actually enforce on kind, recreate the cluster with a
policy CNI. Easiest is Calico:
```powershell
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```
On **AKS**, create the cluster with `--network-policy calico` (or Cilium) and
policies enforce natively. This kind/AKS difference is itself a key lesson.

## Suggested order
Fifth. Best appreciated right before Scenario 08, which uses lateral movement as
the payoff of an initial foothold.

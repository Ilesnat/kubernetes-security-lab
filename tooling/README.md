# Kubernetes security tooling

> **LAB ONLY.** These commands can inspect or actively probe the cluster selected by the current kubeconfig context. Confirm the context and authorization before every run:
>
> ```powershell
> kubectl config current-context
> kubectl config view --minify --output='jsonpath={.clusters[0].cluster.server}'
> ```
>
> Do not use the offensive tools against a cluster you do not own or have explicit authorization to test. The install script accepts no context override; it uses the current context and requires `-ConfirmLab`.

## Install Falco

From the workspace root, install or upgrade the pinned Falco release:

```powershell
.\tooling\install.ps1 -ConfirmLab
```

The script checks `kubectl` and Helm, checks reachability of the current context, and installs Helm chart `falcosecurity/falco` **9.2.0** with Falco image **0.45.0** in namespace `falco` as release `falco`. Re-running it upgrades the same pinned release. It disables metrics, the metrics Service, and ServiceMonitor creation; it does not create a public service. Installation requires cluster permissions to create the namespace, DaemonSet, service account, and RBAC objects.

Falco is configured here for **runtime syscall detection**, not Kubernetes API audit ingestion. Its kernel/eBPF driver needs compatible Linux nodes and may need elevated privileges. On Docker Desktop for Windows, kind nodes share the Docker Desktop Linux VM kernel; driver availability and event visibility are not guaranteed. AKS node policies, kernel/runtime details, and cluster admission controls may also prevent the driver from loading or limit visibility. Check the Falco pod logs and node coverage rather than treating a successful Helm release as proof of detection.

## Audit visibility and limitations

`audit\audit-policy.yaml` is a Kubernetes API-server audit policy. The existing kind configuration wires it into the kind control plane and writes audit records under `/var/log/kubernetes/kube-apiserver-audit.log`. When the current context is a kind context, `install.ps1` performs a read-only check of the API-server audit arguments, policy readability, and log readability; it reports an empty log separately. This check does not alter the cluster. For this workspace's kind cluster, inspect records with:

```powershell
if ((kubectl config current-context) -ne 'kind-k8s-sec-lab') { throw 'Switch to the intended kind lab context first.' }; docker exec k8s-sec-lab-control-plane sh -c 'tail -n 50 /var/log/kubernetes/kube-apiserver-audit.log'
```

The kind policy file does **not** configure AKS. AKS control-plane audit logs are Azure Monitor resource logs and require an already-configured Azure diagnostic setting and destination. The install script does not call Azure tools or create/change cloud resources. To inspect existing AKS settings, use the AKS resource ID explicitly in this read-only Azure CLI query:

```powershell
$AksResourceId = '<authorized AKS resource ID>'; az monitor diagnostic-settings list --resource $AksResourceId --query "[].{name:name,logs:logs[?category=='kube-audit' || category=='kube-audit-admin']}" --output json
```

The query shows configured settings, not delivered events. Confirm ingestion in the configured Azure Monitor destination (for example, `AKSAudit` / `AKSAuditAdmin` in resource-specific mode or `AzureDiagnostics` in Azure diagnostics mode). No diagnostic setting means no such resource-log visibility; this script does not create one. Other Kubernetes backends expose audit records differently, and the script does not claim audit visibility when it cannot verify the backend.

## Security tooling examples

These examples use explicit versions. Ensure the relevant CLI is installed at the listed version first; none of the commands silently select `latest`.

| Tool | Pinned version | PowerShell example |
| --- | --- | --- |
| kube-hunter | PyPI `0.6.8` | `$ApiHost = ([uri](kubectl config view --minify --output='jsonpath={.clusters[0].cluster.server}')).Host; if (-not $ApiHost) { throw 'No API host found in the current context.' }; pipx run --spec 'kube-hunter==0.6.8' kube-hunter --remote $ApiHost` |
| kube-bench | `0.10.1` | `sudo kube-bench run --targets node` |
| Trivy | Container `aquasec/trivy:0.74.0` | `$Context = kubectl config current-context; docker run --rm -v "${HOME}/.kube:/root/.kube:ro" aquasec/trivy:0.74.0 k8s --report summary $Context` |
| Kubescape | CLI `4.0.11` | `kubescape scan framework nsa` |
| Peirates | Go module `v1.1.28` (stable) | `go run github.com/inguardians/peirates@v1.1.28` |
| kubeletctl | Release `v1.13` | `$Context = kubectl config current-context; $Node = '<authorized node name>'; $NodeIp = kubectl --context $Context get node $Node --output='jsonpath={.status.addresses[?(@.type=="InternalIP")].address}'; if (-not $NodeIp) { throw 'No internal node IP was returned.' }; kubeletctl --server $NodeIp pods` |
| Falco runtime | Helm chart `9.2.0`, image `0.45.0` | `$Context = kubectl config current-context; kubectl --context $Context --namespace falco logs --selector app.kubernetes.io/name=falco --all-containers=true --prefix=true` |

These checks have different scope and side effects:

- kube-hunter remote mode probes the API-server address from the current context; it does not use the AKS diagnostic setting. Version `0.6.8` is a legacy pin, so treat its coverage as limited.
- kube-bench node checks inspect the host they run on. Run them on an authorized Linux Kubernetes node; running them from Windows/Docker Desktop does not audit a remote Kubernetes node. Managed AKS control-plane nodes are not user-accessible, so control-plane host checks are unavailable.
- Trivy cluster scanning and Kubescape framework scanning read cluster resources with the current kubeconfig permissions. The Trivy example assumes the standard `$HOME\.kube` config location and passes the current context explicitly; if `KUBECONFIG` is set to a custom location, mount that config and any referenced certificate files read-only. Image scanning may still require registry access.
- Peirates is an offensive penetration-testing tool and may perform privilege escalation or other state-changing actions. Use only in an explicitly authorized disposable lab; its interactive start is not a passive audit.
- kubeletctl operates against kubelet endpoints, not through the Kubernetes API context by default. The example first resolves a node's internal IP from the current context and requests its pod listing; kubelet access can expose container data, and other kubeletctl commands can enable execution.
- Falco pod logs show runtime alerts only. For kind API audit records, use the kind command above. For AKS, query the existing Azure Monitor destination; Falco logs do not substitute for managed control-plane audit logs.

The pinned tool versions are explicit examples, not a promise that every benchmark/framework supports the cluster's Kubernetes version. Review each tool's compatibility and output before relying on results.

## Teardown

Remove only the Falco Helm release while retaining the namespace and unrelated resources:

```powershell
.\tooling\install.ps1 -ConfirmLab -Remove
```

The script uses the current context, checks whether the release exists, and leaves the namespace in place. It does not delete the audit policy, alter kind cluster configuration, remove other tooling, or modify AKS/Azure resources.

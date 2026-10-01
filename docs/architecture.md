# Architecture and safety boundaries

## Components

- `up.ps1`, `down.ps1`, `reset.ps1`, and `status.ps1` are the PowerShell interface.
- `cluster/kind/` creates and destroys the local multi-node kind cluster.
- `cluster/aks/` owns the Azure resource-group lifecycle; it checks the configured subscription and API-server allow-list before creating resources.
- `scenarios/<name>/manifest.yaml` contains one deliberately vulnerable lab in one namespace. No scenario creates a public service.
- `tooling/` installs runtime detection and documents explicit scanner invocations.

## Network boundary

kind listens on the local Docker environment and does not publish scenario services. AKS API access is limited to the configured authorized CIDR; the scenario services remain `ClusterIP`. Access the web app via `kubectl port-forward`. Never add `LoadBalancer`, `NodePort`, or broad API CIDRs to a scenario.

Kubernetes NetworkPolicy enforcement depends on the CNI. kind's default CNI does not enforce the remediation exercise in scenario 06; the scenario README describes the policy-capable CNI requirement. The vulnerable baseline intentionally contains no default-deny policy.

## Cloud boundary

All AKS-managed resources must be created in the one dedicated lab resource group. AKS may create a separate managed node resource group; deleting the AKS cluster's parent lab group must also remove that managed group and its resources. Scripts must verify resource-group ownership before destructive deletion and must never change the active subscription automatically.

The API server is public only with the allow-list configured; this is not equivalent to a private cluster. If the allow-list is missing or malformed, deployment must stop. No sample uses a public workload endpoint.

## Cost and lifecycle

The price preview is an estimate for node compute, not a billing guarantee. The free control plane does not make node compute or network traffic free. Use one node, no autoscaler, and a short session. The workstation watchdog is not a remote Azure expiry mechanism; explicit teardown and a resource-group absence check are mandatory.

## Intentional risk

The lab intentionally grants cluster-admin access, permits privileged pods and hostPath mounts, and provides an anonymous API-access example. Those controls are teaching defects, not templates for production. Deploy only into the disposable lab.

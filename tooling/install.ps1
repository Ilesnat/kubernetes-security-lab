[CmdletBinding()]
param(
    [switch]$ConfirmLab,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$ReleaseName = 'falco'
$Namespace = 'falco'
$ChartRepository = 'https://falcosecurity.github.io/charts'
$ChartVersion = '9.2.0'
$FalcoVersion = '0.45.0'

if (-not $ConfirmLab) {
    throw 'LAB ONLY: inspect the current Kubernetes context, then rerun with -ConfirmLab.'
}

$KubectlCommand = Get-Command kubectl -ErrorAction SilentlyContinue
if ($null -eq $KubectlCommand) {
    throw 'kubectl is required and must be available on PATH.'
}

$HelmCommand = Get-Command helm -ErrorAction SilentlyContinue
if ($null -eq $HelmCommand) {
    throw 'Helm is required and must be available on PATH.'
}

$KubectlVersion = & $KubectlCommand.Source version --client --output=yaml
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to verify the kubectl client version.'
}

$HelmVersion = & $HelmCommand.Source version --short
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to verify the Helm client version.'
}
if ($HelmVersion -notmatch 'v?(?<HelmMajor>\d+)\.' -or [int]$Matches.HelmMajor -lt 3) {
    throw "Helm 3 or newer is required; found '$HelmVersion'."
}

$CurrentContext = (& $KubectlCommand.Source config current-context).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($CurrentContext)) {
    throw 'kubectl has no usable current context.'
}

Write-Warning "LAB ONLY: this operation targets the current context '$CurrentContext'. Review it before continuing. No context override is accepted."
Write-Host "kubectl: $($KubectlVersion | Select-Object -First 1)"
Write-Host "Helm: $HelmVersion"

$ClusterInfo = & $KubectlCommand.Source --context $CurrentContext cluster-info
if ($LASTEXITCODE -ne 0) {
    throw "The current Kubernetes context '$CurrentContext' is not reachable."
}

$Nodes = & $KubectlCommand.Source --context $CurrentContext get nodes --output=name
if ($LASTEXITCODE -ne 0) {
    throw "Unable to list nodes using the current context '$CurrentContext'."
}

$ApiServer = (& $KubectlCommand.Source --context $CurrentContext config view --minify --output='jsonpath={.clusters[0].cluster.server}').Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read the API server address from the current kubeconfig context.'
}

if ($ApiServer -match '\.azmk8s\.io(?::\d+)?/?$') {
    Write-Warning 'AKS detected. This script does not configure or verify Azure Monitor diagnostic settings. AKS API audit visibility requires an existing Azure diagnostic setting (for example, kube-audit or kube-audit-admin); tooling\audit\audit-policy.yaml is not an AKS configuration mechanism.'
}
elseif ($CurrentContext -match '^kind-(?<KindCluster>.+)$') {
    $KindCluster = $Matches.KindCluster
    $DockerCommand = Get-Command docker -ErrorAction SilentlyContinue

    if ($null -eq $DockerCommand) {
        Write-Warning "kind context detected, but Docker is unavailable; API audit visibility could not be checked for cluster '$KindCluster'."
    }
    else {
        $ControlPlaneContainers = @(& $DockerCommand.Source ps --filter "label=io.x-k8s.kind.cluster=$KindCluster" --filter 'label=io.x-k8s.kind.role=control-plane' --format '{{.Names}}')
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Docker could not inspect kind cluster '$KindCluster'; API audit visibility could not be checked."
        }
        elseif ($ControlPlaneContainers.Count -eq 0) {
            Write-Warning "No running kind control-plane container was found for '$KindCluster'; API audit visibility could not be checked."
        }
        else {
            $ControlPlaneContainer = $ControlPlaneContainers[0].Trim()
            $AuditProbe = 'grep -Fq -- "--audit-policy-file=/etc/kubernetes/audit-policy.yaml" /etc/kubernetes/manifests/kube-apiserver.yaml && grep -Fq -- "--audit-log-path=/var/log/kubernetes/kube-apiserver-audit.log" /etc/kubernetes/manifests/kube-apiserver.yaml && test -r /etc/kubernetes/audit-policy.yaml && test -r /var/log/kubernetes/kube-apiserver-audit.log'
            & $DockerCommand.Source exec $ControlPlaneContainer sh -c $AuditProbe
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "The kind API-server audit configuration or log is not readable in '$ControlPlaneContainer'. The policy file alone does not prove that audit logging is active."
            }
            else {
                Write-Host "kind API-server audit arguments, policy file, and log path are present and readable in '$ControlPlaneContainer'."
                & $DockerCommand.Source exec $ControlPlaneContainer sh -c 'test -s /var/log/kubernetes/kube-apiserver-audit.log'
                if ($LASTEXITCODE -eq 0) {
                    Write-Host 'The kind API audit log contains data.'
                }
                else {
                    Write-Warning 'The kind API audit log is currently empty; generate lab API activity before expecting audit events.'
                }
            }
        }
    }
}
else {
    Write-Warning 'The current context is neither identified as kind nor AKS. This installer cannot infer whether API-server audit logging is enabled for this backend.'
}

if ($Remove) {
    $ReleaseList = & $HelmCommand.Source list --all --namespace $Namespace --kube-context $CurrentContext --filter "^$ReleaseName$" --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect Helm release '$ReleaseName' in namespace '$Namespace'."
    }

    $InstalledReleases = @($ReleaseList | ConvertFrom-Json)
    if ($InstalledReleases.Count -eq 0) {
        Write-Host "Helm release '$ReleaseName' is already absent from namespace '$Namespace'."
        return
    }

    & $HelmCommand.Source uninstall $ReleaseName --namespace $Namespace --kube-context $CurrentContext
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove Helm release '$ReleaseName' from namespace '$Namespace'."
    }

    Write-Host "Removed Helm release '$ReleaseName'. The namespace and any unrelated resources were left unchanged."
    return
}

& $HelmCommand.Source repo add falcosecurity $ChartRepository --force-update
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to add or refresh the Falco Helm chart repository.'
}

& $HelmCommand.Source repo update falcosecurity
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to update the Falco Helm chart repository index.'
}

$InstallArguments = @(
    'upgrade', '--install', $ReleaseName, 'falcosecurity/falco',
    '--version', $ChartVersion,
    '--namespace', $Namespace,
    '--create-namespace',
    '--kube-context', $CurrentContext,
    '--wait',
    '--timeout', '10m',
    '--set-string', "image.tag=$FalcoVersion",
    '--set', 'driver.enabled=true',
    '--set', 'driver.kind=auto',
    '--set', 'metrics.enabled=false',
    '--set', 'metrics.service.create=false',
    '--set', 'serviceMonitor.create=false'
)

& $HelmCommand.Source @InstallArguments
if ($LASTEXITCODE -ne 0) {
    throw "Failed to install or upgrade Falco chart $ChartVersion ($FalcoVersion) in namespace '$Namespace'."
}

$Rollout = & $KubectlCommand.Source --context $CurrentContext --namespace $Namespace rollout status daemonset/$ReleaseName --timeout=10m
if ($LASTEXITCODE -ne 0) {
    throw "The Falco DaemonSet did not become ready in namespace '$Namespace'."
}

Write-Host "Falco is ready on the current context '$CurrentContext'."
Write-Host 'Runtime event visibility depends on the node OS, kernel, container runtime, and the Falco driver being supported.'
Write-Host 'This install does not configure Falco Kubernetes-audit ingestion or change API-server audit settings.'

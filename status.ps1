<#
================================================================================
 status.ps1  -- what's deployed, and (for aks) whether a cloud cluster is live
 plus estimated accrued cost this session.

 Usage:
   ./status.ps1 [-Backend kind|aks]
================================================================================
#>
[CmdletBinding()]
param(
    [ValidateSet('kind', 'aks')]
    [string]$Backend
)

. "$PSScriptRoot/scripts/lib/common.ps1"
$cfg = Import-DotEnv
if (-not $Backend) { $Backend = Get-Cfg $cfg 'BACKEND' 'kind' }

Write-Step "k8s-sec-lab STATUS  (backend = $Backend)"

switch ($Backend) {
    'kind' {
        $clusterName = Get-Cfg $cfg 'KIND_CLUSTER_NAME' 'k8s-sec-lab'
        Assert-Command kind "Install: winget install Kubernetes.kind"
        $existing = (kind get clusters 2>$null)
        if ($existing -and ($existing -split "`n" | ForEach-Object { $_.Trim() }) -contains $clusterName) {
            Select-LabContext -Backend kind -Config $cfg
            Write-Ok "kind cluster '$clusterName' is RUNNING."
            Invoke-Kubectl get nodes -o wide
        } else {
            Write-Warn "kind cluster '$clusterName' is NOT running."
            return
        }
    }
    'aks' {
        $aksStatus = "$PSScriptRoot/cluster/aks/status.ps1"
        if (-not (Test-Path $aksStatus)) { throw "AKS status script is missing: $aksStatus" }
        $aksClusterExists = & $aksStatus
        if ($LASTEXITCODE -ne 0) { throw "AKS status check failed." }
        if (-not $aksClusterExists) {
            Write-Warn 'No live AKS cluster was found; skipping kubectl queries to avoid using a stale context.'
            return
        }
        Select-LabContext -Backend aks -Config $cfg
    }
}

# Scenario workloads (backend-agnostic).
Write-Info "`nScenario namespaces present:"
Invoke-Kubectl get ns -l lab=k8s-sec-lab
Write-Info "`nAll pods across lab namespaces:"
Invoke-Kubectl get pods -A -l lab=k8s-sec-lab -o wide
Write-Info "`nNote: scenario 07 (anonymous-api) is RBAC-only and has no pods; scenario 09 (aks-imds) is AKS-only and idles on kind."

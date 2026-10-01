<#
================================================================================
 down.ps1  -- push-button "destroy everything, zero leftovers"
   kind: deletes the kind cluster.
   aks:  deletes the entire resource group (cluster + node RG + LBs + IPs +
         disks + NSGs) in one shot, and verifies it's gone.

 Usage:
   ./down.ps1                 # backend from .env
   ./down.ps1 -Backend kind
   ./down.ps1 -Backend aks
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

Write-Step "k8s-sec-lab DOWN  (backend = $Backend)"

switch ($Backend) {
    'kind' {
        & "$PSScriptRoot/cluster/kind/destroy.ps1"
    }
    'aks' {
        $aksDestroy = "$PSScriptRoot/cluster/aks/destroy.ps1"
        if (-not (Test-Path $aksDestroy)) {
            throw "AKS destroy script is missing: $aksDestroy"
        }
        & $aksDestroy
    }
}

Write-Ok "Teardown complete for backend '$Backend'."

<#
================================================================================
 reset.ps1  -- fast wipe + redeploy of scenarios/tooling WITHOUT recreating the
 cluster (kind) or resource group (aks). Good for iterating on a scenario.
 Use ./down.ps1 then ./up.ps1 for a full cluster rebuild.

 Usage:
   ./reset.ps1 [-Backend kind|aks] [-Scenarios a,b] [-NoTooling]
================================================================================
#>
[CmdletBinding()]
param(
    [ValidateSet('kind', 'aks')]
    [string]$Backend,
    [string[]]$Scenarios,
    [switch]$NoTooling
)

. "$PSScriptRoot/scripts/lib/common.ps1"
$cfg = Import-DotEnv
if (-not $Backend) { $Backend = Get-Cfg $cfg 'BACKEND' 'kind' }

Write-Step "k8s-sec-lab RESET  (backend = $Backend)"
Select-LabContext -Backend $Backend -Config $cfg

Write-Info "Removing existing scenario workloads..."
Remove-Scenarios -Only $Scenarios

Write-Info "Redeploying scenarios..."
Deploy-Scenarios -Only $Scenarios

if (-not $NoTooling) {
    $toolInstall = "$PSScriptRoot/tooling/install.ps1"
    if (-not (Test-Path $toolInstall)) { throw "Tooling installer is missing: $toolInstall" }
    & $toolInstall -ConfirmLab
    if ($LASTEXITCODE -ne 0) { throw "Tooling installation failed." }
}

Write-Ok "Reset complete."

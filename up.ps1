<#
================================================================================
 up.ps1  -- push-button "deploy the lab"
 Creates the cluster (kind or aks), waits for readiness, deploys every enabled
 vulnerable scenario, installs tooling, and prints a summary + teardown reminder.

 Usage:
   ./up.ps1                      # backend from .env (default kind)
   ./up.ps1 -Backend kind
   ./up.ps1 -Backend aks
   ./up.ps1 -Scenarios 01-rbac-privilege-escalation,02-privileged-container-escape
   ./up.ps1 -NoTooling           # skip scanner/Falco install
================================================================================
#>
[CmdletBinding()]
param(
    [ValidateSet('kind', 'aks')]
    [string]$Backend,
    [string[]]$Scenarios,
    [switch]$NoTooling,
    [int]$AutoDestroyHours
)

. "$PSScriptRoot/scripts/lib/common.ps1"
$cfg = Import-DotEnv
if (-not $Backend) { $Backend = Get-Cfg $cfg 'BACKEND' 'kind' }

Write-Step "k8s-sec-lab UP  (backend = $Backend)"
Write-Warn "AUTHORIZED, SELF-OWNED RESEARCH ONLY. This cluster is intentionally vulnerable."

# --- 0. Preflight (fail before creating a cluster) ------------------------
if (-not $NoTooling) {
    Assert-Command helm "Install: winget install Helm.Helm  (or re-run with -NoTooling to skip the Falco/tooling install)."
}

# --- 1. Create cluster ----------------------------------------------------
switch ($Backend) {
    'kind' {
        & "$PSScriptRoot/cluster/kind/create.ps1"
        if ($LASTEXITCODE -ne 0) { throw "kind create failed." }
    }
    'aks' {
        $aksCreate = "$PSScriptRoot/cluster/aks/create.ps1"
        if (-not (Test-Path $aksCreate)) {
            throw "AKS backend is incomplete. Missing: $aksCreate"
        }
        $extra = @{}
        if ($PSBoundParameters.ContainsKey('AutoDestroyHours')) { $extra['AutoDestroyHours'] = $AutoDestroyHours }
        & $aksCreate @extra
        if ($LASTEXITCODE -ne 0) { throw "aks create failed." }
    }
}

Select-LabContext -Backend $Backend -Config $cfg

# --- 2. Deploy scenarios --------------------------------------------------
Write-Step "Deploying vulnerable scenarios"
Deploy-Scenarios -Only $Scenarios

# --- 3. Install tooling ---------------------------------------------------
if (-not $NoTooling) {
    $toolInstall = "$PSScriptRoot/tooling/install.ps1"
    if (-not (Test-Path $toolInstall)) { throw "Tooling installer is missing: $toolInstall" }
    Write-Step "Installing tooling (Falco / audit)"
    & $toolInstall -ConfirmLab
    if ($LASTEXITCODE -ne 0) { throw "Tooling installation failed." }
} else {
    Write-Info "Skipping tooling install (-NoTooling)."
}

# --- 4. Summary -----------------------------------------------------------
Write-Step "Summary"
Write-Info "Lab namespaces / scenario workloads:"
& kubectl get ns -l lab=k8s-sec-lab --show-labels 2>$null
Write-Host ""
Write-Ok "Lab is up on backend '$Backend'."
Write-Info "Each scenario has a README with an exploit walkthrough:  scenarios/<name>/README.md"
Write-Info "Scenario workloads are isolated by namespace; use -Scenarios <folder-name> to select a subset."
Write-Info "Check status:   ./status.ps1 -Backend $Backend"
if ($Backend -eq 'aks') {
    Write-Warn "COST: an AKS cluster is now running. Run ./down.ps1 -Backend aks when finished."
} else {
    Write-Info "Tear down:      ./down.ps1 -Backend kind"
}

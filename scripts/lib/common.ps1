# ==========================================================================
# scripts/lib/common.ps1
# Shared helpers for every k8s-sec-lab script: dotenv loading, logging,
# backend dispatch, and safety guards. Dot-source this from top-level scripts:
#   . "$PSScriptRoot/scripts/lib/common.ps1"
# ==========================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Repo root resolution -------------------------------------------------
# common.ps1 lives at <repo>/scripts/lib/common.ps1 -> root is two levels up.
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Get-RepoRoot { return $script:RepoRoot }

# --- Logging --------------------------------------------------------------
function Write-Info  { param([string]$m) Write-Host "[*] $m"  -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "[+] $m"  -ForegroundColor Green }
function Write-Warn  { param([string]$m) Write-Host "[!] $m"  -ForegroundColor Yellow }
function Write-Err   { param([string]$m) Write-Host "[x] $m"  -ForegroundColor Red }
function Write-Step  { param([string]$m) Write-Host "`n==== $m ====" -ForegroundColor Magenta }

# --- .env loader ----------------------------------------------------------
# Loads <repo>/.env into a hashtable AND into $env:* for child processes.
# kind works with built-in defaults if .env is absent; AKS requires a real .env.
function Import-DotEnv {
    param([string]$Path = (Join-Path (Get-RepoRoot) '.env'))

    $map = @{}
    if (-not (Test-Path $Path)) {
        Write-Warn ".env not found at $Path (using built-in defaults where possible)."
        Write-Warn "Copy .env.example to .env and edit it for AKS / IP-restriction settings."
        return $map
    }
    foreach ($line in Get-Content $Path) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $idx = $t.IndexOf('=')
        if ($idx -lt 1) { continue }
        $k = $t.Substring(0, $idx).Trim()
        $v = $t.Substring($idx + 1).Trim().Trim('"').Trim("'")
        $map[$k] = $v
        Set-Item -Path "Env:$k" -Value $v
    }
    return $map
}

# Get a config value: prefer the loaded .env map, then process env, then default.
function Get-Cfg {
    param(
        [hashtable]$Env,
        [string]$Key,
        [string]$Default = $null,
        [switch]$Required
    )
    $val = $null
    if ($Env -and $Env.ContainsKey($Key) -and $Env[$Key]) { $val = $Env[$Key] }
    elseif (Test-Path "Env:$Key") { $val = (Get-Item "Env:$Key").Value }
    else { $val = $Default }

    if ($Required -and [string]::IsNullOrWhiteSpace($val)) {
        throw "Required config '$Key' is not set. Add it to your .env file."
    }
    return $val
}

# --- Tool presence checks -------------------------------------------------
function Assert-Command {
    param([string]$Name, [string]$Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' not found on PATH. $Hint"
    }
}

# --- kubectl helpers ------------------------------------------------------
function Invoke-Kubectl {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$KArgs)
    & kubectl @KArgs
    if ($LASTEXITCODE -ne 0) { throw "kubectl $($KArgs -join ' ') failed (exit $LASTEXITCODE)." }
}

function Select-LabContext {
    param(
        [ValidateSet('kind', 'aks')][string]$Backend,
        [hashtable]$Config
    )

    Assert-Command kubectl "Install: winget install Kubernetes.kubectl"
    if ($Backend -eq 'kind') {
        $context = "kind-$(Get-Cfg $Config 'KIND_CLUSTER_NAME' 'k8s-sec-lab')"
    } else {
        $context = Get-Cfg $Config 'AKS_KUBECONFIG_CONTEXT' (Get-Cfg $Config 'AKS_CLUSTER_NAME' 'k8s-sec-lab')
    }

    $contexts = & kubectl config get-contexts -o name
    if ($LASTEXITCODE -ne 0) { throw "Unable to read kubectl contexts." }
    if (($contexts -split "`n" | ForEach-Object { $_.Trim() }) -notcontains $context) {
        throw "Expected kubectl context '$context' for backend '$Backend' is not configured. Refusing to operate on another cluster."
    }

    & kubectl config use-context $context | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to select kubectl context '$context'." }
    Write-Ok "Selected kubectl context '$context'."
}

function Assert-ScenarioSelection {
    param([string[]]$Only)

    if (-not $Only -or $Only.Count -eq 0) { return }
    $root = Get-RepoRoot
    $available = @(Get-ChildItem (Join-Path $root 'scenarios') -Directory |
        Select-Object -ExpandProperty Name)
    $unknown = @($Only | Where-Object { $_ -notin $available })
    if ($unknown.Count -gt 0) {
        throw "Unknown scenario(s): $($unknown -join ', '). Available: $($available -join ', ')"
    }
}

# Apply every scenarios/*/manifest.yaml (sorted), or only the ones requested.
function Deploy-Scenarios {
    param([string[]]$Only)
    Assert-ScenarioSelection -Only $Only
    $root = Get-RepoRoot
    $dirs = Get-ChildItem (Join-Path $root 'scenarios') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name
    if (-not $dirs) { Write-Warn "No scenarios found."; return }

    foreach ($d in $dirs) {
        if ($Only -and $Only.Count -gt 0 -and ($Only -notcontains $d.Name)) { continue }
        $manifest = Join-Path $d.FullName 'manifest.yaml'
        if (-not (Test-Path $manifest)) { continue }
        Write-Info "Deploying scenario: $($d.Name)"
        Invoke-Kubectl apply -f $manifest

        $namespace = & kubectl get namespaces -l "scenario=$($d.Name)" -o 'jsonpath={.items[0].metadata.name}'
        if ($LASTEXITCODE -ne 0) { throw "Unable to find namespace for scenario '$($d.Name)'." }
        if ($namespace) {
            $deployments = & kubectl get deployments -n $namespace -o name
            if ($LASTEXITCODE -ne 0) { throw "Unable to inspect deployments in namespace '$namespace'." }
            if ($deployments) {
                Invoke-Kubectl wait --for=condition=Available deployment --all -n $namespace --timeout=180s
            }
        }
    }
}

function Remove-Scenarios {
    param([string[]]$Only)
    Assert-ScenarioSelection -Only $Only
    $root = Get-RepoRoot
    $dirs = Get-ChildItem (Join-Path $root 'scenarios') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
    foreach ($d in $dirs) {
        if ($Only -and $Only.Count -gt 0 -and ($Only -notcontains $d.Name)) { continue }
        $manifest = Join-Path $d.FullName 'manifest.yaml'
        if (-not (Test-Path $manifest)) { continue }
        Write-Info "Removing scenario: $($d.Name)"
        Invoke-Kubectl delete -f $manifest --ignore-not-found=true --wait=true --timeout=120s
    }
}

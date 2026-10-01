# Starts a host-local timer that invokes the guarded destroy script.
# This is not a remote guarantee: the host and child PowerShell process must remain online.
[CmdletBinding()]
param(
    [int]$Hours = 3,
    [string]$ResourceGroup,
    [string]$SubscriptionId,
    [string]$ExpectedRunId,
    [switch]$RunTimer
)

. (Join-Path $PSScriptRoot '..\..\scripts\lib\common.ps1')
. (Join-Path $PSScriptRoot 'aks-common.ps1')
$cfg = Import-AksLabConfig
if (-not $ResourceGroup) { $ResourceGroup = Get-Cfg -Env $cfg -Key 'AKS_RESOURCE_GROUP' -Default 'rg-k8s-sec-lab' }
if (-not $SubscriptionId) { $SubscriptionId = ([string](Get-Cfg -Env $cfg -Key 'AKS_SUBSCRIPTION_ID' -Required)).Trim() }
if ($Hours -lt 1 -or $Hours -gt 168) { throw 'Auto-destroy duration must be between 1 and 168 hours.' }

Assert-AksActiveSubscription -SubscriptionId $SubscriptionId
if ($ResourceGroup -ne (Get-Cfg -Env $cfg -Key 'AKS_RESOURCE_GROUP' -Default 'rg-k8s-sec-lab')) {
    throw 'Auto-destroy resource group does not match AKS_RESOURCE_GROUP in .env.'
}
if (-not $ExpectedRunId) {
    $state = Get-AksState
    if (-not $state) { throw 'Cannot schedule auto-destroy without the persisted AKS run marker.' }
    $ExpectedRunId = [string]$state.runId
}

if ($RunTimer) {
    Write-Warn "Host-local auto-destroy timer started for '$ResourceGroup'; it will wait $Hours hour(s)."
    Write-Warn 'The host must stay powered on and this child PowerShell process must remain running; shutdown or process termination cancels this timer.'
    Start-Sleep -Seconds ([int]($Hours * 3600))
    & (Join-Path $PSScriptRoot 'destroy.ps1') -ExpectedRunId $ExpectedRunId
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Guarded destroy returned exit code $LASTEXITCODE." }
    return
}

$state = Get-AksState
if (-not $state -or $state.runId -ne $ExpectedRunId -or $state.resourceGroup -ne $ResourceGroup -or $state.subscriptionId -ne $SubscriptionId) {
    throw 'The persisted AKS marker does not match this auto-destroy request; no timer was started.'
}

$powerShellExe = $null
try {
    $powerShellExe = [System.Environment]::ProcessPath
} catch {
    $powerShellExe = $null
}
if ([string]::IsNullOrWhiteSpace($powerShellExe)) {
    try {
        $powerShellExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    } catch {
        $powerShellExe = $null
    }
}
if ([string]::IsNullOrWhiteSpace($powerShellExe) -or
    -not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
    throw 'Could not resolve the current PowerShell executable path; auto-destroy was not scheduled.'
}

$stdoutLog = Join-Path $PSScriptRoot "auto-destroy-$ExpectedRunId.log"
$stderrLog = Join-Path $PSScriptRoot "auto-destroy-$ExpectedRunId.err.log"
$argumentParts = @('-NoProfile')
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $argumentParts += @('-ExecutionPolicy', 'Bypass')
}
$argumentParts += @(
    '-File', "`"$PSCommandPath`"",
    '-RunTimer',
    '-Hours', [string]$Hours,
    '-ResourceGroup', "`"$ResourceGroup`"",
    '-SubscriptionId', $SubscriptionId,
    '-ExpectedRunId', $ExpectedRunId
)
$startParameters = @{
    FilePath = $powerShellExe
    ArgumentList = ($argumentParts -join ' ')
    RedirectStandardOutput = $stdoutLog
    RedirectStandardError = $stderrLog
    PassThru = $true
}
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $startParameters.WindowStyle = 'Hidden'
}
$process = Start-Process @startParameters
if (-not $process -or $process.HasExited) {
    throw 'The host-local auto-destroy timer process failed to start.'
}
Write-Ok "Auto-destroy timer process $($process.Id) scheduled for about $Hours hour(s) from now."
Write-Warn 'This is not a remote guarantee: the host must remain powered on and the child PowerShell process must keep running.'
Write-Info "Timer output: $stdoutLog"

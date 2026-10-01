# Approximate compute-only estimate; this makes no Azure requests.
[CmdletBinding()]
param(
    [string]$NodeSize,
    [int]$NodeCount,
    [int]$AutoDestroyHours
)

. (Join-Path $PSScriptRoot '..\..\scripts\lib\common.ps1')
. (Join-Path $PSScriptRoot 'aks-common.ps1')
$cfg = Import-AksLabConfig

if (-not $NodeSize) { $NodeSize = Get-Cfg -Env $cfg -Key 'AKS_NODE_SIZE' -Default 'Standard_B4ms' }
if (-not $PSBoundParameters.ContainsKey('NodeCount')) {
    $countText = Get-Cfg -Env $cfg -Key 'AKS_NODE_COUNT' -Default '1'
    if (-not [int]::TryParse($countText, [ref]$NodeCount)) { throw "AKS_NODE_COUNT '$countText' is not an integer." }
}
if (-not $PSBoundParameters.ContainsKey('AutoDestroyHours')) {
    $hoursText = Get-Cfg -Env $cfg -Key 'AUTO_DESTROY_HOURS' -Default '3'
    if (-not [int]::TryParse($hoursText, [ref]$AutoDestroyHours)) { throw "AUTO_DESTROY_HOURS '$hoursText' is not an integer." }
}
Assert-AksLabShape -NodeSize $NodeSize -NodeCount $NodeCount
if ($AutoDestroyHours -lt 1 -or $AutoDestroyHours -gt 168) {
    throw 'Auto-destroy duration must be between 1 and 168 hours.'
}

$hourly = (Get-AksHourlyRate -NodeSize $NodeSize) * $NodeCount
$daily = $hourly * 24
$duration = $hourly * $AutoDestroyHours
Write-Step 'AKS estimated cost (USD, compute only)'
Write-Host ('  Estimated per hour : ${0:N4}' -f $hourly)
Write-Host ('  Estimated per day  : ${0:N2}' -f $daily)
Write-Host ('  Through auto-destroy ({0}h): ${1:N2}' -f $AutoDestroyHours, $duration)
Write-Warn 'Estimate uses the East US Linux pay-as-you-go Standard_B4ms rate ($0.166/hour) and covers node compute only; other regions, taxes, disks, networking, egress, and subscription discounts can change actual charges.'

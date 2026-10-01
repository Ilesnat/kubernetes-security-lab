# Read-only status and elapsed-cost estimate for the AKS backend.
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\..\scripts\lib\common.ps1')
. (Join-Path $PSScriptRoot 'aks-common.ps1')
$cfg = Import-AksLabConfig
$subId = ([string](Get-Cfg -Env $cfg -Key 'AKS_SUBSCRIPTION_ID' -Required)).Trim()
$rg = Get-Cfg -Env $cfg -Key 'AKS_RESOURCE_GROUP' -Default 'rg-k8s-sec-lab'
$cluster = Get-Cfg -Env $cfg -Key 'AKS_CLUSTER_NAME' -Default 'k8s-sec-lab'

Assert-AksActiveSubscription -SubscriptionId $subId
Write-Step "AKS status: '$cluster' in '$rg'"

$clusterExists = $false
$state = Get-AksState
if (-not (Test-AksResourceGroupExists -Name $rg)) {
    Write-Warn "Resource group '$rg' is not present; no AKS cluster is running there."
} else {
    $group = Get-AksResourceGroup -Name $rg
    $groupRunId = Assert-AksOwnedResourceGroup -ResourceGroup $group
    if ($state -and $state.runId -ne $groupRunId) {
        Write-Warn 'The local start marker does not match this resource group; refusing to attribute its cost to this run.'
        $state = $null
    }

    $output = & az aks list --resource-group $rg --output json 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Could not read AKS cluster status (az aks list failed, exit $exitCode): $(($output | Out-String).Trim())"
    }
    try {
        $clusters = @(($output | Out-String) | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "Azure CLI returned invalid AKS status data: $($_.Exception.Message)"
    }
    $aks = $clusters | Where-Object { $_.name -eq $cluster } | Select-Object -First 1
    if ($aks) {
        $clusterExists = $true
        Write-Ok "Cluster '$cluster' exists; provisioning state: $($aks.provisioningState)."
        Write-Info "Node resource group: $($aks.nodeResourceGroup)"
    } else {
        Write-Warn "No AKS cluster '$cluster' was found in the owned resource group (partial creation or deletion may be in progress)."
    }
}

if ($state) {
    $startedAt = [DateTimeOffset]::Parse([string]$state.startedAtUtc).ToUniversalTime()
    $elapsedHours = [Math]::Max(0.0, ([DateTimeOffset]::UtcNow - $startedAt).TotalHours)
    $rate = [double]$state.hourlyRateUsd
    $accrued = $rate * $elapsedHours
    Write-Info ('Start marker: {0} UTC; estimated elapsed compute: ${1:N2} at ${2:N4}/hour.' -f $startedAt.ToString('u'), $accrued, $rate)
    Write-Info ('Estimated 24-hour compute cost: ${0:N2}. Estimate covers node compute only; ancillary Azure charges and discounts are excluded.' -f ($rate * 24))
} else {
    Write-Warn 'No matching persisted AKS start marker is available; elapsed cost cannot be estimated.'
}

return $clusterExists

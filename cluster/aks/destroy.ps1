# Guarded, idempotent teardown of the lab resource group and verification of its AKS-managed node group.
[CmdletBinding()]
param([string]$ExpectedRunId)

. (Join-Path $PSScriptRoot '..\..\scripts\lib\common.ps1')
. (Join-Path $PSScriptRoot 'aks-common.ps1')
$cfg = Import-AksLabConfig
$subId = ([string](Get-Cfg -Env $cfg -Key 'AKS_SUBSCRIPTION_ID' -Required)).Trim()
$rg = Get-Cfg -Env $cfg -Key 'AKS_RESOURCE_GROUP' -Default 'rg-k8s-sec-lab'
$cluster = Get-Cfg -Env $cfg -Key 'AKS_CLUSTER_NAME' -Default 'k8s-sec-lab'

Assert-AksActiveSubscription -SubscriptionId $subId
$state = Get-AksState
$labGroupExists = Test-AksResourceGroupExists -Name $rg
if ($ExpectedRunId -and $state -and $state.runId -ne $ExpectedRunId) {
    if (-not $labGroupExists) {
        Write-Info 'The lab resource group is absent and this auto-destroy timer belongs to an older run; leaving the newer local state untouched.'
        return
    }
    throw 'The local AKS marker belongs to another run. Refusing auto-destroy to protect a newer lab.'
}

$stateResourceGroup = ''
$stateSubscriptionId = ''
$stateRunId = ''
$stateNodeResourceGroup = ''
if ($state) {
    $stateResourceGroup = [string]$state.resourceGroup
    $stateSubscriptionId = [string]$state.subscriptionId
    $stateRunId = [string]$state.runId
    $nodeNameProperty = $state.PSObject.Properties['nodeResourceGroup']
    if ($nodeNameProperty) { $stateNodeResourceGroup = ([string]$nodeNameProperty.Value).Trim() }
}
$stateMatchesTarget = $state -and $stateResourceGroup -eq $rg -and $stateSubscriptionId -eq $subId

if (-not $labGroupExists) {
    Write-Info "Lab resource group '$rg' is absent."
    if ($stateMatchesTarget -and $stateNodeResourceGroup) {
        Write-Info "Checking persisted AKS-managed node resource group '$stateNodeResourceGroup'."
        Wait-AksResourceGroupAbsent -Name $stateNodeResourceGroup
        if (-not $ExpectedRunId -or $stateRunId -eq $ExpectedRunId) {
            Remove-AksState
        }
        Write-Ok "Lab resource group '$rg' and managed node resource group '$stateNodeResourceGroup' are both absent."
        return
    }
    if ($stateMatchesTarget) {
        throw "Lab resource group '$rg' is absent, but its state marker has no nodeResourceGroup name. Cannot verify the managed node group; marker retained at .lab-state\aks-state.json. No inferred group was deleted."
    }
    if ($state) {
        Write-Warn 'The lab resource group is absent, but the local state marker does not identify this subscription/resource group; it was left untouched and no managed node group was inferred.'
    } else {
        Write-Warn 'The lab resource group is absent and no persisted nodeResourceGroup name is available for a separate managed-group check. No inferred group was deleted.'
    }
    Write-Ok 'No lab resource group remains to delete.'
    return
}

$group = Get-AksResourceGroup -Name $rg
$ownedRunId = Assert-AksOwnedResourceGroup -ResourceGroup $group -ExpectedRunId $ExpectedRunId
$stateMatchesRun = $stateMatchesTarget -and $stateRunId -eq $ownedRunId
if ($ExpectedRunId -and $state -and -not $stateMatchesRun) {
    throw 'The local AKS marker does not match the owned resource group run. Refusing auto-destroy.'
}
if ($stateMatchesRun -and $stateNodeResourceGroup -and
    $state.PSObject.Properties['clusterName'] -and [string]$state.clusterName -ne $cluster) {
    throw 'The local AKS marker cluster name does not match AKS_CLUSTER_NAME. Refusing to use its node resource-group name.'
}

Write-Info "Reading AKS '$cluster' in owned lab resource group '$rg' to identify its managed node resource group."
$nodeGroupOutput = & az aks show --resource-group $rg --name $cluster --query nodeResourceGroup --output tsv 2>&1
$showExitCode = $LASTEXITCODE
$liveNodeResourceGroup = ($nodeGroupOutput | Out-String).Trim()
$nodeResourceGroup = ''
if ($showExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($liveNodeResourceGroup)) {
    if ($stateMatchesRun -and $stateNodeResourceGroup -and $stateNodeResourceGroup -ne $liveNodeResourceGroup) {
        throw "Persisted node resource group '$stateNodeResourceGroup' does not match Azure's current value '$liveNodeResourceGroup'. Refusing teardown."
    }
    $nodeResourceGroup = $liveNodeResourceGroup
} elseif ($stateMatchesRun -and $stateNodeResourceGroup) {
    $nodeResourceGroup = $stateNodeResourceGroup
    Write-Warn "az aks show could not resolve the node group (exit $showExitCode); using the persisted Azure-reported name '$nodeResourceGroup'. Details: $(($nodeGroupOutput | Out-String).Trim())"
} else {
    Write-Warn "Could not resolve AKS nodeResourceGroup (az aks show exit $showExitCode) and no matching persisted name is available. The owned lab group will be removed, but no other group will be inferred or deleted. Details: $(($nodeGroupOutput | Out-String).Trim())"
}

if (-not $stateMatchesRun) {
    $state = [pscustomobject]@{
        runId = $ownedRunId
        resourceGroup = $rg
        subscriptionId = $subId
        clusterName = $cluster
        nodeResourceGroup = $nodeResourceGroup
        status = 'Deleting'
    }
} else {
    $nodeNameProperty = $state.PSObject.Properties['nodeResourceGroup']
    if ($nodeNameProperty) {
        $state.nodeResourceGroup = $nodeResourceGroup
    } else {
        $state | Add-Member -NotePropertyName nodeResourceGroup -NotePropertyValue $nodeResourceGroup
    }
    $state.status = 'Deleting'
}
Save-AksState -State $state

Write-Warn "Deleting only the verified AKS-owned lab resource group '$rg' (run $ownedRunId)."
Write-Warn 'Azure billing can continue until deletion of the lab and managed node resource groups is complete.'
& az group delete --name $rg --yes --no-wait
if ($LASTEXITCODE -ne 0) {
    throw "az group delete failed (exit $LASTEXITCODE). The lab resource group was not confirmed deleted; inspect it and retry."
}

Wait-AksResourceGroupAbsent -Name $rg
if (-not $nodeResourceGroup) {
    throw "Lab resource group '$rg' is absent, but the AKS-managed node resource group name could not be resolved or recovered from state. Marker retained; no inferred group was deleted. Inspect Azure to identify any orphaned managed node group."
}

Write-Info "Verifying Azure removed managed node resource group '$nodeResourceGroup'."
try {
    Wait-AksResourceGroupAbsent -Name $nodeResourceGroup
} catch {
    throw "AKS-managed node resource group '$nodeResourceGroup' remains after lab resource group '$rg' deletion. It was not deleted because this script will not blindly delete a separate group. Verify its ownership before taking action. $($_.Exception.Message)"
}

$finalState = Get-AksState
if ($finalState -and $finalState.runId -eq $ownedRunId) {
    Remove-AksState
}
Write-Ok "Lab resource group '$rg' and managed node resource group '$nodeResourceGroup' are both absent; teardown verified."

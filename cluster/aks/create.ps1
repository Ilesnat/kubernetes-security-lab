# Creates the single-node AKS lab in one dedicated, ownership-tagged RG.
# This script provisions Azure resources and incurs charges when explicitly run.
[CmdletBinding()]
param(
    [int]$AutoDestroyHours,
    [switch]$NoAutoDestroy
)

. (Join-Path $PSScriptRoot '..\..\scripts\lib\common.ps1')
. (Join-Path $PSScriptRoot 'aks-common.ps1')
$cfg = Import-AksLabConfig

$subId = ([string](Get-Cfg -Env $cfg -Key 'AKS_SUBSCRIPTION_ID' -Required)).Trim()
$rg = Get-Cfg -Env $cfg -Key 'AKS_RESOURCE_GROUP' -Default 'rg-k8s-sec-lab'
$location = Get-Cfg -Env $cfg -Key 'AKS_LOCATION' -Default 'eastus'
$cluster = Get-Cfg -Env $cfg -Key 'AKS_CLUSTER_NAME' -Default 'k8s-sec-lab'
$kubeContext = Get-Cfg -Env $cfg -Key 'AKS_KUBECONFIG_CONTEXT'
$nodeSize = Get-Cfg -Env $cfg -Key 'AKS_NODE_SIZE' -Default 'Standard_B4ms'
$nodeCountText = Get-Cfg -Env $cfg -Key 'AKS_NODE_COUNT' -Default '1'
$nodeCount = 0
if (-not [int]::TryParse($nodeCountText, [ref]$nodeCount)) {
    throw "AKS_NODE_COUNT '$nodeCountText' is not an integer."
}
Assert-AksLabShape -NodeSize $nodeSize -NodeCount $nodeCount
$allowIp = Assert-AksSingleIpCidr -Cidr ([string](Get-Cfg -Env $cfg -Key 'ALLOWED_IP'))

if (-not $PSBoundParameters.ContainsKey('AutoDestroyHours')) {
    $hoursText = Get-Cfg -Env $cfg -Key 'AUTO_DESTROY_HOURS' -Default '3'
    if (-not [int]::TryParse($hoursText, [ref]$AutoDestroyHours)) {
        throw "AUTO_DESTROY_HOURS '$hoursText' is not an integer."
    }
}
if ($AutoDestroyHours -lt 1 -or $AutoDestroyHours -gt 168) {
    throw 'Auto-destroy duration must be between 1 and 168 hours.'
}

Assert-AksActiveSubscription -SubscriptionId $subId
Assert-Command kubectl 'Install kubectl: winget install Kubernetes.kubectl'
Write-Step "AKS backend preflight: '$cluster' in '$rg' ($location)"
Write-Warn 'AUTHORIZED, SELF-OWNED RESEARCH ONLY. This deliberately vulnerable lab incurs Azure charges.'
Assert-AksEphemeralOsDiskSupport -Location $location -NodeSize $nodeSize

if (Test-AksResourceGroupExists -Name $rg) {
    throw "Resource group '$rg' already exists. This backend never adopts existing groups; choose a new dedicated AKS_RESOURCE_GROUP or inspect/remove the existing group yourself."
}

$hourlyRate = Get-AksHourlyRate -NodeSize $nodeSize
& (Join-Path $PSScriptRoot 'cost.ps1') -NodeSize $nodeSize -NodeCount $nodeCount -AutoDestroyHours $AutoDestroyHours

$runId = [guid]::NewGuid().ToString()
$state = [pscustomobject]@{
    runId = $runId
    resourceGroup = $rg
    clusterName = $cluster
    subscriptionId = $subId
    location = $location
    nodeSize = $nodeSize
    nodeCount = $nodeCount
    hourlyRateUsd = $hourlyRate
    nodeResourceGroup = $null
    startedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    status = 'Creating'
}
Save-AksState -State $state

Write-Step "Creating dedicated resource group '$rg'"
& az group create --name $rg --location $location --tags 'aksLabOwner=k8s-sec-lab' "aksLabRunId=$runId" 'purpose=k8s-sec-lab' 'ephemeral=true' --output none
if ($LASTEXITCODE -ne 0) {
    throw "az group create failed (exit $LASTEXITCODE). No AKS cluster was requested. Inspect '$rg' before retrying."
}
$createdGroup = Get-AksResourceGroup -Name $rg
[void](Assert-AksOwnedResourceGroup -ResourceGroup $createdGroup -ExpectedRunId $runId)

if (-not $NoAutoDestroy) {
    & (Join-Path $PSScriptRoot 'auto-destroy.ps1') -Hours $AutoDestroyHours -ResourceGroup $rg -SubscriptionId $subId -ExpectedRunId $runId
} else {
    Write-Warn 'Auto-destroy is disabled. You are responsible for running down.ps1 -Backend aks.'
}

Write-Step "Creating AKS cluster '$cluster' (one Standard_B4ms node, free control-plane tier)"
$createArgs = @(
    'aks', 'create',
    '--resource-group', $rg,
    '--name', $cluster,
    '--location', $location,
    '--tier', 'free',
    '--node-count', '1',
    '--node-vm-size', 'Standard_B4ms',
    '--node-osdisk-type', 'Ephemeral',
    '--node-osdisk-size', '30',
    '--os-sku', 'Ubuntu',
    '--network-plugin', 'kubenet',
    '--network-policy', 'calico',
    '--api-server-authorized-ip-ranges', $allowIp,
    '--enable-managed-identity',
    '--generate-ssh-keys',
    '--yes'
)
& az @createArgs
if ($LASTEXITCODE -ne 0) {
    throw "az aks create failed (exit $LASTEXITCODE). The auto-destroy timer is active unless disabled; otherwise run down.ps1 -Backend aks to remove the owned partial resource group."
}

$nodeResourceGroup = & az aks show --resource-group $rg --name $cluster --query nodeResourceGroup --output tsv 2>&1
$showExitCode = $LASTEXITCODE
$nodeResourceGroup = ($nodeResourceGroup | Out-String).Trim()
if ($showExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($nodeResourceGroup)) {
    throw "AKS was created, but az aks show could not provide its nodeResourceGroup (exit $showExitCode). Run down.ps1 -Backend aks; teardown will retry the read and will not blindly delete an inferred group."
}
$state.nodeResourceGroup = $nodeResourceGroup
$state.status = 'Running'
Save-AksState -State $state

Write-Info 'Fetching cluster credentials and confirming node readiness.'
$credentialArgs = @('aks', 'get-credentials', '--resource-group', $rg, '--name', $cluster, '--overwrite-existing')
if (-not [string]::IsNullOrWhiteSpace($kubeContext)) {
    $credentialArgs += @('--context', $kubeContext)
}
& az @credentialArgs
if ($LASTEXITCODE -ne 0) {
    throw "az aks get-credentials failed (exit $LASTEXITCODE). The owned RG remains available for guarded teardown."
}
& kubectl get nodes -o wide
if ($LASTEXITCODE -ne 0) { throw "kubectl get nodes failed (exit $LASTEXITCODE)." }

Write-Ok "AKS lab '$cluster' is ready in '$rg'."
Write-Warn 'No Kubernetes workloads or LoadBalancer/public Services are created by this backend.'
Write-Warn 'Cost is accruing. Tear down with: .\down.ps1 -Backend aks'
if (-not $NoAutoDestroy) {
    Write-Warn "Auto-destroy is scheduled for about $AutoDestroyHours hour(s); the timer runs on this host and requires it to remain online with the process running."
}

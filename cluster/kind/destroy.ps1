# ==========================================================================
# cluster/kind/destroy.ps1
# Deletes the local kind cluster completely. Idempotent (ignore-not-found).
# ==========================================================================
param()

. "$PSScriptRoot/../../scripts/lib/common.ps1"
$cfg = Import-DotEnv
$clusterName = Get-Cfg $cfg 'KIND_CLUSTER_NAME' 'k8s-sec-lab'

Write-Step "kind backend: destroy cluster '$clusterName'"
Assert-Command kind "Install: winget install Kubernetes.kind"

$existing = (kind get clusters 2>$null)
if ($existing -and ($existing -split "`n" | ForEach-Object { $_.Trim() }) -contains $clusterName) {
    & kind delete cluster --name $clusterName
    if ($LASTEXITCODE -ne 0) { throw "kind delete cluster failed (exit $LASTEXITCODE)." }
    Write-Ok "kind cluster '$clusterName' deleted. Zero local leftovers."
} else {
    Write-Ok "kind cluster '$clusterName' not present. Nothing to delete."
}

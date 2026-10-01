# ==========================================================================
# cluster/kind/create.ps1
# Creates the local multi-node kind cluster. Pre-flight checks Docker is up
# and warns on low resources. Idempotent: re-running is safe.
# Invoked by top-level up.ps1; can also be run directly.
# ==========================================================================
param()

. "$PSScriptRoot/../../scripts/lib/common.ps1"
$cfg = Import-DotEnv

$clusterName = Get-Cfg $cfg 'KIND_CLUSTER_NAME' 'k8s-sec-lab'
$nodeMode    = Get-Cfg $cfg 'KIND_NODES' 'multi'
$root        = Get-RepoRoot

Write-Step "kind backend: create cluster '$clusterName' ($nodeMode)"

Assert-Command kind    "Install: winget install Kubernetes.kind"
Assert-Command kubectl "Install: winget install Kubernetes.kubectl"
Assert-Command docker  "Install/start Docker Desktop (WSL2 backend)."

# --- Pre-flight: Docker running? -----------------------------------------
& docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker does not appear to be running. Start Docker Desktop and retry."
}
Write-Ok "Docker is running."

# --- Pre-flight: resource sanity (warn only) ------------------------------
try {
    $dockerResources = (docker info --format '{{.NCPU}} {{.MemTotal}}') 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Unable to read Docker resource allocation." }
    $parts = "$dockerResources" -split '\s+'
    if ($parts.Count -eq 2) {
        $cpus = [int]$parts[0]
        $memory = [int64]$parts[1]
        if ($cpus -lt 4) { Write-Warn "Docker Desktop is configured for fewer than 4 CPUs; Falco and all scenarios may be slow or remain Pending." }
        if ($memory -lt 8GB) {
            Write-Warn "Docker Desktop is configured for less than 8 GB RAM; Falco and all scenarios may be slow or remain Pending."
            Write-Warn "Consider KIND_NODES=single in .env or raise Docker Desktop memory (Settings > Resources > Advanced)."
        }
    }
} catch {
    Write-Warn "Could not determine Docker Desktop CPU/memory allocation: $($_.Exception.Message)"
}

$systemDrive = Get-PSDrive -Name $env:SystemDrive.TrimEnd(':') -ErrorAction SilentlyContinue
if ($systemDrive -and $systemDrive.Free -lt 5GB) {
    Write-Warn "Less than 5 GB free on $($env:SystemDrive); kind images and nodes may exhaust disk space."
}

# --- Idempotency: already exists? ----------------------------------------
$existing = (kind get clusters 2>$null)
if ($existing -and ($existing -split "`n" | ForEach-Object { $_.Trim() }) -contains $clusterName) {
    Write-Ok "kind cluster '$clusterName' already exists. Skipping create."
} else {
    if ($nodeMode -eq 'single') {
        # Single-node: write a temp config with just a control-plane + audit mount.
        $tmp = Join-Path $env:TEMP "kind-single-$clusterName.yaml"
        @"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $clusterName
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            audit-log-path: /var/log/kubernetes/kube-apiserver-audit.log
            audit-log-maxage: "7"
            audit-log-maxbackup: "3"
            audit-policy-file: /etc/kubernetes/audit-policy.yaml
          extraVolumes:
            - name: audit-policy
              hostPath: /etc/kubernetes/audit-policy.yaml
              mountPath: /etc/kubernetes/audit-policy.yaml
              readOnly: true
              pathType: File
            - name: audit-log
              hostPath: /var/log/kubernetes
              mountPath: /var/log/kubernetes
              readOnly: false
              pathType: DirectoryOrCreate
    extraMounts:
      - hostPath: ./tooling/audit/audit-policy.yaml
        containerPath: /etc/kubernetes/audit-policy.yaml
        readOnly: true
"@ | Set-Content -Path $tmp -Encoding utf8
        $configPath = $tmp
    } else {
        $configPath = Join-Path $root 'cluster/kind/kind-config.yaml'
    }

    # kind resolves extraMounts hostPath relative to CWD -> run from repo root.
    Push-Location $root
    try {
        Write-Info "Creating cluster from $configPath ..."
        & kind create cluster --name $clusterName --config $configPath --wait 120s
        if ($LASTEXITCODE -ne 0) { throw "kind create cluster failed (exit $LASTEXITCODE)." }
    } finally {
        Pop-Location
    }
    Write-Ok "kind cluster '$clusterName' created."
}

# Point kubectl at it and confirm readiness.
& kubectl cluster-info --context "kind-$clusterName" *> $null
Invoke-Kubectl config use-context "kind-$clusterName"
Write-Info "Nodes:"
Invoke-Kubectl get nodes -o wide
Write-Ok "kind cluster ready."

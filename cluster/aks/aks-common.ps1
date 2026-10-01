# Shared helpers for the AKS backend. Dot-source after scripts/lib/common.ps1.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AksOwnerTag = 'aksLabOwner'
$script:AksOwnerValue = 'k8s-sec-lab'
$script:AksRunTag = 'aksLabRunId'
$script:AksStateDirectory = Join-Path (Get-RepoRoot) '.lab-state'
$script:AksStatePath = Join-Path $script:AksStateDirectory 'aks-state.json'
$script:AksNodeHourlyUsd = @{
    # Azure Retail Prices API East US Linux pay-as-you-go rate, checked 2026-09-30.
    'Standard_B4ms' = 0.166
}

function Import-AksLabConfig {
    $envPath = Join-Path (Get-RepoRoot) '.env'
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        throw "AKS requires a real .env file. Copy .env.example to .env and set AKS_SUBSCRIPTION_ID."
    }

    $config = Import-DotEnv -Path $envPath
    if (-not $config.ContainsKey('AKS_SUBSCRIPTION_ID') -or
        [string]::IsNullOrWhiteSpace([string]$config['AKS_SUBSCRIPTION_ID'])) {
        throw "AKS_SUBSCRIPTION_ID must be set in .env. Refusing to use a process-environment fallback."
    }

    $subscriptionId = ([string]$config['AKS_SUBSCRIPTION_ID']).Trim()
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParse($subscriptionId, [ref]$parsedId)) {
        throw "AKS_SUBSCRIPTION_ID in .env must be a valid subscription GUID."
    }
    return $config
}

function Assert-AksActiveSubscription {
    param([Parameter(Mandatory = $true)][string]$SubscriptionId)

    Assert-Command az 'Install Azure CLI: winget install Microsoft.AzureCLI'
    $output = & az account show --query id --output tsv 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Unable to read the active Azure subscription (az account show failed, exit $exitCode). Run az login, then retry."
    }

    $activeId = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($activeId)) {
        throw 'Azure CLI returned no active subscription id. Run az login, then retry.'
    }
    if ($activeId -ne $SubscriptionId) {
        throw "WRONG SUBSCRIPTION: active Azure subscription is '$activeId' but .env AKS_SUBSCRIPTION_ID is '$SubscriptionId'. Refusing all AKS operations; explicitly select the expected subscription and retry."
    }
    Write-Ok "Active subscription matches .env ($SubscriptionId)."
}

function Assert-AksLabShape {
    param(
        [Parameter(Mandatory = $true)][string]$NodeSize,
        [Parameter(Mandatory = $true)][int]$NodeCount
    )

    if ($NodeSize -ne 'Standard_B4ms' -or $NodeCount -ne 1) {
        throw "This backend is intentionally fixed to one Standard_B4ms node. Standard_B2s cannot fit the required 30-GiB ephemeral OS disk. Set AKS_NODE_SIZE=Standard_B4ms and AKS_NODE_COUNT=1 in .env."
    }
}

function Assert-AksSingleIpCidr {
    param([Parameter(Mandatory = $true)][string]$Cidr)

    if ([string]::IsNullOrWhiteSpace($Cidr)) {
        throw 'ALLOWED_IP is required in .env and must be one IPv4 address in CIDR form, for example 203.0.113.7/32.'
    }
    $value = $Cidr.Trim()
    if ($value -eq '0.0.0.0/0') {
        throw 'ALLOWED_IP must never be 0.0.0.0/0; use a single public IPv4 address with /32.'
    }
    if ($value -notmatch '^(?<address>(?:[0-9]{1,3}\.){3}[0-9]{1,3})/(?<prefix>[0-9]{1,2})$') {
        throw "ALLOWED_IP '$Cidr' is invalid. Use exactly one IPv4 address with a /32 prefix (for example 203.0.113.7/32)."
    }

    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($Matches.address, [ref]$address) -or
        $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        [int]$Matches.prefix -ne 32) {
        throw "ALLOWED_IP '$Cidr' is not a valid single IPv4 address CIDR. Use a valid address ending in /32."
    }
    return "$($address.IPAddressToString)/32"
}

function Assert-AksEphemeralOsDiskSupport {
    param(
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $true)][string]$NodeSize
    )

    Write-Info "Checking read-only VM SKU capabilities for a 30-GiB ephemeral OS disk ($NodeSize in $Location)."
    $output = & az vm list-skus --location $Location --resource-type virtualMachines --size $NodeSize --all --output json 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Could not preflight VM SKU capabilities (az vm list-skus failed, exit $exitCode). No resource group or cluster was created."
    }

    try {
        $skus = (($output | Out-String) | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "Azure CLI returned invalid VM SKU capability data. Refusing to fall back to a managed OS disk. Details: $($_.Exception.Message)"
    }
    $matchingSkus = @($skus | Where-Object { $_.name -eq $NodeSize })
    if ($matchingSkus.Count -eq 0) {
        throw "Azure did not return SKU '$NodeSize' in '$Location'. Cannot verify ephemeral OS disk support; no resources were created."
    }

    $minimumMiB = 30 * 1024
    foreach ($sku in $matchingSkus) {
        $restricted = @($sku.restrictions | Where-Object { $_.type -eq 'Location' -and $_.values -contains $Location })
        if ($restricted.Count -gt 0) { continue }

        $capabilities = @{}
        foreach ($capability in $sku.capabilities) {
            $capabilities[[string]$capability.name] = [string]$capability.value
        }
        if ($capabilities['EphemeralOSDiskSupported'] -ne 'True') { continue }

        $availableMiB = 0.0
        foreach ($key in @('MaxResourceVolumeMB', 'NvmeDiskSizeInMiB')) {
            $number = 0.0
            if ([double]::TryParse($capabilities[$key], [ref]$number) -and $number -gt $availableMiB) {
                $availableMiB = $number
            }
        }
        $cachedBytes = 0.0
        if ([double]::TryParse($capabilities['CachedDiskBytes'], [ref]$cachedBytes)) {
            $availableMiB = [Math]::Max($availableMiB, ($cachedBytes / 1048576.0))
        }
        $cachedGiB = 0.0
        if ([double]::TryParse($capabilities['CachedDiskSizeGB'], [ref]$cachedGiB)) {
            $availableMiB = [Math]::Max($availableMiB, ($cachedGiB * 1024.0))
        }

        if ($availableMiB -ge $minimumMiB) { return }
    }

    throw "SKU '$NodeSize' in '$Location' does not advertise both ephemeral OS disk support and at least 30 GiB of local cache/temp/NVMe capacity required by the AKS Ubuntu image. This backend refuses to use a managed OS disk. No resource group or cluster was created; choose a compatible SKU and revise the backend configuration deliberately."
}

function Test-AksResourceGroupExists {
    param([Parameter(Mandatory = $true)][string]$Name)

    $output = & az group exists --name $Name --output tsv 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Could not check resource group '$Name' (az group exists failed, exit $exitCode)."
    }
    $value = ($output | Out-String).Trim()
    if ($value -notin @('true', 'false')) {
        throw "Unexpected response checking resource group '$Name': '$value'."
    }
    return ($value -eq 'true')
}

function Wait-AksResourceGroupAbsent {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutMinutes = 30
    )

    $deadline = [DateTimeOffset]::UtcNow.AddMinutes($TimeoutMinutes)
    while (Test-AksResourceGroupExists -Name $Name) {
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            throw "Azure still reports resource group '$Name' after $TimeoutMinutes minutes. It was not deleted by this script; verify ownership and clean it up manually if appropriate."
        }
        Start-Sleep -Seconds 15
    }
}

function Get-AksResourceGroup {
    param([Parameter(Mandatory = $true)][string]$Name)

    $output = & az group show --name $Name --output json 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Could not read resource group '$Name' (az group show failed, exit $exitCode)."
    }
    try {
        return (($output | Out-String) | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "Azure CLI returned invalid resource-group data for '$Name': $($_.Exception.Message)"
    }
}

function Assert-AksOwnedResourceGroup {
    param(
        [Parameter(Mandatory = $true)]$ResourceGroup,
        [string]$ExpectedRunId
    )

    $tags = $ResourceGroup.tags
    if (-not $tags) {
        throw "Resource group '$($ResourceGroup.name)' has no AKS lab ownership tags. It was left untouched."
    }
    $ownerProperty = $tags.PSObject.Properties[$script:AksOwnerTag]
    $runProperty = $tags.PSObject.Properties[$script:AksRunTag]
    if (-not $ownerProperty -or $ownerProperty.Value -ne $script:AksOwnerValue -or
        -not $runProperty -or [string]::IsNullOrWhiteSpace([string]$runProperty.Value)) {
        throw "Resource group '$($ResourceGroup.name)' is not marked as owned by this AKS lab. It was left untouched."
    }
    if ($ExpectedRunId -and [string]$runProperty.Value -ne $ExpectedRunId) {
        throw "Resource group '$($ResourceGroup.name)' belongs to a different AKS lab run. It was left untouched."
    }
    return [string]$runProperty.Value
}

function Get-AksState {
    if (-not (Test-Path -LiteralPath $script:AksStatePath -PathType Leaf)) { return $null }
    try {
        return (Get-Content -LiteralPath $script:AksStatePath -Raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "AKS state marker '$($script:AksStatePath)' is corrupt. Preserve it for inspection; fix or remove it manually only after verifying Azure resource ownership. Details: $($_.Exception.Message)"
    }
}

function Save-AksState {
    param([Parameter(Mandatory = $true)]$State)
    if (-not (Test-Path -LiteralPath $script:AksStateDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $script:AksStateDirectory -Force | Out-Null
    }
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:AksStatePath -Encoding UTF8
}

function Remove-AksState {
    if (Test-Path -LiteralPath $script:AksStatePath -PathType Leaf) {
        Remove-Item -LiteralPath $script:AksStatePath -Force
    }
}

function Get-AksHourlyRate {
    param([Parameter(Mandatory = $true)][string]$NodeSize)
    if (-not $script:AksNodeHourlyUsd.ContainsKey($NodeSize)) {
        throw "No estimate is defined for node size '$NodeSize'."
    }
    return [double]$script:AksNodeHourlyUsd[$NodeSize]
}

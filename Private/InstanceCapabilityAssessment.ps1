<#
.SYNOPSIS
    Bewertet ausschliesslich deklarierte Instanzfaehigkeiten ohne Runtimezugriff.
#>
function New-LabInstanceCapabilityAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)]$ProviderCapability,
        [Parameter(Mandatory)]$Network,
        [AllowEmptyCollection()][object[]]$Drives = @(),
        [Parameter(Mandatory)]$Software
    )

    $providerName = ([string]$Instance.provider).ToLowerInvariant()
    $provider = if ($providerName -in @('docker','podman','hyperv')) { $providerName } else { 'UNKNOWN' }
    $providerStatus = if ($provider -ne 'UNKNOWN' -and [string]$ProviderCapability.Provider -eq $provider) { 'DECLARED_SUPPORTED' } else { 'DECLARED_UNSUPPORTED' }
    $os = if ($Instance.os) { ([string]$Instance.os).ToLowerInvariant() } elseif ($provider -eq 'hyperv') { 'windows' } else { 'linux' }
    if ($os -notin @('linux','windows')) { $os = 'UNKNOWN' }
    $osStatus = if (($provider -in @('docker','podman') -and $os -eq 'linux') -or ($provider -eq 'hyperv' -and $os -eq 'windows')) { 'DECLARED_SUPPORTED' } else { 'DECLARED_UNSUPPORTED' }

    $requested = [string]$Instance.version
    $sqlStatus = 'NOT_REQUESTED'
    $catalogId = $null
    if ($requested) {
        # Keine freien Bezeichner oder Rohfehler in dieser Projektion.
        if ($requested.Length -le 64 -and $requested -match '^\d{4}(?:R2)?(?:-latest|-CU\d+(?:-ubuntu-\d{2}\.\d{2})?)?$') {
            $definition = Get-SqlServerVersion -VersionId $requested
            $decision = Test-SqlServerVersionSupported -VersionId $requested
            $sqlStatus = [string]$decision.Status
            if ($definition) { $catalogId = [string]$definition.id }
        }
        else { $requested = $null; $sqlStatus = 'UNKNOWN' }
    }
    else { $requested = $null }

    $networkReason = if ($Network.ReasonCode) { [string]$Network.ReasonCode } else { $null }
    $bindings = @($Drives | ForEach-Object { [string]$_.Binding } | Sort-Object -Unique)
    $driveCapabilities = @($Drives | ForEach-Object { [string]$_.RequiredCapability } | Sort-Object -Unique)
    $storageStatus = if ($Drives.Count -eq 0) { 'NOT_REQUESTED' } elseif (@($Drives | Where-Object CapabilityStatus -ne 'DECLARED_SUPPORTED').Count -gt 0) { 'DECLARED_UNSUPPORTED' } else { 'DECLARED_SUPPORTED' }
    $softwareCapabilities = @($Software.Items | ForEach-Object { $_.RequiredCapabilities } | Sort-Object -Unique)
    $softwareReasons = @($Software.Items | Where-Object ReasonCode | ForEach-Object { [string]$_.ReasonCode } | Sort-Object -Unique)
    $result = [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name='SqlServerLab.InstanceCapabilityAssessment'; Version='1.0'; EvidenceBoundary='catalog-and-provider-metadata' }
        Provider = [PSCustomObject]@{ Name=$provider; Status=$providerStatus }
        OperatingSystem = [PSCustomObject]@{ Name=$os; Status=$osStatus }
        SqlVersion = [PSCustomObject]@{ Requested=$requested; CatalogVersionId=$catalogId; Status=$sqlStatus }
        Network = [PSCustomObject]@{ RequiredCapability=[string]$Network.RequiredCapability; Status=[string]$Network.CapabilityStatus; ReasonCode=$networkReason }
        Storage = [PSCustomObject]@{ Bindings=$bindings; RequiredCapabilities=$driveCapabilities; Status=$storageStatus }
        Software = [PSCustomObject]@{ RequiredCapabilities=$softwareCapabilities; ReasonCodes=$softwareReasons; Status=[string]$Software.CapabilityStatus }
        Status = 'DECLARED_SUPPORTED'
        BlockerCodes = @()
    }
    $result.BlockerCodes = @(Get-LabInstanceCapabilityBlockerCode -Assessment $result)
    if ($result.BlockerCodes.Count -gt 0) { $result.Status = 'DECLARED_UNSUPPORTED' }
    if (-not (Test-LabInstanceCapabilityAssessment -Assessment $result)) { throw 'INSTANCE_CAPABILITY_ASSESSMENT_INVALID' }
    return $result
}

function Get-LabInstanceCapabilityBlockerCode {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Assessment)
    $codes = [Collections.Generic.List[string]]::new()
    foreach ($dimension in @('Provider','OperatingSystem','Network','Storage','Software')) {
        if ([string]$Assessment.$dimension.Status -eq 'DECLARED_UNSUPPORTED') {
            $code = switch ($dimension) {
                'Provider' { 'PROVIDER_UNDECLARED' }
                'OperatingSystem' { 'OS_PROVIDER_UNSUPPORTED' }
                'Network' { 'NETWORK_UNSUPPORTED' }
                'Storage' { 'STORAGE_UNSUPPORTED' }
                'Software' { 'SOFTWARE_UNSUPPORTED' }
            }
            $codes.Add($code)
        }
    }
    if ([string]$Assessment.SqlVersion.Status -notin @('SUPPORTED','PREVIEW','NOT_REQUESTED')) { $codes.Add('SQL_VERSION_POLICY_UNSUPPORTED') }
    return @($codes | Sort-Object -Unique)
}

function Test-LabInstanceCapabilityAssessment {
    [CmdletBinding()]
    param([AllowNull()]$Assessment)
    if ($null -eq $Assessment) { return $false }
    try {
        $json = ConvertTo-Json -InputObject $Assessment -Depth 12 -Compress -WarningAction Stop
        $schema = Join-Path $script:SchemasPath 'instance-capability-assessment.schema.json'
        if (-not (Test-Json -Json $json -SchemaFile $schema -ErrorAction Stop)) { return $false }
        foreach ($items in @(
            ,@($Assessment.Storage.Bindings), ,@($Assessment.Storage.RequiredCapabilities),
            ,@($Assessment.Software.RequiredCapabilities), ,@($Assessment.Software.ReasonCodes), ,@($Assessment.BlockerCodes)
        )) {
            if (($items -join ',') -cne (@($items | Sort-Object -Unique) -join ',')) { return $false }
        }
        $expected = @(Get-LabInstanceCapabilityBlockerCode -Assessment $Assessment)
        if (($expected -join ',') -cne (@($Assessment.BlockerCodes) -join ',')) { return $false }
        $status = if ($expected.Count) { 'DECLARED_UNSUPPORTED' } else { 'DECLARED_SUPPORTED' }
        if ([string]$Assessment.Status -cne $status) { return $false }
        if ($Assessment.Provider.Name -eq 'UNKNOWN' -and $Assessment.Provider.Status -ne 'DECLARED_UNSUPPORTED') { return $false }
        $osSupported = ($Assessment.Provider.Name -in @('docker','podman') -and $Assessment.OperatingSystem.Name -eq 'linux') -or
            ($Assessment.Provider.Name -eq 'hyperv' -and $Assessment.OperatingSystem.Name -eq 'windows')
        if (($Assessment.OperatingSystem.Status -eq 'DECLARED_SUPPORTED') -ne $osSupported) { return $false }
        if (($Assessment.SqlVersion.Status -in @('UNKNOWN','NOT_REQUESTED')) -and $null -ne $Assessment.SqlVersion.CatalogVersionId) { return $false }
        if ($Assessment.SqlVersion.Status -notin @('UNKNOWN','NOT_REQUESTED') -and ($null -eq $Assessment.SqlVersion.CatalogVersionId -or $null -eq $Assessment.SqlVersion.Requested)) { return $false }
        if ($Assessment.SqlVersion.Status -eq 'NOT_REQUESTED' -and $null -ne $Assessment.SqlVersion.Requested) { return $false }
        if ($Assessment.Network.Status -eq 'DECLARED_SUPPORTED' -and ($null -ne $Assessment.Network.ReasonCode -or $Assessment.Network.RequiredCapability -eq 'unknown-network-intent')) { return $false }
        if ($Assessment.Storage.Status -eq 'NOT_REQUESTED' -and (@($Assessment.Storage.Bindings).Count -or @($Assessment.Storage.RequiredCapabilities).Count)) { return $false }
        if ($Assessment.Storage.Status -ne 'NOT_REQUESTED' -and (-not @($Assessment.Storage.Bindings).Count -or -not @($Assessment.Storage.RequiredCapabilities).Count)) { return $false }
        if ($Assessment.Software.Status -eq 'NOT_REQUESTED' -and (@($Assessment.Software.RequiredCapabilities).Count -or @($Assessment.Software.ReasonCodes).Count)) { return $false }
        if ($Assessment.Software.Status -eq 'DECLARED_SUPPORTED' -and @($Assessment.Software.ReasonCodes).Count) { return $false }
        return $true
    }
    catch { return $false }
}

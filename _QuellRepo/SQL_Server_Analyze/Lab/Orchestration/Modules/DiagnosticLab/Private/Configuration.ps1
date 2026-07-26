function Get-LabDefaultStateRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return [System.IO.Path]::GetFullPath(
        (Join-Path $script:DiagnosticLabRoot '.state')
    )
}

function Resolve-LabConfiguration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string] $ConfigPath,

        [Parameter()]
        [ValidateSet('AUTO', 'WINDOWS_SINGLE_HOST', 'LINUX_NATIVE', 'DISTRIBUTED')]
        [string] $ExecutionMode
    )

    if (-not $PSBoundParameters.ContainsKey('ConfigPath')) {
        $localPath = Join-Path $script:DiagnosticLabRoot 'Config/lab.config.psd1'
        $examplePath = Join-Path $script:DiagnosticLabRoot 'Config/lab.config.example.psd1'
        $ConfigPath = if (Test-Path -LiteralPath $localPath -PathType Leaf) {
            $localPath
        }
        else {
            $examplePath
        }
    }

    $resolvedPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
    $configuration = Import-PowerShellDataFile -LiteralPath $resolvedPath

    if ($configuration.SchemaVersion -ne '1.0') {
        throw 'LAB-001 configuration SchemaVersion must be 1.0.'
    }
    if ($configuration.DataClassification -notin @(
            'SYNTHETIC_EXAMPLE',
            'LOCAL_RUNTIME_CONFIG'
        )) {
        throw 'LAB-001 configuration DataClassification is invalid.'
    }

    $validExecutionModes = @(
        'WINDOWS_SINGLE_HOST'
        'LINUX_NATIVE'
        'DISTRIBUTED'
    )
    $allowedExecutionModes = @($configuration.AllowedExecutionModes)
    if ($allowedExecutionModes.Count -eq 0) {
        throw 'AllowedExecutionModes must contain at least one execution mode.'
    }
    if (@($allowedExecutionModes | Where-Object { $_ -notin $validExecutionModes }).Count -gt 0) {
        throw 'AllowedExecutionModes contains an unsupported value.'
    }
    if (@($allowedExecutionModes | Select-Object -Unique).Count -ne $allowedExecutionModes.Count) {
        throw 'AllowedExecutionModes must not contain duplicates.'
    }

    $requestedMode = if ($PSBoundParameters.ContainsKey('ExecutionMode')) {
        $ExecutionMode
    }
    else {
        [string] $configuration.ExecutionMode
    }
    if ($requestedMode -notin (@('AUTO') + $validExecutionModes)) {
        throw 'ExecutionMode contains an unsupported value.'
    }
    if ($configuration.ContainerEngine -notin @('DOCKER', 'PODMAN')) {
        throw 'ContainerEngine contains an unsupported value.'
    }
    if ($configuration.ResourceProfile -notin @('Compact', 'Standard', 'Stress')) {
        throw 'ResourceProfile contains an unsupported value.'
    }
    $sqlVersionPriority = @($configuration.SqlVersionPriority)
    if (
        $sqlVersionPriority.Count -eq 0 -or
        @($sqlVersionPriority | Where-Object { $_ -notin @(2019, 2022, 2025) }).Count -gt 0 -or
        @($sqlVersionPriority | Select-Object -Unique).Count -ne $sqlVersionPriority.Count
    ) {
        throw 'SqlVersionPriority must contain unique supported SQL Server versions.'
    }
    $containerImageLogicalIds = @{}
    if ($configuration.ContainsKey('ContainerImageLogicalIds')) {
        foreach ($version in @(2019, 2022, 2025)) {
            $versionKey = [string] $version
            if ($configuration.ContainerImageLogicalIds.ContainsKey($versionKey)) {
                $logicalImageId = [string] (
                    $configuration.ContainerImageLogicalIds[$versionKey]
                )
                if ($logicalImageId -notmatch '^[A-Z0-9_]+$') {
                    throw 'ContainerImageLogicalIds contains an invalid logical image identifier.'
                }
                $containerImageLogicalIds[$versionKey] = $logicalImageId
            }
        }
    }
    elseif ($configuration.ContainsKey('ContainerImageLogicalId')) {
        $legacyLogicalImageId = [string] $configuration.ContainerImageLogicalId
        if ($legacyLogicalImageId -notmatch '^[A-Z0-9_]+$') {
            throw 'ContainerImageLogicalId is invalid.'
        }
        $containerImageLogicalIds['2025'] = $legacyLogicalImageId
    }
    foreach ($version in $sqlVersionPriority) {
        if (-not $containerImageLogicalIds.ContainsKey([string] $version)) {
            throw "ContainerImageLogicalIds is missing SQL Server $version."
        }
    }
    if (-not $configuration.ContainsKey('AcceptSqlServerEula')) {
        throw 'AcceptSqlServerEula must be explicitly configured.'
    }

    $storageTargets = @()
    if ($configuration.ContainsKey('StorageTargets')) {
        foreach ($target in @($configuration.StorageTargets)) {
            $logicalTargetId = [string] $target.LogicalTargetId
            if ($logicalTargetId -notmatch '^[A-Z0-9_]+$') {
                throw 'Every StorageTarget requires a generic LogicalTargetId.'
            }
            $roles = @($target.Roles)
            if ($roles.Count -eq 0 -or @(
                    $roles | Where-Object {
                        $_ -notin @(
                            'IMAGE_CACHE',
                            'ACTIVE_VM',
                            'EPHEMERAL_DATA',
                            'FAULT_TARGET'
                        )
                    }
                ).Count -gt 0) {
                throw "StorageTarget $logicalTargetId contains an invalid role."
            }

            $storageTargets += [pscustomobject] @{
                LogicalTargetId = $logicalTargetId
                Path = [string] $target.Path
                Roles = @($roles | Select-Object -Unique)
                IsSystemTarget = [bool] $target.IsSystemTarget
                IsApprovedLabTarget = [bool] $target.IsApprovedLabTarget
                MaximumSizeGiB = if ($target.ContainsKey('MaximumSizeGiB')) {
                    [int] $target.MaximumSizeGiB
                }
                else {
                    $null
                }
            }
        }
    }
    $targetIds = @($storageTargets | ForEach-Object { $_.LogicalTargetId })
    if (@($targetIds | Select-Object -Unique).Count -ne $targetIds.Count) {
        throw 'StorageTargets must use unique LogicalTargetId values.'
    }
    foreach ($requiredRole in @(
            'IMAGE_CACHE',
            'ACTIVE_VM',
            'EPHEMERAL_DATA',
            'FAULT_TARGET'
        )) {
        if (-not $configuration.StorageRoleBindings.ContainsKey($requiredRole)) {
            throw "StorageRoleBindings is missing $requiredRole."
        }
        if (
            [string] $configuration.StorageRoleBindings[$requiredRole] -notin
            $targetIds
        ) {
            throw "StorageRoleBindings references an unknown target for $requiredRole."
        }
    }
    $faultTargetId = [string] $configuration.StorageRoleBindings.FAULT_TARGET
    $faultTarget = $storageTargets |
        Where-Object { $_.LogicalTargetId -eq $faultTargetId } |
        Select-Object -First 1
    if (
        $null -eq $faultTarget -or
        $faultTarget.IsSystemTarget -or
        'IMAGE_CACHE' -in @($faultTarget.Roles) -or
        'FAULT_TARGET' -notin @($faultTarget.Roles) -or
        $null -eq $faultTarget.MaximumSizeGiB -or
        $faultTarget.MaximumSizeGiB -lt 1 -or
        $faultTarget.MaximumSizeGiB -gt 256
    ) {
        throw 'FAULT_TARGET must resolve to a bounded non-system target.'
    }

    $remoteHosts = @()
    if ($configuration.ContainsKey('RemoteHosts')) {
        foreach ($remoteHost in @($configuration.RemoteHosts)) {
            $logicalHostId = [string] $remoteHost.LogicalHostId
            if ($logicalHostId -notmatch '^[A-Z0-9_]+$') {
                throw 'Every RemoteHost requires a generic LogicalHostId.'
            }
            $remoteHosts += [pscustomobject] @{
                LogicalHostId = $logicalHostId
                Approved = [bool] $remoteHost.Approved
                Transport = [string] $remoteHost.Transport
                Endpoint = [string] $remoteHost.Endpoint
                Port = if (
                    $remoteHost.ContainsKey('Port') -and
                    $null -ne $remoteHost.Port
                ) {
                    [int] $remoteHost.Port
                }
                else {
                    $null
                }
                UserName = if ($remoteHost.ContainsKey('UserName')) {
                    [string] $remoteHost.UserName
                }
                else {
                    ''
                }
                CredentialSecretName = if (
                    $remoteHost.ContainsKey('CredentialSecretName')
                ) {
                    [string] $remoteHost.CredentialSecretName
                }
                else {
                    ''
                }
                KeyFilePath = if ($remoteHost.ContainsKey('KeyFilePath')) {
                    [string] $remoteHost.KeyFilePath
                }
                else {
                    ''
                }
                StorageTargets = if ($remoteHost.ContainsKey('StorageTargets')) {
                    @($remoteHost.StorageTargets)
                }
                else {
                    @()
                }
            }
        }
    }
    $remoteHostIds = @($remoteHosts | ForEach-Object { $_.LogicalHostId })
    if (@($remoteHostIds | Select-Object -Unique).Count -ne $remoteHostIds.Count) {
        throw 'RemoteHosts must use unique LogicalHostId values.'
    }

    $secretPolicy = if ($configuration.ContainsKey('SecretPolicy')) {
        [pscustomobject] @{
            Provider = [string] $configuration.SecretPolicy.Provider
            RequiredSecretNames = @($configuration.SecretPolicy.RequiredSecretNames)
            AllowInteractive = [bool] $configuration.SecretPolicy.AllowInteractive
        }
    }
    else {
        [pscustomobject] @{
            Provider = 'NONE'
            RequiredSecretNames = @()
            AllowInteractive = $false
        }
    }
    if ($secretPolicy.Provider -notin @(
            'NONE',
            'ENVIRONMENT',
            'SECRET_MANAGEMENT',
            'INTERACTIVE'
        )) {
        throw 'SecretPolicy.Provider contains an unsupported value.'
    }
    foreach ($secretName in $secretPolicy.RequiredSecretNames) {
        if ([string] $secretName -notmatch '^[A-Z][A-Z0-9_]{0,63}$') {
            throw 'SecretPolicy contains an invalid logical secret name.'
        }
    }

    $contentBytes = [System.IO.File]::ReadAllBytes($resolvedPath)
    $configurationHash = [System.Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($contentBytes)
    )
    $configDirectory = Split-Path -Parent $resolvedPath
    $imageLockPath = if (
        $configuration.ContainsKey('ImageLockPath') -and
        -not [string]::IsNullOrWhiteSpace([string] $configuration.ImageLockPath)
    ) {
        if ([System.IO.Path]::IsPathRooted([string] $configuration.ImageLockPath)) {
            [System.IO.Path]::GetFullPath([string] $configuration.ImageLockPath)
        }
        else {
            [System.IO.Path]::GetFullPath(
                (Join-Path $configDirectory ([string] $configuration.ImageLockPath))
            )
        }
    }
    else {
        Join-Path $script:DiagnosticLabRoot 'Config/image-lock.example.json'
    }
    $networkPolicy = [pscustomobject] @{
        PrivateRangeReference = [string] (
            $configuration.NetworkPolicy.PrivateRangeReference
        )
        PrivateRangeCidr = if (
            $configuration.NetworkPolicy.ContainsKey('PrivateRangeCidr')
        ) {
            [string] $configuration.NetworkPolicy.PrivateRangeCidr
        }
        else {
            ''
        }
        RejectRouteCollision = [bool] (
            $configuration.NetworkPolicy.RejectRouteCollision
        )
        AllowExternalLabDataNetwork = [bool] (
            $configuration.NetworkPolicy.AllowExternalLabDataNetwork
        )
    }

    return [pscustomobject] @{
        SchemaVersion = '1.0'
        DataClassification = [string] $configuration.DataClassification
        ConfigSource = if (
            [string] $configuration.DataClassification -eq 'SYNTHETIC_EXAMPLE'
        ) {
            'EXAMPLE'
        }
        else {
            'LOCAL_CONFIG'
        }
        ConfigurationHash = $configurationHash
        ExecutionMode = $requestedMode
        AllowedExecutionModes = $allowedExecutionModes
        SqlVersionPriority = $sqlVersionPriority
        ContainerEngine = [string] $configuration.ContainerEngine
        ContainerImageLogicalIds = $containerImageLogicalIds
        AcceptSqlServerEula = [bool] $configuration.AcceptSqlServerEula
        ResourceProfile = [string] $configuration.ResourceProfile
        StorageTargets = $storageTargets
        StorageRoleBindings = $configuration.StorageRoleBindings
        ImageLockPath = $imageLockPath
        NetworkPolicy = $networkPolicy
        Retention = $configuration.Retention
        Timeouts = $configuration.Timeouts
        RemoteHosts = $remoteHosts
        SecretPolicy = $secretPolicy
    }
}

function Test-LabImageLock {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Configuration,

        [Parameter()]
        [AllowNull()]
        [string] $ResolvedExecutionMode
    )

    if (-not (Test-Path -LiteralPath $Configuration.ImageLockPath -PathType Leaf)) {
        return [pscustomobject] @{
            CheckStatus = 'NOT_CONFIGURED'
            ReasonCodes = @('IMAGE_LOCK_NOT_FOUND')
            Items = @()
        }
    }
    try {
        $lock = Get-Content `
            -LiteralPath $Configuration.ImageLockPath `
            -Raw `
            -Encoding utf8 |
            ConvertFrom-Json -Depth 100
    }
    catch {
        return [pscustomobject] @{
            CheckStatus = 'INVALID'
            ReasonCodes = @('IMAGE_LOCK_INVALID')
            Items = @()
        }
    }

    $checkMedia = $ResolvedExecutionMode -in @(
        'WINDOWS_SINGLE_HOST',
        'DISTRIBUTED'
    )
    $items = [Collections.Generic.List[object]]::new()
    $reasonCodes = [Collections.Generic.List[string]]::new()
    $images = if ($null -ne $lock.PSObject.Properties['Images']) {
        @($lock.Images)
    }
    else {
        @()
    }
    foreach ($image in $images) {
        $statusProperty = $image.PSObject.Properties['Status']
        $digestProperty = $image.PSObject.Properties['Digest']
        $logicalIdProperty = $image.PSObject.Properties['LogicalImageId']
        $imageStatus = if ($null -ne $statusProperty) {
            $statusProperty.Value
        }
        else {
            ''
        }
        $imageDigest = if ($null -ne $digestProperty) {
            [string] $digestProperty.Value
        }
        else {
            ''
        }
        $logicalImageId = if ($null -ne $logicalIdProperty) {
            [string] $logicalIdProperty.Value
        }
        else {
            ''
        }
        $isLocked = (
            $imageStatus -eq 'LOCKED' -and
            $imageDigest -match '^(sha256:)?[A-Fa-f0-9]{64}$' -and
            $logicalImageId -match '^[A-Z0-9_]+$'
        )
        if (-not $isLocked) {
            $reasonCodes.Add('IMAGE_LOCK_UNRESOLVED')
        }
        $items.Add([pscustomobject] @{
                LogicalId = $logicalImageId
                ItemType = 'IMAGE'
                Status = if ($isLocked) { 'AVAILABLE' } else { 'UNRESOLVED' }
            })
    }
    if ($checkMedia) {
        $mediaItems = if ($null -ne $lock.PSObject.Properties['Media']) {
            @($lock.Media)
        }
        else {
            @()
        }
        foreach ($media in $mediaItems) {
            $statusProperty = $media.PSObject.Properties['Status']
            $checksumProperty = $media.PSObject.Properties['Checksum']
            $logicalIdProperty = $media.PSObject.Properties['LogicalMediaId']
            $mediaStatus = if ($null -ne $statusProperty) {
                $statusProperty.Value
            }
            else {
                ''
            }
            $mediaChecksum = if ($null -ne $checksumProperty) {
                [string] $checksumProperty.Value
            }
            else {
                ''
            }
            $logicalMediaId = if ($null -ne $logicalIdProperty) {
                [string] $logicalIdProperty.Value
            }
            else {
                ''
            }
            $isBound = (
                $mediaStatus -eq 'BOUND' -and
                $mediaChecksum -match '^(sha256:)?[A-Fa-f0-9]{64}$' -and
                $logicalMediaId -match '^[A-Z0-9_]+$'
            )
            if (-not $isBound) {
                $reasonCodes.Add('MEDIA_LOCK_UNRESOLVED')
            }
            $items.Add([pscustomobject] @{
                    LogicalId = $logicalMediaId
                    ItemType = 'MEDIA'
                    Status = if ($isBound) { 'AVAILABLE' } else { 'UNRESOLVED' }
                })
        }
    }
    if ($items.Count -eq 0) {
        $reasonCodes.Add('IMAGE_LOCK_EMPTY')
    }

    return [pscustomobject] @{
        CheckStatus = if ($reasonCodes.Count -eq 0) { 'PASS' } else { 'UNRESOLVED' }
        ReasonCodes = @($reasonCodes | Select-Object -Unique)
        Items = @($items)
    }
}

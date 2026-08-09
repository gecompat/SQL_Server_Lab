<#
.SYNOPSIS
    Lokale Registry fuer verifizierte LAB_GENERATED-Datenbank-Baselines.
.DESCRIPTION
    Erzeugt deterministische, secretfreie Baseline-Keys, registriert Backups
    inhaltsadressiert und waehlt exakte oder explizit kompatible Baselines.
    Hash-Abweichungen werden quarantainisiert und niemals still verwendet.
#>

function Get-LabSampleBaselinePaths {
    [CmdletBinding()]
    param([string]$StateRoot, [string]$TestDataRoot)

    $artifactPaths = Initialize-LabArtifactStore -StateRoot $StateRoot -TestDataRoot $TestDataRoot
    $baselineRoot = Join-Path $artifactPaths.TestDataRoot '_baselines'
    return [PSCustomObject]@{
        BaselineRoot   = $baselineRoot
        RegistryPath  = Join-Path $baselineRoot 'registry.json'
        ObjectsRoot   = Join-Path $baselineRoot 'objects'
        QuarantineRoot = Join-Path $baselineRoot 'quarantine'
    }
}

function Initialize-LabSampleBaselineRegistry {
    [CmdletBinding()]
    param([string]$StateRoot, [string]$TestDataRoot)

    $paths = Get-LabSampleBaselinePaths -StateRoot $StateRoot -TestDataRoot $TestDataRoot
    foreach ($directory in @($paths.BaselineRoot, $paths.ObjectsRoot, $paths.QuarantineRoot)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $paths.RegistryPath -PathType Leaf)) {
        Write-LabArtifactJsonAtomic -Path $paths.RegistryPath -InputObject ([PSCustomObject]@{
            formatVersion = '1'
            records = @()
        })
    }
    return $paths
}

function Get-LabSampleBaselineRegistryData {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Paths)

    $registry = Get-Content -LiteralPath $Paths.RegistryPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    if ([string]$registry.formatVersion -ne '1') {
        throw "SAMPLE_BASELINE_REGISTRY_VERSION_UNSUPPORTED: '$($registry.formatVersion)'"
    }
    if ($null -eq $registry.records) {
        $registry | Add-Member -NotePropertyName records -NotePropertyValue @() -Force
    }
    return $registry
}

function Get-LabSampleBaselineSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function New-LabSampleBaselineKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RestoreDefinition,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$SourceSha256,
        [Parameter(Mandatory)][string]$SqlVersion,
        [string]$Edition = 'Developer',
        [string[]]$FeatureRequirements = @(),
        [Parameter(Mandatory)][int]$CompatibilityLevel,
        [System.Collections.IDictionary]$Variables = @{},
        [string]$VerificationContractVersion = '1',
        [string]$BaselineFormatVersion = '1'
    )

    $outputs = @(
        $RestoreDefinition.expectedOutputs |
            ForEach-Object { [PSCustomObject][ordered]@{ name = [string]$_.name; kind = [string]$_.kind } } |
            Sort-Object kind, name
    )
    if ($outputs.Count -eq 0 -or @($outputs | Where-Object { $_.kind -ne 'database' -or -not $_.name }).Count -gt 0) {
        throw 'SAMPLE_BASELINE_KEY_OUTPUTS_INVALID: Erwartete Datenbankoutputs fehlen.'
    }

    $installationVariables = @()
    foreach ($name in @($Variables.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
        if ($name -match '(?i)(password|secret|token|credential|private.?key)') {
            throw "SAMPLE_BASELINE_KEY_SECRET_REJECTED: Variable '$name' darf nicht im Baseline-Key gespeichert werden."
        }
        $installationVariables += [PSCustomObject][ordered]@{ name = $name; value = [string]$Variables[$name] }
    }

    $keyData = [PSCustomObject][ordered]@{
        sampleId = [string]$RestoreDefinition.sampleId
        sampleVariant = [string]$RestoreDefinition.sampleVariant
        sourceSha256 = $SourceSha256.ToLowerInvariant()
        artifactType = [string]$RestoreDefinition.artifactType
        handlerContractVersion = [string]$RestoreDefinition.handlerContractVersion
        expectedOutputs = $outputs
        sqlVersion = [string]$SqlVersion
        edition = [string]$Edition
        featureRequirements = @($FeatureRequirements | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        compatibilityLevel = $CompatibilityLevel
        installationVariables = $installationVariables
        verificationContractVersion = [string]$VerificationContractVersion
        baselineFormatVersion = [string]$BaselineFormatVersion
    }
    $canonicalJson = $keyData | ConvertTo-Json -Depth 30 -Compress
    return [PSCustomObject]@{
        KeyId = Get-LabSampleBaselineSha256Text -Text $canonicalJson
        Data = $keyData
        CanonicalJson = $canonicalJson
    }
}

function Register-LabSampleBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Key,
        [Parameter(Mandatory)][string]$BackupPath,
        [string]$StateRoot,
        [string]$TestDataRoot
    )

    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        throw "SAMPLE_BASELINE_BACKUP_NOT_FOUND: $BackupPath"
    }
    $paths = Initialize-LabSampleBaselineRegistry -StateRoot $StateRoot -TestDataRoot $TestDataRoot
    $backupSha256 = (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $objectDirectory = Join-Path $paths.ObjectsRoot $backupSha256
    $objectPath = Join-Path $objectDirectory 'baseline.bak'
    New-Item -Path $objectDirectory -ItemType Directory -Force | Out-Null
    if (-not (Test-Path -LiteralPath $objectPath -PathType Leaf)) {
        Copy-Item -LiteralPath $BackupPath -Destination $objectPath
    }
    elseif ((Get-FileHash -LiteralPath $objectPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $backupSha256) {
        throw "SAMPLE_BASELINE_OBJECT_CONFLICT: $backupSha256"
    }

    $registry = Get-LabSampleBaselineRegistryData -Paths $paths
    $record = [PSCustomObject][ordered]@{
        baselineId = New-LabGuid
        keyId = [string]$Key.KeyId
        origin = 'LAB_GENERATED'
        key = $Key.Data
        backupSha256 = $backupSha256
        objectPath = "objects/$backupSha256/baseline.bak"
        verified = $true
        quarantined = $false
        quarantineReason = $null
        verifiedAt = Get-LabTimestamp
    }
    $registry.records = @($registry.records | Where-Object { [string]$_.keyId -ne [string]$Key.KeyId }) + $record
    Write-LabArtifactJsonAtomic -Path $paths.RegistryPath -InputObject $registry

    return [PSCustomObject]@{
        Record = $record
        Path = $objectPath
    }
}

function Set-LabSampleBaselineQuarantined {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$KeyId,
        [Parameter(Mandatory)][string]$Reason,
        [string]$StateRoot,
        [string]$TestDataRoot
    )

    $paths = Initialize-LabSampleBaselineRegistry -StateRoot $StateRoot -TestDataRoot $TestDataRoot
    $registry = Get-LabSampleBaselineRegistryData -Paths $paths
    $target = @($registry.records | Where-Object { [string]$_.keyId -eq $KeyId } | Select-Object -First 1)
    if ($target.Count -eq 0) { return $false }

    $backupSha256 = [string]$target[0].backupSha256
    $objectDirectory = Join-Path $paths.ObjectsRoot $backupSha256
    if (Test-Path -LiteralPath $objectDirectory -PathType Container) {
        $quarantineDirectory = Join-Path $paths.QuarantineRoot "$([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff'))-$backupSha256"
        Move-Item -LiteralPath $objectDirectory -Destination $quarantineDirectory
        Write-LabArtifactJsonAtomic -Path (Join-Path $quarantineDirectory 'quarantine.json') -InputObject ([PSCustomObject]@{
            reason = $Reason
            quarantinedAt = Get-LabTimestamp
            backupSha256 = $backupSha256
        })
    }

    foreach ($record in @($registry.records | Where-Object { [string]$_.backupSha256 -eq $backupSha256 })) {
        $record.verified = $false
        $record.quarantined = $true
        $record.quarantineReason = $Reason
    }
    Write-LabArtifactJsonAtomic -Path $paths.RegistryPath -InputObject $registry
    return $true
}

function Test-LabSampleBaselineKeyCompatibility {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Candidate, [Parameter(Mandatory)]$Requested)

    foreach ($field in @('sampleId', 'sampleVariant', 'sourceSha256', 'artifactType', 'handlerContractVersion', 'edition', 'verificationContractVersion', 'baselineFormatVersion')) {
        if ([string]$Candidate.$field -ne [string]$Requested.$field) { return $false }
    }
    foreach ($field in @('expectedOutputs', 'featureRequirements', 'installationVariables')) {
        if (($Candidate.$field | ConvertTo-Json -Depth 20 -Compress) -ne ($Requested.$field | ConvertTo-Json -Depth 20 -Compress)) { return $false }
    }

    $candidateYear = [int](([string]$Candidate.sqlVersion -split '-', 2)[0])
    $requestedYear = [int](([string]$Requested.sqlVersion -split '-', 2)[0])
    return $candidateYear -le $requestedYear -and [int]$Candidate.compatibilityLevel -le [int]$Requested.compatibilityLevel
}

function Get-LabSampleBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Key,
        [switch]$AllowCompatible,
        [string]$StateRoot,
        [string]$TestDataRoot
    )

    $paths = Initialize-LabSampleBaselineRegistry -StateRoot $StateRoot -TestDataRoot $TestDataRoot
    $registry = Get-LabSampleBaselineRegistryData -Paths $paths
    $eligible = @($registry.records | Where-Object { $_.verified -eq $true -and $_.quarantined -ne $true })
    $exact = @($eligible | Where-Object { [string]$_.keyId -eq [string]$Key.KeyId })
    $compatible = @()
    if ($AllowCompatible) {
        $compatible = @(
            $eligible |
                Where-Object { [string]$_.keyId -ne [string]$Key.KeyId -and (Test-LabSampleBaselineKeyCompatibility -Candidate $_.key -Requested $Key.Data) } |
                Sort-Object @{ Expression = { [int](([string]$_.key.sqlVersion -split '-', 2)[0]) }; Descending = $true }, keyId
        )
    }

    foreach ($candidate in @($exact + $compatible)) {
        $relativePath = ([string]$candidate.objectPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $objectPath = [System.IO.Path]::GetFullPath((Join-Path $paths.BaselineRoot $relativePath))
        $rootPrefix = [System.IO.Path]::GetFullPath($paths.BaselineRoot + [System.IO.Path]::DirectorySeparatorChar)
        if (-not $objectPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $objectPath -PathType Leaf)) {
            $null = Set-LabSampleBaselineQuarantined -KeyId $candidate.keyId -Reason 'baseline-object-missing-or-outside-root' -StateRoot $StateRoot -TestDataRoot $TestDataRoot
            continue
        }

        $actualSha256 = (Get-FileHash -LiteralPath $objectPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha256 -ne [string]$candidate.backupSha256) {
            $null = Set-LabSampleBaselineQuarantined -KeyId $candidate.keyId -Reason 'baseline-hash-mismatch' -StateRoot $StateRoot -TestDataRoot $TestDataRoot
            continue
        }

        return [PSCustomObject]@{
            MatchType = if ([string]$candidate.keyId -eq [string]$Key.KeyId) { 'exact' } else { 'compatible' }
            KeyId = [string]$candidate.keyId
            Path = $objectPath
            Sha256 = [string]$candidate.backupSha256
            Record = $candidate
        }
    }
    return $null
}

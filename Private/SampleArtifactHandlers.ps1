<#
.SYNOPSIS
    Sample-Artifact-Handler fuer den gemeinsamen Installations-Lifecycle.
.DESCRIPTION
    Implementiert den Backup-Handler aus dem Sample-Zielvertrag: Acquisition
    und Integritaet laufen ueber den Artifact Resolver (Trust Store, Cache,
    Quarantaene, Run Lock), danach folgen Idempotenzpruefung, Restore und
    Output-Verification. Alle Ergebnisse verwenden stabile Statusklassen
    (DATASET_READY, TRUST_REQUIRED, SAMPLE_OUTPUT_CONFLICT,
    SAMPLE_INSTALLATION_FAILED, SAMPLE_VERIFICATION_FAILED).
#>

function Get-LabExecutableSampleVariant {
    <#
    .SYNOPSIS
        Listet automatisch installierbare Sample-Varianten des Katalogs auf.
    .DESCRIPTION
        Liefert nur Varianten, die der implementierte Backup-Handler ausfuehren
        kann: artifactType backup, runtimeStatus executable, direkte .bak-URL
        und genau eine erwartete Datenbank. Optional wird nach SQL-Version
        gefiltert.
    #>
    [CmdletBinding()]
    param(
        [string]$SqlVersion
    )

    $baseVersion = $null
    if ($SqlVersion) {
        $baseVersionText = ([string]$SqlVersion -split '-', 2)[0]
        if ($baseVersionText -match '^\d{4}$') {
            $baseVersion = [int]$baseVersionText
        }
    }

    $results = @()
    foreach ($sample in @(Get-LabSampleDatabase)) {
        if ($baseVersion -and $sample.minSqlVersion -and [int]$sample.minSqlVersion -gt $baseVersion) {
            continue
        }

        foreach ($variantProperty in @($sample.versions.PSObject.Properties)) {
            $definition = $variantProperty.Value
            if ($definition.runtimeStatus -ne 'executable' -or
                $definition.artifactType -ne 'backup' -or
                $definition.installation.kind -ne 'backup') {
                continue
            }

            $outputs = @($definition.expectedOutputs)
            if ($outputs.Count -ne 1 -or $outputs[0].kind -ne 'database') {
                continue
            }

            $results += [PSCustomObject]@{
                SampleId               = [string]$sample.id
                Variant                = [string]$variantProperty.Name
                DisplayName            = [string]$sample.displayName
                Description            = [string]$sample.description
                Category               = [string]$sample.category
                License                = [string]$sample.license
                SourcePage             = [string]$sample.source
                Source                 = [string]$definition.url
                ArtifactType           = [string]$definition.artifactType
                ExpectedDatabase       = [string]$outputs[0].name
                DownloadSizeMB         = $definition.downloadSizeMB
                EstimatedInstallSizeMB = $definition.estimatedInstallSizeMB
                MinSqlVersion          = [string]$sample.minSqlVersion
                Compatibility          = $definition.compatibility
                ExpectedSha256         = if ($definition.sha256) { ([string]$definition.sha256).ToLowerInvariant() } else { $null }
                TrustPolicy            = [string]$definition.trustPolicy
            }
        }
    }

    return @($results)
}

function Get-LabSampleArtifactLocalStatus {
    <#
    .SYNOPSIS
        Ermittelt Trust- und Cache-Status einer Sample-Variante read-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$SampleId,
        [Parameter(Mandatory)][string]$SampleVariant,
        [string]$ExpectedSha256,
        [string]$StateRoot
    )

    $knownSha256 = if ($ExpectedSha256) { $ExpectedSha256.ToLowerInvariant() } else { $null }
    $trustStatus = 'TRUST_REQUIRED'

    if ($knownSha256) {
        $trustStatus = 'catalog-verified'
    }
    else {
        $trustRecord = Get-LabArtifactTrustRecord `
            -Source $Source `
            -SampleId $SampleId `
            -SampleVariant $SampleVariant `
            -StateRoot $StateRoot
        if ($trustRecord) {
            $trustStatus = [string]$trustRecord.integrityOrigin
            $knownSha256 = [string]$trustRecord.sha256
        }
    }

    $cacheStatus = 'MISS'
    if ($knownSha256 -and (Get-LabArtifactCacheEntry -Sha256 $knownSha256 -StateRoot $StateRoot)) {
        $cacheStatus = 'HIT'
    }

    return [PSCustomObject]@{
        TrustStatus = $trustStatus
        CacheStatus = $cacheStatus
        KnownSha256 = $knownSha256
    }
}

function Install-LabSampleDatabase {
    <#
    .SYNOPSIS
        Installiert ein Backup-Sample ueber den gemeinsamen Handler-Lifecycle.
    .DESCRIPTION
        Acquire und VerifyIntegrity laufen ueber Resolve-LabArtifact mit der
        vollstaendigen Sample-Identitaet, damit Trust Store und Run Lock den
        Katalogbezug enthalten. Danach prueft der Handler die Idempotenzregel
        (fail-if-exists), stellt das Backup aus dem verifizierten Cache wieder
        her und verifiziert die erwartete Datenbank als ONLINE.
    #>
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)]$RestoreDefinition,
        [switch]$NonInteractive,
        [switch]$TrustUnknownArtifact,
        [string]$RunDirectory,
        [string]$StateRoot
    )

    $databaseName = [string]$RestoreDefinition.expectedOutputs[0].name
    $result = [ordered]@{
        Status        = $null
        Message       = $null
        SampleId      = [string]$RestoreDefinition.sampleId
        SampleVariant = [string]$RestoreDefinition.sampleVariant
        DatabaseName  = $databaseName
        Artifact      = $null
        Success       = $false
    }

    $resolverArguments = @{
        Source                 = [string]$RestoreDefinition.source
        ArtifactType           = 'backup'
        TrustPolicy            = if ($RestoreDefinition.trustPolicy) { [string]$RestoreDefinition.trustPolicy } else { 'interactive-once' }
        SampleId               = [string]$RestoreDefinition.sampleId
        SampleVariant          = [string]$RestoreDefinition.sampleVariant
        HandlerContractVersion = [string]$RestoreDefinition.handlerContractVersion
        ExpectedOutputs        = @($RestoreDefinition.expectedOutputs)
        NonInteractive         = $NonInteractive
        TrustUnknownArtifact   = $TrustUnknownArtifact
        RunDirectory           = $RunDirectory
        StateRoot              = $StateRoot
    }
    if ($RestoreDefinition.expectedSha256) {
        $resolverArguments.ExpectedSha256 = [string]$RestoreDefinition.expectedSha256
    }
    if ($RestoreDefinition.compatibility) {
        $resolverArguments.Compatibility = [int]$RestoreDefinition.compatibility
    }

    $artifactResolution = Resolve-LabArtifact @resolverArguments
    $result.Artifact = $artifactResolution
    if ($artifactResolution.Status -ne 'ARTIFACT_READY') {
        $result.Status = $artifactResolution.Status
        $result.Message = $artifactResolution.Message
        return [PSCustomObject]$result
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try {
        $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    try {
        $escapedDatabaseName = $databaseName.Replace("'", "''")
        $existsOutput = Invoke-SqlQuery `
            -HostName $HostName `
            -Port $Port `
            -SaPlain $saPlain `
            -Query "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name = N'$escapedDatabaseName';"
        $existsText = (@($existsOutput) | ForEach-Object { ([string]$_).Trim() })

        $idempotencyMode = if ($RestoreDefinition.idempotencyMode) { [string]$RestoreDefinition.idempotencyMode } else { 'fail-if-exists' }
        if ($existsText -contains $databaseName -and $idempotencyMode -eq 'fail-if-exists') {
            $result.Status = 'SAMPLE_OUTPUT_CONFLICT'
            $result.Message = "Datenbank '$databaseName' existiert bereits; Idempotenzregel fail-if-exists blockiert die Installation."
            return [PSCustomObject]$result
        }

        $restoreResult = Restore-SqlServerLabDatabase `
            -HostName $HostName `
            -Port $Port `
            -SaPassword $SaPassword `
            -BackupSource $artifactResolution.Path `
            -ExpectedSha256 $artifactResolution.Sha256 `
            -DatabaseName $databaseName `
            -ContainerName $ContainerName `
            -StateRoot $StateRoot

        if (-not $restoreResult.Success) {
            $result.Status = 'SAMPLE_INSTALLATION_FAILED'
            $result.Message = $restoreResult.Message
            return [PSCustomObject]$result
        }

        $stateOutput = Invoke-SqlQuery `
            -HostName $HostName `
            -Port $Port `
            -SaPlain $saPlain `
            -Query "SET NOCOUNT ON; SELECT state_desc FROM sys.databases WHERE name = N'$escapedDatabaseName';"
        $stateText = (@($stateOutput) | ForEach-Object { ([string]$_).Trim() })

        if ($stateText -notcontains 'ONLINE') {
            $result.Status = 'SAMPLE_VERIFICATION_FAILED'
            $result.Message = "Erwartete Datenbank '$databaseName' ist nach der Installation nicht ONLINE."
            return [PSCustomObject]$result
        }

        $result.Status = 'DATASET_READY'
        $result.Message = "Sample '$($result.SampleId)' Variante '$($result.SampleVariant)' installiert und verifiziert."
        $result.Success = $true
        return [PSCustomObject]$result
    }
    finally {
        $saPlain = $null
    }
}

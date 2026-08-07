<#
.SYNOPSIS
    Sample-Artifact-Handler fuer den gemeinsamen Installations-Lifecycle.
.DESCRIPTION
    Implementiert die freigegebenen Sample-Handler aus dem Sample-Zielvertrag:
    direkte Backups, ZIP-Archive mit genau einem katalogisierten Backup und
    einzelne T-SQL-Skripte. Acquisition und Integritaet laufen ueber den
    Artifact Resolver (Trust Store, Cache, Quarantaene, Run Lock), danach
    folgen Idempotenzpruefung, Apply und Output-Verification. Alle Ergebnisse verwenden stabile Statusklassen
    (DATASET_READY, TRUST_REQUIRED, SAMPLE_OUTPUT_CONFLICT,
    SAMPLE_INSTALLATION_FAILED, SAMPLE_VERIFICATION_FAILED).
#>

function Get-LabExecutableSampleVariant {
    <#
    .SYNOPSIS
        Listet automatisch installierbare Sample-Varianten des Katalogs auf.
    .DESCRIPTION
        Liefert nur Varianten, fuer die ein freigegebener Runtime-Handler
        vorhanden ist: direkte Backups, ZIP-Backups und einzelne T-SQL-Skripte.
        Jede Variante muss genau eine erwartete Datenbank definieren. Optional
        wird nach SQL-Version gefiltert.
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
                $definition.artifactType -notin @('backup', 'archive-backup', 'sql-script') -or
                [string]$definition.installation.kind -ne [string]$definition.artifactType) {
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
                Installation           = $definition.installation
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

function Get-LabArchiveBackupPayload {
    <#
    .SYNOPSIS
        Extrahiert ein katalogisiertes .bak aus einem verifizierten ZIP temporär.
    .DESCRIPTION
        Es wird ausschliesslich der exakte, im Katalog vereinbarte Payload-Pfad
        extrahiert. Das verhindert Mehrdeutigkeit sowie Zip-Slip-Pfade; das
        Arbeitsverzeichnis wird vom aufrufenden Handler immer wieder entfernt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$PayloadPath,
        [string]$RunDirectory
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "SAMPLE_ARCHIVE_NOT_FOUND: $ArchivePath"
    }

    $normalizedPayload = ($PayloadPath -replace '\\', '/').TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($normalizedPayload) -or
        $normalizedPayload -match '(^|/)\.\.(/|$)' -or
        [System.IO.Path]::IsPathRooted($normalizedPayload) -or
        $normalizedPayload -notmatch '(?i)\.bak$') {
        throw "SAMPLE_ARCHIVE_PAYLOAD_INVALID: '$PayloadPath' ist kein sicherer relativer .bak-Pfad."
    }

    $temporaryBase = if ($RunDirectory -and (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
        Join-Path $RunDirectory 'artifact-work'
    }
    else {
        Join-Path ([System.IO.Path]::GetTempPath()) 'sql-server-lab-artifacts'
    }
    $workingDirectory = Join-Path $temporaryBase ([guid]::NewGuid().ToString('N'))
    New-Item -Path $workingDirectory -ItemType Directory -Force | Out-Null

    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        try {
            $matches = @($archive.Entries | Where-Object {
                $_.FullName.Replace('\\', '/') -ieq $normalizedPayload
            })
            if ($matches.Count -ne 1 -or $matches[0].Length -le 0) {
                throw "SAMPLE_ARCHIVE_PAYLOAD_NOT_FOUND: ZIP muss genau die katalogisierte Backup-Payload '$normalizedPayload' enthalten."
            }

            $targetPath = Join-Path $workingDirectory ($normalizedPayload -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $targetRoot = [System.IO.Path]::GetFullPath($workingDirectory + [System.IO.Path]::DirectorySeparatorChar)
            $fullTargetPath = [System.IO.Path]::GetFullPath($targetPath)
            if (-not $fullTargetPath.StartsWith($targetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "SAMPLE_ARCHIVE_PAYLOAD_INVALID: ZIP-Payload verlaesst das temporaere Arbeitsverzeichnis."
            }

            $targetDirectory = Split-Path -Parent $fullTargetPath
            New-Item -Path $targetDirectory -ItemType Directory -Force | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($matches[0], $fullTargetPath, $false)
            return [PSCustomObject]@{
                Path             = $fullTargetPath
                WorkingDirectory = $workingDirectory
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    catch {
        if (Test-Path -LiteralPath $workingDirectory) {
            Remove-Item -LiteralPath $workingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Install-LabSampleDatabase {
    <#
    .SYNOPSIS
        Installiert ein katalogisiertes Sample ueber den gemeinsamen Handler-Lifecycle.
    .DESCRIPTION
        Acquire und VerifyIntegrity laufen ueber Resolve-LabArtifact mit der
        vollstaendigen Sample-Identitaet, damit Trust Store und Run Lock den
        Katalogbezug enthalten. Danach prueft der Handler die Idempotenzregel
        (fail-if-exists), fuehrt den typisierten Handler aus und verifiziert
        die erwartete Datenbank als ONLINE.
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
        ArtifactType           = [string]$RestoreDefinition.artifactType
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
    $temporaryArchivePayload = $null
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

        switch ([string]$RestoreDefinition.artifactType) {
            'backup' {
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
            }
            'archive-backup' {
                if ([string]$RestoreDefinition.installation.archiveFormat -ne 'zip') {
                    throw "SAMPLE_ARCHIVE_FORMAT_UNSUPPORTED: '$($RestoreDefinition.installation.archiveFormat)'"
                }
                $temporaryArchivePayload = Get-LabArchiveBackupPayload `
                    -ArchivePath $artifactResolution.Path `
                    -PayloadPath ([string]$RestoreDefinition.installation.payloadPath) `
                    -RunDirectory $RunDirectory
                $restoreResult = Restore-SqlServerLabDatabase `
                    -HostName $HostName `
                    -Port $Port `
                    -SaPassword $SaPassword `
                    -BackupSource $temporaryArchivePayload.Path `
                    -DatabaseName $databaseName `
                    -ContainerName $ContainerName `
                    -StateRoot $StateRoot
                if (-not $restoreResult.Success) {
                    $result.Status = 'SAMPLE_INSTALLATION_FAILED'
                    $result.Message = $restoreResult.Message
                    return [PSCustomObject]$result
                }
            }
            'sql-script' {
                $executionMode = [string]$RestoreDefinition.installation.executionMode
                if ($executionMode -eq 'existing-database') {
                    $createResult = New-SqlServerLabDatabase `
                        -HostName $HostName `
                        -Port $Port `
                        -SaPassword $SaPassword `
                        -DatabaseName $databaseName
                    if (-not $createResult.Success) {
                        $result.Status = 'SAMPLE_INSTALLATION_FAILED'
                        $result.Message = "Zieldatenbank '$databaseName' konnte nicht erstellt werden."
                        return [PSCustomObject]$result
                    }
                }
                elseif ($executionMode -ne 'self-creates-databases') {
                    throw "SAMPLE_SCRIPT_EXECUTION_MODE_UNSUPPORTED: '$executionMode'"
                }

                $scriptDatabase = if ($executionMode -eq 'existing-database') { $databaseName } else { 'master' }
                $scriptResult = Invoke-LabSqlScript `
                    -ScriptPath $artifactResolution.Path `
                    -HostName $HostName `
                    -Port $Port `
                    -SaPassword $SaPassword `
                    -Database $scriptDatabase `
                    -KeepConnection `
                    -TimeoutSeconds ([int]$RestoreDefinition.installation.timeoutSeconds)
                if (-not $scriptResult.Success) {
                    $result.Status = 'SAMPLE_INSTALLATION_FAILED'
                    $result.Message = $scriptResult.Message
                    return [PSCustomObject]$result
                }
            }
            default {
                throw "SAMPLE_HANDLER_UNSUPPORTED: '$($RestoreDefinition.artifactType)'"
            }
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
        if ($temporaryArchivePayload -and (Test-Path -LiteralPath $temporaryArchivePayload.WorkingDirectory)) {
            Remove-Item -LiteralPath $temporaryArchivePayload.WorkingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

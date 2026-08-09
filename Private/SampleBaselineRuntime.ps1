function New-LabSampleBaselineRequestKey {
    <#
    .SYNOPSIS
        Baut den Registry-Key fuer einen aufgeloesten Samplevertrag.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RestoreDefinition,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$SourceSha256,
        [Parameter(Mandatory)][string]$SqlVersion
    )

    $features = @(
        @($RestoreDefinition.featureRequirements) +
        @($RestoreDefinition.installation.featureRequirements) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $variables = @{}
    if ($RestoreDefinition.installation.variables) {
        foreach ($property in @($RestoreDefinition.installation.variables.PSObject.Properties)) {
            $variables[[string]$property.Name] = [string]$property.Value
        }
    }

    $keyArguments = @{
        RestoreDefinition   = $RestoreDefinition
        SourceSha256        = $SourceSha256.ToLowerInvariant()
        SqlVersion          = $SqlVersion
        FeatureRequirements = $features
        Variables           = $variables
    }
    if ($RestoreDefinition.compatibility) {
        $keyArguments.CompatibilityLevel = [int]$RestoreDefinition.compatibility
    }
    return New-LabSampleBaselineKey @keyArguments
}

function Get-LabSampleBaselineRequest {
    <#
    .SYNOPSIS
        Waehlt eine verifizierte Baseline ohne Netzwerkzugriff aus.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RestoreDefinition,
        [Parameter(Mandatory)][string]$SqlVersion,
        [string]$StateRoot,
        [string]$TestDataRoot
    )

    if ([string]$RestoreDefinition.installation.baselinePolicy -ne 'eligible-after-verification') {
        return $null
    }

    $sourceSha256 = if ($RestoreDefinition.expectedSha256) {
        ([string]$RestoreDefinition.expectedSha256).ToLowerInvariant()
    }
    else {
        $localStatus = Get-LabSampleArtifactLocalStatus `
            -Source ([string]$RestoreDefinition.source) `
            -SampleId ([string]$RestoreDefinition.sampleId) `
            -SampleVariant ([string]$RestoreDefinition.sampleVariant) `
            -StateRoot $StateRoot `
            -TestDataRoot $TestDataRoot
        [string]$localStatus.KnownSha256
    }
    if ([string]::IsNullOrWhiteSpace($sourceSha256)) {
        return $null
    }

    $key = New-LabSampleBaselineRequestKey `
        -RestoreDefinition $RestoreDefinition `
        -SourceSha256 $sourceSha256 `
        -SqlVersion $SqlVersion
    $selection = Get-LabSampleBaseline `
        -Key $key `
        -AllowCompatible `
        -StateRoot $StateRoot `
        -TestDataRoot $TestDataRoot
    if (-not $selection) {
        return $null
    }

    return [PSCustomObject]@{
        Key       = $key
        Selection = $selection
        SourceSha256 = $sourceSha256
    }
}

function Initialize-LabSampleBaselineContainerBackup {
    <#
    .SYNOPSIS
        Erstellt das Backupverzeichnis in einem eindeutig bestimmten Labcontainer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$ContainerName
    )

    $target = Resolve-LabRestoreContainer -ContainerName $ContainerName -Port $Port
    $runtime = [string]$target.Provider
    & $runtime exec $target.ContainerName mkdir -p /var/opt/mssql/backup 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "SAMPLE_BASELINE_BACKUP_DIRECTORY_FAILED: Backupverzeichnis konnte in $runtime/$($target.ContainerName) nicht erstellt werden."
    }
    return $target
}

function Export-LabSampleBaselineContainerBackup {
    <#
    .SYNOPSIS
        Kopiert ein erzeugtes Backup aus einem eindeutig bestimmten Labcontainer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)][string]$ContainerBackupPath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $target = Resolve-LabRestoreContainer -ContainerName $ContainerName -Port $Port
    $runtime = [string]$target.Provider
    try {
        & $runtime cp "$($target.ContainerName):$ContainerBackupPath" $DestinationPath 1>$null 2>$null
        if ($LASTEXITCODE -ne 0 -or
            -not (Test-Path -LiteralPath $DestinationPath -PathType Leaf) -or
            (Get-Item -LiteralPath $DestinationPath).Length -le 0) {
            throw "SAMPLE_BASELINE_EXPORT_FAILED: Backup konnte nicht aus $runtime/$($target.ContainerName) exportiert werden."
        }

        return [PSCustomObject]@{
            Provider      = $runtime
            ContainerName = [string]$target.ContainerName
        }
    }
    finally {
        & $runtime exec $target.ContainerName rm -f $ContainerBackupPath 1>$null 2>$null
    }
}

function New-LabSampleBaselineBackup {
    <#
    .SYNOPSIS
        Erzeugt, verifiziert, exportiert und registriert ein Single-Output-Backup.
    #>
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$DatabaseName,
        [Parameter(Mandatory)]$Key,
        [string]$RunDirectory,
        [string]$StateRoot,
        [string]$TestDataRoot
    )

    $temporaryBase = if ($RunDirectory -and (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
        Join-Path $RunDirectory 'artifact-work'
    }
    else {
        Join-Path ([System.IO.Path]::GetTempPath()) 'sql-server-lab-baselines'
    }
    $workingDirectory = Join-Path $temporaryBase ([guid]::NewGuid().ToString('N'))
    $backupFileName = "baseline-$([guid]::NewGuid().ToString('N')).bak"
    $hostBackupPath = Join-Path $workingDirectory $backupFileName
    $containerBackupPath = "/var/opt/mssql/backup/$backupFileName"
    New-Item -Path $workingDirectory -ItemType Directory -Force | Out-Null

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try {
        $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $export = $null
    try {
        $null = Initialize-LabSampleBaselineContainerBackup -Port $Port -ContainerName $ContainerName
        $escapedDatabaseName = $DatabaseName.Replace(']', ']]')
        $escapedBackupPath = $containerBackupPath.Replace("'", "''")
        $query = @"
BACKUP DATABASE [$escapedDatabaseName]
    TO DISK = N'$escapedBackupPath'
    WITH COPY_ONLY, INIT, CHECKSUM;
RESTORE VERIFYONLY
    FROM DISK = N'$escapedBackupPath'
    WITH CHECKSUM;
"@
        $null = Invoke-SqlQuery `
            -HostName $HostName `
            -Port $Port `
            -SaPlain $saPlain `
            -Query $query

        $export = Export-LabSampleBaselineContainerBackup `
            -Port $Port `
            -ContainerName $ContainerName `
            -ContainerBackupPath $containerBackupPath `
            -DestinationPath $hostBackupPath
        $registered = Register-LabSampleBaseline `
            -Key $Key `
            -BackupPath $hostBackupPath `
            -StateRoot $StateRoot `
            -TestDataRoot $TestDataRoot

        return [PSCustomObject]@{
            Status        = 'BASELINE_REGISTERED'
            KeyId         = [string]$Key.KeyId
            Path          = [string]$registered.Path
            Record        = $registered.Record
            Provider      = [string]$export.Provider
            ContainerName = [string]$export.ContainerName
        }
    }
    finally {
        $saPlain = $null
        if (Test-Path -LiteralPath $hostBackupPath -PathType Leaf) {
            Remove-Item -LiteralPath $hostBackupPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $workingDirectory -PathType Container) {
            Remove-Item -LiteralPath $workingDirectory -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-LabSampleBaselineBundle {
    <#
    .SYNOPSIS
        Erzeugt ein verifiziertes ZIP aus mehreren Datenbankbackups.
    #>
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)][ValidateCount(2, 128)][string[]]$DatabaseNames,
        [Parameter(Mandatory)]$Key,
        [string]$RunDirectory,
        [string]$StateRoot,
        [string]$TestDataRoot
    )

    $validatedNames = @($DatabaseNames | Select-Object -Unique)
    if ($validatedNames.Count -ne $DatabaseNames.Count -or
        @($validatedNames | Where-Object { $_ -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$' }).Count -gt 0) {
        throw 'SAMPLE_BASELINE_OUTPUTS_INVALID: Multi-Output-Baselines benoetigen eindeutige sichere Datenbanknamen.'
    }

    $temporaryBase = if ($RunDirectory -and (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
        Join-Path $RunDirectory 'artifact-work'
    }
    else {
        Join-Path ([System.IO.Path]::GetTempPath()) 'sql-server-lab-baselines'
    }
    $workingDirectory = Join-Path $temporaryBase ([guid]::NewGuid().ToString('N'))
    $bundlePath = Join-Path $workingDirectory 'baseline.zip'
    New-Item -Path $workingDirectory -ItemType Directory -Force | Out-Null

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try {
        $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    try {
        $null = Initialize-LabSampleBaselineContainerBackup -Port $Port -ContainerName $ContainerName
        $backupFiles = [System.Collections.Generic.List[object]]::new()
        foreach ($databaseName in @($validatedNames | Sort-Object)) {
            $fileName = "$databaseName.bak"
            $hostBackupPath = Join-Path $workingDirectory $fileName
            $containerBackupPath = "/var/opt/mssql/backup/baseline-$([guid]::NewGuid().ToString('N')).bak"
            $escapedDatabaseName = $databaseName.Replace(']', ']]')
            $escapedBackupPath = $containerBackupPath.Replace("'", "''")
            $query = @"
BACKUP DATABASE [$escapedDatabaseName]
    TO DISK = N'$escapedBackupPath'
    WITH COPY_ONLY, INIT, CHECKSUM;
RESTORE VERIFYONLY
    FROM DISK = N'$escapedBackupPath'
    WITH CHECKSUM;
"@
            $null = Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain -Query $query
            $null = Export-LabSampleBaselineContainerBackup `
                -Port $Port `
                -ContainerName $ContainerName `
                -ContainerBackupPath $containerBackupPath `
                -DestinationPath $hostBackupPath
            $backupFiles.Add([PSCustomObject]@{ DatabaseName = $databaseName; Path = $hostBackupPath })
        }

        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        $archive = [System.IO.Compression.ZipFile]::Open($bundlePath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($backupFile in $backupFiles) {
                $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $archive,
                    [string]$backupFile.Path,
                    "$($backupFile.DatabaseName).bak",
                    [System.IO.Compression.CompressionLevel]::Optimal)
            }
        }
        finally {
            $archive.Dispose()
        }

        $registered = Register-LabSampleBaseline `
            -Key $Key `
            -BackupPath $bundlePath `
            -ArtifactFormat 'multi-database-zip' `
            -StateRoot $StateRoot `
            -TestDataRoot $TestDataRoot
        return [PSCustomObject]@{
            Status = 'BASELINE_REGISTERED'
            KeyId  = [string]$Key.KeyId
            Path   = [string]$registered.Path
            Record = $registered.Record
        }
    }
    finally {
        $saPlain = $null
        foreach ($file in @(Get-ChildItem -LiteralPath $workingDirectory -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $workingDirectory -PathType Container) {
            Remove-Item -LiteralPath $workingDirectory -Force -ErrorAction SilentlyContinue
        }
    }
}

function Expand-LabSampleBaselineBundle {
    <#
    .SYNOPSIS
        Extrahiert exakt die erwarteten Backups einer Multi-Output-Baseline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string[]]$DatabaseNames,
        [string]$RunDirectory
    )

    $temporaryBase = if ($RunDirectory -and (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
        Join-Path $RunDirectory 'artifact-work'
    }
    else {
        Join-Path ([System.IO.Path]::GetTempPath()) 'sql-server-lab-baselines'
    }
    $workingDirectory = Join-Path $temporaryBase ([guid]::NewGuid().ToString('N'))
    New-Item -Path $workingDirectory -ItemType Directory -Force | Out-Null

    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        $archive = [System.IO.Compression.ZipFile]::OpenRead($BundlePath)
        try {
            $fileEntries = @($archive.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
            $expectedFileNames = @($DatabaseNames | ForEach-Object { "$_.bak" } | Sort-Object)
            $actualFileNames = @($fileEntries | ForEach-Object { [string]$_.FullName } | Sort-Object)
            if (($expectedFileNames -join '|') -cne ($actualFileNames -join '|') -or
                @($fileEntries | Where-Object { $_.FullName -ne $_.Name }).Count -gt 0) {
                throw 'SAMPLE_BASELINE_BUNDLE_CONTENT_INVALID: ZIP enthaelt nicht exakt die erwarteten Datenbankbackups.'
            }

            $payloads = @()
            foreach ($databaseName in $DatabaseNames) {
                $entry = $fileEntries | Where-Object { $_.Name -ceq "$databaseName.bak" } | Select-Object -First 1
                $targetPath = Join-Path $workingDirectory $entry.Name
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $false)
                if ((Get-Item -LiteralPath $targetPath).Length -le 0) {
                    throw "SAMPLE_BASELINE_BUNDLE_CONTENT_INVALID: Backup fuer '$databaseName' ist leer."
                }
                $payloads += [PSCustomObject]@{
                    DatabaseName = $databaseName
                    Path = $targetPath
                    Sha256 = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
            return [PSCustomObject]@{ Payloads = $payloads; WorkingDirectory = $workingDirectory }
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

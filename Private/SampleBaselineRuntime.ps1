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

    $sourceIntegrityOrigin = $null
    $sourceSha256 = if ($RestoreDefinition.expectedSha256) {
        $sourceIntegrityOrigin = if ($RestoreDefinition.integrityOrigin) {
            [string]$RestoreDefinition.integrityOrigin
        }
        else {
            'catalog-verified'
        }
        ([string]$RestoreDefinition.expectedSha256).ToLowerInvariant()
    }
    else {
        $localStatus = Get-LabSampleArtifactLocalStatus `
            -Source ([string]$RestoreDefinition.source) `
            -SampleId ([string]$RestoreDefinition.sampleId) `
            -SampleVariant ([string]$RestoreDefinition.sampleVariant) `
            -StateRoot $StateRoot `
            -TestDataRoot $TestDataRoot
        $sourceIntegrityOrigin = [string]$localStatus.TrustStatus
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
        SourceIntegrityOrigin = $sourceIntegrityOrigin
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
    $runtimeInvocation = Get-LabHostToolInvocation -Name $runtime
    & $runtimeInvocation exec $target.ContainerName mkdir -p /var/opt/mssql/backup 1>$null 2>$null
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
    $runtimeInvocation = Get-LabHostToolInvocation -Name $runtime
    try {
        & $runtimeInvocation cp "$($target.ContainerName):$ContainerBackupPath" $DestinationPath 1>$null 2>$null
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
        & $runtimeInvocation exec $target.ContainerName rm -f $ContainerBackupPath 1>$null 2>$null
    }
}

function Initialize-LabSampleBaselineBackupTarget {
    <#
    .SYNOPSIS
        Bindet den temporaeren Backup-Export an einen Container oder die
        verifizierte Hyper-V-Backup-Lane eines Runs.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('docker','podman','hyperv')][string]$Provider,
        [Parameter(Mandatory)][int]$Port,
        [string]$ContainerName,
        [string]$RunId,
        [string]$InstanceId = 'primary',
        [PSCredential]$GuestCredential,
        [string]$StateRoot
    )

    if ($Provider -eq 'hyperv') {
        if (-not $RunId -or -not $GuestCredential) {
            throw 'SAMPLE_BASELINE_HYPERV_RUN_AND_GUEST_CREDENTIAL_REQUIRED'
        }
        $context = Get-LabVerifiedStorageRuntimeContext `
            -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if ([string]$context.Plan.Provider -ne 'hyperv') {
            throw 'SAMPLE_BASELINE_HYPERV_STORAGE_CONTEXT_REQUIRED'
        }
        if ([string]$context.Receipt.Status -ne 'VERIFIED') {
            throw 'SAMPLE_BASELINE_HYPERV_VERIFIED_RECEIPT_REQUIRED'
        }
        $backupBindings = @($context.Receipt.FileBindings | Where-Object { [string]$_.Role -eq 'backup' })
        if ($backupBindings.Count -ne 1 -or -not [string]$backupBindings[0].SqlPhysicalPath) {
            throw 'SAMPLE_BASELINE_HYPERV_BACKUP_BINDING_EXACTLY_ONE_REQUIRED'
        }
        return [PSCustomObject]@{
            Provider='hyperv'; RunId=$RunId; InstanceId=$InstanceId
            GuestCredential=$GuestCredential
            BackupRoot=[string]$backupBindings[0].SqlPhysicalPath
            StateRoot=$context.StateRoot; ContainerName=$null
        }
    }

    if ([string]::IsNullOrWhiteSpace($ContainerName)) {
        throw 'SAMPLE_BASELINE_CONTAINER_NAME_REQUIRED'
    }
    $container = Initialize-LabSampleBaselineContainerBackup -Port $Port -ContainerName $ContainerName
    if ($Provider -and [string]$container.Provider -ne $Provider) {
        throw 'SAMPLE_BASELINE_CONTAINER_PROVIDER_MISMATCH'
    }
    return [PSCustomObject]@{
        Provider=[string]$container.Provider; ContainerName=[string]$container.ContainerName
        RunId=$null; InstanceId=$null; GuestCredential=$null
        BackupRoot='/var/opt/mssql/backup'; StateRoot=$StateRoot
    }
}

function Export-LabSampleBaselineBackup {
    <#
    .SYNOPSIS
        Exportiert genau ein erzeugtes Backup aus dem gebundenen Runtimeziel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$RuntimeBackupPath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][int]$Port
    )

    if ([string]$Target.Provider -eq 'hyperv') {
        try {
            $null = Copy-LabFileFromHyperVGuest `
                -RunId ([string]$Target.RunId) `
                -SourcePath $RuntimeBackupPath `
                -DestinationPath $DestinationPath `
                -Credential $Target.GuestCredential `
                -StateRoot ([string]$Target.StateRoot)
            return [PSCustomObject]@{
                Provider='hyperv'; ContainerName=$null
                RunId=[string]$Target.RunId; InstanceId=[string]$Target.InstanceId
            }
        }
        finally {
            Remove-LabHyperVGuestFile `
                -RunId ([string]$Target.RunId) `
                -Path $RuntimeBackupPath `
                -Credential $Target.GuestCredential `
                -StateRoot ([string]$Target.StateRoot)
        }
    }

    return Export-LabSampleBaselineContainerBackup `
        -Port $Port `
        -ContainerName ([string]$Target.ContainerName) `
        -ContainerBackupPath $RuntimeBackupPath `
        -DestinationPath $DestinationPath
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
        [ValidateSet('docker','podman','hyperv')][string]$Provider,
        [string]$ContainerName,
        [string]$RunId,
        [string]$InstanceId = 'primary',
        [PSCredential]$GuestCredential,
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
        $targetArguments = @{
            Port=$Port; ContainerName=$ContainerName; RunId=$RunId
            InstanceId=$InstanceId; GuestCredential=$GuestCredential; StateRoot=$StateRoot
        }
        if ($Provider) { $targetArguments.Provider=$Provider }
        $target = Initialize-LabSampleBaselineBackupTarget @targetArguments
        $runtimeBackupPath = if ([string]$target.Provider -eq 'hyperv') {
            Get-LabStorageGuestChildPath -Root ([string]$target.BackupRoot) -Child $backupFileName
        }
        else { "/var/opt/mssql/backup/$backupFileName" }
        $escapedDatabaseName = $DatabaseName.Replace(']', ']]')
        $escapedBackupPath = $runtimeBackupPath.Replace("'", "''")
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

        $export = Export-LabSampleBaselineBackup `
            -Target $target -RuntimeBackupPath $runtimeBackupPath `
            -DestinationPath $hostBackupPath -Port $Port
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
            RunId         = [string]$export.RunId
            InstanceId    = [string]$export.InstanceId
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
        [ValidateSet('docker','podman','hyperv')][string]$Provider,
        [string]$ContainerName,
        [string]$RunId,
        [string]$InstanceId = 'primary',
        [PSCredential]$GuestCredential,
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
        $targetArguments = @{
            Port=$Port; ContainerName=$ContainerName; RunId=$RunId
            InstanceId=$InstanceId; GuestCredential=$GuestCredential; StateRoot=$StateRoot
        }
        if ($Provider) { $targetArguments.Provider=$Provider }
        $target = Initialize-LabSampleBaselineBackupTarget @targetArguments
        $backupFiles = [System.Collections.Generic.List[object]]::new()
        foreach ($databaseName in @($validatedNames | Sort-Object)) {
            $fileName = "$databaseName.bak"
            $hostBackupPath = Join-Path $workingDirectory $fileName
            $runtimeBackupName = "baseline-$([guid]::NewGuid().ToString('N')).bak"
            $runtimeBackupPath = if ([string]$target.Provider -eq 'hyperv') {
                Get-LabStorageGuestChildPath -Root ([string]$target.BackupRoot) -Child $runtimeBackupName
            }
            else { "/var/opt/mssql/backup/$runtimeBackupName" }
            $escapedDatabaseName = $databaseName.Replace(']', ']]')
            $escapedBackupPath = $runtimeBackupPath.Replace("'", "''")
            $query = @"
BACKUP DATABASE [$escapedDatabaseName]
    TO DISK = N'$escapedBackupPath'
    WITH COPY_ONLY, INIT, CHECKSUM;
RESTORE VERIFYONLY
    FROM DISK = N'$escapedBackupPath'
    WITH CHECKSUM;
"@
            $null = Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain -Query $query
            $null = Export-LabSampleBaselineBackup `
                -Target $target -RuntimeBackupPath $runtimeBackupPath `
                -DestinationPath $hostBackupPath -Port $Port
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
            Provider = [string]$target.Provider
            RunId = [string]$target.RunId
            InstanceId = [string]$target.InstanceId
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

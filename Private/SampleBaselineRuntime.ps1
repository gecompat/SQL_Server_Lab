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

    if ([string]$RestoreDefinition.installation.baselinePolicy -ne 'eligible-after-verification' -or
        @($RestoreDefinition.expectedOutputs).Count -ne 1) {
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

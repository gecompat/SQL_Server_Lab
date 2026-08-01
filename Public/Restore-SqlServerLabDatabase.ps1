function Resolve-LabRestoreContainer {
    [CmdletBinding()]
    param(
        [ValidateSet('docker', 'podman')][string]$Provider,
        [string]$ContainerName,
        [Parameter(Mandatory)][int]$Port
    )

    $candidateProviders = if ($Provider) { @($Provider) } else { @('docker', 'podman') }
    $containerCandidates = @()

    foreach ($candidateProvider in $candidateProviders) {
        if (-not (Get-Command $candidateProvider -ErrorAction SilentlyContinue)) {
            continue
        }

        & $candidateProvider info 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        if ($ContainerName) {
            $inspect = & $candidateProvider inspect $ContainerName 2>$null |
                ConvertFrom-Json -Depth 30
            if ($LASTEXITCODE -eq 0 -and $inspect) {
                $item = @($inspect)[0]
                $runId = [string]$item.Config.Labels.'sql-server-lab.run-id'
                if (-not $runId) {
                    throw "Container '$ContainerName' bei $candidateProvider ist kein SQL_Server_Lab-Container."
                }
                $containerCandidates += [PSCustomObject]@{
                    Provider      = $candidateProvider
                    ContainerName = ([string]$item.Name).TrimStart('/')
                    RunId         = $runId
                    ScopeId       = [string]$item.Config.Labels.'sql-server-lab.scope-id'
                }
            }
            continue
        }

        $output = & $candidateProvider ps -a `
            --filter 'label=sql-server-lab.run-id' `
            --format '{{.Names}}|{{.Ports}}' 2>$null
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        foreach ($line in @($output)) {
            $parts = ([string]$line).Split('|', 2)
            if ($parts.Count -ne 2 -or $parts[1] -notmatch ":$Port->1433") {
                continue
            }

            $name = $parts[0].Trim()
            $inspect = & $candidateProvider inspect $name 2>$null |
                ConvertFrom-Json -Depth 30
            if ($LASTEXITCODE -ne 0 -or -not $inspect) {
                continue
            }

            $item = @($inspect)[0]
            $containerCandidates += [PSCustomObject]@{
                Provider      = $candidateProvider
                ContainerName = ([string]$item.Name).TrimStart('/')
                RunId         = [string]$item.Config.Labels.'sql-server-lab.run-id'
                ScopeId       = [string]$item.Config.Labels.'sql-server-lab.scope-id'
            }
        }
    }

    $containerCandidates = @(
        $containerCandidates |
            Sort-Object Provider, ContainerName -Unique
    )

    if ($containerCandidates.Count -eq 0) {
        $targetText = if ($ContainerName) {
            "Container '$ContainerName'"
        }
        else {
            "Lab-Container fuer Host-Port $Port"
        }
        throw "$targetText wurde bei keinem erreichbaren Provider gefunden."
    }

    if ($containerCandidates.Count -gt 1) {
        $matchText = $containerCandidates |
            ForEach-Object { "$($_.Provider):$($_.ContainerName)" } |
            Sort-Object |
            Join-String -Separator ', '
        throw "Restore-Ziel ist nicht eindeutig: $matchText. Bitte -Provider und -ContainerName angeben."
    }

    return $containerCandidates[0]
}

function Restore-SqlServerLabDatabase {
    <#
    .SYNOPSIS
        Stellt eine Datenbank aus einer direkten .bak-Datei wieder her.
    .DESCRIPTION
        Verarbeitet eine lokale Backup-Datei oder eine HTTP(S)-URL. Das Backup
        wird in den eindeutig bestimmten Docker- oder Podman-Labcontainer kopiert
        und mit RESTORE FILELISTONLY sowie RESTORE DATABASE WITH MOVE
        wiederhergestellt.
    .PARAMETER HostName
        Hostname oder IP-Adresse des SQL Servers. Standard ist 127.0.0.1.
    .PARAMETER Port
        Host-Port der SQL-Server-Instanz im direkten Modus. Der Port dient auch
        zur automatischen Zuordnung, wenn ContainerName nicht angegeben ist.
    .PARAMETER SaPassword
        SA-Passwort als SecureString.
    .PARAMETER BackupSource
        Pfad zu einer vorhandenen lokalen .bak-Datei oder direkte HTTP(S)-URL.
        URLs werden vor dem Restore in den State-Cache heruntergeladen.
    .PARAMETER DatabaseName
        Name der Zieldatenbank. Erlaubt sind Buchstaben, Ziffern und Unterstriche;
        das erste Zeichen muss ein Buchstabe sein.
    .PARAMETER ExpectedSha256
        Optional erwartete SHA-256-Pruefsumme. Eine Abweichung bricht vor dem
        Restore ab.
    .PARAMETER NonInteractive
        Unterbindet jede Rueckfrage. Fehlt eine bekannte Pruefsumme, wird kein
        Download gestartet und der Aufruf endet mit TRUST_REQUIRED.
    .PARAMETER Provider
        Optionaler Containerprovider docker oder podman. Schrankt die Suche nach
        dem Zielcontainer ein.
    .PARAMETER ContainerName
        Optionaler Name des SQL_Server_Lab-Containers. Die explizite Angabe
        verhindert Mehrdeutigkeit bei mehreren passenden Instanzen.
    .PARAMETER RunId
        Bevorzugte Identitaet einer gespeicherten Labumgebung. Provider,
        Container, Host und Port werden aus connection-info.json aufgeloest.
    .PARAMETER InstanceId
        Instanz-ID innerhalb des Runs. Standard ist primary.
    .PARAMETER DataPath
        Absoluter Linux-Pfad fur die wiederhergestellten Daten- und Logdateien im
        Container. Standard ist /var/opt/mssql/data.
    .PARAMETER Replace
        Fuegt der Wiederherstellung WITH REPLACE hinzu und erlaubt das
        Ueberschreiben einer vorhandenen Zieldatenbank.
    .PARAMETER StateRoot
        Optionales State-Stammverzeichnis fuer Trust Store, inhaltsadressierten
        Artifact Cache und Quarantaene. Ohne Angabe wird der Framework-Default
        verwendet.
    .PARAMETER RunDirectory
        Optionales Verzeichnis eines bereits angelegten Lab-Runs. Der verifizierte
        Artifact-Vertrag wird dort vor dem Restore in manifest.lock.json abgelegt.
    .OUTPUTS
        System.Management.Automation.PSCustomObject. Liefert das Ergebnis der
        Wiederherstellung einschliesslich Ziel- und Backupinformationen.
    .EXAMPLE
        Restore-SqlServerLabDatabase -RunId $lab.RunId -InstanceId 'primary' -SaPassword $pw -BackupSource 'C:\Backups\AW.bak' -DatabaseName 'AdventureWorks'

        Loest das Restore-Ziel eindeutig aus dem gespeicherten Run-State auf.
    .EXAMPLE
        Restore-SqlServerLabDatabase -Provider docker -ContainerName $lab.Instances[0].ContainerName -Port $lab.Instances[0].Port -SaPassword $pw -BackupSource 'C:\Backups\AW.bak' -DatabaseName 'AdventureWorks'

        Stellt eine lokale Backup-Datei in einem explizit benannten Container
        wieder her.
    .EXAMPLE
        Restore-SqlServerLabDatabase -Port 14330 -SaPassword $pw -BackupSource 'https://example.invalid/database.bak' -DatabaseName 'RestoreDemo'

        Ladt ein Backup in den State-Cache und ermittelt den Container anhand des
        Host-Ports.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Direct')]
    param(
        [Parameter(ParameterSetName = 'Direct')][string]$HostName = '127.0.0.1',
        [Parameter(ParameterSetName = 'Direct', Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][string]$BackupSource,
        [Parameter(Mandatory)][string]$DatabaseName,
        [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
        [switch]$NonInteractive,
        [Parameter(ParameterSetName = 'Direct')]
        [ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(ParameterSetName = 'Direct')][string]$ContainerName,
        [Parameter(ParameterSetName = 'RunBased', Mandatory)][string]$RunId,
        [Parameter(ParameterSetName = 'RunBased')][string]$InstanceId = 'primary',
        [string]$DataPath = '/var/opt/mssql/data',
        [switch]$Replace,
        [string]$StateRoot,
        [string]$RunDirectory
    )

    $ErrorActionPreference = 'Stop'

    if ($DatabaseName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$') {
        throw "DatabaseName '$DatabaseName' ist ungueltig."
    }
    if ($PSCmdlet.ParameterSetName -eq 'RunBased') {
        $runTarget = Resolve-LabRunInstance -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $HostName = $runTarget.HostName
        $Port = $runTarget.Port
        $Provider = $runTarget.Provider
        $ContainerName = $runTarget.ContainerName
        if (-not $RunDirectory) {
            $effectiveStateRoot = if ($StateRoot) { $StateRoot } else { Get-LabStateRoot }
            $RunDirectory = Join-Path (Join-Path $effectiveStateRoot 'runs') $RunId
        }
    }

    if ($Port -lt 1 -or $Port -gt 65535) {
        throw "Port '$Port' liegt ausserhalb des gueltigen TCP-Portbereichs."
    }
    if (-not $DataPath.StartsWith('/')) {
        throw "DataPath '$DataPath' muss ein absoluter Linux-Containerpfad sein."
    }

    $artifactResolution = $null
    $backupPath = if ($BackupSource -match '^https?://') {
        $artifactResolution = Resolve-LabArtifact `
            -Source $BackupSource `
            -ArtifactType backup `
            -ExpectedSha256 $ExpectedSha256 `
            -TrustPolicy interactive-once `
            -NonInteractive:$NonInteractive `
            -RunDirectory $RunDirectory `
            -StateRoot $StateRoot

        if ($artifactResolution.Status -ne 'ARTIFACT_READY') {
            $integrityDetails = if ($artifactResolution.Status -eq 'ARTIFACT_INTEGRITY_MISMATCH') {
                " Erwartet: $($artifactResolution.ExpectedSha256); beobachtet: $($artifactResolution.ObservedSha256)."
            }
            else {
                ''
            }
            throw "$($artifactResolution.Status): $($artifactResolution.Message)$integrityDetails"
        }
        $artifactResolution.Path
    }
    elseif (Test-Path -LiteralPath $BackupSource -PathType Leaf) {
        (Resolve-Path -LiteralPath $BackupSource).Path
    }
    else {
        throw "Backup-Quelle nicht gefunden oder kein direktes File: $BackupSource"
    }

    if ($ExpectedSha256 -and -not $artifactResolution) {
        $actualSha256 = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
            throw "SHA-256-Pruefung fuer Backup '$BackupSource' fehlgeschlagen."
        }
    }

    $restoreTarget = Resolve-LabRestoreContainer `
        -Provider $Provider `
        -ContainerName $ContainerName `
        -Port $Port
    $runtime = $restoreTarget.Provider
    $ContainerName = $restoreTarget.ContainerName

    $containerBackupPath = "/var/opt/mssql/backup/${DatabaseName}.bak"
    Write-LabInfo "Kopiere Backup nach $runtime/${ContainerName}:${containerBackupPath}"

    & $runtime exec $ContainerName mkdir -p /var/opt/mssql/backup 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Backup-Verzeichnis konnte im $runtime-Container nicht erstellt werden."
    }

    & $runtime cp $backupPath "${ContainerName}:${containerBackupPath}" 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Backup-Kopie in den $runtime-Container ist fehlgeschlagen."
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try {
        $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    try {
        Write-LabInfo 'Lese Backup-Metadaten mit RESTORE FILELISTONLY...'
        $escapedContainerBackupPath = $containerBackupPath.Replace("'", "''")
        $fileListQuery = "RESTORE FILELISTONLY FROM DISK = N'$escapedContainerBackupPath';"
        $fileListOutput = sqlcmd `
            -S "$HostName,$Port" `
            -U sa `
            -P $saPlain `
            -C `
            -b `
            -Q $fileListQuery `
            -s '|' `
            -W `
            -h 1 2>&1
        $fileListExitCode = $LASTEXITCODE
        $fileListText = ($fileListOutput | ForEach-Object { [string]$_ }) -join "`n"

        if ($fileListExitCode -ne 0 -or $fileListText -match 'Msg \d+, Level (1[1-9]|[2-9]\d)') {
            throw "FILELISTONLY fehlgeschlagen: $fileListText"
        }

        $moveStatements = @()
        $dataFileIndex = 0
        $logFileIndex = 0

        foreach ($lineValue in @($fileListOutput)) {
            $line = ([string]$lineValue).Trim()
            if ($line -notmatch '^([^|]+)\|[^|]*\|([DL])(?:\||$)') {
                continue
            }

            $logicalName = $Matches[1].Trim()
            $fileType = $Matches[2]
            $escapedLogicalName = $logicalName.Replace("'", "''")

            if ($fileType -eq 'D') {
                $dataFileIndex++
                $extension = if ($dataFileIndex -eq 1) { '.mdf' } else { ".${dataFileIndex}.ndf" }
                $targetFile = "${DataPath}/${DatabaseName}_Data${dataFileIndex}${extension}"
            }
            else {
                $logFileIndex++
                $targetFile = "${DataPath}/${DatabaseName}_Log${logFileIndex}.ldf"
            }

            $escapedTargetFile = $targetFile.Replace("'", "''")
            $moveStatements += "MOVE N'$escapedLogicalName' TO N'$escapedTargetFile'"
        }

        if ($moveStatements.Count -eq 0) {
            throw "Keine logischen Dateien im Backup erkannt. FILELISTONLY-Output: $fileListText"
        }

        $escapedDatabaseName = $DatabaseName.Replace(']', ']]')
        $moveClauses = $moveStatements -join ",`n        "
        $replaceClause = if ($Replace) { ', REPLACE' } else { '' }
        $restoreQuery = @"
RESTORE DATABASE [$escapedDatabaseName]
    FROM DISK = N'$escapedContainerBackupPath'
    WITH $moveClauses$replaceClause;
"@

        Write-LabInfo "RESTORE DATABASE [$DatabaseName]..."
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $restoreOutput = sqlcmd `
            -S "$HostName,$Port" `
            -U sa `
            -P $saPlain `
            -C `
            -b `
            -Q $restoreQuery 2>&1
        $restoreExitCode = $LASTEXITCODE
        $stopwatch.Stop()
        $restoreText = ($restoreOutput | ForEach-Object { [string]$_ }) -join "`n"

        if ($restoreExitCode -ne 0 -or $restoreText -match 'Msg \d+, Level (1[1-9]|[2-9]\d)') {
            return [PSCustomObject]@{
                Success      = $false
                DatabaseName = $DatabaseName
                Provider     = $runtime
                ContainerName = $ContainerName
                Message      = "RESTORE fehlgeschlagen: $restoreText"
                Duration     = $stopwatch.Elapsed
                Files        = $moveStatements.Count
            }
        }

        Write-LabSuccess "Datenbank wiederhergestellt: $DatabaseName ($($moveStatements.Count) Dateien, $($stopwatch.Elapsed.TotalSeconds.ToString('F1'))s)"
        return [PSCustomObject]@{
            Success       = $true
            DatabaseName  = $DatabaseName
            Provider      = $runtime
            ContainerName = $ContainerName
            Message       = 'RESTORE erfolgreich'
            Duration      = $stopwatch.Elapsed
            Files         = $moveStatements.Count
            Artifact      = $artifactResolution
        }
    }
    finally {
        $saPlain = $null
    }
}

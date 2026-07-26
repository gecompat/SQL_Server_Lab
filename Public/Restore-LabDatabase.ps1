<#
.SYNOPSIS
    Stellt eine Datenbank aus einem .bak-Backup in einem Lab wieder her.
.DESCRIPTION
    Unterstuetzt drei Quellen:
    - URL: Download + Cache in StateRoot/cache/
    - Lokaler Pfad: Wird direkt verwendet
    - Container-Volume: Pfad innerhalb des Containers

    Fuehrt RESTORE DATABASE ... WITH MOVE aus, um Datenbankdateien
    auf Container-kompatible Pfade umzuleiten.
.EXAMPLE
    Restore-LabDatabase -Port 14330 -SaPassword $pw -BackupSource 'https://...' -DatabaseName 'AdventureWorks'
.EXAMPLE
    Restore-LabDatabase -Port 14330 -SaPassword $pw -BackupSource 'C:\Backups\AW.bak' -DatabaseName 'AW'
#>
function Restore-LabDatabase {
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][string]$BackupSource,
        [Parameter(Mandatory)][string]$DatabaseName,
        [string]$ContainerName,
        [string]$DataPath = '/var/opt/mssql/data',
        [switch]$Replace,
        [string]$StateRoot
    )

    $ErrorActionPreference = 'Stop'

    $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword))

    # =========================================================================
    # 1. Backup-Datei beschaffen
    # =========================================================================
    $backupPath = $null

    if ($BackupSource -match '^https?://') {
        # URL -> Download + Cache
        Write-LabInfo "Download: $BackupSource"
        $backupPath = Get-LabCachedBackup -Url $BackupSource -StateRoot $StateRoot
        Write-LabSuccess "Cached: $backupPath"
    }
    elseif (Test-Path $BackupSource) {
        # Lokaler Pfad
        $backupPath = Resolve-Path $BackupSource
        Write-LabInfo "Lokales Backup: $backupPath"
    }
    else {
        throw "Backup-Quelle nicht gefunden: $BackupSource"
    }

    # =========================================================================
    # 2. Backup in Container kopieren (falls noetig)
    # =========================================================================
    $containerBackupPath = "/var/opt/mssql/backup/$($DatabaseName).bak"
    $rt = Get-ContainerRuntime

    if ($ContainerName) {
        Write-LabInfo "Kopiere Backup in Container: $ContainerName"
        & $rt exec $ContainerName mkdir -p /var/opt/mssql/backup 2>$null
        & $rt cp $backupPath "${ContainerName}:${containerBackupPath}"
        if ($LASTEXITCODE -ne 0) { throw "Backup-Kopie in Container fehlgeschlagen." }
    }
    else {
        # Container-Name aus Label ermitteln (wenn nicht angegeben)
        $containers = & $rt ps -q --filter "label=sql-server-lab.run-id" 2>$null
        if ($containers) {
            $firstContainer = ($containers | Select-Object -First 1).Trim()
            $inspectJson = & $rt inspect $firstContainer 2>$null | ConvertFrom-Json
            $ContainerName = $inspectJson[0].Name.TrimStart('/')
            Write-LabInfo "Container erkannt: $ContainerName"
            & $rt exec $ContainerName mkdir -p /var/opt/mssql/backup 2>$null
            & $rt cp $backupPath "${ContainerName}:${containerBackupPath}"
            if ($LASTEXITCODE -ne 0) { throw "Backup-Kopie in Container fehlgeschlagen." }
        }
        else {
            throw "Kein Lab-Container gefunden. Bitte -ContainerName angeben."
        }
    }

    # =========================================================================
    # 3. RESTORE FILELISTONLY (logische Dateinamen ermitteln)
    # =========================================================================
    Write-LabInfo "Lese Backup-Metadaten (FILELISTONLY)..."

    $fileListQuery = "RESTORE FILELISTONLY FROM DISK = '$containerBackupPath'"
    $fileListOutput = sqlcmd -S "$HostName,$Port" -U sa -P $saPlain `
        -Q $fileListQuery -s '|' -W -h 1 2>&1
    $fileListText = ($fileListOutput | ForEach-Object { "$_" }) -join "`n"

    if ($LASTEXITCODE -ne 0 -or $fileListText -match 'Msg \d+, Level (1[1-9]|[2-9]\d)') {
        throw "FILELISTONLY fehlgeschlagen: $fileListText"
    }

    # Parse: LogicalName | Type (D=Data, L=Log)
    $moveStatements = @()
    $fileListOutput | ForEach-Object {
        $line = "$_".Trim()
        if ($line -match '^([^|]+)\|[^|]*\|([DL])') {
            $logicalName = $Matches[1].Trim()
            $fileType = $Matches[2]
            $ext = if ($fileType -eq 'D') { '.mdf' } else { '.ldf' }
            # Erstes Data File -> .mdf, weitere -> .ndf
            if ($fileType -eq 'D' -and $moveStatements.Count -gt 0 -and ($moveStatements | Where-Object { $_ -match '\.mdf' })) {
                $ext = '.ndf'
            }
            $targetFile = "${DataPath}/${DatabaseName}_${logicalName}${ext}"
            $moveStatements += "MOVE '$logicalName' TO '$targetFile'"
        }
    }

    if ($moveStatements.Count -eq 0) {
        throw "Keine logischen Dateien im Backup erkannt. FILELISTONLY-Output: $fileListText"
    }

    Write-LabInfo "$($moveStatements.Count) Datei(en) im Backup erkannt."

    # =========================================================================
    # 4. RESTORE DATABASE ... WITH MOVE
    # =========================================================================
    $moveClauses = $moveStatements -join ",`n        "
    $withClause = if ($Replace) { ", REPLACE" } else { "" }

    $restoreQuery = @"
RESTORE DATABASE [$DatabaseName]
    FROM DISK = '$containerBackupPath'
    WITH $moveClauses$withClause;
"@

    Write-LabInfo "RESTORE DATABASE [$DatabaseName]..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $restoreOutput = sqlcmd -S "$HostName,$Port" -U sa -P $saPlain `
        -Q $restoreQuery -b 2>&1
    $restoreText = ($restoreOutput | ForEach-Object { "$_" }) -join "`n"
    $sw.Stop()

    $saPlain = $null

    if ($LASTEXITCODE -ne 0 -or $restoreText -match 'Msg \d+, Level (1[1-9]|[2-9]\d)') {
        return [PSCustomObject]@{
            Success      = $false
            DatabaseName = $DatabaseName
            Message      = "RESTORE fehlgeschlagen: $restoreText"
            Duration     = $sw.Elapsed
            Files        = $moveStatements.Count
        }
    }

    Write-LabSuccess "Datenbank wiederhergestellt: $DatabaseName ($($moveStatements.Count) Dateien, $($sw.Elapsed.TotalSeconds.ToString('F1'))s)"

    return [PSCustomObject]@{
        Success      = $true
        DatabaseName = $DatabaseName
        Message      = "RESTORE erfolgreich"
        Duration     = $sw.Elapsed
        Files        = $moveStatements.Count
    }
}

function Get-LabCachedBackup {
    <#
    .SYNOPSIS Laedt ein Backup von URL herunter und cached es lokal.
    .DESCRIPTION Prueft ob Datei bereits im Cache liegt (Dateiname + Groesse).
                 Cache-Verzeichnis: <StateRoot>/cache/backups/
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $cacheDir = Join-Path $StateRoot 'cache/backups'
    if (-not (Test-Path $cacheDir)) { New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null }

    # Dateiname aus URL
    $fileName = [System.IO.Path]::GetFileName([System.Uri]::new($Url).LocalPath)
    if (-not $fileName) { $fileName = "backup_$(Get-LabTimestamp).bak" }
    $cachedPath = Join-Path $cacheDir $fileName

    # Cache-Hit?
    if (Test-Path $cachedPath) {
        $fileSize = (Get-Item $cachedPath).Length
        Write-LabInfo "Cache-Hit: $fileName ($([Math]::Round($fileSize / 1MB, 1)) MB)"
        return $cachedPath
    }

    # Download
    Write-LabInfo "Downloading: $fileName ..."
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $cachedPath -UseBasicParsing
        $ProgressPreference = 'Continue'
    }
    catch {
        if (Test-Path $cachedPath) { Remove-Item $cachedPath -Force }
        throw "Download fehlgeschlagen: $Url - $_"
    }

    $fileSize = (Get-Item $cachedPath).Length
    Write-LabSuccess "Downloaded: $fileName ($([Math]::Round($fileSize / 1MB, 1)) MB)"
    return $cachedPath
}

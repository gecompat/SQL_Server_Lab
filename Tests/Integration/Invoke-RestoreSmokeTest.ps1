#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft einen echten lokalen Backup-/Restore-Lifecycle in einem Labcontainer.
.DESCRIPTION
    Erzeugt eine kleine synthetische Datenbank, schreibt ein temporaeres Backup
    im Testcontainer, kopiert es auf den Host und stellt es ueber
    Restore-SqlServerLabDatabase run-basiert unter neuem Namen wieder her.
    Es werden keine externen oder persistenten Backupdaten verwendet.
.PARAMETER Provider
    Expliziter Provider docker oder podman.
.PARAMETER Version
    SQL-Server-Version fuer die temporaere Labinstanz. Default: 2022.
.PARAMETER KeepOnFailure
    Behaelt Lab-State und synthetische Fixture bei einem Fehler zur Diagnose.
.EXAMPLE
    .\Tests\Integration\Invoke-RestoreSmokeTest.ps1 -Provider docker
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('docker', 'podman')]
    [string]$Provider,

    [string]$Version = '2022',

    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-server-lab-restore-$([guid]::NewGuid().ToString('N'))"
$stateRoot = Join-Path $testRoot 'state'
$hostBackupPath = Join-Path $testRoot 'synthetic-restore-source.bak'
$containerBackupPath = '/var/opt/mssql/backup/synthetic-restore-source.bak'
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$lab = $null
$testFailed = $false
$saPlain = $null

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Description
    )

    if (-not $Condition) {
        throw $Description
    }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function Invoke-SyntheticSqlcmd {
    param(
        [Parameter(Mandatory)][string]$Query,
        [string]$Database = 'master'
    )

    $output = @(& sqlcmd `
        -S "127.0.0.1,$($lab.Instances[0].Port)" `
        -U sa `
        -P $saPlain `
        -C `
        -b `
        -d $Database `
        -Q $Query `
        -h -1 `
        -W 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd schlug fehl: $(($output | ForEach-Object { [string]$_ }) -join "`n")"
    }
    return @($output)
}

try {
    Write-Host "Restore-Smoke-Test: $Provider / SQL Server $Version" -ForegroundColor Cyan
    if ($Provider -eq 'podman') {
        $null = & (Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1')
    }

    foreach ($command in @($Provider, 'sqlcmd')) {
        Assert-True `
            -Condition ([bool](Get-Command $command -ErrorAction SilentlyContinue)) `
            -Description "Befehl '$command' ist verfuegbar"
    }
    & $Provider info 1>$null 2>$null
    Assert-True -Condition ($LASTEXITCODE -eq 0) -Description "Runtime '$Provider' ist erreichbar"

    New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
    $env:SQL_SERVER_LAB_STATE = $stateRoot
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -ErrorAction Stop

    $passwordToken = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $saPassword = ConvertTo-SecureString "RestoreSmoke_${passwordToken}!Aa7" -AsPlainText -Force
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($saPassword)
    try {
        $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $lab = New-SqlServerLab `
        -Version $Version `
        -Provider $Provider `
        -SaPassword $saPassword `
        -SkipAssessment
    $instance = $lab.Instances[0]

    & $Provider exec $instance.ContainerName mkdir -p /var/opt/mssql/backup 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Temporaeres Backup-Verzeichnis konnte nicht angelegt werden.'
    }

    # CREATE DATABASE und der erste Zugriff auf die neue Datenbank muessen in
    # getrennten Batches laufen: SQL Server kompiliert USE sonst, bevor die
    # vorherige CREATE-Anweisung ausgefuehrt wurde.
    $null = Invoke-SyntheticSqlcmd -Query 'CREATE DATABASE [RestoreSmokeSource];'
    $null = Invoke-SyntheticSqlcmd -Query 'ALTER DATABASE [RestoreSmokeSource] SET RECOVERY SIMPLE;'
    $null = Invoke-SyntheticSqlcmd -Database 'RestoreSmokeSource' -Query @'
CREATE TABLE dbo.SyntheticRows (
    Id int NOT NULL PRIMARY KEY,
    Payload nvarchar(100) NOT NULL
);
INSERT INTO dbo.SyntheticRows (Id, Payload)
VALUES (1, N'alpha'), (2, N'beta'), (3, N'gamma');
'@
    $null = Invoke-SyntheticSqlcmd -Query @"
BACKUP DATABASE [RestoreSmokeSource]
    TO DISK = N'$containerBackupPath'
    WITH INIT, CHECKSUM;
"@

    $copyOutput = @(& $Provider cp "$($instance.ContainerName):$containerBackupPath" $hostBackupPath 2>&1)
    $copyExitCode = $LASTEXITCODE
    if ($copyExitCode -ne 0 -or -not (Test-Path -LiteralPath $hostBackupPath -PathType Leaf)) {
        throw "Synthetisches Backup konnte nicht auf den Host kopiert werden: $($copyOutput -join "`n")"
    }
    Assert-True -Condition ((Get-Item -LiteralPath $hostBackupPath).Length -gt 0) -Description 'Synthetisches Backup ist nicht leer'

    $sha256 = (Get-FileHash -LiteralPath $hostBackupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $null = Invoke-SyntheticSqlcmd -Query @'
ALTER DATABASE [RestoreSmokeSource] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE [RestoreSmokeSource];
'@

    $hashGuardTriggered = $false
    try {
        $null = Restore-SqlServerLabDatabase `
            -RunId $lab.RunId `
            -InstanceId $instance.Id `
            -SaPassword $saPassword `
            -BackupSource $hostBackupPath `
            -ExpectedSha256 ('0' * 64) `
            -DatabaseName 'RestoreHashGuard' `
            -StateRoot $stateRoot
    }
    catch {
        $hashGuardTriggered = $_.Exception.Message -match 'SHA-256-Pruefung'
    }
    Assert-True -Condition $hashGuardTriggered -Description 'Falscher SHA-256 wird vor dem Restore abgelehnt'

    $restoreResult = Restore-SqlServerLabDatabase `
        -RunId $lab.RunId `
        -InstanceId $instance.Id `
        -SaPassword $saPassword `
        -BackupSource $hostBackupPath `
        -ExpectedSha256 $sha256 `
        -DatabaseName 'RestoreSmokeTarget' `
        -StateRoot $stateRoot
    Assert-True -Condition $restoreResult.Success -Description 'Restore-Cmdlet meldet Erfolg'
    Assert-True -Condition ($restoreResult.Provider -eq $Provider) -Description 'Restore verwendet den gespeicherten Provider'
    Assert-True -Condition ($restoreResult.Files -ge 2) -Description 'Daten- und Logdateien wurden per MOVE aufgeloest'

    $verification = Invoke-SyntheticSqlcmd -Query @'
SET NOCOUNT ON;
SELECT state_desc FROM sys.databases WHERE name = N'RestoreSmokeTarget';
SELECT COUNT(*) FROM RestoreSmokeTarget.dbo.SyntheticRows;
SELECT Payload FROM RestoreSmokeTarget.dbo.SyntheticRows WHERE Id = 2;
'@
    $verificationText = ($verification | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join '|'
    Assert-True -Condition ($verificationText -match 'ONLINE') -Description 'Wiederhergestellte Datenbank ist ONLINE'
    Assert-True -Condition ($verificationText -match '(^|\|)3(\||$)') -Description 'Alle drei synthetischen Datensaetze wurden wiederhergestellt'
    Assert-True -Condition ($verificationText -match 'beta') -Description 'Synthetischer Inhalt ist unveraendert'

    $removeResult = Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force
    Assert-True -Condition ($removeResult.Status -eq 'REMOVED') -Description 'Restore-Lab wurde vollstaendig bereinigt'
    $lab = $null
}
catch {
    $testFailed = $true
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    $saPlain = $null
    if ($lab -and -not $KeepOnFailure) {
        try {
            Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force | Out-Null
        }
        catch {
            Write-Host "Cleanup-Fehler: $($_.Exception.Message)" -ForegroundColor Red
            $testFailed = $true
        }
    }

    if (-not $KeepOnFailure -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    $env:SQL_SERVER_LAB_STATE = $previousStateRoot
}

if ($testFailed) {
    exit 1
}

Write-Host 'Restore-Smoke-Test erfolgreich.' -ForegroundColor Green
exit 0

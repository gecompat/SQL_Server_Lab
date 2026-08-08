#Requires -Version 7.2
[CmdletBinding()] param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'

if ($showHelpRequested) {

    Get-Help -Full -Name $PSCommandPath | Out-Host

    return

}
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$toolPath = Join-Path $repoRoot 'Tools/Initialize-SqlServerLabDataRoot.ps1'
$consolePath = Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1'
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-data-root-$([guid]::NewGuid().ToString('N'))"
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Data Root Checks' -ForegroundColor Cyan
try {
    $receipt = & $toolPath -RootPath $temporaryRoot -LabId evaluation-refresh
    Add-CheckResult -Name 'Zentraler Data Root wird ausserhalb von Run-State angelegt' -Success ($receipt.DataRoot -eq $temporaryRoot)
    foreach ($version in @('2019','2022','2025')) {
        Add-CheckResult -Name "SQL-$version-Datendateien sind versionsgetrennt" -Success (
            Test-Path -LiteralPath (Join-Path $temporaryRoot "Labs/evaluation-refresh/Versions/$version/Data")
        )
    }
    Add-CheckResult -Name 'Portable Full-Backup-Ebene wird pro Lab angelegt' -Success (
        Test-Path -LiteralPath (Join-Path $temporaryRoot 'Labs/evaluation-refresh/Backups/Full')
    )
    $rootReadme = Get-Content -LiteralPath (Join-Path $temporaryRoot 'README.md') -Raw -Encoding utf8
    Add-CheckResult -Name 'Lokale Anleitung beschreibt Evaluation-Refresh und Backup/Restore' -Success (
        $rootReadme -match 'Evaluation' -and $rootReadme -match 'Full-Backup' -and $rootReadme -match 'nicht rueckwaertskompatibel|nicht.*Downgrade'
    )
    $second = & $toolPath -RootPath $temporaryRoot -LabId evaluation-refresh
    Add-CheckResult -Name 'Data-Root-Initialisierung ist idempotent' -Success (
        @($second.CreatedDirectories).Count -eq 0 -and @($second.SkippedReadmeFiles).Count -eq 0
    )
    $consoleText = Get-Content -LiteralPath $consolePath -Raw -Encoding utf8
    Add-CheckResult -Name 'Konsolen-Neuanlage bietet den gespeicherten Data Root optional an' -Success (
        $consoleText -match 'Get-LabDataRootDefault' -and
        $consoleText -match 'SQL-System- und Datenbanken persistent im Data Root einbinden' -and
        $consoleText -match '\$newLabArguments\.PersistentData = \$true' -and
        $consoleText -match '\$newLabArguments\.DataRoot = \$defaultDataRoot' -and
        $consoleText -match '\[d\] Persistenten Data Root konfigurieren' -and
        $consoleText -match "'d' \{ Invoke-LabAction -ActionName 'DataRoot' \}" -and
        $consoleText -match 'Set-LabDataRootDefault -DataRoot \$candidate'
    )
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    $persistentDriveContract = & $module {
        param($root)
        $storage = Get-LabPersistentInstanceStorage -DataRoot $root -LabName 'persistent-test' -Provider docker -InstanceId primary -SqlVersion 2025 -Create
        $instance = [PSCustomObject]@{ drives = @() }
        $null = Add-LabPersistentContainerDrive -Instance $instance -Storage $storage
        return $instance.drives
    } $temporaryRoot
    $sqlSystemDrive = @($persistentDriveContract | Where-Object id -eq 'persistent-mssql')[0]
    $backupDrive = @($persistentDriveContract | Where-Object id -eq 'persistent-backups')[0]
    Add-CheckResult -Name 'Container-SQL-System nutzt ein stabiles Runtime-Volume statt eines NTFS-Bind-Mounts' -Success (
        $sqlSystemDrive -and $sqlSystemDrive.containerPath -eq '/var/opt/mssql' -and
        $sqlSystemDrive.volumeName -match '^sql-lab-persistent-' -and -not $sqlSystemDrive.hostPath -and
        $sqlSystemDrive.persistence -eq 'data-root-runtime-volume'
    )
    Add-CheckResult -Name 'Container-Backups bleiben im sichtbaren Data Root eingebunden' -Success (
        $backupDrive -and $backupDrive.containerPath -eq '/var/opt/mssql/backup' -and
        $backupDrive.hostPath -eq (Join-Path $temporaryRoot 'Labs/persistent-test/Instances/docker/primary/SqlServer/2025/backups')
    )
}
catch { Add-CheckResult -Name 'Data-Root-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally { if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force } }
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0




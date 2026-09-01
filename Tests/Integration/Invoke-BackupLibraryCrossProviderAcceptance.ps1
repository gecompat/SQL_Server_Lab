#Requires -Version 7.2
<#
.SYNOPSIS
    Reale PSR-008-Abnahme Docker nach Podman.
.DESCRIPTION
    Erzeugt eine test-eigene Datenbank in Docker, veröffentlicht sie erst nach
    CHECKSUM/VERIFYONLY/Hash in einer temporären Lab_Data-Bibliothek, stellt sie
    in Podman wieder her und vergleicht den deterministischen Inhalt. Linux-
    Container werden nicht als FILESTREAM-fähig ausgegeben.
#>
[CmdletBinding()]
param(
    [string]$Image='mcr.microsoft.com/mssql/server:2025-latest',
    [switch]$KeepOnFailure
)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$hostToolResolution=@(& (Join-Path $repoRoot 'Tools\Initialize-SqlServerLabHostTools.ps1') -Name docker,podman)
$runtimeInvocation=@{}
foreach($resolution in $hostToolResolution){if($resolution.Available){$runtimeInvocation[[string]$resolution.Name]=[string]$resolution.Invocation}}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-psr008-$([Guid]::NewGuid().ToString('N'))"
$dataRoot=Join-Path $testRoot 'Lab_Data'
$token=[Guid]::NewGuid().ToString('N').Substring(0,12)
$sourceContainer="sql-lab-psr008-docker-$token"
$targetContainer="sql-lab-psr008-podman-$token"
$sourceRun=[Guid]::NewGuid().ToString('D')
$targetRun=[Guid]::NewGuid().ToString('D')
$scope=[Guid]::NewGuid().ToString('D')
$saPlain="Psr008_${token}!Aa7"
$password=ConvertTo-SecureString $saPlain -AsPlainText -Force
$previousDataRoot=$env:SQL_SERVER_LAB_DATA_ROOT
$completed=$false
$active=@()
$mutexName=if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}
$mutex=[Threading.Mutex]::new($false,$mutexName)
$mutexAcquired=$false

function Assert-BackupAcceptance { param([bool]$Condition,[string]$Description) if(-not $Condition){throw "BACKUP_LIBRARY_ACCEPTANCE_FAILED: $Description"}; Write-Host "PASS: $Description" -ForegroundColor Green }
function Get-BackupAcceptancePort { $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0); try{$listener.Start();return ([Net.IPEndPoint]$listener.LocalEndpoint).Port}finally{$listener.Stop()} }
function Invoke-BackupRuntime { param([string]$Provider,[string[]]$Arguments,[switch]$AllowFailure) $invocation=[string]$runtimeInvocation[$Provider]; if(-not $invocation){throw "PSR008_${Provider}_NOT_RESOLVED"}; $output=@(& $invocation @Arguments 2>&1); if(-not $AllowFailure -and $LASTEXITCODE -ne 0){throw "PSR008_${Provider}_FAILED: $($output -join ' ')"}; @($output) }
function Start-BackupSqlContainer { param([string]$Provider,[string]$Name,[int]$Port,[string]$RunId) $null=Invoke-BackupRuntime $Provider @('run','-d','--name',$Name,'-p',"127.0.0.1:${Port}:1433",'-e','ACCEPT_EULA=Y','-e',"MSSQL_SA_PASSWORD=$saPlain",'-e','MSSQL_PID=Developer','--label',"sql-server-lab.run-id=$RunId",'--label',"sql-server-lab.scope-id=$scope",$Image); $script:active+=@([PSCustomObject]@{Provider=$Provider;Name=$Name}) }
function Wait-BackupSql { param([int]$Port) $deadline=[DateTime]::UtcNow.AddSeconds(180); do{$out=@(& sqlcmd -S "127.0.0.1,$Port" -U sa -P $saPlain -C -b -Q 'SET NOCOUNT ON; SELECT 1;' -h -1 -W 2>$null); if($LASTEXITCODE -eq 0 -and (($out|ForEach-Object{([string]$_).Trim()}) -contains '1')){return}; Start-Sleep -Seconds 2}while([DateTime]::UtcNow -lt $deadline); throw 'PSR008_SQL_READINESS_TIMEOUT' }
function Invoke-BackupSql { param([int]$Port,[string]$Query,[string]$Database='master') $out=@(& sqlcmd -S "127.0.0.1,$Port" -U sa -P $saPlain -C -b -d $Database -Q "SET NOCOUNT ON; $Query" -h -1 -W 2>&1); if($LASTEXITCODE -ne 0){throw "PSR008_SQLCMD_FAILED: $($out -join ' ')"}; (($out|ForEach-Object{([string]$_).Trim()}|Where-Object{$_ -and $_ -notmatch '^Changed database context'}) -join "`n") }
function Get-TextSha256 { param([string]$Text) ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))).ToLowerInvariant() }

try {
    $mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10)); if(-not $mutexAcquired){throw 'PSR008_RUNTIME_LOCK_TIMEOUT'}
    foreach($provider in @('docker','podman')){Assert-BackupAcceptance ([bool]$runtimeInvocation[$provider]) "Befehl '$provider' wurde zentral aufgelöst"}
    Assert-BackupAcceptance ([bool](Get-Command sqlcmd -ErrorAction SilentlyContinue)) "Befehl 'sqlcmd' ist verfügbar"
    & (Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1') | Out-Host
    foreach($provider in @('docker','podman')){$null=Invoke-BackupRuntime $provider @('info'); $null=Invoke-BackupRuntime $provider @('image','inspect',$Image)}
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    & $module { param($Root) $null=Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId ([Guid]::NewGuid().ToString('D')) -Confirm:$false } $dataRoot
    $env:SQL_SERVER_LAB_DATA_ROOT=$dataRoot

    $sourcePort=Get-BackupAcceptancePort
    Start-BackupSqlContainer docker $sourceContainer $sourcePort $sourceRun
    Wait-BackupSql $sourcePort
    $null=Invoke-BackupSql $sourcePort 'CREATE DATABASE [Psr008Source];'
    $null=Invoke-BackupSql $sourcePort @"
CREATE TABLE dbo.Evidence(Id int NOT NULL PRIMARY KEY, Payload nvarchar(64) NOT NULL);
INSERT dbo.Evidence VALUES(1,N'alpha'),(2,N'beta'),(3,N'psr008-$token');
"@ 'Psr008Source'
    $sourceContent=Invoke-BackupSql $sourcePort "SELECT CONCAT(COUNT_BIG(*),N'|',MAX(CASE WHEN Id=2 THEN Payload END),N'|',MAX(CASE WHEN Id=3 THEN Payload END)) FROM dbo.Evidence;" 'Psr008Source'
    $sourceDigest=Get-TextSha256 $sourceContent
    $backup=Backup-SqlServerLabDatabase -Provider docker -ContainerName $sourceContainer -Port $sourcePort `
        -SaPassword $password -DatabaseName Psr008Source -DataRoot $dataRoot
    Assert-BackupAcceptance ($backup.Status -eq 'BACKUP_REUSABLE' -and -not $backup.HasFileStream) 'Docker-Backup wurde checksum-/hashverifiziert veröffentlicht, ohne FILESTREAM zu behaupten'
    $null=Invoke-BackupRuntime docker @('rm','-f',$sourceContainer) -AllowFailure
    $active=@($active|Where-Object Name -ne $sourceContainer)

    $targetPort=Get-BackupAcceptancePort
    Start-BackupSqlContainer podman $targetContainer $targetPort $targetRun
    Wait-BackupSql $targetPort
    $restore=Restore-SqlServerLabDatabase -Provider podman -ContainerName $targetContainer -Port $targetPort `
        -SaPassword $password -BackupSource $backup.Path -ExpectedSha256 $backup.Sha256 -DatabaseName Psr008Target
    Assert-BackupAcceptance ($restore.Success -and $restore.Provider -eq 'podman') 'Backup wurde durch den zweiten Provider nach VERIFYONLY restauriert'
    $targetContent=Invoke-BackupSql $targetPort "SELECT CONCAT(COUNT_BIG(*),N'|',MAX(CASE WHEN Id=2 THEN Payload END),N'|',MAX(CASE WHEN Id=3 THEN Payload END)) FROM dbo.Evidence;" 'Psr008Target'
    $targetDigest=Get-TextSha256 $targetContent
    Assert-BackupAcceptance ($targetDigest -eq $sourceDigest) 'Sanitisierter Inhaltsdigest stimmt providerübergreifend überein'
    $targetMajor=Invoke-BackupSql $targetPort "SELECT CONVERT(nvarchar(10),SERVERPROPERTY('ProductMajorVersion'));"
    $evidence=& $module { param($Id,$Major,$Digest,$Root) Add-LabDatabaseBackupRestoreVerification -BackupSetId $Id -TargetProvider podman -TargetSqlMajorVersion $Major -ContentSha256 $Digest -FileStreamContentVerified $false -DataRoot $Root } $backup.BackupSetId $targetMajor $targetDigest $dataRoot
    Assert-BackupAcceptance ($evidence.TargetProvider -eq 'podman' -and $evidence.ContentSha256 -eq $sourceDigest) 'Cross-Provider-Evidence wurde ohne Host-, Port- oder Containeridentität registriert'
    $registry=Get-Content -LiteralPath $backup.RegistryPath -Raw
    Assert-BackupAcceptance ($registry -notmatch [regex]::Escape($saPlain) -and $registry -notmatch "$sourcePort|$targetPort|$sourceContainer|$targetContainer") 'Bibliotheksreceipt ist sanitisiert'
    $completed=$true
}
finally {
    foreach($item in @($active)){$null=Invoke-BackupRuntime $item.Provider @('rm','-f',$item.Name) -AllowFailure}
    if($completed -or -not $KeepOnFailure){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
    $env:SQL_SERVER_LAB_DATA_ROOT=$previousDataRoot
    $saPlain=$null
    if($mutexAcquired){$mutex.ReleaseMutex()}
    $mutex.Dispose()
}
Write-Host 'BACKUP LIBRARY CROSS-PROVIDER ACCEPTANCE: PASS' -ForegroundColor Green

#Requires -Version 7.2
<#
.SYNOPSIS
Erstellt eine automatisierte Windows-Server-2003-/SQL-Server-2005-Abnahmeumgebung.

.DESCRIPTION
Erzeugt aus der versiegelten Windows-Server-2003-Evaluation-Vorlage einen
frischen Generation-1-Child, schließt Mini-Setup unbeaufsichtigt ab, setzt das
deutsche Anmeldelayout und eine reservierte Adresse im isolierten Labnetz.
Anschließend werden SQL Server 2005 Evaluation und seine Voraussetzungen ohne
Gast-PowerShell installiert und Create/Insert/Backup/Restore/Drop geprüft.

Windows Server 2003 wird nicht als aktiviert ausgegeben. Der Lauf ist nur
zulässig, solange der Gast eine positive Evaluation-/Aktivierungs-Gnadenfrist
meldet. Erfolgreiche VMs bleiben als TESTS_PASSED-Umgebung erhalten.

.PARAMETER SqlVersion
Derzeit ausschließlich SQL Server 2005.

.PARAMETER ResultPath
Optionaler JSON-Nachweis ohne Kennwort oder Credential.

.PARAMETER ShowHelp
Zeigt diese Hilfe ohne Mutation.
#>
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param(
    [ValidateSet('2005')][string]$SqlVersion,
    [string]$MediaRoot='D:\Lab1_Base',
    [string]$DataRoot,
    [string]$StateRoot,
    [string]$ParentVhdPath='D:\Lab1_Base\WindowsServer\2003\Eval\VHDX\WindowsServer2003Enterprise-Eval-SP2-x86-Gen1-Sysprep.vhdx',
    [string]$EvaluationIsoPath='D:\Lab1_Base\WindowsServer\2003\Eval\ISO\WindowsServer2003Enterprise-Evaluation.iso',
    [string]$IntegrationServicesIsoPath='D:\Lab1_Base\WindowsServer\2003\Eval\IntegrationServices\Hyper-V-Integration-Services-6.3.9600.16384-vmguest.iso',
    [string]$SqlMediaPath='SQL/2005/Evaluation/ISO/SQL2005_Evaluation.iso',
    [ValidateRange(1024,4096)][int]$MemoryStartupMB=2048,
    [ValidateRange(1,4)][int]$ProcessorCount=2,
    [ValidateRange(300,3600)][int]$OobeTimeoutSeconds=1200,
    [ValidateRange(600,10800)][int]$SetupTimeoutSeconds=7200,
    [ValidateRange(120,1800)][int]$ReadinessTimeoutSeconds=900,
    [string]$ResultPath,
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$RemainingArgs
)

$ErrorActionPreference='Stop'
$showHelpRequested=$ShowHelp.IsPresent -or @($RemainingArgs)-contains'/?' -or
    @($RemainingArgs)-contains'-?' -or @($RemainingArgs)-contains'-h' -or
    @($RemainingArgs)-contains'--help'
if($showHelpRequested){Get-Help -Full -Name $PSCommandPath|Out-Host;return}
if(-not $SqlVersion){throw 'WS2003_SQL_ACCEPTANCE_SQL_VERSION_REQUIRED'}

$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
if(-not $StateRoot){$StateRoot=& $module {Get-LabStateRoot}}
if(-not $DataRoot){$DataRoot=& $module {Get-LabDataRootDefault}}
if(-not $DataRoot){$DataRoot='D:\Lab1_Data'}
$StateRoot=[IO.Path]::GetFullPath($StateRoot)
$DataRoot=[IO.Path]::GetFullPath($DataRoot)
$sqlSetupContractVersion='sql2005-setup-v9'
$sqlCompletionServiceName='SqlLabCompleteV9'
$sqlResumeTaskName='SqlLabSql2005V9'

$plan=[pscustomobject]@{
    Status='PLANNED';SqlVersion='2005';OperatingSystemId='windows-server-2003'
    SqlMediaRelativePath=$SqlMediaPath.Replace('\','/')
    GuestControl='offline-startup-wmi-read';ActivationState='OOB_GRACE'
    CredentialDisclosed=$false;PasswordDisclosed=$false
}
if(-not $PSCmdlet.ShouldProcess('Windows Server 2003 / SQL Server 2005','frischen Child erstellen und vollständigen SQL-Test ausführen')){
    return $plan
}

$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=[Security.Principal.WindowsPrincipal]::new($identity)
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    if($env:SQL_SERVER_LAB_ELEVATED_CHILD-eq'1'){throw 'WS2003_SQL_ACCEPTANCE_REQUIRES_ELEVATED_RUNNER'}
    $forward=[ordered]@{
        SqlVersion=$SqlVersion;MediaRoot=$MediaRoot;DataRoot=$DataRoot;StateRoot=$StateRoot
        ParentVhdPath=$ParentVhdPath;EvaluationIsoPath=$EvaluationIsoPath
        IntegrationServicesIsoPath=$IntegrationServicesIsoPath;SqlMediaPath=$SqlMediaPath
        MemoryStartupMB=$MemoryStartupMB;ProcessorCount=$ProcessorCount
        OobeTimeoutSeconds=$OobeTimeoutSeconds;SetupTimeoutSeconds=$SetupTimeoutSeconds
        ReadinessTimeoutSeconds=$ReadinessTimeoutSeconds
    }
    if($ResultPath){$forward.ResultPath=$ResultPath}
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($forward|ConvertTo-Json -Depth 4 -Compress)))
    $escapedScript=$PSCommandPath.Replace("'","''")
    $command=@"
`$ErrorActionPreference='Stop'
`$env:SQL_SERVER_LAB_ELEVATED_CHILD='1'
`$json=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload'))|ConvertFrom-Json
`$arguments=@{}
foreach(`$property in `$json.PSObject.Properties){`$arguments[`$property.Name]=`$property.Value}
& '$escapedScript' @arguments -Confirm:`$false
"@
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $pwsh=(Get-Command pwsh.exe -ErrorAction Stop).Source
    try{Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @('-NoLogo','-NoProfile','-EncodedCommand',$encoded) -ErrorAction Stop}
    catch{throw "WS2003_SQL_ACCEPTANCE_ELEVATION_START_FAILED: $($_.Exception.Message)"}
    return [pscustomobject]@{Status='ELEVATION_STARTED';SqlVersion='2005';ResultPath=$ResultPath;CredentialDisclosed=$false;PasswordDisclosed=$false}
}

Import-Module Hyper-V -ErrorAction Stop

function Save-Ws2003SqlBuildState {
    param([Parameter(Mandatory)]$Build,[Parameter(Mandatory)][string]$Reason,[string]$State)
    if($State){
        $Build.state=$State
        $Build.stateHistory=@($Build.stateHistory)+[pscustomobject]@{state=$State;timestamp=[datetime]::UtcNow.ToString('o');reason=$Reason}
        if($Build.PSObject.Properties['lastError']){$Build.lastError=$null}
    }
    if($Reason){$Build.lastReason=$Reason}
    & $module {param($Directory,$Document) Write-HyperVSqlImageBuildState -BuildDirectory $Directory -State $Document} $Build.BuildDirectory $Build
    return & $module {param($Id,$Root) Get-HyperVSqlImageBuildPlan -BuildId $Id -StateRoot $Root} $Build.buildId $StateRoot
}

function Test-Ws2003SqlFileBinding {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Binding,[Parameter(Mandatory)][string]$ErrorCode)
    $item=Get-Item -LiteralPath $Path -ErrorAction Stop
    if([long]$item.Length-ne[long]$Binding.lengthBytes -or
        $item.LastWriteTimeUtc-ne([datetime]$Binding.lastWriteTimeUtc).ToUniversalTime()){
        throw $ErrorCode
    }
}

function Mount-Ws2003SqlChildVolume {
    param([Parameter(Mandatory)][string]$Path)
    $mounted=Mount-VHD -Path $Path -NoDriveLetter -Passthru -ErrorAction Stop
    $mountRoot=Join-Path ([IO.Path]::GetTempPath()) ('SqlServerLab-VhdMount-'+[guid]::NewGuid().ToString('N'))
    $accessPath=$null
    try{
        $disk=$mounted|Get-Disk -ErrorAction Stop
        $partition=Get-Partition -DiskNumber $disk.Number -ErrorAction Stop|Where-Object{$_.Size-ge1GB-and$_.Type-ne'Reserved'}|Sort-Object Size -Descending|Select-Object -First 1
        if(-not$partition){throw 'WS2003_SQL_OFFLINE_PARTITION_NOT_FOUND'}
        New-Item -Path $mountRoot -ItemType Directory -Force|Out-Null
        $accessPath=$mountRoot.TrimEnd('\')+'\'
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath $accessPath -ErrorAction Stop|Out-Null
        return [pscustomobject]@{Path=$Path;DiskNumber=$disk.Number;PartitionNumber=$partition.PartitionNumber;RootPath=$accessPath;AccessPath=$accessPath}
    }catch{
        if($accessPath){Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath $accessPath -ErrorAction SilentlyContinue}
        Dismount-VHD -Path $Path -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $mountRoot -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Dismount-Ws2003SqlChildVolume {
    param([Parameter(Mandatory)]$Mount)
    try{
        if($Mount.AccessPath){Remove-PartitionAccessPath -DiskNumber $Mount.DiskNumber -PartitionNumber $Mount.PartitionNumber -AccessPath $Mount.AccessPath -ErrorAction Stop}
    }finally{
        Dismount-VHD -Path $Mount.Path -ErrorAction Stop
        if($Mount.AccessPath){Remove-Item -LiteralPath ([string]$Mount.AccessPath).TrimEnd('\') -Force -ErrorAction SilentlyContinue}
    }
}

function Set-Ws2003SqlOfflineJob {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$BuildId)
    $mount=$null
    try{
        $mount=Mount-Ws2003SqlChildVolume -Path $Path;$root=$mount.RootPath;$jobRoot=Join-Path $root 'SQLServerLab'
        [IO.Directory]::CreateDirectory($jobRoot)|Out-Null
        $guestRoot='C:\SQLServerLab';$sqlFile="$guestRoot\Sql2005Acceptance.sql";$backup="$guestRoot\SQLLAB_ACCEPTANCE.bak"
        $sql=@"
SET NOCOUNT ON;
IF DB_ID('SQLLAB_ACCEPTANCE') IS NOT NULL BEGIN ALTER DATABASE SQLLAB_ACCEPTANCE SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE SQLLAB_ACCEPTANCE; END;
CREATE DATABASE SQLLAB_ACCEPTANCE;
GO
CREATE TABLE SQLLAB_ACCEPTANCE.dbo.Probe(Id int NOT NULL PRIMARY KEY, Value varchar(32) NOT NULL);
INSERT SQLLAB_ACCEPTANCE.dbo.Probe VALUES(1,'ok');
IF (SELECT COUNT(*) FROM SQLLAB_ACCEPTANCE.dbo.Probe WHERE Id=1 AND Value='ok') <> 1 RAISERROR('INSERT_SELECT_FAILED',16,1);
BACKUP DATABASE SQLLAB_ACCEPTANCE TO DISK='$backup' WITH INIT,CHECKSUM;
RESTORE VERIFYONLY FROM DISK='$backup' WITH CHECKSUM;
ALTER DATABASE SQLLAB_ACCEPTANCE SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE SQLLAB_ACCEPTANCE;
"@
        Set-Content -LiteralPath (Join-Path $jobRoot 'Sql2005Acceptance.sql') -Value $sql -Encoding ascii -NoNewline
        $command=@"
@echo off
setlocal EnableExtensions
if not exist $guestRoot mkdir $guestRoot
sc.exe delete $sqlCompletionServiceName >nul 2>&1
schtasks.exe /Create /TN $sqlResumeTaskName /TR "$guestRoot\Sql2005Acceptance.cmd" /SC ONSTART /RU SYSTEM /F >nul 2>&1
set DVD=
for /f "tokens=2 delims==" %%I in ('wmic logicaldisk where "VolumeName='SQLEVAL'" get DeviceID /value ^| find "="') do set DVD=%%I
if not defined DVD goto MEDIA_FAILED
if exist $guestRoot\netfx.done goto SQL_SETUP
"%DVD%\SQL Server x86\Servers\redist\2.0\dotnetfx.exe" /q:a /c:"install /q"
set NETFX_EXIT=%ERRORLEVEL%
if not "%NETFX_EXIT%"=="0" if not "%NETFX_EXIT%"=="3010" goto NETFX_FAILED
>$guestRoot\netfx.done echo %NETFX_EXIT%
if "%NETFX_EXIT%"=="3010" goto RESTART
:SQL_SETUP
if exist $guestRoot\sqlsetup.done goto WAIT_SQL
if not exist "%ProgramFiles%\Microsoft SQL Server\90\Tools\Binn\sqlcmd.exe" goto RUN_SQL_SETUP
sc.exe query MSSQLSERVER | find "RUNNING" >nul 2>&1
if errorlevel 1 goto RUN_SQL_SETUP
>$guestRoot\sqlsetup.done echo EXISTING_READY
goto WAIT_SQL
:RUN_SQL_SETUP
"%DVD%\SQL Server x86\Servers\setup.exe" /qn ADDLOCAL=SQL_Engine,Client_Components INSTANCENAME=MSSQLSERVER SQLACCOUNT="NT AUTHORITY\SYSTEM" SQLAUTOSTART=1 AGTACCOUNT="NT AUTHORITY\SYSTEM" AGTAUTOSTART=0 SQLBROWSERACCOUNT="NT AUTHORITY\SYSTEM" SQLBROWSERAUTOSTART=0 DISABLENETWORKPROTOCOLS=1 ERRORREPORTING=0 SQMREPORTING=0
set SETUP_EXIT=%ERRORLEVEL%
if not "%SETUP_EXIT%"=="0" if not "%SETUP_EXIT%"=="3010" goto SETUP_FAILED
>$guestRoot\sqlsetup.done echo %SETUP_EXIT%
if "%SETUP_EXIT%"=="3010" goto RESTART
:WAIT_SQL
set WAIT_COUNT=0
:WAIT_SQL_LOOP
sc.exe query MSSQLSERVER | find "RUNNING" >nul 2>&1
if not errorlevel 1 goto SQL_READY
set /a WAIT_COUNT+=1
if %WAIT_COUNT% GEQ 180 goto SQL_SERVICE_FAILED
ping.exe -n 6 127.0.0.1 >nul
goto WAIT_SQL_LOOP
:SQL_READY
"%ProgramFiles%\Microsoft SQL Server\90\Tools\Binn\sqlcmd.exe" -E -S localhost -b -h -1 -W -Q "SET NOCOUNT ON;SELECT CONVERT(varchar(128),SERVERPROPERTY('ProductVersion'))+'|'+CONVERT(varchar(128),SERVERPROPERTY('Edition'))+'|'+CONVERT(varchar(10),(SELECT COUNT(*) FROM sys.databases WHERE name IN ('master','model','msdb','tempdb')))" -o "$guestRoot\query.txt"
if errorlevel 1 goto SQL_QUERY_FAILED
"%ProgramFiles%\Microsoft SQL Server\90\Tools\Binn\sqlcmd.exe" -E -S localhost -b -i "$sqlFile" -o "$guestRoot\acceptance.txt"
if errorlevel 1 goto SQL_ACCEPTANCE_FAILED
for /f "tokens=1-3 delims=|" %%A in ($guestRoot\query.txt) do set PRODUCT_VERSION=%%A&set EDITION=%%B&set DATABASE_COUNT=%%C
if not "%DATABASE_COUNT%"=="4" goto SQL_QUERY_FAILED
del /f /q "$backup" >nul 2>&1
>$guestRoot\sql2005-result.tmp echo status=COMPLETED
>>$guestRoot\sql2005-result.tmp echo setupExitCode=0
>>$guestRoot\sql2005-result.tmp echo productVersion=%PRODUCT_VERSION%
>>$guestRoot\sql2005-result.tmp echo edition=%EDITION%
>>$guestRoot\sql2005-result.tmp echo databaseCount=%DATABASE_COUNT%
>>$guestRoot\sql2005-result.tmp echo databaseCreate=True
>>$guestRoot\sql2005-result.tmp echo insertSelect=True
>>$guestRoot\sql2005-result.tmp echo backupChecksum=True
>>$guestRoot\sql2005-result.tmp echo restoreVerifyOnly=True
>>$guestRoot\sql2005-result.tmp echo databaseDrop=True
>>$guestRoot\sql2005-result.tmp echo backupRemoved=True
move /y $guestRoot\sql2005-result.tmp $guestRoot\sql2005-result.ini >nul
sc.exe create $sqlCompletionServiceName binPath= "%SystemRoot%\System32\cmd.exe /c exit 0" start= demand >nul 2>&1
goto FINISH
:RESTART
shutdown.exe -r -t 5 -f
exit /b 0
:MEDIA_FAILED
set JOB_ERROR=SQL2005_MEDIA_NOT_FOUND
goto WRITE_FAILURE
:NETFX_FAILED
set JOB_ERROR=DOTNETFX_EXIT_%NETFX_EXIT%
goto WRITE_FAILURE
:SETUP_FAILED
set JOB_ERROR=SQL2005_SETUP_EXIT_%SETUP_EXIT%
goto WRITE_FAILURE
:SQL_SERVICE_FAILED
set JOB_ERROR=SQL_SERVICE_TIMEOUT
goto WRITE_FAILURE
:SQL_QUERY_FAILED
set JOB_ERROR=SQL_QUERY_FAILED
goto WRITE_FAILURE
:SQL_ACCEPTANCE_FAILED
set JOB_ERROR=SQL_ACCEPTANCE_FAILED
:WRITE_FAILURE
>$guestRoot\sql2005-result.tmp echo status=FAILED
>>$guestRoot\sql2005-result.tmp echo errorCode=%JOB_ERROR%
move /y $guestRoot\sql2005-result.tmp $guestRoot\sql2005-result.ini >nul
sc.exe create $sqlCompletionServiceName binPath= "%SystemRoot%\System32\cmd.exe /c exit 1" start= demand >nul 2>&1
:FINISH
schtasks.exe /Delete /TN $sqlResumeTaskName /F >nul 2>&1
del /f /q C:\Windows\System32\GroupPolicy\Machine\Scripts\scripts.ini >nul 2>&1
shutdown.exe -s -t 10 -f
exit /b 0
"@
        Set-Content -LiteralPath (Join-Path $jobRoot 'Sql2005Acceptance.cmd') -Value $command -Encoding ascii -NoNewline
        foreach($name in @('sql2005-result.ini','sql2005-result.tmp','sqlsetup.done')){Remove-Item -LiteralPath (Join-Path $jobRoot $name) -Force -ErrorAction SilentlyContinue}
        $policy=Join-Path $root 'Windows\System32\GroupPolicy\Machine\Scripts'
        Remove-Item -LiteralPath (Join-Path $policy 'scripts.ini') -Force -ErrorAction SilentlyContinue
    }finally{if($mount){Dismount-Ws2003SqlChildVolume -Mount $mount}}
}

function Start-Ws2003SqlStagedJob {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [ValidateRange(30,300)][int]$TimeoutSeconds=180
    )
    $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds);$lastFailure=$null
    do{
        try{
            $scope=& $module {param($GuestAddress,$GuestCredential) Connect-HyperVLegacyWindowsWmiScope -Address $GuestAddress -Namespace 'root\cimv2' -Credential $GuestCredential} $Address $Credential
            $process=[Management.ManagementClass]::new($scope,[Management.ManagementPath]::new('Win32_Process'),$null)
            $input=$process.GetMethodParameters('Create')
            $input['CommandLine']='C:\Windows\System32\cmd.exe /d /c C:\SQLServerLab\Sql2005Acceptance.cmd'
            $output=$process.InvokeMethod('Create',$input,$null)
            if([uint32]$output['ReturnValue']-ne0){throw "WIN32_PROCESS_CREATE_$($output['ReturnValue'])"}
            return [uint32]$output['ProcessId']
        }catch{$lastFailure=$_.Exception.Message;Start-Sleep -Seconds 5}
    }while([datetime]::UtcNow-lt$deadline)
    throw "WS2003_SQL_WMI_START_FAILED: $lastFailure"
}

function Get-Ws2003SqlOfflineReceipt {
    param([Parameter(Mandatory)][string]$Path)
    $mount=$null
    try{
        $mount=Mount-Ws2003SqlChildVolume -Path $Path;$receipt=Join-Path $mount.RootPath 'SQLServerLab\sql2005-result.ini'
        if(-not(Test-Path -LiteralPath $receipt -PathType Leaf)){throw 'WS2003_SQL_OFFLINE_RECEIPT_MISSING'}
        $result=ConvertFrom-StringData -StringData(Get-Content -LiteralPath $receipt -Raw -Encoding ascii)
        if([string]$result.status-eq'FAILED'){
            $logRoot=Join-Path $mount.RootPath 'Program Files\Microsoft SQL Server\90\Setup Bootstrap\LOG'
            $diagnostic=@()
            if(Test-Path -LiteralPath $logRoot -PathType Container){
                $logFiles=@(Get-ChildItem -LiteralPath $logRoot -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Name-match'(?i)summary|detail|core|error'}|Sort-Object LastWriteTime -Descending|Select-Object -First 12)
                foreach($file in $logFiles){
                    $matches=@(Select-String -LiteralPath $file.FullName -Pattern 'error|failed|failure|return value 3|28006' -CaseSensitive:$false -ErrorAction SilentlyContinue|Select-Object -Last 8)
                    foreach($match in $matches){$diagnostic+=(("{0}: {1}"-f$file.Name,$match.Line).Trim())}
                }
            }
            $acceptanceLog=Join-Path $mount.RootPath 'SQLServerLab\acceptance.txt'
            if(Test-Path -LiteralPath $acceptanceLog -PathType Leaf){
                foreach($line in @(Get-Content -LiteralPath $acceptanceLog -Encoding Default -ErrorAction SilentlyContinue|Select-Object -Last 24)){
                    if(-not[string]::IsNullOrWhiteSpace($line)){$diagnostic+=("acceptance.txt: $($line.Trim())")}
                }
            }
            $result['diagnostic']=(@($diagnostic|Select-Object -Unique|Select-Object -Last 24)-join' | ')
        }
        return $result
    }finally{if($mount){Dismount-Ws2003SqlChildVolume -Mount $mount}}
}

try{
    $templateSecretRoot=Join-Path $StateRoot 'legacy-templates\windows-server-2003'
    $templatePassword=& $module {param($Path) Get-LabSecret -Path $Path -Name 'administrator-password'} $templateSecretRoot
    if(-not $templatePassword){
        $templateCredential=Get-Credential -UserName Administrator -Message 'Einmaliges Administrator-Kennwort der versiegelten Windows-Server-2003-Vorlage'
        if(-not $templateCredential){throw 'WS2003_SQL_ACCEPTANCE_TEMPLATE_CREDENTIAL_CANCELLED'}
        if([string]$templateCredential.GetNetworkCredential().UserName-ne'Administrator'){throw 'WS2003_SQL_ACCEPTANCE_TEMPLATE_ADMINISTRATOR_REQUIRED'}
        $templatePassword=$templateCredential.Password
        & $module {param($Path,$Secret) Save-LabSecret -Path $Path -Name 'administrator-password' -Secret $Secret} $templateSecretRoot $templatePassword
    }
    $active=@(& $module {
        param($Root)
        @(Get-HyperVSqlImageBuildPlans -StateRoot $Root|Where-Object{
            [string]$_.provisioningMode-eq'windows-server-2003-legacy-child' -and
            [string]$_.sql.version-eq'2005' -and [string]$_.state-ne'CLEANED_UP'
        })
    } $StateRoot)
    if($active.Count-gt1){throw "WS2003_SQL_ACCEPTANCE_BUILD_AMBIGUOUS: $($active.Count)"}
    $build=if($active.Count-eq1){$active[0]}else{$null}

    if(-not $build){
        $resolvedMediaRoot=(Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
        $resolvedParent=(Resolve-Path -LiteralPath $ParentVhdPath -ErrorAction Stop).Path
        $resolvedEvaluation=(Resolve-Path -LiteralPath $EvaluationIsoPath -ErrorAction Stop).Path
        $resolvedIntegration=(Resolve-Path -LiteralPath $IntegrationServicesIsoPath -ErrorAction Stop).Path
        if([IO.Path]::IsPathRooted($SqlMediaPath)-or$SqlMediaPath-match'(^|[\\/])\.\.([\\/]|$)'){
            throw 'WS2003_SQL_ACCEPTANCE_MEDIA_PATH_INVALID'
        }
        $resolvedSql=(Resolve-Path -LiteralPath (Join-Path $resolvedMediaRoot $SqlMediaPath) -ErrorAction Stop).Path
        $sqlRoot=(Resolve-Path -LiteralPath (Join-Path $resolvedMediaRoot 'SQL') -ErrorAction Stop).Path.TrimEnd('\')+'\'
        if(-not $resolvedSql.StartsWith($sqlRoot,[StringComparison]::OrdinalIgnoreCase)){
            throw 'WS2003_SQL_ACCEPTANCE_MEDIA_PATH_INVALID'
        }
        $sidecar=Join-Path (Join-Path $resolvedMediaRoot 'Hashes') ($SqlMediaPath.Replace('/','\')+'.sha256')
        $sidecarText=(Get-Content -LiteralPath $sidecar -Raw -Encoding utf8).Trim()
        if($sidecarText-notmatch'^(?<sha>[A-Fa-f0-9]{64})\s{2}(?<relative>.+)$' -or
            $Matches.relative.Replace('\','/')-notin@($SqlMediaPath.Replace('\','/'),[IO.Path]::GetFileName($resolvedSql))){
            throw 'WS2003_SQL_ACCEPTANCE_MEDIA_HASH_BINDING_INVALID'
        }
        $sqlSha=$Matches.sha.ToLowerInvariant()
        $actualSqlSha=(Get-FileHash -LiteralPath $resolvedSql -Algorithm SHA256).Hash.ToLowerInvariant()
        if($actualSqlSha-ne$sqlSha){throw 'WS2003_SQL_ACCEPTANCE_MEDIA_INTEGRITY_MISMATCH'}

        $buildId=[guid]::NewGuid().ToString('D');$scopeId=[guid]::NewGuid().ToString('D')
        $buildDirectory=Join-Path (Join-Path $StateRoot 'image-builds\hyperv-sql') $buildId
        New-Item -Path $buildDirectory -ItemType Directory -Force|Out-Null
        $short=$buildId.Substring(0,8);$vmName="sql-lab-sql-image-2005-$short"
        $vmRoot=Join-Path (Join-Path (Join-Path $DataRoot 'HyperV\Builds') $short) $vmName
        $timestamp=[datetime]::UtcNow.ToString('o')
        $files=[ordered]@{}
        foreach($definition in @(
            @{Name='parentVhd';Path=$resolvedParent},@{Name='evaluationIso';Path=$resolvedEvaluation},
            @{Name='integrationIso';Path=$resolvedIntegration},@{Name='sqlIso';Path=$resolvedSql}
        )){
            $item=Get-Item -LiteralPath $definition.Path
            $files[$definition.Name]=[pscustomobject]@{path=$item.FullName;lengthBytes=[long]$item.Length;lastWriteTimeUtc=$item.LastWriteTimeUtc.ToString('o')}
        }
        $files.sqlIso|Add-Member -NotePropertyName sha256 -NotePropertyValue $sqlSha
        & $module {param($Path,$Document) Write-LabArtifactJsonAtomic -Path $Path -InputObject $Document} `
            (Join-Path $buildDirectory 'build-local.json') ([pscustomobject]@{files=$files;vmRoot=$vmRoot;verifiedAt=$timestamp})
        $build=[pscustomobject]@{
            BuildDirectory=$buildDirectory;contractVersion='2';buildKind='hyperv-nt5-sql-acceptance'
            buildId=$buildId;scopeId=$scopeId;provisioningMode='windows-server-2003-legacy-child'
            displayName='SQL Server 2005 Acceptance';state='MEDIA_VERIFIED'
            stateHistory=@([pscustomobject]@{state='MEDIA_VERIFIED';timestamp=$timestamp;reason='SQL-ISO SHA-256 verifiziert und Legacy-Medien gebunden'})
            parentArtifact=[pscustomobject]@{
                artifactId='legacy-hyperv-template-7566d0627bf88db4e937948bda159d09afe4dc9b140a20682a7b616919490872'
                sha256='7566d0627bf88db4e937948bda159d09afe4dc9b140a20682a7b616919490872'
                operatingSystem=[pscustomobject]@{id='windows-server-2003';version='2003-sp2';edition='enterprise-evaluation';installationType='desktop-experience';language='en-US';architecture='x86'}
                platform=[pscustomobject]@{provider='hyperv';generation=1;guestControl='legacy-wmi'}
                license=[pscustomobject]@{type='evaluation';activation='required';productionUseAllowed=$false}
            }
            sql=[pscustomobject]@{version='2005';mediaEdition='Evaluation';edition='Evaluation';features=@('SQLENGINE');mediaSha256=$sqlSha;setupBuild=$null;setupContractVersion=$sqlSetupContractVersion;mediaTrust='COMMUNITY_UNVERIFIED_USER_APPROVED_FOR_LAB'}
            builder=[pscustomobject]@{vmName=$vmName;vmRootKey=$short;vmCreated=$false;networkAttached=$false}
            labNetwork=$null;licenseEvidence=$null;testEnvironment=$null;acceptanceEvidence=$null
            createdAt=$timestamp;updatedAt=$timestamp;lastReason='initialisiert'
        }
        $build=Save-Ws2003SqlBuildState -Build $build -Reason 'Legacy-Abnahmebuild initialisiert'
        & $module {param($Path,$Secret) Save-LabSecret -Path $Path -Name 'guest-administrator-password' -Secret $Secret} $build.BuildDirectory $templatePassword
    }

    $localPath=Join-Path $build.BuildDirectory 'build-local.json'
    if(-not(Test-Path -LiteralPath $localPath -PathType Leaf)){throw 'WS2003_SQL_ACCEPTANCE_LOCAL_BINDING_MISSING'}
    $local=Get-Content -LiteralPath $localPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 20
    foreach($name in @('parentVhd','evaluationIso','integrationIso','sqlIso')){
        Test-Ws2003SqlFileBinding -Path ([string]$local.files.$name.path) -Binding $local.files.$name -ErrorCode "WS2003_SQL_ACCEPTANCE_${name}_CHANGED"
    }
    if([string]$local.files.sqlIso.sha256-ne[string]$build.sql.mediaSha256){throw 'WS2003_SQL_ACCEPTANCE_MEDIA_BINDING_CHANGED'}
    $expectedParentArtifactId="legacy-hyperv-template-$([string]$build.parentArtifact.sha256)"
    if([string]$build.parentArtifact.artifactId-ne$expectedParentArtifactId){
        $build.parentArtifact.artifactId=$expectedParentArtifactId
        $build=Save-Ws2003SqlBuildState -Build $build -Reason 'Legacy-Parentidentität an den VHDX-SHA-256-Vertrag gebunden'
    }
    $password=& $module {param($Path) Get-LabSecret -Path $Path -Name 'guest-administrator-password'} $build.BuildDirectory
    if(-not $password){throw 'WS2003_SQL_ACCEPTANCE_GUEST_PASSWORD_MISSING'}
    $credential=[PSCredential]::new('Administrator',$password)

    if([string]$build.state-eq'TESTS_PASSED'){$ready=$build.testEnvironment;$acceptance=$build.acceptanceEvidence}
    else{
        $network=& $module {Ensure-LabHyperVNetwork}
        $lease=& $module {param($Network,$Run,$Scope,$Root) Reserve-LabHyperVNetworkAddress -Network $Network -RunId $Run -ScopeId $Scope -InstanceId 'sql-image-2005' -StateRoot $Root} $network $build.buildId $build.scopeId $StateRoot
        if(-not $build.labNetwork){
            $build.labNetwork=[pscustomobject]@{name=[string]$network.Name;subnet=[string]$network.Subnet;prefixLength=[int]$network.PrefixLength;address=[string]$lease.address;leaseId=[string]$lease.leaseId}
            $build.builder.networkAttached=$true
            $build=Save-Ws2003SqlBuildState -Build $build -Reason 'Labnetzadresse reserviert'
        }
        $vmName=[string]$build.builder.vmName;$childPath=Join-Path ([string]$local.vmRoot) 'os.vhdx'
        if([string]$build.state-eq'MEDIA_VERIFIED'){
            Write-Host "[INFO]    Child: erzeuge $vmName aus versiegelter Windows-Server-2003-Vorlage"
            $child=& (Join-Path $PSScriptRoot 'New-WindowsServer2003LegacyChild.ps1') `
                -VmName $vmName -VmRoot ([string]$local.vmRoot) -ParentVhdPath ([string]$local.files.parentVhd.path) `
                -EvaluationIsoPath ([string]$local.files.evaluationIso.path) -SwitchName ([string]$network.Name) `
                -IntegrationServicesIsoPath ([string]$local.files.integrationIso.path) -AdministratorCredential $credential `
                -MemoryStartupBytes ([uint64]$MemoryStartupMB*1MB) -ProcessorCount $ProcessorCount -Confirm:$false
            if([string]$child.Status-ne'CREATED'-or-not[bool]$child.MiniSetupUnattended){throw 'WS2003_SQL_ACCEPTANCE_CHILD_CREATE_FAILED'}
            $notes=& $module {param($Run,$Scope,$Path) ConvertTo-HyperVLabNotes -RunId $Run -ScopeId $Scope -InstanceId 'sql-image-2005' -ChildVhdxPath $Path} $build.buildId $build.scopeId $childPath
            Set-VM -Name $vmName -Notes $notes -ErrorAction Stop
            $build.builder.vmCreated=$true;$build=Save-Ws2003SqlBuildState -Build $build -State 'MANUAL_ACTION_REQUIRED' -Reason 'Child erstellt; Mini-Setup und Gastnetz ausstehend'
        }
        if([string]$build.state-eq'MANUAL_ACTION_REQUIRED'){
            Write-Host "[INFO]    OOBE: automatisiere Mini-Setup, deutsches Login und $($build.labNetwork.address)"
            $license=& (Join-Path $PSScriptRoot 'Invoke-WindowsServer2003LegacyActivation.ps1') `
                -VmName $vmName -ChildVhdPath $childPath -AdministratorCredential $credential `
                -ActivationMode KeyboardOnly -StaticAddress ([string]$build.labNetwork.address) `
                -TimeoutSeconds $OobeTimeoutSeconds -Confirm:$false
            $remaining=[Math]::Max([int]$license.EvaluationDaysRemaining,[int]$license.GraceDaysRemaining)
            if([string]$license.Status-ne'KEYBOARD_LAYOUT_CONFIGURED'-or-not[bool]$license.StaticAddressConfigured-or$remaining-le0){
                throw 'WS2003_SQL_ACCEPTANCE_GRACE_NOT_USABLE'
            }
            $build.licenseEvidence=[pscustomobject]@{state='OOB_GRACE';activationRequired=[int]$license.ActivationRequired;evaluationDaysRemaining=[int]$license.EvaluationDaysRemaining;graceDaysRemaining=[int]$license.GraceDaysRemaining;activated=$false;observedAt=[datetime]::UtcNow.ToString('o')}
            $build=Save-Ws2003SqlBuildState -Build $build -State 'OOBE_COMPLETED' -Reason 'Mini-Setup, deutsches Login und statische Labnetzadresse verifiziert; Gast innerhalb Gnadenfrist'
        }
        if([string]$build.state-in@('OOBE_COMPLETED','SQL_INSTALL_RUNNING')){
            $vm=Get-VM -Name $vmName -ErrorAction Stop
            $completeMarker=$false;$offline=$null
            $appliedVersion=if($build.sql.PSObject.Properties['setupContractVersion']){[string]$build.sql.setupContractVersion}else{''}
            if([string]$vm.State-eq'Off'-and[string]$build.state-eq'SQL_INSTALL_RUNNING'){
                if($appliedVersion-ne$sqlSetupContractVersion){
                    Write-Host "[INFO]    SQL Setup: wiederhole fehlgeschlagenen Lauf mit korrigiertem Vertrag $sqlSetupContractVersion"
                }else{
                    try{$offline=Get-Ws2003SqlOfflineReceipt -Path $childPath;$completeMarker=$true}catch{}
                }
            }
            $runningJob=[string]$vm.State-eq'Running'-and[string]$build.state-eq'SQL_INSTALL_RUNNING'-and$appliedVersion-eq$sqlSetupContractVersion
            if(-not$completeMarker-and-not$runningJob){
                if([string]$vm.State-ne'Off'){Stop-VM -VM $vm -TurnOff -Force}
                $dvd=Get-VMDvdDrive -VMName $vmName -ErrorAction Stop|Select-Object -First 1
                if($dvd){Set-VMDvdDrive -VMDvdDrive $dvd -Path ([string]$local.files.sqlIso.path)}else{Add-VMDvdDrive -VMName $vmName -Path ([string]$local.files.sqlIso.path)|Out-Null}
                $build.sql|Add-Member -NotePropertyName setupContractVersion -NotePropertyValue $sqlSetupContractVersion -Force
                Set-Ws2003SqlOfflineJob -Path $childPath -BuildId $build.buildId
                $build=Save-Ws2003SqlBuildState -Build $build -State 'SQL_INSTALL_RUNNING' -Reason 'SQL Server 2005 Setup gestartet'
                Write-Host "[INFO]    SQL Setup: starte lokalen NT5-Startup-Job im Gast $vmName"
                Start-VM -Name $vmName|Out-Null
                $jobProcessId=Start-Ws2003SqlStagedJob -Address ([string]$build.labNetwork.address) -Credential $credential
                Write-Host "[INFO]    SQL Setup: lokaler NT5-Job als Gastprozess $jobProcessId gestartet"
            }elseif($runningJob){
                Write-Host '[INFO]    SQL Setup: laufender lokaler NT5-Startup-Job wird fortgesetzt'
            }else{
                Write-Host '[INFO]    SQL Setup: vorhandenes atomisches Receipt wird fortgesetzt'
            }
            if(-not$completeMarker){
                $setupDeadline=[datetime]::UtcNow.AddSeconds($SetupTimeoutSeconds)
                do{
                    Start-Sleep -Seconds 5
                    $vm=Get-VM -Name $vmName -ErrorAction Stop
                    if([string]$vm.State-eq'Off'){$completeMarker=$true}
                    elseif([string]$vm.State-eq'Running'){
                        try{
                            $scope=& $module {param($Address,$Credential) Connect-HyperVLegacyWindowsWmiScope -Address $Address -Namespace 'root\cimv2' -Credential $Credential} ([string]$build.labNetwork.address) $credential
                            $query=[Management.ObjectQuery]::new("SELECT Name FROM Win32_Service WHERE Name='$sqlCompletionServiceName'")
                            $searcher=[Management.ManagementObjectSearcher]::new($scope,$query)
                            $searcher.Options.Timeout=[timespan]::FromSeconds(5)
                            $completeMarker=@($searcher.Get()).Count-eq1
                        }catch{}
                    }
                }while(-not$completeMarker-and[datetime]::UtcNow-lt$setupDeadline)
            }
            if(-not$completeMarker){throw 'WS2003_SQL_OFFLINE_JOB_TIMEOUT'}
            $vm=Get-VM -Name $vmName -ErrorAction Stop
            if([string]$vm.State-ne'Off'){
                Start-Sleep -Seconds 10
                Stop-VM -VM $vm -TurnOff -Force
            }
            if(-not$offline){$offline=Get-Ws2003SqlOfflineReceipt -Path $childPath}
            if([string]$offline.status-ne'COMPLETED'){throw "WS2003_SQL_OFFLINE_JOB_FAILED: $($offline.errorCode); $($offline.diagnostic)"}
            if([string]$offline.productVersion-notmatch'^9\.'-or[int]$offline.databaseCount-ne4){throw 'WS2003_SQL_OFFLINE_POSTCONDITION_FAILED'}
            $build.sql|Add-Member -NotePropertyName setupExitCode -NotePropertyValue ([int]$offline.setupExitCode) -Force
            $ready=[pscustomobject]@{status='COMPLETED';majorVersion=9;productVersion=([string]$offline.productVersion).Trim();edition=([string]$offline.edition).Trim();databaseCount=4;observedAt=[datetime]::UtcNow.ToString('o')}
            $acceptance=[pscustomobject]@{databaseCreate=[bool]::Parse($offline.databaseCreate);insertSelect=[bool]::Parse($offline.insertSelect);backupChecksum=[bool]::Parse($offline.backupChecksum);restoreVerifyOnly=[bool]::Parse($offline.restoreVerifyOnly);databaseDrop=[bool]::Parse($offline.databaseDrop);backupRemoved=[bool]::Parse($offline.backupRemoved);observedAt=[datetime]::UtcNow.ToString('o')}
            if(@($acceptance.databaseCreate,$acceptance.insertSelect,$acceptance.backupChecksum,$acceptance.restoreVerifyOnly,$acceptance.databaseDrop,$acceptance.backupRemoved)-contains$false){throw 'WS2003_SQL_OFFLINE_ACCEPTANCE_FAILED'}
            $build.sql.setupBuild=[string]$ready.productVersion;$build.testEnvironment=$ready;$build.acceptanceEvidence=$acceptance
            $build=Save-Ws2003SqlBuildState -Build $build -State 'TESTS_PASSED' -Reason 'SQL Server 2005 Create/Insert/Backup/Restore/Drop bestanden'
        }
    }

    $result=[pscustomobject]@{
        Status='TESTS_PASSED';BuildId=[string]$build.buildId;VMName=[string]$build.builder.vmName
        SqlVersion='2005';SqlMajorVersion=9;ProductVersion=[string]$ready.productVersion;Edition=[string]$ready.edition
        OperatingSystemId='windows-server-2003';ArtifactId=[string]$build.parentArtifact.artifactId
        MediaSha256=[string]$build.sql.mediaSha256;MediaTrust=[string]$build.sql.mediaTrust
        GuestControl='offline-startup-wmi-read';ActivationState=[string]$build.licenseEvidence.state
        ActivationRequired=[int]$build.licenseEvidence.activationRequired;Activated=$false
        EvaluationDaysRemaining=[int]$build.licenseEvidence.evaluationDaysRemaining
        GraceDaysRemaining=[int]$build.licenseEvidence.graceDaysRemaining
        Tests=[pscustomobject]@{databaseCreate=[bool]$acceptance.databaseCreate;insertSelect=[bool]$acceptance.insertSelect;backupChecksum=[bool]$acceptance.backupChecksum;restoreVerifyOnly=[bool]$acceptance.restoreVerifyOnly;databaseDrop=[bool]$acceptance.databaseDrop;backupRemoved=[bool]$acceptance.backupRemoved}
        CredentialDisclosed=$false;PasswordDisclosed=$false;CompletedAt=[datetime]::UtcNow.ToString('o')
    }
}
catch{
    if($build){
        $build|Add-Member -NotePropertyName lastError -NotePropertyValue ([pscustomobject]@{message=$_.Exception.Message;observedAt=[datetime]::UtcNow.ToString('o')}) -Force
        try{$null=Save-Ws2003SqlBuildState -Build $build -Reason 'Lauf unterbrochen; Build bleibt für Diagnose und Resume erhalten'}catch{}
    }
    if($ResultPath){
        $failure=[pscustomobject]@{Status='FAILED';SqlVersion='2005';ErrorCode=if($_.Exception.Message-match'[A-Z][A-Z0-9_]{5,}'){$Matches[0]}else{'WS2003_SQL_ACCEPTANCE_FAILED'};CredentialDisclosed=$false;PasswordDisclosed=$false;FailedAt=[datetime]::UtcNow.ToString('o')}
        New-Item -Path (Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath))) -ItemType Directory -Force|Out-Null
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath),($failure|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    }
    throw
}
if($ResultPath){
    New-Item -Path (Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath))) -ItemType Directory -Force|Out-Null
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath),($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
$result

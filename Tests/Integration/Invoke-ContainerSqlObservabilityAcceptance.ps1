#Requires -Version 7.2
<#
.SYNOPSIS
    Belegt die öffentliche, rungebundene SQL-Observability-Evidence für einen Containerprovider.
.DESCRIPTION
    Der Runner erstellt ausschließlich einen frischen SQL-2025-Test-Run in einem
    eigenen temporären State-Root. Er richtet eine kleine Query-Store-Datenbank
    ein, erfasst die sanitisierte öffentliche Evidence vor und nach einem
    öffentlichen Restart und entfernt in jedem Ausgang nur Ressourcen aus diesem
    State-Root. Es werden keine fremden Runs inventarisiert oder behalten.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-observability-'+$Provider+'-'+[guid]::NewGuid().ToString('N'))
$stateRoot=Join-Path $testRoot 'state'
$operationId=[guid]::NewGuid().ToString()
$previous=@{}
foreach($name in @('SQL_SERVER_LAB_STATE','SQL_SERVER_LAB_RESOURCE_LIFECYCLE','SQL_SERVER_LAB_TEST_OPERATION_ID')){
    $previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
}
$mutex=$null; $acquired=$false; $module=$null; $lab=$null; $password=$null; $completed=$false; $cleanupSucceeded=$false; $runtimeInvocation=$null

function Assert-ObservabilityAcceptance {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Reason)
    if(-not $Condition){throw "SQL_OBSERVABILITY_ACCEPTANCE_FAILED: $Reason"}
    Write-Host "PASS: $Reason" -ForegroundColor Green
}

function New-ObservabilityAcceptancePassword {
    $secret=[Security.SecureString]::new()
    foreach($character in ('Observability_'+[guid]::NewGuid().ToString('N')+'!Aa7').ToCharArray()){$secret.AppendChar($character)}
    $secret.MakeReadOnly()
    return $secret
}

function Invoke-ObservabilityAcceptanceScript {
    param([Parameter(Mandatory)][string]$Content,[Parameter(Mandatory)][string]$Database)
    $path=Join-Path $testRoot ([guid]::NewGuid().ToString('N')+'.sql')
    try {
        [IO.File]::WriteAllText($path,$Content,[Text.UTF8Encoding]::new($true))
        $result=Invoke-SqlServerLabScript -ScriptPath $path -RunId $lab.RunId -InstanceId primary `
            -SaPassword $password -Database $Database -StateRoot $stateRoot -KeepConnection
        if(-not $result.Success){throw 'SQL_OBSERVABILITY_ACCEPTANCE_SCRIPT_FAILED'}
    }
    finally { if([IO.File]::Exists($path)){[IO.File]::Delete($path)} }
}

function Test-ObservabilityEvidence {
    param([Parameter(Mandatory)]$Evidence,[Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$Provider,[Parameter(Mandatory)][string[]]$Forbidden)
    $json=$Evidence | ConvertTo-Json -Depth 20 -Compress
    Assert-ObservabilityAcceptance ($Evidence.ContractVersion -eq 'SqlServerLab.SqlObservabilityEvidence/1.0' -and
        $Evidence.ObservationStatus -eq 'SQL_ENGINE_COMPLETE' -and $Evidence.Source.SqlMajorVersion -eq '17') 'Öffentliche Evidence erfüllt den geschlossenen SQL-2025-Vertragsstatus'
    Assert-ObservabilityAcceptance ($Evidence.Source.Provider -eq $Provider -and $Evidence.Source.RunId -eq $RunId -and
        $Evidence.Source.InstanceId -eq 'primary') 'Öffentliche Evidence bleibt an den eigenen Run und die Instanz gebunden'
    Assert-ObservabilityAcceptance ($Evidence.Server.CpuCount -ge 1 -and $Evidence.Server.PhysicalMemoryKb -ge 1 -and
        $Evidence.Databases.OnlineCount -ge 1 -and $Evidence.Databases.TotalFileSizeKb -ge 1 -and
        $Evidence.Databases.QueryStoreEnabledCount -ge 0 -and $Evidence.WaitStatistics.NonSleepWaitTypeCount -ge 0 -and
        $Evidence.WaitStatistics.WaitingTaskCount -ge 0 -and $Evidence.WaitStatistics.WaitTimeMs -ge 0) 'CPU-, RAM-, Datenbank-, Dateigrößen- und Wait-Metriken sind strukturell gültig'
    Assert-ObservabilityAcceptance (-not $Evidence.EvidenceBoundary.SqlTextIncluded -and -not $Evidence.EvidenceBoundary.DatabaseNamesIncluded -and
        -not $Evidence.EvidenceBoundary.LoginNamesIncluded -and -not $Evidence.EvidenceBoundary.HostValuesIncluded -and
        -not $Evidence.EvidenceBoundary.SecretValuesIncluded) 'Evidence deklariert die Privacy-Grenze vollständig'
    foreach($value in @($Forbidden | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})){
        Assert-ObservabilityAcceptance (-not $json.Contains($value,[StringComparison]::OrdinalIgnoreCase)) 'Evidence enthält keine dynamischen Test-, Host- oder Secretwerte'
    }
}

function Remove-ObservabilityAcceptanceRuns {
    if(-not (Test-Path -LiteralPath $stateRoot -PathType Container)){return}
    $runsPath=Join-Path $stateRoot 'runs'
    if(-not (Test-Path -LiteralPath $runsPath -PathType Container)){return}
    $runIds=@(Get-ChildItem -LiteralPath $runsPath -Directory -ErrorAction Stop | ForEach-Object {$_.Name})
    foreach($runId in $runIds){
        try {
            $result=Remove-SqlServerLab -RunId $runId -StateRoot $stateRoot -Force -Confirm:$false
            if($result.Status -ne 'REMOVED' -or ($result.PSObject.Properties['Errors'] -and [int]$result.Errors -ne 0)){throw 'result'}
        }
        catch { throw 'SQL_OBSERVABILITY_ACCEPTANCE_CLEANUP_FAILED' }
    }
    foreach($runId in $runIds){
        $volumeResult=& $module { param($Invocation,$RunId)
            Invoke-LabProgressNativeCommand -FilePath $Invocation -ArgumentList @('volume','ls','-q','--filter',('label=sql-server-lab.run-id='+$RunId)) -Phase Cleanup -TimeoutSeconds 30
        } $runtimeInvocation $runId
        if($volumeResult.ExitCode -ne 0 -or @($volumeResult.Output | Where-Object {$_}).Count -ne 0){throw 'SQL_OBSERVABILITY_ACCEPTANCE_VOLUME_REMAINS'}
    }
    $containerResult=& $module { param($Invocation,$OperationId)
        Invoke-LabProgressNativeCommand -FilePath $Invocation -ArgumentList @('ps','-a','--filter',('label=sql-server-lab.test-operation-id='+$OperationId),'--format','{{.ID}}') -Phase Cleanup -TimeoutSeconds 30
    } $runtimeInvocation $operationId
    $operationVolumeResult=& $module { param($Invocation,$OperationId)
        Invoke-LabProgressNativeCommand -FilePath $Invocation -ArgumentList @('volume','ls','-q','--filter',('label=sql-server-lab.test-operation-id='+$OperationId)) -Phase Cleanup -TimeoutSeconds 30
    } $runtimeInvocation $operationId
    if($containerResult.ExitCode -ne 0 -or $operationVolumeResult.ExitCode -ne 0 -or
        @($containerResult.Output | Where-Object {$_}).Count -ne 0 -or @($operationVolumeResult.Output | Where-Object {$_}).Count -ne 0){throw 'SQL_OBSERVABILITY_ACCEPTANCE_CLEANUP_REMAINS'}
}

function Test-ObservabilityAcceptanceTempRoot {
    $fullTestRoot=[IO.Path]::GetFullPath($testRoot)
    $fullTempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $relative=[IO.Path]::GetRelativePath($fullTempRoot,$fullTestRoot)
    if([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar) -or
        -not (Split-Path -Leaf $fullTestRoot).StartsWith('sql-lab-observability-'+$Provider+'-',[StringComparison]::Ordinal)) { throw 'SQL_OBSERVABILITY_ACCEPTANCE_TEMP_PATH_INVALID' }
}

try {
    $readiness=& (Join-Path $repoRoot 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider $Provider -Operation Create
    if($readiness.Status -notin @('READY','READY_WITH_WARNINGS') -or @($readiness.MissingPrerequisites).Count -gt 0){throw 'SQL_OBSERVABILITY_ACCEPTANCE_READINESS_BLOCKED'}
    $resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if(-not $resolution.Available){throw 'SQL_OBSERVABILITY_ACCEPTANCE_CLI_UNAVAILABLE'}
    $runtimeInvocation=[string]$resolution.Invocation
    $mutexName=if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}
    $mutex=[Threading.Mutex]::new($false,$mutexName)
    $acquired=$mutex.WaitOne([TimeSpan]::FromSeconds(30))
    if(-not $acquired){throw 'SQL_OBSERVABILITY_ACCEPTANCE_LOCK_TIMEOUT'}
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Test-ObservabilityAcceptanceTempRoot
    $env:SQL_SERVER_LAB_STATE=$stateRoot
    $env:SQL_SERVER_LAB_RESOURCE_LIFECYCLE='test'
    $env:SQL_SERVER_LAB_TEST_OPERATION_ID=$operationId
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module=Import-Module $modulePath -Force -PassThru
    $password=New-ObservabilityAcceptancePassword
    $token=[guid]::NewGuid().ToString('N').Substring(0,16)
    $databaseName='Observability'+$token
    $marker='marker-'+$token
    $lab=New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Cpu 1 -MemoryMB 2048 `
        -AutoStart off -LabName ('observability-'+$operationId.Substring(0,8)) -SaPassword $password -StateRoot $stateRoot -SkipAssessment
    Assert-ObservabilityAcceptance ($lab.State -eq 'Running') 'Frischer isolierter SQL-2025-Test-Run ist bereit'
    $connection=Get-Content -LiteralPath (Join-Path $stateRoot ('runs/'+$lab.RunId+'/connection-info.json')) -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
    $instance=@($connection.instances | Where-Object {$_.id -eq 'primary'})[0]
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
    try {$plainSecret=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)} finally {[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
    try {
        $forbidden=@($token,$databaseName,$marker,[string]$instance.host,[string]$instance.containerName,$plainSecret)
        $before=Get-SqlServerLabSqlObservabilityEvidence -RunId $lab.RunId -InstanceId primary -SaPassword $password -StateRoot $stateRoot
        Test-ObservabilityEvidence -Evidence $before -RunId $lab.RunId -Provider $Provider -Forbidden $forbidden
    New-SqlServerLabDatabase -HostName ([string]$instance.host) -Port ([int]$instance.port) -SaPassword $password -DatabaseName $databaseName `
        -Options ([PSCustomObject]@{queryStore=$true;compatibility=170}) | Out-Null
    Invoke-ObservabilityAcceptanceScript -Database $databaseName -Content "CREATE TABLE dbo.Marker(Id int NOT NULL PRIMARY KEY, Value nvarchar(64) NOT NULL); INSERT dbo.Marker(Id,Value) VALUES(1,N'$marker');"
    $afterCreate=Get-SqlServerLabSqlObservabilityEvidence -RunId $lab.RunId -InstanceId primary -SaPassword $password -StateRoot $stateRoot
    Test-ObservabilityEvidence -Evidence $afterCreate -RunId $lab.RunId -Provider $Provider -Forbidden $forbidden
    Assert-ObservabilityAcceptance ($afterCreate.Databases.OnlineCount -eq ($before.Databases.OnlineCount+1) -and
        $afterCreate.Databases.TotalFileSizeKb -gt $before.Databases.TotalFileSizeKb -and
        $afterCreate.Databases.QueryStoreEnabledCount -eq ($before.Databases.QueryStoreEnabledCount+1)) 'Synthetische Query-Store-Datenbank verändert nur erwartete Aggregatwerte'
    $restart=Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 180 -Force
    Assert-ObservabilityAcceptance ($restart.Status -eq 'RUNNING') 'Öffentlicher Restart erreicht erneut SQL-Readiness'
    $markerValue=& $module { param($RunId,$Password,$StateRoot,$Database)
        $target=Resolve-LabRunInstance -RunId $RunId -InstanceId primary -StateRoot $StateRoot
        $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try {$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)} finally {[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
        try {
            $markerRows=@(Invoke-SqlQuery -HostName $target.HostName -Port $target.Port -SaPlain $plain -Database $Database -Query "SET NOCOUNT ON; SELECT CONCAT(N'OBS_ACCEPTANCE_MARKER|',Value) FROM dbo.Marker WHERE Id=1;" |
                ForEach-Object {([string]$_).Trim()} | Where-Object {$_ -match '^OBS_ACCEPTANCE_MARKER\|'})
            if($markerRows.Count -ne 1){throw 'SQL_OBSERVABILITY_ACCEPTANCE_MARKER_RESULT_INVALID'}
            return [string]$markerRows[0]
        }
        finally {$plain=$null}
    } $lab.RunId $password $stateRoot $databaseName
    Assert-ObservabilityAcceptance ($markerValue -eq ('OBS_ACCEPTANCE_MARKER|'+$marker)) 'Synthetischer Datenmarker bleibt über den öffentlichen Restart erhalten'
    $afterRestart=Get-SqlServerLabSqlObservabilityEvidence -RunId $lab.RunId -InstanceId primary -SaPassword $password -StateRoot $stateRoot
    Test-ObservabilityEvidence -Evidence $afterRestart -RunId $lab.RunId -Provider $Provider -Forbidden $forbidden
    Assert-ObservabilityAcceptance ($afterRestart.Databases.OnlineCount -ge $afterCreate.Databases.OnlineCount -and
        $afterRestart.Databases.TotalFileSizeKb -ge $afterCreate.Databases.TotalFileSizeKb -and
        $afterRestart.Databases.QueryStoreEnabledCount -ge $afterCreate.Databases.QueryStoreEnabledCount) 'Aggregierte Evidence bleibt nach Restart vollständig'
    }
    finally {$forbidden=$null; $plainSecret=$null}
    Remove-ObservabilityAcceptanceRuns
    $lab=$null; $cleanupSucceeded=$true; $completed=$true
}
finally {
    if(-not $cleanupSucceeded){
        try { Remove-ObservabilityAcceptanceRuns; $cleanupSucceeded=$true }
        catch { $cleanupSucceeded=$false }
    }
    $finalizationFailed=$false
    if($cleanupSucceeded -and (Test-Path -LiteralPath $testRoot)){
        try { Test-ObservabilityAcceptanceTempRoot; Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop }
        catch { $finalizationFailed=$true }
    }
    foreach($name in $previous.Keys){[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')}
    if($password){$password.Dispose()}
    if($acquired){$mutex.ReleaseMutex()}
    if($mutex){$mutex.Dispose()}
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if(-not $cleanupSucceeded -or $finalizationFailed) { throw 'SQL_OBSERVABILITY_ACCEPTANCE_RECOVERY_REQUIRED' }
    if($completed){Write-Host 'CONTAINER_SQL_OBSERVABILITY_ACCEPTANCE: PASS' -ForegroundColor Green}
}

#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft einen gueltigen SA-Passwort-Creationjob im gerenderten Browser.
.DESCRIPTION
    Verwendet einen eigenen isolierten State-/Data-Root, echten Loopback-HTTP-
    Transport, einen gepinnten Browser und genau einen neuen Docker- oder
    Podman-SQL-2025-Run. Ressourcen werden nur nach nativer Bindung entfernt.
    Bei unklarer Prozess- oder Runtime-Custody bleibt der eigene Root erhalten.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [Parameter(Mandatory)][string]$BrowserRuntimeMetadataPath
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo 'Tests/Common/ContainerAutoStartPreviewBrowserAcceptance.ps1')
. (Join-Path $repo 'Tests/Common/SaPasswordBrowserAcceptance.ps1')
$id=[guid]::NewGuid().ToString('N')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-sa-browser-'+$id)
$state=Join-Path $root state;$data=Join-Path $root Lab_Data
$evidence=Join-Path $repo ('.artifacts/test-runs/sa-password-browser-'+$id)
$labName='sa-browser-'+$id.Substring(0,12)
$module=$null;$mutex=$null;$locked=$false;$server=$null;$serverStarted=$false;$serverCapture=$null;$driver=$null;$driverCapture=$null
$client=$null;$binding=$null;$jobId=$null;$version=$null;$serverExited=$false
$completed=$false;$cleanupComplete=$false;$processRecovery=$false;$primary=$null;$cleanupError=$null
$oldState=$env:SQL_SERVER_LAB_STATE;$oldData=$env:SQL_SERVER_LAB_DATA_ROOT

function Assert-SaBrowserOwnRoot([string]$Path) {
    $absolute=[IO.Path]::GetFullPath($Path)
    $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($absolute) -cnotmatch '^sql-lab-sa-browser-[a-f0-9]{32}$') { throw 'SA_BROWSER_ROOT_SCOPE_INVALID' }
    foreach($item in @(Get-Item -LiteralPath $absolute -Force)+@(Get-ChildItem -LiteralPath $absolute -Force -Recurse)){
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'SA_BROWSER_ROOT_REPARSE'}
    }
    return $absolute
}

function Get-SaBrowserOwnBinding($Module,[string]$RunId,[string]$StateRoot,[string]$Name,[string]$Selected,[string]$Version) {
    & $Module {
        param($Run,$State,$Name,$Selected,$Version)
        $runState=Get-LabRunState -RunId $Run -StateRoot $State
        $instance=Resolve-LabRunInstance -RunId $Run -InstanceId primary -StateRoot $State
        if($runState.state -cne 'RUNNING' -or $runState.metadata.name -cne $Name -or
            $runState.metadata.persistentData -or $instance.Provider -cne $Selected -or
            $instance.Version -cne $Version){throw 'SA_BROWSER_RUN_BINDING_INVALID'}
        $scope=Get-LabContainerRuntimeScope -Provider $Selected -StateRoot $State
        if($scope.Status -cne 'AVAILABLE' -or -not $scope.RuntimeId){throw 'SA_BROWSER_RUNTIME_SCOPE_INVALID'}
        $inspection=@((Invoke-LabTransferNative -Provider $Selected -Arguments @('inspect',$instance.ContainerName) -StateRoot $State) -join "`n" | ConvertFrom-Json -Depth 30)
        if($inspection.Count -ne 1){throw 'SA_BROWSER_CONTAINER_AMBIGUOUS'}
        $container=$inspection[0];$labels=$container.Config.Labels
        if(-not $container.State.Running -or [string]$container.Id -cnotmatch '^[a-f0-9]{64}$' -or
            $labels.'sql-server-lab.run-id' -cne $Run -or $labels.'sql-server-lab.scope-id' -cne $runState.scopeId -or
            $labels.'sql-server-lab.instance-id' -cne 'primary') {throw 'SA_BROWSER_CONTAINER_BINDING_INVALID'}
        $ports=@($container.NetworkSettings.Ports.'1433/tcp')
        if($ports.Count -ne 1 -or [int]$ports[0].HostPort -ne $instance.Port -or
            $ports[0].HostIp -notin @('127.0.0.1','::1') -or $instance.HostName -cne $ports[0].HostIp){throw 'SA_BROWSER_ENDPOINT_INVALID'}
        $mounts=@($container.Mounts)
        if($mounts.Count -ne 1 -or $mounts[0].Type -cne 'volume' -or
            $mounts[0].Destination -cne '/var/opt/mssql' -or -not $mounts[0].RW){throw 'SA_BROWSER_VOLUME_BINDING_INVALID'}
        $volume=@((Invoke-LabTransferNative -Provider $Selected -Arguments @('volume','inspect',[string]$mounts[0].Name) -StateRoot $State) -join "`n" | ConvertFrom-Json -Depth 30)
        if($volume.Count -ne 1){throw 'SA_BROWSER_VOLUME_AMBIGUOUS'}
        $vl=$volume[0].Labels
        if($vl.'sql-server-lab.run-id' -cne $Run -or $vl.'sql-server-lab.scope-id' -cne $runState.scopeId -or
            $vl.'sql-server-lab.instance-id' -cne 'primary' -or $vl.'sql-server-lab.persistence' -cne 'run-scoped-runtime-volume'){
            throw 'SA_BROWSER_VOLUME_BINDING_INVALID'
        }
        $attached=@(Invoke-LabTransferNative -Provider $Selected -Arguments @('ps','-a','--no-trunc','--filter',"volume=$($mounts[0].Name)",'--format','{{.ID}}') -StateRoot $State)
        if($attached.Count -ne 1 -or $attached[0] -cne $container.Id){throw 'SA_BROWSER_VOLUME_SHARED'}
        [pscustomobject]@{RunId=$Run;ScopeId=[string]$runState.scopeId;Provider=$Selected;RuntimeScopeId=[string]$scope.RuntimeId;
            ContainerId=[string]$container.Id;Volume=[string]$mounts[0].Name;HostName=[string]$instance.HostName;Port=[int]$instance.Port}
    } $RunId $StateRoot $Name $Selected $Version
}

function Wait-SaBrowserProcess($Process,$Capture,[int]$Seconds) {
    $deadline=[datetime]::UtcNow.AddSeconds($Seconds)
    while(-not $Process.HasExited -and [datetime]::UtcNow -lt $deadline){Read-AutoStartBrowserPipeCapture $Capture;Start-Sleep -Milliseconds 100}
    Read-AutoStartBrowserPipeCapture $Capture
    return [bool]$Process.HasExited
}

try {
    $mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}))
    try{$locked=$mutex.WaitOne([TimeSpan]::FromMinutes(10))}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'SA_BROWSER_MUTEX_TIMEOUT'}
    $resolution=@(& (Join-Path $repo 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if(-not $resolution.Available -or -not [IO.Path]::IsPathFullyQualified([string]$resolution.Invocation) -or
        -not (Test-Path -LiteralPath $resolution.Invocation -PathType Leaf)){throw 'SA_BROWSER_PROVIDER_UNAVAILABLE'}
    $readiness=& (Join-Path $repo 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider $Provider -Operation Create
    if($readiness.Status -notin @('READY','READY_WITH_WARNINGS')){throw 'SA_BROWSER_CLIENT_NOT_READY'}
    $module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
    $browserTools=Assert-AutoStartBrowserRuntimeMetadata -Module $module -Path $BrowserRuntimeMetadataPath
    if(Test-Path -LiteralPath $root){throw 'SA_BROWSER_ROOT_EXISTS'}
    $null=New-Item -ItemType Directory -Path $root
    $null=New-Item -ItemType Directory -Path $evidence
    $env:SQL_SERVER_LAB_STATE=$state;$env:SQL_SERVER_LAB_DATA_ROOT=$data
    & $module {param($Root)$null=Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false} $data
    $builds=@(& $module {Get-SqlServerBuilds -VersionId '2025'} | Where-Object {[string]$_.cu -match '^CU[0-9]+$'} | Sort-Object {[int](([string]$_.cu).Substring(2))} -Descending)
    if($builds.Count -lt 1){throw 'SA_BROWSER_CATALOG_BUILD_MISSING'}
    $version='2025-'+[string]$builds[0].cu
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start();$port=[int]$listener.LocalEndpoint.Port;$listener.Stop()
    if($port -eq 14336){throw 'SA_BROWSER_RESERVED_PORT'}
    $serverSource=Join-Path $evidence 'server.private.ps1';$driverSource=Join-Path $evidence 'driver.private.cjs'
    [IO.File]::WriteAllText($serverSource,(Get-SaPasswordBrowserServerSource),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($driverSource,(Get-SaPasswordBrowserDriverSource),[Text.UTF8Encoding]::new($false))
    $readyPath=Join-Path $evidence 'ready.private.json';$stopPath=Join-Path $evidence 'stop.private.json'
    $serverConfig=[ordered]@{RepositoryRoot=$repo;StateRoot=$state;DataRoot=$data;ListenerPort=$port;ReadyPath=$readyPath;StopPath=$stopPath}
    $serverConfigPath=Join-Path $evidence 'server-config.private.json'
    [IO.File]::WriteAllText($serverConfigPath,($serverConfig|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    $pwsh=@(Get-Command pwsh -CommandType Application -ErrorAction Stop |
        Where-Object { [IO.Path]::IsPathFullyQualified([string]$_.Source) -and (Test-Path -LiteralPath $_.Source -PathType Leaf) })[0].Source
    if(-not $pwsh){throw 'SA_BROWSER_POWERSHELL_UNRESOLVED'}
    $serverStart=New-AutoStartBrowserServerStartInfo -PowerShell $pwsh -Script $serverSource -Config $serverConfigPath -Scope ([pscustomobject]@{DataRoot=$data;StateRoot=$state})
    $server=[Diagnostics.Process]::new();$server.StartInfo=$serverStart
    $serverStarted=$server.Start()
    if(-not $serverStarted){throw 'SA_BROWSER_SERVER_START_FAILED'}
    $serverCapture=New-AutoStartBrowserPipeCapture $server
    $deadline=[datetime]::UtcNow.AddSeconds(90)
    while(-not (Test-Path -LiteralPath $readyPath) -and [datetime]::UtcNow -lt $deadline){
        Read-AutoStartBrowserPipeCapture $serverCapture
        if($server.HasExited){throw 'SA_BROWSER_SERVER_EXITED'}
        Start-Sleep -Milliseconds 100
    }
    if(-not (Test-Path -LiteralPath $readyPath)){throw 'SA_BROWSER_SERVER_NOT_READY'}
    $driverConfig=[ordered]@{ListenerPort=$port;Provider=$Provider;Version=$version;LabName=$labName;
        BrowserExecutable=$browserTools.Browser.Path;PlaywrightDirectory=(Split-Path $browserTools.PlaywrightPackage.Path);ResultPath=(Join-Path $evidence 'browser-result.private.json')}
    $driverConfigPath=Join-Path $evidence 'driver-config.private.json'
    [IO.File]::WriteAllText($driverConfigPath,($driverConfig|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    $driverStart=[Diagnostics.ProcessStartInfo]::new([string]$browserTools.Node.Path)
    $driverStart.UseShellExecute=$false;$driverStart.CreateNoWindow=$true
    $driverStart.RedirectStandardOutput=$true;$driverStart.RedirectStandardError=$true
    $driverStart.ArgumentList.Add($driverSource);$driverStart.ArgumentList.Add($driverConfigPath)
    $driver=[Diagnostics.Process]::new();$driver.StartInfo=$driverStart
    if(-not $driver.Start()){throw 'SA_BROWSER_DRIVER_START_FAILED'}
    $driverCapture=New-AutoStartBrowserPipeCapture $driver
    if(-not (Wait-SaBrowserProcess $driver $driverCapture 180)){throw 'SA_BROWSER_DRIVER_PROCESS_RECOVERY_REQUIRED'}
    if($driver.ExitCode -ne 0){throw 'SA_BROWSER_DRIVER_FAILED'}
    $rendered=Get-Content -LiteralPath $driverConfig.ResultPath -Raw | ConvertFrom-Json
    if($rendered.Status -cne 'PASS' -or $rendered.ActionRequests -ne 1 -or $rendered.EarlyRequests -ne 0 -or
        -not $rendered.RenderedDialog -or $rendered.ConfirmedMinimum -ne 3 -or $rendered.JobId -cnotmatch '^[a-f0-9]{32}$'){
        throw 'SA_BROWSER_RENDERED_EVIDENCE_INVALID'
    }
    $jobId=[string]$rendered.JobId
    $client=[Net.Http.HttpClient]::new();$client.Timeout=[TimeSpan]::FromSeconds(10)
    $base="http://127.0.0.1:$port";$jobState=$null
    $jobLines=[Collections.Generic.List[string]]::new()
    $deadline=[datetime]::UtcNow.AddMinutes(7)
    while([datetime]::UtcNow -lt $deadline){
        Read-AutoStartBrowserPipeCapture $serverCapture
        if($server.HasExited){throw 'SA_BROWSER_SERVER_EXITED_DURING_JOB'}
        $response=$client.GetAsync($base+'/api/jobs').GetAwaiter().GetResult()
        try{
            if(-not $response.IsSuccessStatusCode){throw 'SA_BROWSER_JOBS_UNAVAILABLE'}
            $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if($body.Contains('Ab3')){throw 'SA_BROWSER_JOB_SECRET_EXPOSED'}
            $jobs=@($body|ConvertFrom-Json -Depth 8)
            $own=@($jobs|Where-Object { $_.Id -ceq $jobId -and $_.Action -ceq 'NewContainerLab' })
            if($own.Count -ne 1){throw 'SA_BROWSER_JOB_IDENTITY_INVALID'}
            $jobState=[string]$own[0].State
            $jobLines.Clear()
            foreach($line in @($own[0].Lines)){
                if($line -isnot [string]){throw 'SA_BROWSER_JOB_LINE_INVALID'}
                $jobLines.Add($line)
            }
            if([Text.Encoding]::UTF8.GetByteCount(($jobLines -join "`n")) -gt 65536){throw 'SA_BROWSER_JOB_OUTPUT_LIMIT'}
        }finally{$response.Dispose()}
        if($jobState -in @('Completed','Failed','Stopped','Blocked')){break}
        Start-Sleep -Seconds 2
    }
    [IO.File]::WriteAllText((Join-Path $evidence 'job-lines.private.json'),
        ($jobLines|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    if($jobState -cne 'Completed'){throw 'SA_BROWSER_CREATION_JOB_NOT_COMPLETED'}
    $runDirectory=Join-Path $state runs
    $runs=@(Get-ChildItem -LiteralPath $runDirectory -Directory -ErrorAction Stop)
    if($runs.Count -ne 1 -or $runs[0].Name -cnotmatch '^[a-f0-9-]{36}$'){throw 'SA_BROWSER_RUN_AMBIGUOUS'}
    $binding=Get-SaBrowserOwnBinding $module $runs[0].Name $state $labName $Provider $version
    $configuration=@(& $module {param($Bound,$State)Invoke-LabTransferNative -Provider $Bound.Provider -Arguments @('exec',$Bound.ContainerId,'cat','/var/opt/mssql/mssql.conf') -StateRoot $State} $binding $state)
    if(($configuration -join "`n") -cnotmatch '(?m)^passwordminimumlength=3\s*$'){throw 'SA_BROWSER_CONFIG_INVALID'}
    $sql=@(& $module {param($Bound)
        Invoke-SqlQuery -HostName $Bound.HostName -Port $Bound.Port -SaPlain 'Ab3' -Query 'SET NOCOUNT ON; SELECT 17;' -TimeoutSeconds 15
    } $binding)
    if(($sql -join "`n") -notmatch '(?m)^\s*17\s*$'){throw 'SA_BROWSER_SQL_LOGIN_FAILED'}
    $completed=$true
}
catch{$primary=$_}
finally {
    if($client){$client.Dispose()}
    if($serverStarted){
        try{
            if(-not (Test-Path -LiteralPath $stopPath)){
                [IO.File]::WriteAllText($stopPath,'STOP',[Text.UTF8Encoding]::new($false))
            }
            $serverExited=Wait-SaBrowserProcess $server $serverCapture 40
            if(-not $serverExited){$processRecovery=$true}
        }catch{$processRecovery=$true;if(-not $cleanupError){$cleanupError=$_}}
    }
    if($driver -and -not $driver.HasExited){$processRecovery=$true}
    if($processRecovery){$cleanupError=[Management.Automation.RuntimeException]::new('SA_BROWSER_PROCESS_RECOVERY_REQUIRED')}
    if($serverExited -and -not $processRecovery -and $module -and -not $binding -and $version -and
        (Test-Path -LiteralPath (Join-Path $state runs) -PathType Container)){
        try{
            $candidate=@(Get-ChildItem -LiteralPath (Join-Path $state runs) -Directory -ErrorAction Stop)
            if($candidate.Count -eq 1 -and $candidate[0].Name -cmatch '^[a-f0-9-]{36}$'){
                $binding=Get-SaBrowserOwnBinding $module $candidate[0].Name $state $labName $Provider $version
            }
        }catch{if(-not $cleanupError){$cleanupError=$_}}
    }
    if($serverExited -and -not $processRecovery -and $module -and $binding){
        try{
            $removed=Remove-SqlServerLab -RunId $binding.RunId -StateRoot $state -Force -Confirm:$false
            if($removed.Status -cne 'REMOVED' -or $removed.Cleanup -cne 'CLEANUP_SUCCEEDED'){throw 'SA_BROWSER_CLEANUP_UNCONFIRMED'}
            & $module {param($Bound,$State)Assert-LabTransferNoResidue -Binding $Bound -StateRoot $State} $binding $state
            $terminal=@('run-state.json','cleanup-plan.json')
            foreach($name in $terminal){
                $source=Join-Path (Join-Path $state ('runs/'+$binding.RunId)) $name
                Copy-Item -LiteralPath $source -Destination (Join-Path $evidence ('terminal-'+$name+'.private.json')) -ErrorAction Stop
            }
            $cleanupComplete=$true
        }catch{$cleanupError=$_}
    }
    if($server -and $serverExited){
        if($serverCapture){foreach($stream in $serverCapture.Streams){$stream.Dispose()}}
        $server.Dispose()
    }
    elseif($server -and -not $serverStarted){$server.Dispose()}
    if($driver -and $driver.HasExited){
        if($driverCapture){foreach($stream in $driverCapture.Streams){$stream.Dispose()}}
        $driver.Dispose()
    }
    $env:SQL_SERVER_LAB_STATE=$oldState;$env:SQL_SERVER_LAB_DATA_ROOT=$oldData
    if($module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue}
    if($mutex){if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
    if($cleanupComplete -and $completed -and -not $primary -and -not $cleanupError){
        try{$absolute=Assert-SaBrowserOwnRoot $root;Remove-Item -LiteralPath $absolute -Recurse -Force -ErrorAction Stop}
        catch{$cleanupError=$_}
    }
    if(Test-Path -LiteralPath $evidence){
        $result=[ordered]@{Contract='SqlServerLab.SaPasswordBrowserNativeAcceptance/1.0';Provider=$Provider;
            Status=$(if($completed -and $cleanupComplete -and -not $cleanupError){'PASS'}else{'RECOVERY_REQUIRED'});
            RenderedBrowser=$(if($completed){'PASSED'}else{'NOT_CONFIRMED'});
            HttpCreationJob=$(if($completed){'PASSED'}else{'NOT_CONFIRMED'});
            JobState=$jobState;OwnResourcesRemoved=$cleanupComplete;RootRemoved=(-not (Test-Path -LiteralPath $root));
            ProcessRecoveryRequired=$processRecovery;PrimaryFailure=[bool]$primary;CleanupFailure=[bool]$cleanupError}
        $resultPath=Join-Path $evidence 'result.private.json'
        [IO.File]::WriteAllText($resultPath,($result|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    }
}
if($primary){throw $primary}
if($cleanupError -or -not $completed -or -not $cleanupComplete){throw 'SA_BROWSER_ACCEPTANCE_RECOVERY_REQUIRED'}
Write-Output "SA PASSWORD BROWSER ACCEPTANCE: PASS ($Provider; real HTTP job; rendered browser; SQL login; own cleanup)"

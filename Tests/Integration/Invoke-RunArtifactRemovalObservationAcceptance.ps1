#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft Run-Metadatenentfernung mit echter lesender Providerbeobachtung.
.DESCRIPTION
    Verwendet einen frischen eigenen synthetischen REMOVED-Run und einen
    isolierten registrierten Dateiroot. Ohne CreateSqlRun entstehen keine
    SQL-/Providerressourcen; mit dem Schalter wird ein eigener SQL-Run erstellt.
    Native Ressourcenlisten, Runtimebindung und Scopefilter bleiben echt;
    Providerinventar und Auswahl müssen nach Cleanup unverändert sein.
    Der optionale SQL-Lauf prüft Lifecycle, Abfragen und eigene Entfernung;
    Hyper-V-Abnahmen und weitere Providerkombinationen bleiben separat.
.PARAMETER Provider
    Docker oder Podman; getrennte Ausführung erforderlich.
.PARAMETER CreateSqlRun
    Prüft zusätzlich einen eigenen echten SQL-Create/Query/Stop/Start/Remove-Run.
    Bei Fehlern bleibt dessen isolierter State für Recovery erhalten.
.PARAMETER GuidedConsole
    Verwendet den tatsächlichen Wartungsmenürouter und Fachdialog mit festen
    synthetischen Auswahl-/Bestätigungsleaves. Öffentlicher Core und native
    Providerbeobachtung bleiben echt; dies prüft keinen gerenderten Terminal.
.PARAMETER GuidedBrowserHttp
    Prüft den tatsächlichen Browser-HTTP-Handler über einen eigenen Loopback-
    Listener mit Read, Preview, abgelehnter und bestätigter Apply-Anfrage.
    Öffentlicher Core und Native-Reads bleiben echt; kein gerenderter Browser.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,[switch]$CreateSqlRun,[switch]$GuidedConsole,[switch]$GuidedBrowserHttp)
$ErrorActionPreference='Stop'
if ($GuidedConsole -and $GuidedBrowserHttp) {throw 'RUN_ARTIFACT_NATIVE_SINGLE_GUIDED_MODE_REQUIRED'}
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$parent=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-run-artifact-observation-'+[guid]::NewGuid().ToString('N'))
$data=Join-Path $parent 'Lab_Data'
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
$previous=@{}
$completion=[pscustomobject]@{SafeToDelete=$false}
$mutex=[Threading.Mutex]::new($false,$(if ($IsWindows) {'Global\SQL_Server_Lab_Runtime_Smoke'} else {'SQL_Server_Lab_Runtime_Smoke'}))
$mutexAcquired=$false
foreach ($name in @('SQL_SERVER_LAB_DATA_ROOT','SQL_SERVER_LAB_CONTROLLER_ID','SQL_SERVER_LAB_STATE')) {$previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try {
    try {$mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(15))} catch [Threading.AbandonedMutexException] {$mutexAcquired=$true}
    if (-not $mutexAcquired) { throw 'RUN_ARTIFACT_NATIVE_SMOKE_BUSY' }
    & $module {
        param($Root,$Selected,$CreateSql,$Completion,$Guided,$BrowserHttp)
        $stateRoot=Join-Path $Root 'State'
        $controller=[guid]::NewGuid().ToString('D')
        $env:SQL_SERVER_LAB_DATA_ROOT=$Root; $env:SQL_SERVER_LAB_CONTROLLER_ID=$controller; $env:SQL_SERVER_LAB_STATE=$stateRoot
        $marker=Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId $controller -Confirm:$false
        $location=New-LabStorageLocationRecord -ControllerId $controller -LabDataRoot $Root
        $null=Write-LabStorageConfiguration -Configuration ([pscustomobject]@{
            ControllerId=$controller;DefaultLocationId=$location.LocationId;DefaultDataRoot=$Root;LabDataLocations=@($location)})
        $binding=@((New-LabRunArtifactCreationBinding -Provider $Selected -StateRoot $stateRoot).Records)
        if ($binding.Count -ne 1 -or $binding[0].Status -cne 'AVAILABLE') {throw 'RUN_ARTIFACT_NATIVE_RUNTIME_UNAVAILABLE'}
        $context=Get-LabRunArtifactRuntimeContext -Provider $Selected -StateRoot $stateRoot
        function Read-ObservationInventory {
            $rows=@(foreach ($arguments in @(@('ps','-a','--no-trunc','--format','{{.ID}}'),@('volume','ls','--format','{{.Name}}'),@('network','ls','--format','{{.Name}}'))) {
                $native=Invoke-LabRunArtifactNative -Context $context -Arguments $arguments
                if ($native.ExitCode -ne 0) {throw 'RUN_ARTIFACT_NATIVE_INVENTORY_UNAVAILABLE'}
                @($native.Output | Sort-Object) -join '|'
            })
            Get-LabRetainedStoreHash $rows
        }
        $before=Read-ObservationInventory
        if ($CreateSql) {
            $password=[Security.SecureString]::new()
            $token='Artifact_'+[guid]::NewGuid().ToString('N')+'!Aa7'
            foreach ($character in $token.ToCharArray()) {$password.AppendChar($character)}
            $password.MakeReadOnly(); $token=$null
            $lab=$null
            try {
                $lab=New-SqlServerLab -Provider $Selected -Version 2025 -Profile compact -Cpu 1 -MemoryMB 1536 -SaPassword $password -LabName ('artifact-'+[guid]::NewGuid().ToString('N').Substring(0,8)) -StateRoot $stateRoot -SkipAssessment
                $query=Join-Path (Split-Path $Root -Parent) 'probe.sql'
                [IO.File]::WriteAllText($query,"IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) <> 17 THROW 50000, 'Unexpected SQL major', 1;")
                $result=Invoke-SqlServerLabScript -RunId $lab.RunId -StateRoot $stateRoot -ScriptPath $query -SaPassword $password
                if (-not $result.Success) {throw 'RUN_ARTIFACT_NATIVE_SQL_QUERY_FAILED'}
                $null=Stop-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Confirm:$false
                $null=Start-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot
                $result=Invoke-SqlServerLabScript -RunId $lab.RunId -StateRoot $stateRoot -ScriptPath $query -SaPassword $password
                if (-not $result.Success) {throw 'RUN_ARTIFACT_NATIVE_SQL_RESTART_FAILED'}
                $removed=Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false
                if ($removed.Status -cne 'REMOVED') {throw 'RUN_ARTIFACT_NATIVE_REMOVE_FAILED'}
                $state=Get-LabRunState -RunId $lab.RunId -StateRoot $stateRoot
                $run=[pscustomobject]@{RunId=$lab.RunId;ScopeId=$state.scopeId;RunDir=(Join-Path $stateRoot ('runs/'+$lab.RunId))}
            }
            catch {
                if ($lab) {
                    try { $null=Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false } catch {Write-Host 'RUN_ARTIFACT_NATIVE_CLEANUP_RECOVERY_REQUIRED'}
                }
                throw
            }
            finally {$password.Dispose()}
        }
        else {
            $run=New-LabRunState -StateRoot $stateRoot -Metadata @{name='Synthetic metadata acceptance';persistentData=$false;artifactRemovalRuntimeScopes=$binding}
            $state=Get-LabRunState -RunId $run.RunId -StateRoot $stateRoot
            $state.state='REMOVED'; Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'run-state.json') -InputObject $state
            $name='sql-lab-absent-'+[guid]::NewGuid().ToString('N')
            Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'cleanup-plan.json') -InputObject ([pscustomobject]@{
                runId=$run.RunId;scopeId=$run.ScopeId;status='COMPLETED';steps=@(
                    [pscustomobject]@{provider=$Selected;resourceType='container';resourceId=$name;action='remove';state='COMPLETED'},
                    [pscustomobject]@{provider=$Selected;resourceType='volume';resourceId=$name;action='remove';state='COMPLETED'})})
            Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject ([pscustomobject]@{
                runId=$run.RunId;scopeId=$run.ScopeId;instances=@([pscustomobject]@{
                    id='synthetic';provider=$Selected;containerName=$name;containerId=([guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N'))})})
        }
        $arguments=@{RunId=$run.RunId;StateRoot=$stateRoot;DataRoot=$Root}
        if (-not $BrowserHttp) {
            $plan=Get-SqlServerLabRunArtifactRemovalPlan @arguments
            if ($plan.Status -cne 'READY') {throw ('RUN_ARTIFACT_NATIVE_PLAN_BLOCKED: '+$plan.ReasonCode)}
        }
        if ($BrowserHttp) {
            $portProbe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
            try {$portProbe.Start();$listenerPort=$portProbe.LocalEndpoint.Port} finally {$portProbe.Stop()}
            $listener=[Net.HttpListener]::new();$client=[Net.Http.HttpClient]::new();$previews=@{}
            try {
                $origin="http://127.0.0.1:$listenerPort"
                $listener.Prefixes.Add($origin+'/');$listener.Start()
                $client.Timeout=[TimeSpan]::FromMinutes(2)
                $null=$client.DefaultRequestHeaders.TryAddWithoutValidation('Origin',$origin)
                function Send-ArtifactHttp($Payload) {
                    $content=[Net.Http.StringContent]::new(($Payload | ConvertTo-Json -Compress),[Text.Encoding]::UTF8,'application/json')
                    $response=$null
                    try {
                        $responseTask=$client.PostAsync($origin+'/api/run-artifact-removal',$content)
                        $accept=$listener.GetContextAsync()
                        if (-not $accept.Wait(10000)) {throw 'RUN_ARTIFACT_NATIVE_HTTP_ACCEPT_TIMEOUT'}
                        $http=$accept.GetAwaiter().GetResult()
                        try {
                            try {
                                $view=Invoke-LabRunArtifactRemovalHttpRequest -Request $http.Request -ListenerPort $listenerPort -Previews $previews
                                $http.Response.StatusCode=200;$body=$view | ConvertTo-Json -Depth 5 -Compress
                            } catch {$http.Response.StatusCode=400;$body='{"Code":"RUN_ARTIFACT_HTTP_UNCONFIRMED"}'}
                            $bytes=[Text.Encoding]::UTF8.GetBytes($body)
                            $http.Response.ContentType='application/json; charset=utf-8';$http.Response.ContentLength64=$bytes.Length
                            $http.Response.OutputStream.Write($bytes,0,$bytes.Length)
                        } finally {$http.Response.Close()}
                        $response=$responseTask.GetAwaiter().GetResult()
                        [pscustomobject]@{Status=[int]$response.StatusCode;View=($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json)}
                    } finally {if ($response) {$response.Dispose()};$content.Dispose()}
                }
                $read=Send-ArtifactHttp @{Action='Read'}
                if ($read.Status -ne 200 -or $read.View.Status -cne 'METADATA_ONLY' -or $read.View.CanApply -or
                    @($read.View.Targets).Count -ne 1 -or $read.View.Targets[0].RunId -cne $run.RunId) {throw 'RUN_ARTIFACT_NATIVE_HTTP_METADATA_INVALID'}
                $preview=Send-ArtifactHttp @{Action='Preview';RunId=$run.RunId}
                if ($preview.Status -ne 200 -or $preview.View.Status -cne 'READY' -or -not $preview.View.CanApply -or
                    $preview.View.PreviewToken -cnotmatch '^[a-f0-9]{32}$') {throw 'RUN_ARTIFACT_NATIVE_HTTP_PREVIEW_INVALID'}
                $apply=@{Action='Apply';RunId=$run.RunId;PreviewToken=$preview.View.PreviewToken;Confirmed=$false}
                $denied=Send-ArtifactHttp $apply
                if ($denied.Status -ne 400 -or -not (Test-Path -LiteralPath $run.RunDir)) {throw 'RUN_ARTIFACT_NATIVE_HTTP_CONFIRMATION_BARRIER'}
                $apply.Confirmed=$true;$applied=Send-ArtifactHttp $apply
                if ($applied.Status -ne 200 -or $applied.View.RunId -cne $run.RunId -or $applied.View.Status -cne 'REMOVED' -or
                    $applied.View.Changed -ne $true) {throw 'RUN_ARTIFACT_NATIVE_HTTP_APPLY_UNCONFIRMED'}
                $replayed=Send-ArtifactHttp $apply
                if ($replayed.Status -ne 400) {throw 'RUN_ARTIFACT_NATIVE_HTTP_REPLAY_ACCEPTED'}
                $result=$applied.View
            } finally {$listener.Stop();$listener.Close();$client.Dispose()}
        }
        elseif ($Guided) {
            $script:artifactConsoleAcceptanceRunId=$run.RunId
            $script:artifactConsoleAcceptanceSelections=0
            function Show-LabSubMenu { param($ScreenId,$Title,$Subtitle,$Items)
                if ($ScreenId -cne 'maintenance-menu' -or 'RunArtifactRemoval' -cnotin @($Items.Id)) {throw 'RUN_ARTIFACT_NATIVE_MENU_UNAVAILABLE'}
                'RunArtifactRemoval'
            }
            function Invoke-LabConsoleMenu { param($ScreenId,$Title,$Subtitle,$Items)
                $id=if ($ScreenId -ceq 'run-artifact-removal') {$script:artifactConsoleAcceptanceRunId}
                    elseif ($ScreenId -ceq 'run-artifact-removal-review') {'apply'} else {throw 'RUN_ARTIFACT_NATIVE_MENU_UNEXPECTED'}
                $item=@($Items | Where-Object Id -CEQ $id)
                if ($item.Count -ne 1 -or $item[0].Disabled) {throw 'RUN_ARTIFACT_NATIVE_SELECTION_BLOCKED'}
                $script:artifactConsoleAcceptanceSelections++
                [pscustomobject]@{Status='Selected';SelectedItem=$item[0]}
            }
            function Read-LabConfirm { param($Prompt,$Default)
                if ($Default -ne $false -or -not $Prompt.Contains($script:artifactConsoleAcceptanceRunId)) {throw 'RUN_ARTIFACT_NATIVE_CONFIRMATION_INVALID'}
                $true
            }
            function Wait-LabConsoleAcknowledgement {}
            Invoke-LabMenuAction -ActionName (Show-LabMaintenanceMenu)
            if ($script:artifactConsoleAcceptanceSelections -ne 2) {throw 'RUN_ARTIFACT_NATIVE_MENU_NOT_EXECUTED'}
            $result=Get-SqlServerLabRunArtifactRemovalPlan @arguments
        }
        else { $result=Invoke-SqlServerLabRunArtifactRemoval @arguments -ExpectedPlanKey $plan.PlanKey -Confirm:$false }
        if ($result.Status -cne 'REMOVED' -or (Test-Path -LiteralPath $run.RunDir) -or
            (Test-Path -LiteralPath (Join-Path $stateRoot ('scope-markers/'+$run.ScopeId+'.json')))) {throw 'RUN_ARTIFACT_NATIVE_ABSENCE_FAILED'}
        $after=Read-ObservationInventory
        $fresh=Get-LabRunArtifactRuntimeContext -Provider $Selected -StateRoot $stateRoot
        if ($before -cne $after -or $context.RuntimeScopeId -cne $fresh.RuntimeScopeId) {throw 'RUN_ARTIFACT_NATIVE_PROTECTION_CHANGED'}
        $Completion.SafeToDelete=$true
        Write-Host "${Selected}: own metadata removal and unchanged provider inventory PASS; real SQL lifecycle=$CreateSql; guided console handler=$Guided; real browser HTTP handler=$BrowserHttp"
    } $data $Provider ([bool]$CreateSqlRun) $completion ([bool]$GuidedConsole) ([bool]$GuidedBrowserHttp)
}
finally {
    try {
    foreach ($name in $previous.Keys) {[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')}
    $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $resolved=[IO.Path]::GetFullPath($parent)
    if (-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^sql-lab-run-artifact-observation-[a-f0-9]{32}$') {throw 'RUN_ARTIFACT_NATIVE_CLEANUP_BOUNDARY'}
    if ($completion.SafeToDelete -and (Test-Path -LiteralPath $resolved)) {Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop}
    elseif (Test-Path -LiteralPath $resolved) {Write-Host 'RUN_ARTIFACT_NATIVE_OWN_RECOVERY_SCOPE_RETAINED'}
    Remove-Module $module.Name -Force
    }
    finally {if ($mutexAcquired) {$mutex.ReleaseMutex()};$mutex.Dispose()}
}

#Requires -Version 7.2
# Readonly production guard composition with synthetic native/SQL boundaries.
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$module=Import-Module (Join-Path $repository 'SqlServerLab.psd1') -Force -PassThru -WarningAction SilentlyContinue
$cases=& $module {
    param($SyntheticRoot)
    $repository=$SyntheticRoot
    $names=@('Get-LabCmsInspectionSelection','Get-LabContainerRuntimeScopeEvidence','ConvertTo-LabContainerRuntimeScope','Get-LabHostToolInvocation','Get-LabSecret','Invoke-LabCmsInspectionSql','Assert-LabCmsInspectionReadPath')
    $saved=@{};foreach($name in $names){$saved[$name]=(Get-Item ('Function:'+$name)).ScriptBlock}
    $results=[Collections.Generic.List[object]]::new()
    try {
        Set-Item Function:script:Assert-LabCmsInspectionReadPath {param($Root,$Path) if(-not $Path.EndsWith('/secrets/sa-password.secret') -and -not $Path.EndsWith('\secrets\sa-password.secret')){throw 'UNEXPECTED_SECRET_PATH'}}
        Set-Item Function:script:Get-LabCmsInspectionSelection { $script:CmsFixtureSelection }
        Set-Item Function:script:Get-LabContainerRuntimeScopeEvidence {param($Provider)[pscustomobject]@{Provider=$Provider;Available=$true;Info=[pscustomobject]@{ID='synthetic-engine';Host=[pscustomobject]@{Hostname='synthetic-host'};Version=[pscustomobject]@{Version='synthetic-version'};Store=[pscustomobject]@{GraphRoot='synthetic-store'}}}}
        Set-Item Function:script:ConvertTo-LabContainerRuntimeScope {param($Evidence)[pscustomobject]@{Status='AVAILABLE';RuntimeId=('b'*64);Binding=[pscustomobject]@{EndpointKind='LOCAL_NPIPE'}}}
        Set-Item Function:script:Get-LabHostToolInvocation {param($Name)'Invoke-CmsSyntheticInspect'}
        Set-Item Function:script:Invoke-CmsSyntheticInspect {
            param($Command,$Id)
            if($Command -cne 'inspect' -or $Id -cne ('a'*64)){throw 'UNEXPECTED_NATIVE_SCOPE'}
            $script:CmsInspectCalls++;$global:LASTEXITCODE=0
            $script:CmsFixtureContainer|ConvertTo-Json -Depth 10 -Compress
        }
        Set-Item Function:script:Get-LabSecret {param($Path,$Name)$script:CmsSecretReads++;$secret=[SecureString]::new();foreach($character in 'SYNTHETIC_ONLY'.ToCharArray()){$secret.AppendChar($character)};$secret.MakeReadOnly();$secret}
        Set-Item Function:script:Invoke-LabCmsInspectionSql {
            param($Binding,$Secret)$script:CmsSqlOpens++
            if($Binding.HostName -cne '127.0.0.1' -or $Binding.Port -ne 15433){throw 'UNEXPECTED_SQL_ENDPOINT'}
            if($script:CmsFixtureCase -ceq 'post-native-drift'){$script:CmsFixtureContainer.NetworkSettings.Ports.'1433/tcp'[0].HostPort='15434'}
            if($script:CmsFixtureCase -ceq 'raw-error'){throw 'SYNTHETIC_PRIVATE_SQL_MESSAGE'}
            [pscustomobject]@{SqlMajor=17;ManagedRootCount=[long]1;ManagedGroupCount=[long]3;ManagedServerCount=[long]5}
        }
        foreach($case in @('observed','stored-host-changed','stored-port-changed','wildcard-port','multiple-ports','wrong-native-id','wrong-run-label','hyperv','post-native-drift','raw-error')){
            $script:CmsFixtureCase=$case;$script:CmsSecretReads=0;$script:CmsSqlOpens=0;$script:CmsInspectCalls=0
            $script:CmsFixtureSelection=[pscustomobject]@{RunId='11111111-1111-1111-1111-111111111111';InstanceId='primary';Provider='docker';Key=('c'*64);StateRoot=$repository;Run=[pscustomobject]@{state='RUNNING';scopeId='22222222-2222-2222-2222-222222222222'};Instance=[pscustomobject]@{containerId=('a'*64);host='127.0.0.1';port=15433;version='2025'};Layout=[pscustomobject]@{CmsUseRootGroup=$true}}
            $script:CmsFixtureContainer=[pscustomobject]@{Id=('a'*64);State=[pscustomobject]@{Running=$true};Config=[pscustomobject]@{Labels=[pscustomobject]@{'sql-server-lab.run-id'=$script:CmsFixtureSelection.RunId;'sql-server-lab.scope-id'=$script:CmsFixtureSelection.Run.scopeId;'sql-server-lab.instance-id'='primary'}};NetworkSettings=[pscustomobject]@{Ports=[pscustomobject]@{'1433/tcp'=@([pscustomobject]@{HostIp='127.0.0.1';HostPort='15433'})}}}
            switch($case){
                'stored-host-changed' {$script:CmsFixtureSelection.Instance.host='192.0.2.10'}
                'stored-port-changed' {$script:CmsFixtureSelection.Instance.port=15434}
                'wildcard-port' {$script:CmsFixtureContainer.NetworkSettings.Ports.'1433/tcp'[0].HostIp='0.0.0.0'}
                'multiple-ports' {$script:CmsFixtureContainer.NetworkSettings.Ports.'1433/tcp'+=[pscustomobject]@{HostIp='::1';HostPort='15433'}}
                'wrong-native-id' {$script:CmsFixtureContainer.Id=('d'*64)}
                'wrong-run-label' {$script:CmsFixtureContainer.Config.Labels.'sql-server-lab.run-id'='33333333-3333-3333-3333-333333333333'}
                'hyperv' {$script:CmsFixtureSelection.Provider='hyperv'}
            }
            $result=Invoke-LabCmsInspectionWorkerCore -ExpectedPlanKey ('c'*64)
            $results.Add([pscustomobject]@{Case=$case;Result=$result;SecretReads=$script:CmsSecretReads;SqlOpens=$script:CmsSqlOpens;NativeReads=$script:CmsInspectCalls})
        }
    } finally {foreach($name in $names){Set-Item ('Function:script:'+$name) $saved[$name]};Remove-Item Function:script:Invoke-CmsSyntheticInspect -ErrorAction SilentlyContinue}
    ,$results
} $repository
$passed=0
foreach($case in $cases){
    $valid=if($case.Case -ceq 'observed'){$case.Result.Status -ceq 'OBSERVED' -and $case.Result.ManagedServerCount -eq 5 -and $case.SecretReads -eq 1 -and $case.SqlOpens -eq 1 -and $case.NativeReads -eq 2}else{$case.Result.Status -ceq 'UNKNOWN' -and $null -eq $case.Result.ManagedServerCount -and $null -eq $case.Result.SqlMajor}
    if($case.Case -notin @('observed','post-native-drift','raw-error')){$valid=$valid -and $case.SecretReads -eq 0 -and $case.SqlOpens -eq 0}
    if(($case.Result|ConvertTo-Json -Compress) -match 'SYNTHETIC_PRIVATE|SYNTHETIC_ONLY|192\.0\.2\.10'){$valid=$false}
    if(-not $valid){throw ('ASSERT actual CMS '+$case.Case+' pre-secret barrier and readonly composition')}
    $passed++;Write-Host ('PASS actual CMS '+$case.Case+' pre-secret barrier and nullable sanitized result')
}
Write-Host ('CMS FOCUS '+$passed+' PASS')

# Actual file-authority and public status: only an isolated synthetic state root.
$ownLeaf='sql-lab-cms-inspection-'+[guid]::NewGuid().ToString('N')
$ownParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$ownRoot=Join-Path $ownParent $ownLeaf
$null=New-Item -ItemType Directory -Path (Join-Path $ownRoot 'catalog'),(Join-Path $ownRoot 'runs/11111111-1111-1111-1111-111111111111') -Force
function Write-CmsFixtureJson($Relative,$Value){[IO.File]::WriteAllText((Join-Path $ownRoot $Relative),($Value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$configuration=[ordered]@{ContractVersion='SqlServerLab.ConnectionCenterCms/1.1';RunId='11111111-1111-1111-1111-111111111111';Provider='docker';Purpose='Central Management Server';AdoptedExistingEnvironment=$true}
$run=[ordered]@{runId=$configuration.RunId;scopeId='22222222-2222-2222-2222-222222222222';state='RUNNING';revision=1}
$connection=[ordered]@{runId=$configuration.RunId;scopeId=$run.scopeId;instances=@([ordered]@{id='primary';provider='docker';host='127.0.0.1';port=15433;version='2025';containerId=('a'*64)})}
try {
    Write-CmsFixtureJson 'catalog/sql-connection-center-cms.json' $configuration
    Write-CmsFixtureJson ('runs/'+$run.runId+'/run-state.json') $run
    Write-CmsFixtureJson ('runs/'+$run.runId+'/connection-info.json') $connection
    $checks=& $module {
        param($Root)
        $savedRoot=(Get-Item Function:Get-LabStateRoot).ScriptBlock;$savedSecret=(Get-Item Function:Get-LabSecret).ScriptBlock;$savedNative=(Get-Item Function:Get-LabContainerRuntimeScopeEvidence).ScriptBlock
        try {
            $script:CmsOwnFixtureRoot=$Root
            Set-Item Function:script:Get-LabStateRoot {$script:CmsOwnFixtureRoot}
            Set-Item Function:script:Get-LabSecret {throw 'IMPLICIT_SECRET_FORBIDDEN'}
            Set-Item Function:script:Get-LabContainerRuntimeScopeEvidence {throw 'IMPLICIT_NATIVE_FORBIDDEN'}
            $view=(Invoke-SqlServerLabWorkflowAction -Action GetCmsInspectionState).Result
            [pscustomobject]@{View=$view;Selection=(Get-LabCmsInspectionSelection -StateRoot $Root)}
        }finally{Set-Item Function:script:Get-LabStateRoot $savedRoot;Set-Item Function:script:Get-LabSecret $savedSecret;Set-Item Function:script:Get-LabContainerRuntimeScopeEvidence $savedNative}
    } $ownRoot
    if($checks.View.Status -cne 'NOT_CHECKED' -or $checks.View.SelectionKey -cnotmatch '^[a-f0-9]{64}$' -or $null -ne $checks.View.ManagedServerCount -or $null -ne $checks.View.ObservedAt){throw 'ASSERT actual public registration-only status'}
    $passed++;Write-Host 'PASS actual public registration-only status validates existing 1.1 authority without native or secret read'
    $cloneRoot=Join-Path $ownRoot 'byte-identical-clone'
    $null=New-Item -ItemType Directory -Path (Join-Path $cloneRoot 'catalog'),(Join-Path $cloneRoot ('runs/'+$run.runId)) -Force
    foreach($relative in @('catalog/sql-connection-center-cms.json',('runs/'+$run.runId+'/run-state.json'),('runs/'+$run.runId+'/connection-info.json'))){Copy-Item -LiteralPath (Join-Path $ownRoot $relative) -Destination (Join-Path $cloneRoot $relative)}
    $clone=& $module {param($Root)Get-LabCmsInspectionSelection -StateRoot $Root} $cloneRoot
    if($clone.Key -ceq $checks.Selection.Key){throw 'ASSERT byte-identical clone root cannot reuse selection key'}
    $cloneBarrier=& $module {
        param($CloneRoot,$OriginalKey)
        $names=@('Get-LabStateRoot','Get-LabSecret','Invoke-LabCmsInspectionSql','Get-LabContainerRuntimeScopeEvidence');$saved=@{};foreach($name in $names){$saved[$name]=(Get-Item ('Function:'+$name)).ScriptBlock}
        try {
            $script:CmsCloneRoot=$CloneRoot;$script:CmsCloneSecret=0;$script:CmsCloneSql=0;$script:CmsCloneNative=0
            Set-Item Function:script:Get-LabStateRoot {$script:CmsCloneRoot}
            Set-Item Function:script:Get-LabSecret {$script:CmsCloneSecret++;throw 'CLONE_SECRET_FORBIDDEN'}
            Set-Item Function:script:Invoke-LabCmsInspectionSql {$script:CmsCloneSql++;throw 'CLONE_SQL_FORBIDDEN'}
            Set-Item Function:script:Get-LabContainerRuntimeScopeEvidence {$script:CmsCloneNative++;throw 'CLONE_NATIVE_FORBIDDEN'}
            $result=Invoke-LabCmsInspectionWorkerCore -ExpectedPlanKey $OriginalKey
            [pscustomobject]@{Result=$result;SecretReads=$script:CmsCloneSecret;SqlOpens=$script:CmsCloneSql;NativeReads=$script:CmsCloneNative}
        }finally{foreach($name in $names){Set-Item ('Function:script:'+$name) $saved[$name]}}
    } $cloneRoot $checks.Selection.Key
    if($cloneBarrier.Result.Code -cne 'CMS_INSPECTION_SELECTION_CHANGED' -or $cloneBarrier.SecretReads -ne 0 -or $cloneBarrier.SqlOpens -ne 0 -or $cloneBarrier.NativeReads -ne 0){throw 'ASSERT actual clone-root worker fails before native/secret/SQL'}
    $passed++;Write-Host 'PASS actual byte-identical clone-root changes key and blocks before native/secret/SQL'
    $originalKey=$checks.Selection.Key;$run.revision=2;Write-CmsFixtureJson ('runs/'+$run.runId+'/run-state.json') $run
    $changed=& $module {param($Root)Get-LabCmsInspectionSelection -StateRoot $Root} $ownRoot
    if($changed.Key -ceq $originalKey){throw 'ASSERT actual run revision changes selection authority'}
    $passed++;Write-Host 'PASS actual run revision bytes invalidate existing inspection selection'
    $connection.instances+= $connection.instances[0];Write-CmsFixtureJson ('runs/'+$run.runId+'/connection-info.json') $connection
    $rejected=try{& $module {param($Root)Get-LabCmsInspectionSelection -StateRoot $Root} $ownRoot;$false}catch{$true}
    if(-not $rejected){throw 'ASSERT duplicate primary instance fails closed'}
    $passed++;Write-Host 'PASS actual stored duplicate primary is not registration authority'
    $connection.instances=@($connection.instances[0]);Write-CmsFixtureJson ('runs/'+$run.runId+'/connection-info.json') $connection
    [IO.File]::WriteAllText((Join-Path $ownRoot 'catalog/sql-connection-center-groups.json'),'{broken',[Text.UTF8Encoding]::new($false))
    $rejected=try{& $module {param($Root)Get-LabCmsInspectionSelection -StateRoot $Root} $ownRoot;$false}catch{$true}
    if(-not $rejected){throw 'ASSERT corrupted layout cannot silently default'}
    $passed++;Write-Host 'PASS actual corrupted layout stays unknown instead of default authority'
    $outsideRejected=try{& $module {param($Root,$Outside)Assert-LabCmsInspectionReadPath -Root $Root -Path $Outside} $ownRoot (Join-Path $repository 'README.md');$false}catch{$true}
    if(-not $outsideRejected){throw 'ASSERT outside read path rejected before read'}
    $passed++;Write-Host 'PASS actual outside secret/file path fails before content read'
} finally {
    $resolved=[IO.Path]::GetFullPath($ownRoot).TrimEnd('\','/')
    $item=Get-Item -LiteralPath $resolved -Force
    if([IO.Path]::GetDirectoryName($resolved) -cne $ownParent -or [IO.Path]::GetFileName($resolved) -cne $ownLeaf -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'CMS_FIXTURE_CLEANUP_SCOPE_INVALID'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

. (Join-Path $repository 'Tools/WorkflowUiJsonBody.ps1')
$adapterAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'Tools/Start-SqlServerLabUi.ps1'),[ref]$null,[ref]$null)
$adapter=$adapterAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-UiCmsInspectionRequest'},$true)
. ([scriptblock]::Create($adapter.Extent.Text))
function New-CmsRequest($Parameters,$Origin='http://127.0.0.1:9999'){
    [pscustomobject]@{HttpMethod='POST';ContentType='application/json';Headers=@{Origin=$Origin};Url=[uri]'http://127.0.0.1:9999/api/cms-inspection';ContentEncoding=[Text.Encoding]::UTF8;InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((@{action='InspectCms';parameters=$Parameters}|ConvertTo-Json -Depth 5)))}
}
foreach($parameters in @(@{ExpectedPlanKey=('c'*64);HostName='192.0.2.10'},@{ExpectedPlanKey=('c'*64);SaPassword='SYNTHETIC_PRIVATE'},@{ExpectedPlanKey=('c'*64);StateRoot='synthetic'},@{ExpectedPlanKey=@('c'*64)},@{ExpectedPlanKey='not-a-key'})){
    $rejected=try{$null=Invoke-UiCmsInspectionRequest (New-CmsRequest $parameters);$false}catch{$_.Exception.Message -ceq 'CMS_INSPECTION_REQUEST_INVALID'}
    if(-not $rejected){throw 'ASSERT actual HTTP accepts only bound scalar key'};$passed++;Write-Host 'PASS actual HTTP rejects caller endpoint/secret/path and non-scalar selection'
}
$rejected=try{$null=Invoke-UiCmsInspectionRequest (New-CmsRequest @{ExpectedPlanKey=('c'*64)} 'https://foreign.invalid');$false}catch{$_.Exception.Message -ceq 'CMS_INSPECTION_ORIGIN_INVALID'}
if(-not $rejected){throw 'ASSERT foreign origin rejected'};$passed++;Write-Host 'PASS actual HTTP rejects foreign origin before inspection'
$original=& $module {(Get-Item Function:Invoke-LabCmsInspection).ScriptBlock}
try {
    & $module {Set-Item Function:script:Invoke-LabCmsInspection {param($ExpectedPlanKey)if($ExpectedPlanKey -cne ('c'*64)){throw 'UNEXPECTED_KEY'};New-LabCmsInspectionResult -Status OBSERVED -Code CMS_INSPECTION_OBSERVED -Selection ([pscustomobject]@{RunId='11111111-1111-1111-1111-111111111111';InstanceId='primary';Provider='docker';Key=$ExpectedPlanKey}) -Observation ([pscustomobject]@{SqlMajor=17;ManagedGroupCount=[long]3;ManagedServerCount=[long]0})}}
    $result=Invoke-UiCmsInspectionRequest (New-CmsRequest @{ExpectedPlanKey=('c'*64)})
    if($result.Action -cne 'InspectCms' -or $result.Result.ManagedServerCount -ne 0){throw 'ASSERT real HTTP reaches same public readonly core'}
    $passed++;Write-Host 'PASS actual HTTP reaches public readonly core with genuine zero and no mutation confirmation'
}finally{& $module {param($Function)Set-Item Function:script:Invoke-LabCmsInspection $Function} $original}
Write-Host ('CMS EXTENDED FOCUS '+$passed+' PASS')

# Actual bounded parent process and strict DTO validation; child has no provider/SQL code.
$workerCases=& $module {
 param($FixtureRoot)
 $savedSelection=(Get-Item Function:Get-LabCmsInspectionSelection).ScriptBlock;$savedModuleRoot=$script:ModuleRoot;$savedEnv=$env:SQL_SERVER_LAB_CMS_FIXTURE_CASE
 try {
  $script:ModuleRoot=$FixtureRoot
  Set-Item Function:script:Get-LabCmsInspectionSelection {[pscustomobject]@{RunId='11111111-1111-1111-1111-111111111111';InstanceId='primary';Provider='docker';Key=('c'*64)}}
  foreach($case in @('observed','unknown','wrong-run','wrong-provider','wrong-key','extra','private-code','negative','fractional','unsafe','unknown-zero','future','stale','invalid-json','timeout')){
   $env:SQL_SERVER_LAB_CMS_FIXTURE_CASE=$case;$watch=[Diagnostics.Stopwatch]::StartNew()
   $result=Invoke-LabCmsInspection -ExpectedPlanKey ('c'*64) -TimeoutMilliseconds $(if($case -ceq 'timeout'){1000}else{20000})
   [pscustomobject]@{Case=$case;Result=$result;Milliseconds=$watch.ElapsedMilliseconds}
  }
 }finally{Set-Item Function:script:Get-LabCmsInspectionSelection $savedSelection;$script:ModuleRoot=$savedModuleRoot;$env:SQL_SERVER_LAB_CMS_FIXTURE_CASE=$savedEnv}
} (Join-Path $PSScriptRoot 'CmsInspectionWorker')
foreach($case in $workerCases){
 $valid=if($case.Case -ceq 'observed'){$case.Result.Status -ceq 'OBSERVED' -and $case.Result.ManagedServerCount -eq 0}elseif($case.Case -ceq 'timeout'){$case.Result.Code -ceq 'CMS_INSPECTION_TIMEOUT' -and $case.Milliseconds -lt 6000}else{$case.Result.Status -ceq 'UNKNOWN' -and $null -eq $case.Result.ManagedServerCount}
 if(-not $valid -or ($case.Result|ConvertTo-Json -Compress) -match 'SYNTHETIC_PRIVATE'){throw ('ASSERT actual CMS worker '+$case.Case+' strict DTO and finite own process')}
 $passed++;Write-Host ('PASS actual CMS worker '+$case.Case+' strict DTO and bounded own process')
}
$cli=& $module {
 $names=@('Get-LabCmsInspectionState','Invoke-LabCmsInspection','Invoke-LabConsoleMenu','Write-LabInfo','Wait-LabConsoleAcknowledgement')
 $saved=@{};foreach($name in $names){$saved[$name]=(Get-Item ('Function:'+$name)).ScriptBlock}
 try {
  $script:CmsCliOriginalMenu=$saved['Invoke-LabConsoleMenu'];$script:CmsCliCalls=0;$script:CmsCliReads=0;$script:CmsCliFrames=[Collections.Generic.List[object]]::new();$script:CmsCliMessages=[Collections.Generic.List[string]]::new()
  Set-Item Function:script:Get-LabCmsInspectionState {New-LabCmsInspectionResult -Status NOT_CHECKED -Code CMS_INSPECTION_NOT_CHECKED -Selection ([pscustomobject]@{RunId='11111111-1111-1111-1111-111111111111';InstanceId='primary';Provider='docker';Key=('c'*64)})}
  Set-Item Function:script:Invoke-LabCmsInspection {param($ExpectedPlanKey)if($ExpectedPlanKey -cne ('c'*64)){throw 'UNEXPECTED_CLI_KEY'};$script:CmsCliReads++;New-LabCmsInspectionResult -Status OBSERVED -Code CMS_INSPECTION_OBSERVED -Observation ([pscustomobject]@{SqlMajor=17;ManagedGroupCount=[long]3;ManagedServerCount=[long]0})}
  Set-Item Function:script:Write-LabInfo {param($Message)$script:CmsCliMessages.Add([string]$Message)}
  Set-Item Function:script:Wait-LabConsoleAcknowledgement {}
  Set-Item Function:script:Invoke-LabConsoleMenu {
   param($ScreenId,$Title,$Subtitle,$Items)
   $script:CmsCliCalls++
   if($script:CmsCliCalls -eq 1){$script:CmsCliFallback=(& $script:CmsCliOriginalMenu -ScreenId $ScreenId -Title $Title -Items $Items -ForceFallback -ReadInput {'1'} -Snapshot $null 6>$null).SelectedItem.Id}
   $script:CmsCliKey=if($script:CmsCliCalls -eq 1){'Escape'}else{'Enter'}
   & $script:CmsCliOriginalMenu -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -SelectedId 'inspect' -Snapshot $null -Capability ([pscustomobject]@{Supported=$true}) -StatusProvider $null -ReadKey {[pscustomobject]@{Key=$script:CmsCliKey;KeyChar=[char]0;Modifiers=[ConsoleModifiers]0}} -FrameWriter {param($session,$frame)$script:CmsCliFrames.Add($frame)} -GetViewport {[pscustomobject]@{Width=180;Height=22}} -SessionFactory {[pscustomobject]@{OriginTop=0;PreviousLineCount=0;ForegroundColor='Gray'}} -SessionCompleter {param($session)}
  }
  Invoke-LabCmsInspectionInteractive;$cancelReads=$script:CmsCliReads
  Invoke-LabCmsInspectionInteractive
  [pscustomobject]@{CancelReads=$cancelReads;Reads=$script:CmsCliReads;Fallback=$script:CmsCliFallback;Frames=$script:CmsCliFrames.Count;Messages=@($script:CmsCliMessages)}
 }finally{foreach($name in $names){Set-Item ('Function:script:'+$name) $saved[$name]}}
}
if($cli.CancelReads -ne 0 -or $cli.Reads -ne 1 -or $cli.Fallback -cne 'inspect' -or $cli.Frames -ne 2 -or ($cli.Messages -join ' ') -notmatch 'markierte Server: 0'){throw 'ASSERT actual CMS CLI cancel/cursor/fallback and zero'}
$passed++;Write-Host 'PASS actual CMS CLI cursor/fallback cancel performs no inspection, explicit bound selection preserves zero'
Write-Host ('CMS COMPLETE FOCUS '+$passed+' PASS')

# Real configured CMS menu entry: candidates and provider repair are forbidden before selection.
$entry=& $module {
 param($Root)
 $names=@('Get-LabConnectionCenterCmsConfiguration','Get-LabConnectionCenterConfiguration','Get-LabConnectionCenterCmsEnvironmentCandidates','Get-AvailableLabProviders','Get-LabRunRuntimeStatus','Sync-SqlServerLabCms','Invoke-LabConsoleMenu','Invoke-LabCmsInspectionInteractive','Get-LabStateRoot','Get-LabSecret','Invoke-LabCmsInspectionSql')
 $saved=@{};foreach($name in $names){$saved[$name]=(Get-Item ('Function:'+$name)).ScriptBlock}
 try {
  $script:CmsEntryRoot=$Root;$script:CmsEntryChoice='cancel';$script:CmsEntryDispatch=0
  Set-Item Function:script:Get-LabStateRoot {$script:CmsEntryRoot}
  Set-Item Function:script:Get-LabConnectionCenterCmsConfiguration {[pscustomobject]@{RunId='11111111-1111-1111-1111-111111111111';Provider='docker'}}
  Set-Item Function:script:Get-LabConnectionCenterConfiguration {[pscustomobject]@{CmsShowGeneratedPasswordInName=$false}}
  foreach($name in @('Get-LabConnectionCenterCmsEnvironmentCandidates','Get-AvailableLabProviders','Get-LabRunRuntimeStatus','Sync-SqlServerLabCms','Get-LabSecret','Invoke-LabCmsInspectionSql')){Set-Item ('Function:script:'+$name) {throw 'IMPLICIT_CMS_SIDE_EFFECT_FORBIDDEN'}}
  Set-Item Function:script:Invoke-LabConsoleMenu {param($ScreenId,$Items)if($ScreenId -cne 'connection-center-cms' -or @($Items|Where-Object Id -ceq inspect).Count -ne 1){throw 'UNEXPECTED_CMS_ENTRY'};if($script:CmsEntryChoice -ceq 'cancel'){[pscustomobject]@{Status='Cancelled'}}else{[pscustomobject]@{Status='Selected';SelectedItem=[pscustomobject]@{Id='inspect'}}}}
  Set-Item Function:script:Invoke-LabCmsInspectionInteractive {$script:CmsEntryDispatch++}
  Invoke-LabCmsInteractive -StateRoot $Root 6>$null;$cancel=$script:CmsEntryDispatch
  $script:CmsEntryChoice='inspect';Invoke-LabCmsInteractive -StateRoot $Root 6>$null
  Invoke-LabCmsInteractive -StateRoot (Join-Path $Root 'synthetic-other-root') 6>$null
  [pscustomobject]@{Cancel=$cancel;Dispatch=$script:CmsEntryDispatch}
 }finally{foreach($name in $names){Set-Item ('Function:script:'+$name) $saved[$name]}}
} $repository
if($entry.Cancel -ne 0 -or $entry.Dispatch -ne 1){throw 'ASSERT configured outer CLI entry has no implicit candidate/provider/repair/sync'}
$passed++;Write-Host 'PASS actual configured CMS outer CLI cancel and inspect dispatch without candidates/provider repair/sync'
$passed++;Write-Host 'PASS actual custom-root CMS menu cannot redirect to active CMS, read secrets or open SQL'
Write-Host ('CMS FINAL FOCUS '+$passed+' PASS')

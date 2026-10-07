#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
if(-not $IsWindows){
    $module=Import-Module (Join-Path $repository 'SqlServerLab.psd1') -Force -PassThru -WarningAction SilentlyContinue
    $blocked=try{& $module {Get-LabSetupWriteProbeBinding '11111111-1111-1111-1111-111111111111'};$false}catch{$_.Exception.Message -ceq 'INITIAL_SETUP_PROBE_PLATFORM_UNSUPPORTED'}
    if(-not $blocked){throw 'ASSERT unsupported platform fails before filesystem probe'}
    Write-Host 'PASS unsupported platform fails before filesystem probe'
    Write-Host 'NOT_EXECUTED Windows-only real filesystem proof'
    return
}
$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$leaf='sql-lab-writeability-check-'+[guid]::NewGuid().ToString('N')
$fixture=Join-Path $parent $leaf
$previous=@{}; foreach($name in @('SQL_SERVER_LAB_MEDIA_ROOT','SQL_SERVER_LAB_DATA_ROOT','SQL_SERVER_LAB_CONTROLLER_ID')){$previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$count=0
function Assert-Probe($Condition,$Name){if(-not $Condition){throw ('ASSERT '+$Name)};$script:count++;Write-Host ('PASS '+$Name)}
try {
    if(Test-Path -LiteralPath $fixture){throw 'FIXTURE_COLLISION'}
    $null=[IO.Directory]::CreateDirectory($fixture)
    foreach($name in $previous.Keys){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
    $module=Import-Module (Join-Path $repository 'SqlServerLab.psd1') -Force -PassThru -WarningAction SilentlyContinue
    & $module {
        Set-Item Function:script:Get-LabMediaRootCandidates { if($env:SQL_SERVER_LAB_MEDIA_ROOT){[pscustomobject]@{Source='ProcessEnvironment';Path=$env:SQL_SERVER_LAB_MEDIA_ROOT;ResolvedPath=$env:SQL_SERVER_LAB_MEDIA_ROOT;Status='READY';Selected=$true}} }
        Set-Item Function:script:Get-LabMediaRootDefault { $env:SQL_SERVER_LAB_MEDIA_ROOT }
        Set-Item Function:script:Get-LabDataRootDefault { $env:SQL_SERVER_LAB_DATA_ROOT }
    }
    $root=Join-Path $fixture 'Lab_Data';$media=Join-Path $fixture 'Lab_Base'
    $null=& $module {param($Root,$Media) Invoke-LabInitialSetup -LabDataRoot $Root -MediaRoot $Media -DefaultDataRoot $Root -ProcessEnvironmentOnly -Confirm:$false} $root $media
    $location=& $module {(Get-LabStorageConfiguration).LabDataLocations[0]}
    $before=@(Get-ChildItem -LiteralPath $root -Force | Select-Object -ExpandProperty Name)
    $marker=Join-Path $root '.sql-server-lab-root.json';$markerHash=(Get-FileHash -LiteralPath $marker).Hash
    $state=(Invoke-SqlServerLabWorkflowAction -Action GetInitialSetupState).Result
    Assert-Probe ($state.Writeability -ceq 'NOT_CHECKED') 'readonly status never claims a probe'
    $plan=(Invoke-SqlServerLabWorkflowAction -Action PlanSetupWriteability -SetupLocationId $location.LocationId).Result
    Assert-Probe ($plan.LocationId -ceq $location.LocationId -and $plan.WriteBytes -eq 1) 'real public preview binds exactly one registered location'
    Assert-Probe (-not (Compare-Object $before @(Get-ChildItem -LiteralPath $root -Force | Select-Object -ExpandProperty Name))) 'preview creates no leaf'
    $rejected=try{Invoke-SqlServerLabWorkflowAction -Action ProbeSetupWriteability -SetupWriteabilityPlanId $plan.PlanId;$false}catch{$_.Exception.Message -match 'CONFIRMATION_REQUIRED'}
    Assert-Probe $rejected 'real public action requires confirmation'
    $whatIf=& $module {param($Id) Invoke-LabInitialSetupWriteabilityPlan -PlanId $Id -Confirmed -WhatIf} $plan.PlanId
    Assert-Probe (-not $whatIf) 'WhatIf retains plan without execution'
    $result=(Invoke-SqlServerLabWorkflowAction -Action ProbeSetupWriteability -SetupWriteabilityPlanId $plan.PlanId -ConfirmWriteability).Result
    Assert-Probe ($result.Status -ceq 'WRITABLE' -and $result.OwnLeafAbsent -and -not $result.PrimaryCode -and -not $result.CleanupCode) ('real bounded worker writes flushes and independently confirms absence: '+$result.Status+'/'+$result.PrimaryCode+'/'+$result.CleanupCode)
    Assert-Probe ((Get-FileHash -LiteralPath $marker).Hash -ceq $markerHash -and -not (Compare-Object $before @(Get-ChildItem -LiteralPath $root -Force | Select-Object -ExpandProperty Name))) 'marker and other directory entries unchanged'
    $replayed=try{Invoke-SqlServerLabWorkflowAction -Action ProbeSetupWriteability -SetupWriteabilityPlanId $plan.PlanId -ConfirmWriteability;$false}catch{$_.Exception.Message -match 'UNKNOWN_OR_EXPIRED'}
    Assert-Probe $replayed 'consumed preview cannot replay'
    Assert-Probe ((Invoke-SqlServerLabWorkflowAction -Action GetInitialSetupState).Result.Writeability -ceq 'NOT_CHECKED') 'momentary result never changes readonly discovery'
    $guardPlan=(Invoke-SqlServerLabWorkflowAction -Action PlanSetupWriteability -SetupLocationId $location.LocationId).Result
    $record=& $module {param($Id) $entry=$null;$null=$script:SetupWriteProbePlans.TryGetValue($Id,[ref]$entry);$entry} $guardPlan.PlanId
    $collision=Join-Path $root $record.Leaf
    [IO.File]::WriteAllText($collision,'SYNTHETIC_OWN_COLLISION')
    $collisionResult=& $module {param($Record) Invoke-LabSetupWriteProbeWorkerCore -Record $Record -Mode Probe} $record
    Assert-Probe (-not $collisionResult.Created -and -not $collisionResult.Written -and -not $collisionResult.Absent -and $collisionResult.CleanupCode -and [IO.File]::ReadAllText($collision) -ceq 'SYNTHETIC_OWN_COLLISION') 'CreateNew collision preserves existing bytes and fails cleanup closed'
    [IO.File]::Delete($collision)
    $alternate=Join-Path $fixture 'own-alternate';$null=[IO.Directory]::CreateDirectory($alternate)
    $guardResult=& $module {
        param($Record,$Alternate)
        $script:WriteProbeOriginalBinding=${function:Get-LabSetupWriteProbeBinding};$script:WriteProbeBindingCalls=0
        $script:WriteProbeTestRoot=$Record.Binding.Root;$script:WriteProbeTestAlternate=$Alternate
        $script:WriteProbeRenameBlocked=$false;$script:WriteProbeReparseBlocked=$false
        try {
            Set-Item Function:script:Get-LabSetupWriteProbeBinding {
                param($LocationId)
                $script:WriteProbeBindingCalls++
                if($script:WriteProbeBindingCalls -eq 3){
                    try{[IO.Directory]::Move($script:WriteProbeTestRoot,($script:WriteProbeTestRoot+'-renamed'))}catch{$script:WriteProbeRenameBlocked=$true}
                    try{$null=New-Item -ItemType Junction -Path $script:WriteProbeTestRoot -Target $script:WriteProbeTestAlternate -Force -ErrorAction Stop}catch{$script:WriteProbeReparseBlocked=$true}
                }
                & $script:WriteProbeOriginalBinding $LocationId
            }
            $worker=Invoke-LabSetupWriteProbeWorkerCore -Record $Record -Mode Probe
            [pscustomobject]@{Worker=$worker;RenameBlocked=$script:WriteProbeRenameBlocked;ReparseBlocked=$script:WriteProbeReparseBlocked}
        } finally {Set-Item Function:script:Get-LabSetupWriteProbeBinding $script:WriteProbeOriginalBinding}
    } $record $alternate
    Assert-Probe ($guardResult.RenameBlocked -and $guardResult.ReparseBlocked -and $guardResult.Worker.Written -and $guardResult.Worker.Absent -and -not $guardResult.Worker.PrimaryCode -and -not $guardResult.Worker.CleanupCode) 'actual worker blocks directory rename and reparse replacement before byte write'
    Assert-Probe (-not @(Get-ChildItem -LiteralPath $alternate -Force).Count -and (Get-FileHash -LiteralPath $marker).Hash -ceq $markerHash) 'exchange target and original marker remain unchanged'
    $expired=& $module {param($Record) $copy=$Record|ConvertTo-Json -Depth 12|ConvertFrom-Json -Depth 12;$copy.ExpiresAt=[datetime]::UtcNow.AddMinutes(-1);Invoke-LabSetupWriteProbeWorkerCore -Record $copy -Mode Probe} $record
    Assert-Probe (-not $expired.Created -and -not $expired.Written -and $expired.PrimaryCode -ceq 'INITIAL_SETUP_PROBE_PLAN_UNKNOWN_OR_EXPIRED' -and $expired.Absent) 'worker independently rejects expiry before CreateNew'
    $originalMarker=[IO.File]::ReadAllBytes($marker)
    try {
        [IO.File]::AppendAllText($marker,"`n ")
        $stale=& $module {param($Record) Invoke-LabSetupWriteProbeWorkerCore -Record $Record -Mode Probe} $record
        Assert-Probe (-not $stale.Created -and -not $stale.Written -and $stale.PrimaryCode -ceq 'INITIAL_SETUP_PROBE_PREVIEW_STALE' -and $stale.CleanupCode -ceq 'INITIAL_SETUP_PROBE_CLEANUP_BINDING_CHANGED') 'marker drift blocks mutation and never fabricates absence'
    } finally {[IO.File]::WriteAllBytes($marker,$originalMarker)}
    . (Join-Path $repository 'Tools/WorkflowUiJsonBody.ps1')
    $serverAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'Tools/Start-SqlServerLabUi.ps1'),[ref]$null,[ref]$null)
    $adapter=$serverAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-UiInitialSetupRequest'},$true)
    . ([scriptblock]::Create($adapter.Extent.Text))
    function New-ProbeRequest($Payload){[pscustomobject]@{HttpMethod='POST';ContentType='application/json';Headers=@{Origin='http://127.0.0.1:9999'};Url=[uri]'http://127.0.0.1:9999/api/initial-setup';ContentEncoding=[Text.Encoding]::UTF8;InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(($Payload|ConvertTo-Json -Depth 12)))}}
    foreach($parameters in @(@{SetupWriteabilityPlanId=$plan.PlanId;ConfirmWriteability='true'},@{SetupWriteabilityPlanId=$plan.PlanId;ConfirmWriteability=$false},@{SetupWriteabilityPlanId=@($plan.PlanId);ConfirmWriteability=$true},@{SetupWriteabilityPlanId=$plan.PlanId;ConfirmWriteability=$true;Root=$root})){
        $rejected=try{$null=Invoke-UiInitialSetupRequest (New-ProbeRequest @{action='ProbeSetupWriteability';parameters=$parameters});$false}catch{$_.Exception.Message -match 'INITIAL_SETUP_(PROBE_CONFIRMATION_REQUIRED|PROBE_REQUEST_INVALID|PARAMETER_INVALID)'}
        Assert-Probe $rejected 'actual HTTP adapter rejects string/false/array/extra-field authority'
    }
    $http=Invoke-UiInitialSetupRequest (New-ProbeRequest @{action='PlanSetupWriteability';parameters=@{SetupLocationId=$location.LocationId}})
    Assert-Probe ($http.Result.LocationId -ceq $location.LocationId) 'actual HTTP preview reaches same registered-location core without write'
    $catalog=Join-Path $root 'Catalog/storage-locations.json';$catalogBackup=$catalog+'.own-fixture-backup'
    try {
        [IO.File]::Move($catalog,$catalogBackup)
        $unregistered=try{Invoke-SqlServerLabWorkflowAction -Action PlanSetupWriteability -SetupLocationId $location.LocationId;$false}catch{$_.Exception.Message -ceq 'INITIAL_SETUP_PROBE_LOCATION_UNREADABLE'}
        Assert-Probe $unregistered 'marker-only legacy discovery cannot authorize a write probe'
    } finally {if(Test-Path -LiteralPath $catalogBackup){[IO.File]::Move($catalogBackup,$catalog)}}
    $cli=& $module {
        param($LocationId)
        $saved=@{};foreach($name in @('Invoke-LabConsoleMenu','Read-LabConfirm','Write-LabInfo','Wait-LabConsoleAcknowledgement','Invoke-LabSetupWriteProbeProcess')){$saved[$name]=(Get-Item ('Function:'+ $name)).ScriptBlock}
        $script:WriteProbeCliMenu=$saved['Invoke-LabConsoleMenu'];$script:WriteProbeCliCount=0;$script:WriteProbeCliFrames=[Collections.Generic.List[object]]::new();$script:WriteProbeCliLocation=$LocationId;$script:WriteProbeCliFallback=$null
        try {
            Set-Item Function:script:Read-LabConfirm {param($Prompt,$Default)$false}
            Set-Item Function:script:Write-LabInfo {param($Message)}
            Set-Item Function:script:Wait-LabConsoleAcknowledgement {}
            Set-Item Function:script:Invoke-LabSetupWriteProbeProcess {throw 'UNEXPECTED_EXECUTION_AFTER_CANCEL'}
            Set-Item Function:script:Invoke-LabConsoleMenu {
                param($ScreenId,$Title,$Subtitle,$Items)
                $script:WriteProbeCliCount++
                if($script:WriteProbeCliCount -eq 1){$script:WriteProbeCliFallback=(& $script:WriteProbeCliMenu -ScreenId $ScreenId -Title $Title -Items $Items -ForceFallback -ReadInput {'3'} -Snapshot $null 6>$null).SelectedItem.Id}
                $selected=if($script:WriteProbeCliCount -eq 1){'Writeability'}else{$script:WriteProbeCliLocation}
                $script:WriteProbeCliKey=if($script:WriteProbeCliCount -gt 2){'Escape'}else{'Enter'}
                & $script:WriteProbeCliMenu -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -SelectedId $selected -Snapshot $null -Capability ([pscustomobject]@{Supported=$true}) -StatusProvider $null -ReadKey {[pscustomobject]@{Key=$script:WriteProbeCliKey;KeyChar=[char]0;Modifiers=[ConsoleModifiers]0}} -FrameWriter {param($session,$frame)$script:WriteProbeCliFrames.Add($frame)} -GetViewport {[pscustomobject]@{Width=160;Height=20}} -SessionFactory {[pscustomobject]@{OriginTop=0;PreviousLineCount=0;ForegroundColor='Gray'}} -SessionCompleter {param($session)}
            }
            $state=Invoke-LabInitialSetupInteractive
            [pscustomobject]@{Fallback=$script:WriteProbeCliFallback;Frames=$script:WriteProbeCliFrames.Count;State=$state}
        } finally {foreach($name in $saved.Keys){Set-Item ('Function:script:'+$name) $saved[$name]}}
    } $location.LocationId
    Assert-Probe ($cli.Fallback -ceq 'Writeability' -and $cli.Frames -eq 3 -and $cli.State.Writeability -ceq 'NOT_CHECKED' -and -not @(Get-ChildItem -LiteralPath $root -Filter '.sql-server-lab-write-probe-*' -Force).Count) 'actual CLI cursor and numbered fallback cancel after preview without worker dispatch'
    $ownTools=Join-Path $fixture 'Tools';$null=[IO.Directory]::CreateDirectory($ownTools)
    [IO.File]::WriteAllText((Join-Path $ownTools 'Invoke-InitialSetupWriteProbe.ps1'),'$null=[Console]::In.ReadToEnd(); Start-Sleep -Seconds 20')
    $timeout=& $module {
        param($Record,$OwnRoot)
        $originalRoot=$script:ModuleRoot;$watch=[Diagnostics.Stopwatch]::StartNew()
        try {$script:ModuleRoot=$OwnRoot;Invoke-LabSetupWriteProbeProcess -Record $Record -Mode Probe -Seconds 1;$code='UNEXPECTED_SUCCESS'}catch{$code=$_.Exception.Message}finally{$script:ModuleRoot=$originalRoot}
        [pscustomobject]@{Code=$code;Seconds=$watch.Elapsed.TotalSeconds}
    } $record $fixture
    Assert-Probe ($timeout.Code -ceq 'INITIAL_SETUP_PROBE_WORKER_TIMEOUT' -and $timeout.Seconds -lt 8) 'actual process helper bounds wait and terminates its own stalled worker'
    $failurePlan=(Invoke-SqlServerLabWorkflowAction -Action PlanSetupWriteability -SetupLocationId $location.LocationId).Result
    $dual=& $module {
        param($PlanId)
        $original=${function:Invoke-LabSetupWriteProbeProcess}
        try {
            Set-Item Function:script:Invoke-LabSetupWriteProbeProcess {param($Record,$Mode,$Seconds)
                [pscustomobject]@{Mode=$Mode;Created=$false;Written=$false;Absent=$true;PrimaryCode=$(if($Mode -eq 'Probe'){'INITIAL_SETUP_PROBE_IO_FAILED'});CleanupCode=$(if($Mode -eq 'Probe'){'INITIAL_SETUP_PROBE_HANDLE_CLEANUP_FAILED'})}
            }
            Invoke-LabInitialSetupWriteabilityPlan -PlanId $PlanId -Confirmed -Confirm:$false
        } finally {Set-Item Function:script:Invoke-LabSetupWriteProbeProcess $original}
    } $failurePlan.PlanId
    Assert-Probe ($dual.Status -ceq 'RECOVERY_REQUIRED' -and $dual.PrimaryCode -ceq 'INITIAL_SETUP_PROBE_IO_FAILED' -and $dual.CleanupCode -ceq 'INITIAL_SETUP_PROBE_HANDLE_CLEANUP_FAILED' -and -not $dual.OwnLeafAbsent) 'actual parent retains primary and cleanup failure even after fresh absence'
    Write-Host ('RESULT '+$count+' PASS')
} finally {
    foreach($name in $previous.Keys){[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')}
    # Only this fixture's exact GUID root, directly under the captured temporary parent.
    if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($fixture)) -cne $parent -or [IO.Path]::GetFileName($fixture) -cne $leaf -or $leaf -cnotmatch '^sql-lab-writeability-check-[a-f0-9]{32}$'){throw 'FIXTURE_CLEANUP_SCOPE_INVALID'}
    if(Test-Path -LiteralPath $fixture){
        if(@(Get-ChildItem -LiteralPath $fixture -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -or (Get-Item -LiteralPath $fixture -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'FIXTURE_CLEANUP_REPARSE_UNEXPECTED'}
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}

#Requires -Version 7.2
# All new capacity fixtures are read-only or synthetic; no root/file creation.
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$module=Import-Module (Join-Path $repository 'SqlServerLab.psd1') -Force -PassThru -WarningAction SilentlyContinue
$locationId='11111111-1111-1111-1111-111111111111';$passed=0
function Assert-Capacity($Condition,$Name){if(-not $Condition){throw ('ASSERT '+$Name)};$script:passed++;Write-Host ('PASS '+$Name)}
$native=& $module {param($Root)Get-LabInitialSetupCapacityValues -VolumeRoot ([IO.Path]::GetPathRoot($Root))} $repository
Assert-Capacity ($native.AvailableBytes -is [long] -and $native.TotalBytes -is [long] -and $native.AvailableBytes -ge 0 -and $native.TotalBytes -ge $native.AvailableBytes) 'actual native host-volume values read without filesystem mutation or raw values in output'
$workerCases=& $module {
    param($Id,$SyntheticRoot)
    $script:CapacitySyntheticRoot=$SyntheticRoot; $saved=@{};foreach($name in @('Get-LabSetupWriteProbeBinding','Open-LabInitialSetupCapacityReadGuards','Get-LabInitialSetupCapacityValues')){$saved[$name]=(Get-Item ('Function:'+$name)).ScriptBlock}
    $cases=[Collections.Generic.List[object]]::new()
    try {
        Set-Item Function:script:Get-LabSetupWriteProbeBinding {
            param($LocationId)
            if($LocationId -cne '11111111-1111-1111-1111-111111111111'){throw 'UNEXPECTED_LOCATION_SCOPE'}
            $script:CapacityBindingCalls++
            switch($script:CapacityCase){
                'unsupported' {throw 'INITIAL_SETUP_PROBE_FILESYSTEM_UNSUPPORTED'}
                'unknown' {throw 'INITIAL_SETUP_PROBE_LOCATION_UNKNOWN'}
                'unverified' {throw 'INITIAL_SETUP_PROBE_OWNERSHIP_OR_VOLUME_CHANGED'}
                'raw-error' {throw 'SYNTHETIC_PRIVATE_CAPACITY_DETAIL'}
            }
            [pscustomobject]@{Root=$script:CapacitySyntheticRoot;Key=$(if(($script:CapacityCase -eq 'before-drift' -and $script:CapacityBindingCalls -gt 1) -or ($script:CapacityCase -eq 'after-drift' -and $script:CapacityBindingCalls -gt 2)){'drift'}else{'bound'})}
        }
        Set-Item Function:script:Open-LabInitialSetupCapacityReadGuards {param($Binding)$script:CapacityGuard=[IO.MemoryStream]::new();,$script:CapacityGuard}
        Set-Item Function:script:Get-LabInitialSetupCapacityValues {param($VolumeRoot)$script:CapacityReads++;[pscustomobject]@{AvailableBytes=$(if($script:CapacityCase -eq 'invalid-value'){[long]-1}else{[long]0});TotalBytes=[long]1099511627776}}
        foreach($case in @('available-zero','before-drift','after-drift','unsupported','unknown','unverified','raw-error','invalid-value')){
            $script:CapacityCase=$case;$script:CapacityBindingCalls=0;$script:CapacityReads=0;$script:CapacityGuard=$null
            $result=Get-LabInitialSetupCapacityWorkerCore -LocationId $Id
            $cases.Add([pscustomobject]@{Case=$case;Result=$result;Reads=$script:CapacityReads;GuardClosed=($null -eq $script:CapacityGuard -or -not $script:CapacityGuard.CanRead)})
        }
    } finally {foreach($name in $saved.Keys){Set-Item ('Function:script:'+$name) $saved[$name]}}
    ,$cases
} $locationId $repository
foreach($case in $workerCases){
    $valid=if($case.Case -ceq 'available-zero'){$case.Result.Status -ceq 'AVAILABLE' -and $case.Result.AvailableBytes -ceq 0 -and $case.Reads -eq 1}else{$case.Result.Status -cne 'AVAILABLE' -and $null -eq $case.Result.AvailableBytes -and $null -eq $case.Result.TotalBytes}
    if($case.Case -ceq 'before-drift'){$valid=$valid -and $case.Reads -eq 0}
    if($case.Case -ceq 'after-drift'){$valid=$valid -and $case.Reads -eq 1 -and $case.Result.Code -ceq 'INITIAL_SETUP_CAPACITY_BINDING_CHANGED'}
    Assert-Capacity ($valid -and $case.GuardClosed -and ($case.Result|ConvertTo-Json -Compress) -cnotmatch 'SYNTHETIC_PRIVATE_CAPACITY_DETAIL') ('actual worker '+$case.Case+' keeps bytes nullable, exact scope and closes read guards')
}
$state=& $module {
    param($Root,$Id)
    $saved=@{};foreach($name in @('Get-LabStorageConfiguration','Test-LabDataRootOwnership','Get-LabMediaRootDefault','Get-LabMediaRootCandidates','Get-LabInitialSetupCapacity')){$saved[$name]=(Get-Item ('Function:'+$name)).ScriptBlock}
    try {
        $script:CapacityFixtureRoot=$Root;$script:CapacityFixtureId=$Id
        Set-Item Function:script:Get-LabStorageConfiguration {[pscustomobject]@{ControllerId='synthetic-controller';DefaultLocationId=$script:CapacityFixtureId;LabDataLocations=@([pscustomobject]@{LocationId=$script:CapacityFixtureId;LabDataRoot=$script:CapacityFixtureRoot})}}
        Set-Item Function:script:Test-LabDataRootOwnership {$true}
        Set-Item Function:script:Get-LabMediaRootDefault {$null}
        Set-Item Function:script:Get-LabMediaRootCandidates {}
        Set-Item Function:script:Get-LabInitialSetupCapacity {throw 'IMPLICIT_CAPACITY_REFRESH_FORBIDDEN'}
        (Invoke-SqlServerLabWorkflowAction -Action GetInitialSetupState).Result
    } finally {foreach($name in $saved.Keys){Set-Item ('Function:script:'+$name) $saved[$name]}}
} $repository $locationId
Assert-Capacity ($state.LocationStatus[0].Capacity.Status -ceq 'NOT_CHECKED' -and $null -eq $state.LocationStatus[0].Capacity.AvailableBytes -and $null -eq $state.LocationStatus[0].Capacity.ObservedAt -and $state.Writeability -ceq 'NOT_CHECKED') 'real public status adds no implicit capacity query or write probe'
$fixtureRoot=Join-Path $PSScriptRoot 'InitialSetupCapacityWorker'
$previousCase=$env:SQL_SERVER_LAB_CAPACITY_FIXTURE_CASE
try {
    foreach($case in @('available','unknown','wrong-id','private-code','extra','unknown-with-zero','negative','fractional','unsafe-number','future','stale','timeout')){
        $env:SQL_SERVER_LAB_CAPACITY_FIXTURE_CASE=$case
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $result=& $module {param($Id,$Fixture,$ShortTimeout)$original=$script:ModuleRoot;try{$script:ModuleRoot=$Fixture;Get-LabInitialSetupCapacity -LocationId $Id -TimeoutMilliseconds $(if($ShortTimeout){1000}else{20000})}finally{$script:ModuleRoot=$original}} $locationId $fixtureRoot ($case -ceq 'timeout')
        $valid=if($case -ceq 'available'){$result.Status -ceq 'AVAILABLE' -and $result.AvailableBytes -ceq 0}else{$result.Status -ceq 'UNKNOWN' -and $null -eq $result.AvailableBytes -and $null -eq $result.TotalBytes}
        if($case -ceq 'timeout'){$valid=$valid -and $result.Code -ceq 'INITIAL_SETUP_CAPACITY_TIMEOUT' -and $watch.Elapsed.TotalSeconds -lt 7}
        Assert-Capacity ($valid -and $result.LocationId -ceq $locationId -and $result.Notice -cnotmatch 'SYNTHETIC_WORKER_NOTICE' -and ($result|ConvertTo-Json -Compress) -cnotmatch 'SYNTHETIC_PRIVATE_DETAIL|PRIVATE_DETAIL') ('actual parent process '+$case+' validates contract and never publishes worker data')
    }
} finally {$env:SQL_SERVER_LAB_CAPACITY_FIXTURE_CASE=$previousCase}
. (Join-Path $repository 'Tools/WorkflowUiJsonBody.ps1')
$adapterAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'Tools/Start-SqlServerLabUi.ps1'),[ref]$null,[ref]$null)
$adapter=$adapterAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-UiInitialSetupRequest'},$true)
. ([scriptblock]::Create($adapter.Extent.Text))
function New-CapacityRequest($Parameters,$Origin='http://127.0.0.1:9999'){
    [pscustomobject]@{HttpMethod='POST';ContentType='application/json';Headers=@{Origin=$Origin};Url=[uri]'http://127.0.0.1:9999/api/initial-setup';ContentEncoding=[Text.Encoding]::UTF8;InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((@{action='RefreshSetupCapacity';parameters=$Parameters}|ConvertTo-Json -Depth 5)))}
}
foreach($parameters in @(@{SetupLocationId=@($locationId)},@{SetupLocationId='C:\synthetic\Lab_Data'},@{SetupLocationId=$locationId;Root='C:\synthetic'},@{SetupLocationId=$locationId;ConfirmSetup=$true})){
    $rejected=try{$null=Invoke-UiInitialSetupRequest (New-CapacityRequest $parameters);$false}catch{$_.Exception.Message -cmatch '^INITIAL_SETUP_(CAPACITY_REQUEST_INVALID|PARAMETER_INVALID)$'}
    Assert-Capacity $rejected 'actual HTTP adapter accepts only one server-resolved UUID, no paths or authority parameters'
}
$originRejected=try{$null=Invoke-UiInitialSetupRequest (New-CapacityRequest @{SetupLocationId=$locationId} 'https://foreign.invalid');$false}catch{$_.Exception.Message -ceq 'INITIAL_SETUP_ORIGIN_INVALID'}
Assert-Capacity $originRejected 'actual HTTP capacity rejects foreign origin before native read'
$original=& $module {${function:Get-LabInitialSetupCapacity}}
try {
    & $module {Set-Item Function:script:Get-LabInitialSetupCapacity {param($LocationId)Get-LabInitialSetupCapacityObservation -LocationId $LocationId -Status AVAILABLE -Code INITIAL_SETUP_CAPACITY_OBSERVED -AvailableBytes ([long]0) -TotalBytes ([long]1099511627776)}}
    $http=Invoke-UiInitialSetupRequest (New-CapacityRequest @{SetupLocationId=$locationId})
    Assert-Capacity ($http.Action -ceq 'RefreshSetupCapacity' -and $http.Result.LocationId -ceq $locationId -and $http.Result.AvailableBytes -ceq 0) 'actual HTTP public core needs no mutation confirmation and preserves measured zero'
} finally {& $module {param($Function)Set-Item Function:script:Get-LabInitialSetupCapacity $Function} $original}
$cli=& $module {
    param($Root,$Id)
    $names=@('Get-LabStorageConfiguration','Test-LabDataRootOwnership','Get-LabMediaRootDefault','Get-LabMediaRootCandidates','Get-LabInitialSetupCapacity','Invoke-LabConsoleMenu','Write-LabInfo','Wait-LabConsoleAcknowledgement')
    $saved=@{};foreach($name in $names){$saved[$name]=(Get-Item ('Function:'+$name)).ScriptBlock}
    try {
        $script:CapacityFixtureRoot=$Root;$script:CapacityFixtureId=$Id;$script:CapacityCliOriginalMenu=$saved['Invoke-LabConsoleMenu'];$script:CapacityCliCount=0;$script:CapacityCliReads=0;$script:CapacityCliFrames=[Collections.Generic.List[object]]::new();$script:CapacityCliMessages=[Collections.Generic.List[string]]::new()
        Set-Item Function:script:Get-LabStorageConfiguration {[pscustomobject]@{ControllerId='synthetic-controller';DefaultLocationId=$script:CapacityFixtureId;LabDataLocations=@([pscustomobject]@{LocationId=$script:CapacityFixtureId;LabDataRoot=$script:CapacityFixtureRoot})}}
        Set-Item Function:script:Test-LabDataRootOwnership {$true}
        Set-Item Function:script:Get-LabMediaRootDefault {$null}
        Set-Item Function:script:Get-LabMediaRootCandidates {}
        Set-Item Function:script:Get-LabInitialSetupCapacity {param($LocationId)$script:CapacityCliReads++;Get-LabInitialSetupCapacityObservation -LocationId $LocationId -Status AVAILABLE -Code INITIAL_SETUP_CAPACITY_OBSERVED -AvailableBytes ([long]0) -TotalBytes ([long]1099511627776)}
        Set-Item Function:script:Write-LabInfo {param($Message)$script:CapacityCliMessages.Add([string]$Message)}
        Set-Item Function:script:Wait-LabConsoleAcknowledgement {}
        Set-Item Function:script:Invoke-LabConsoleMenu {
            param($ScreenId,$Title,$Subtitle,$Items)
            $script:CapacityCliCount++
            if($script:CapacityCliCount -eq 1){$script:CapacityCliFallback=(& $script:CapacityCliOriginalMenu -ScreenId $ScreenId -Title $Title -Items $Items -ForceFallback -ReadInput {'4'} -Snapshot $null 6>$null).SelectedItem.Id}
            $selected=if($script:CapacityCliCount -in @(1,3)){'Capacity'}else{$script:CapacityFixtureId}
            $script:CapacityCliKey=if($script:CapacityCliCount -in @(2,5)){'Escape'}else{'Enter'}
            & $script:CapacityCliOriginalMenu -ScreenId $ScreenId -Title $Title -Subtitle $Subtitle -Items $Items -SelectedId $selected -Snapshot $null -Capability ([pscustomobject]@{Supported=$true}) -StatusProvider $null -ReadKey {[pscustomobject]@{Key=$script:CapacityCliKey;KeyChar=[char]0;Modifiers=[ConsoleModifiers]0}} -FrameWriter {param($session,$frame)$script:CapacityCliFrames.Add($frame)} -GetViewport {[pscustomobject]@{Width=180;Height=22}} -SessionFactory {[pscustomobject]@{OriginTop=0;PreviousLineCount=0;ForegroundColor='Gray'}} -SessionCompleter {param($session)}
        }
        $null=Invoke-LabInitialSetupInteractive
        [pscustomobject]@{Fallback=$script:CapacityCliFallback;Reads=$script:CapacityCliReads;Frames=$script:CapacityCliFrames.Count;Messages=@($script:CapacityCliMessages)}
    } finally {foreach($name in $saved.Keys){Set-Item ('Function:script:'+$name) $saved[$name]}}
} $repository $locationId
Assert-Capacity ($cli.Fallback -ceq 'Capacity' -and $cli.Reads -eq 1 -and $cli.Frames -eq 5 -and ($cli.Messages -join ' ') -match 'Datenträgerfrei.*Momentaufnahme.*0' -and ($cli.Messages -join ' ') -match 'Native Container-Volumes') 'actual CLI cursor/fallback cancel dispatches nothing, explicit one-location read keeps zero and scope visible'
Write-Host ('CAPACITY RESULT '+$passed+' PASS')

$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo Tests/Common/ConnectionCenterCmsNativeBrowserAcceptance.ps1)
$passed=0
function Assert-NativeBrowserCheck([bool]$Value,[string]$Name){if(-not $Value){throw ('ASSERT CMS native browser '+$Name)};$script:passed++}
$parts=Get-CmsFullPageProductParts $repo
$operator=[pscustomobject]@{Contract='SqlServerLab.CmsNativeBrowserOperator/1.0';FullDocument=$true;AllScriptsLoaded=$true;BootstrapRendered=$true;NavigationToCms=$true;InitialNotChecked=$true;FirstNativeInspection=$true;SecondNativeInspection=$true;NoScriptErrors=$true;DialogClosed=$true}
$records=@(foreach($path in $parts.Assets.Keys){[pscustomobject]@{Path=$path;Method='GET';Status=200;Transport='SENT';Action=$null;CmsStatus=$null}})
foreach($path in @('/api/config','/api/commands','/api/workflow','/api/jobs','/api/jobs')){$records+=[pscustomobject]@{Path=$path;Method='GET';Status=200;Transport='SENT';Action=$null;CmsStatus=$null}}
foreach($ordinal in 0..3){$read=($ordinal%2 -eq 0);$records+=[pscustomobject]@{Path='/api/cms-inspection';Method=$(if($read){'GET'}else{'POST'});Status=200;Transport='SENT';Action=$(if($read){'GetCmsInspectionState'}else{'InspectCms'});CmsStatus=$(if($read){'NOT_CHECKED'}else{'OBSERVED'})}}
Assert-CmsNativeBrowserCompletion $operator $records @($parts.Assets.Keys);$passed++
foreach($mutation in @('missing-asset','duplicate-asset','missing-bootstrap','missing-poll','extra-inspection','unknown-endpoint','post-bootstrap','not-observed','wrong-method','false-observation','unknown-property','duplicate-asset-set','disconnected-cms','disconnected-asset','disconnected-required-bootstrap','unknown-transport')){
    $copy=$operator|ConvertTo-Json|ConvertFrom-Json;$rows=@($records|ConvertTo-Json|ConvertFrom-Json);$assets=@($parts.Assets.Keys)
    switch($mutation){
        'disconnected-cms' {$rows[-1].Transport='CLIENT_DISCONNECTED'}
        'disconnected-asset' {$rows[0].Transport='CLIENT_DISCONNECTED'}
        'disconnected-required-bootstrap' {$rows|Where-Object Path -CEQ '/api/config'|ForEach-Object {$_.Transport='CLIENT_DISCONNECTED'}}
        'unknown-transport' {$rows[0].Transport='UNKNOWN'}
        'missing-asset' {$rows=@($rows|Where-Object Path -CNE '/app.js')}
        'duplicate-asset' {$rows+=$rows[0]}
        'missing-bootstrap' {$rows=@($rows|Where-Object Path -CNE '/api/config')}
        'missing-poll' {$rows=@($rows|Where-Object Path -CNE '/api/jobs')}
        'extra-inspection' {$rows+=$rows[-1]}
        'unknown-endpoint' {$rows+=[pscustomobject]@{Path='/api/actions';Method='GET';Status=200;Transport='SENT';Action=$null}}
        'post-bootstrap' {$rows|Where-Object Path -CEQ '/api/workflow'|ForEach-Object {$_.Method='POST'}}
        'not-observed' {$rows[-1].CmsStatus='UNKNOWN'}
        'wrong-method' {$rows[-1].Method='GET'}
        'false-observation' {$copy.SecondNativeInspection=$false}
        'unknown-property' {$copy|Add-Member -NotePropertyName Untrusted -NotePropertyValue $true}
        'duplicate-asset-set' {$assets=@(1..12|ForEach-Object {'/app.js'})}
    }
    $rejected=try{Assert-CmsNativeBrowserCompletion $copy $rows $assets;$false}catch{$_.Exception.Message -cmatch '^CMS_NATIVE_BROWSER_'}
    Assert-NativeBrowserCheck $rejected $mutation
}
$extra=[pscustomobject]@{Path='/api/jobs';Method='GET';Status=200;Transport='CLIENT_DISCONNECTED';Action=$null;CmsStatus=$null}
Assert-CmsNativeBrowserCompletion $operator @($records+$extra) @($parts.Assets.Keys);$passed++
foreach($case in @(
    @{Path='/api/jobs';Method='GET';Error=[Net.HttpListenerException]::new(64);Expected=$true},
    @{Path='/api/config';Method='GET';Error=[Net.HttpListenerException]::new(995);Expected=$true},
    @{Path='/api/cms-inspection';Method='GET';Error=[Net.HttpListenerException]::new(64);Expected=$false},
    @{Path='/app.js';Method='GET';Error=[Net.HttpListenerException]::new(64);Expected=$false},
    @{Path='/api/jobs';Method='POST';Error=[Net.HttpListenerException]::new(64);Expected=$false},
    @{Path='/api/jobs';Method='GET';Error=[Net.HttpListenerException]::new(5);Expected=$false},
    @{Path='/api/jobs';Method='GET';Error=[Exception]::new('other');Expected=$false}
)){
    Assert-NativeBrowserCheck ((Test-CmsNativeBrowserBootstrapDisconnect $case.Path $case.Method $case.Error) -eq $case.Expected) 'bounded bootstrap disconnect classification'
}
foreach($path in @('Tests/Common/ConnectionCenterCmsNativeBrowserAcceptance.ps1','Tests/Integration/Invoke-ConnectionCenterCmsNativeBrowserAcceptance.ps1','Tests/Static/Fixtures/ConnectionCenterCmsNativeBrowserAcceptanceChecks.ps1')){
    $selection=& (Join-Path $repo Tools/Get-CiTestSelection.ps1) -ChangedPath $path
    Assert-NativeBrowserCheck ($selection.StaticChecks -contains 'Invoke-ConnectionCenterCmsChecks.ps1' -and $selection.StaticChecks -contains 'Invoke-ConsoleUiChecks.ps1' -and -not($selection.Docker -or $selection.Podman -or $selection.Mixed -or $selection.HyperV -or $selection.Adapter)) ('single-file impact '+$path)
}
$script:routeReads=0
function Assert-CmsInspectionAcceptanceRoute {param($Module,$Scope,$Provider)$script:routeReads++}
$fake=New-Module -ScriptBlock {
    $script:wrong=$false
    function Invoke-SqlServerLabWorkflowAction {
        param($Action,$ExpectedPlanKey)
        $observed=$Action -ceq 'InspectCms'
        [pscustomobject]@{Result=[pscustomobject]@{ContractVersion='SqlServerLab.CmsInspection/1.0';Status=$(if($observed){'OBSERVED'}else{'NOT_CHECKED'});Code=$(if($observed){'CMS_INSPECTION_OBSERVED'}else{'CMS_INSPECTION_NOT_CHECKED'});RunId='11111111-1111-1111-1111-111111111111';InstanceId='primary';Provider='docker';SelectionKey=('a'*64);ObservedAt=$(if($observed){[DateTime]::UtcNow.ToString('o')}else{$null});SqlMajor=$(if($observed){if($script:wrong){16}else{17}}else{$null});ManagedGroupCount=$(if($observed){[long]2}else{$null});ManagedServerCount=$(if($observed){[long]1}else{$null});Notice='Synthetic fixture only'}}
    }
    Export-ModuleMember -Function Invoke-SqlServerLabWorkflowAction
}
try{
    $custody=[pscustomobject]@{RunId='11111111-1111-1111-1111-111111111111'}
    foreach($action in @('GetCmsInspectionState','InspectCms')){
        $key=if($action -ceq 'InspectCms'){'a'*64}else{''}
        $result=Invoke-CmsNativeBrowserWorkflow $fake $null $custody docker ('a'*64) $action $key
        Assert-NativeBrowserCheck ($result.Result.Status -ceq $(if($action -ceq 'InspectCms'){'OBSERVED'}else{'NOT_CHECKED'})) ('module dispatch '+$action)
    }
    Assert-NativeBrowserCheck ($routeReads -eq 4) 'route before/after each dispatch'
    foreach($case in @(@{Action='Remove';Key=''},@{Action='InspectCms';Key=('b'*64)},@{Action='GetCmsInspectionState';Key=('a'*64)})){
        $rejected=try{$null=Invoke-CmsNativeBrowserWorkflow $fake $null $custody docker ('a'*64) $case.Action $case.Key;$false}catch{$_.Exception.Message -ceq 'CMS_NATIVE_BROWSER_ACTION_INVALID'}
        Assert-NativeBrowserCheck ($rejected -and $routeReads -eq 4) 'invalid request before route/module'
    }
    & $fake {$script:wrong=$true}
    $rejected=try{$null=Invoke-CmsNativeBrowserWorkflow $fake $null $custody docker ('a'*64) InspectCms ('a'*64);$false}catch{$_.Exception.Message -ceq 'CMS_ACCEPTANCE_COUNTS'}
    Assert-NativeBrowserCheck $rejected 'wrong native major veto'
}finally{Remove-Module $fake -Force}
Write-Host ('CMS NATIVE BROWSER FOCUS '+$passed+' PASS; listener/provider/State/SQL not executed')

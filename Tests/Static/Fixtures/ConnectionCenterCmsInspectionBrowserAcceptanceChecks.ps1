$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repository Tests/Common/ConnectionCenterCmsInspectionBrowserAcceptance.ps1)
$passed=0
function Assert-BrowserCheck([bool]$Value,[string]$Name){if(-not $Value){throw ('ASSERT CMS browser '+$Name)}; $script:passed++}
$parts=Get-CmsBrowserProductParts $repository
Assert-BrowserCheck ($parts.Page -cmatch '<dialog id="cms-inspection-dialog">' -and $parts.Page -cnotmatch '/app.js' -and $parts.JavaScript -cmatch 'readCmsInspection' -and $parts.JavaScript -cnotmatch 'pollJobs') 'exact isolated markup/product block'
foreach($path in @('Tests/Common/ConnectionCenterCmsInspectionBrowserAcceptance.ps1','Tests/Integration/Invoke-ConnectionCenterCmsInspectionBrowserAcceptance.ps1','Tests/Static/Fixtures/ConnectionCenterCmsInspectionBrowserAcceptanceChecks.ps1')){
    $selection=& (Join-Path $repository Tools/Get-CiTestSelection.ps1) -ChangedPath $path
    Assert-BrowserCheck ($selection.StaticChecks -contains 'Invoke-ConnectionCenterCmsChecks.ps1' -and $selection.StaticChecks -contains 'Invoke-ConsoleUiChecks.ps1' -and -not($selection.Docker -or $selection.Podman -or $selection.Mixed -or $selection.HyperV -or $selection.Adapter)) ('single-file CMS selection '+$path)
}
$cases=@('docker15','podman16','docker17','not-configured','unknown','hyperv','wrong-binding','unsafe','error','late')
$properties=@('ContractVersion','Status','Code','RunId','InstanceId','Provider','SelectionKey','ObservedAt','SqlMajor','ManagedGroupCount','ManagedServerCount','Notice')
foreach($case in $cases){
    $view=(New-CmsBrowserSyntheticResult $case GetCmsInspectionState).Result
    Assert-BrowserCheck (@($view.PSObject.Properties.Name).Count -eq 12 -and @($view.PSObject.Properties.Name|Where-Object {$_ -cnotin $properties}).Count -eq 0 -and $null -eq $view.SqlMajor -and $null -eq $view.ManagedServerCount -and $null -eq $view.ObservedAt) ('nullable fixture '+$case)
}
foreach($case in @('docker15','podman16','docker17')){
    $view=(New-CmsBrowserSyntheticResult $case InspectCms).Result
    $major=if($case -ceq 'docker15'){15}elseif($case -ceq 'podman16'){16}else{17}
    Assert-BrowserCheck ($view.SqlMajor -eq $major -and $view.ManagedGroupCount -eq 3 -and $view.ManagedServerCount -eq 0) ('major/zero '+$case)
}
$operator=[pscustomobject]@{Contract='SqlServerLab.CmsBrowserOperatorObservation/1.0';RenderedDialog=$true;InitialReadOnly=$true;ExplicitInspection=$true;GenuineZero=$true;NullableUnknown=$true;UnsupportedDisabled=$true;InvalidResultDiscarded=$true;ErrorSanitized=$true;BusyDisabled=$true;RepeatRequiresRead=$true;CloseLateDiscarded=$true;Cases=$cases}
$records=[Collections.Generic.List[object]]::new()
foreach($case in $cases){
    $actions=if($case -ceq 'docker15'){@('GetCmsInspectionState','InspectCms','GetCmsInspectionState','InspectCms')}elseif($case -cin @('not-configured','unknown','hyperv')){@('GetCmsInspectionState')}else{@('GetCmsInspectionState','InspectCms')}
    foreach($action in $actions){$records.Add([pscustomobject]@{Case=$case;Action=$action;Status=$(if($case -ceq 'error' -and $action -ceq 'InspectCms'){400}else{200});RuntimeCalls=0;SqlCalls=0;SecretReads=0})}
}
Assert-CmsBrowserCompletion $operator @($records);$passed++
foreach($mutation in @('missing-case','duplicate-action','runtime-call','false-observation','unknown-property','reordered-actions')){
    $copy=$operator|ConvertTo-Json -Depth 4|ConvertFrom-Json
    $rows=@($records|ConvertTo-Json -Depth 4|ConvertFrom-Json)
    switch($mutation){
        'missing-case' {$copy.Cases=@($cases|Select-Object -Skip 1)}
        'duplicate-action' {$rows+= $rows[0]}
        'runtime-call' {$rows[0].RuntimeCalls=1}
        'false-observation' {$copy.CloseLateDiscarded=$false}
        'unknown-property' {$copy|Add-Member -NotePropertyName Untrusted -NotePropertyValue $true}
        'reordered-actions' {$rows[0].Action='InspectCms'}
    }
    $rejected=try{Assert-CmsBrowserCompletion $copy $rows;$false}catch{$_.Exception.Message -cmatch '^CMS_BROWSER_'}
    Assert-BrowserCheck $rejected $mutation
}
$unsafe=(New-CmsBrowserSyntheticResult unsafe InspectCms).Result
Assert-BrowserCheck ($unsafe.ManagedServerCount -gt 9007199254740991L) 'unsafe integer fixture'
$wrong=(New-CmsBrowserSyntheticResult wrong-binding InspectCms).Result
Assert-BrowserCheck ($wrong.RunId -cne (New-CmsBrowserSyntheticResult wrong-binding GetCmsInspectionState).Result.RunId) 'wrong-binding fixture'
$failed=try{$null=New-CmsBrowserSyntheticResult error InspectCms;$false}catch{$_.Exception.Message -ceq 'SYNTHETIC_PRIVATE_SQL_OR_SECRET'}
Assert-BrowserCheck $failed 'server error fixture'
Write-Host ('CMS BROWSER FOCUS '+$passed+' PASS; listener/runtime/SQL/secret calls=0')

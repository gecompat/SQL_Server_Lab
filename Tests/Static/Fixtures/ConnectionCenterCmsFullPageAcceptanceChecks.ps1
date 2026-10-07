$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo Tests/Common/ConnectionCenterCmsFullPageAcceptance.ps1)
$passed=0
function Assert-FullPageCheck([bool]$Value,[string]$Name){if(-not $Value){throw ('ASSERT CMS full-page '+$Name)};$script:passed++}
$parts=Get-CmsFullPageProductParts $repo
Assert-FullPageCheck ($parts.Sources.Count -eq 14 -and $parts.Assets.Count -eq 13) 'current full source/asset set'
foreach($source in $parts.Sources){Assert-FullPageCheck ((Get-FileHash -LiteralPath (Join-Path $repo $source.Path)).Hash -ceq $source.Sha256) ('actual source digest '+$source.Path)}
$html=[Text.Encoding]::UTF8.GetString($parts.Assets['/'].Bytes)
Assert-FullPageCheck ($html -cmatch 'data-workspace-target="connections"' -and $html -cmatch '<script src="app.js"' -and $html -cmatch 'id="cms-inspection-open"') 'actual full document/navigation'
foreach($path in @('Tests/Common/ConnectionCenterCmsFullPageAcceptance.ps1','Tests/Integration/Invoke-ConnectionCenterCmsFullPageAcceptance.ps1','Tests/Static/Fixtures/ConnectionCenterCmsFullPageAcceptanceChecks.ps1')){
    $selection=& (Join-Path $repo Tools/Get-CiTestSelection.ps1) -ChangedPath $path
    Assert-FullPageCheck ($selection.StaticChecks -contains 'Invoke-ConnectionCenterCmsChecks.ps1' -and $selection.StaticChecks -contains 'Invoke-ConsoleUiChecks.ps1' -and -not($selection.Docker -or $selection.Podman -or $selection.Mixed -or $selection.HyperV -or $selection.Adapter)) ('single-file impact '+$path)
}
$workflow=Get-CmsFullPageBootstrapResponse '/api/workflow'|ConvertFrom-Json
Assert-FullPageCheck (-not $workflow.Host.HyperV.Available -and $workflow.ActiveLabs.Count -eq 0 -and $workflow.HyperVLabs.Count -eq 0 -and $workflow.Summary.RunningWorkers -eq 0) 'synthetic empty workflow'
foreach($path in @('/api/actions','/api/operations','/api/commands?root=other')){
    $rejected=try{$null=Get-CmsFullPageBootstrapResponse $path;$false}catch{$_.Exception.Message -ceq 'CMS_FULL_PAGE_BOOTSTRAP_PATH'}
    Assert-FullPageCheck $rejected ('non-read endpoint rejected '+$path)
}
$operator=[pscustomobject]@{Contract='SqlServerLab.CmsFullPageOperator/1.0';FullDocument=$true;AllScriptsLoaded=$true;BootstrapRendered=$true;NavigationToCms=$true;InitialReadOnly=$true;ExplicitInspection=$true;GenuineZero=$true;NoScriptErrors=$true;DialogClosed=$true}
$records=@(foreach($path in $parts.Assets.Keys){[pscustomobject]@{Path=$path;Method='GET';Status=200;Action=$null}})
foreach($path in @('/api/config','/api/commands','/api/workflow','/api/jobs','/api/jobs')){$records+=[pscustomobject]@{Path=$path;Method='GET';Status=200;Action=$null}}
$records+=[pscustomobject]@{Path='/api/cms-inspection';Method='GET';Status=200;Action='GetCmsInspectionState'}
$records+=[pscustomobject]@{Path='/api/cms-inspection';Method='POST';Status=200;Action='InspectCms'}
Assert-CmsFullPageCompletion $operator $records @($parts.Assets.Keys);$passed++
foreach($mutation in @('missing-asset','duplicate-asset','missing-bootstrap','single-poll','extra-inspection','unknown-endpoint','mutating-bootstrap','false-observation','unknown-property')){
    $copy=$operator|ConvertTo-Json|ConvertFrom-Json;$rows=@($records|ConvertTo-Json|ConvertFrom-Json)
    switch($mutation){
        'missing-asset' {$rows=@($rows|Where-Object Path -CNE '/app.js')}
        'duplicate-asset' {$rows+=$rows[0]}
        'missing-bootstrap' {$rows=@($rows|Where-Object Path -CNE '/api/config')}
        'single-poll' {$removed=$false;$rows=@($rows|Where-Object {if($_.Path -ceq '/api/jobs' -and -not $removed){$removed=$true;$false}else{$true}})}
        'extra-inspection' {$rows+=$rows[-1]}
        'unknown-endpoint' {$rows+=[pscustomobject]@{Path='/api/actions';Method='GET';Status=200;Action=$null}}
        'mutating-bootstrap' {$rows|Where-Object Path -CEQ '/api/workflow'|ForEach-Object {$_.Method='POST'}}
        'false-observation' {$copy.NoScriptErrors=$false}
        'unknown-property' {$copy|Add-Member -NotePropertyName Untrusted -NotePropertyValue $true}
    }
    $rejected=try{Assert-CmsFullPageCompletion $copy $rows @($parts.Assets.Keys);$false}catch{$_.Exception.Message -cmatch '^CMS_FULL_PAGE_'}
    Assert-FullPageCheck $rejected $mutation
}
Write-Host ('CMS FULL PAGE FOCUS '+$passed+' PASS; listener/State/provider/secret/SQL not executed')

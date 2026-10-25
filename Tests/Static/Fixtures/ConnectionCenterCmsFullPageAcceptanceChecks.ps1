$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo Tests/Common/ConnectionCenterCmsFullPageAcceptance.ps1)
$passed=0
function Assert-FullPageCheck([bool]$Value,[string]$Name){if(-not $Value){throw ('ASSERT CMS full-page '+$Name)};$script:passed++}
$parts=Get-CmsFullPageProductParts $repo
$document=Get-Content -LiteralPath (Join-Path $repo Ui/index.html) -Raw
$declaredAssets=@('/','/app.css')+@([regex]::Matches($document,'<script\b[^>]*\bsrc="([^"]+)"')|ForEach-Object {'/'+$_.Groups[1].Value})
$declaredSources=@($declaredAssets|ForEach-Object {if($_ -ceq '/'){'Ui/index.html'}else{'Ui'+$_}})+@('Tools/Start-SqlServerLabUi.ps1')
Assert-FullPageCheck ($parts.Assets.Count -eq $declaredAssets.Count -and @(Compare-Object -ReferenceObject $declaredAssets -DifferenceObject @($parts.Assets.Keys) -CaseSensitive).Count -eq 0) 'current declared asset set'
Assert-FullPageCheck ($parts.Sources.Count -eq $declaredSources.Count -and @(Compare-Object -ReferenceObject $declaredSources -DifferenceObject @($parts.Sources.Path) -CaseSensitive).Count -eq 0) 'current declared source set'
foreach($source in $parts.Sources){Assert-FullPageCheck ((Get-FileHash -LiteralPath (Join-Path $repo $source.Path)).Hash -ceq $source.Sha256) ('actual source digest '+$source.Path)}
$html=[Text.Encoding]::UTF8.GetString($parts.Assets['/'].Bytes)
Assert-FullPageCheck ($html -cmatch 'data-workspace-target="connections"' -and $html -cmatch '<script src="app.js"' -and $html -cmatch 'id="cms-inspection-open"') 'actual full document/navigation'

# A new declared script must join the bound inventory without updating a count.
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('cms-full-page-inventory-'+[guid]::NewGuid().ToString('N'))
$fixtureFailure=$null
try{
    $null=New-Item -ItemType Directory -Path (Join-Path $fixtureRoot Ui),(Join-Path $fixtureRoot Tools)
    foreach($path in @($parts.Sources.Path)+@('Tools/WorkflowUiJsonBody.ps1')){Copy-Item -LiteralPath (Join-Path $repo $path) -Destination (Join-Path $fixtureRoot $path)}
    $extraPath=Join-Path $fixtureRoot Ui/cms-inventory-extra.js
    [IO.File]::WriteAllText($extraPath,'// synthetic inventory addition')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot Ui/cms-inventory-unused.js),'// not declared by the document')
    $extendedDocument=$document.Replace('</body>',"<script src=`"cms-inventory-extra.js`"></script>`n</body>")
    [IO.File]::WriteAllText((Join-Path $fixtureRoot Ui/index.html),$extendedDocument)
    $extended=Get-CmsFullPageProductParts $fixtureRoot
    Assert-FullPageCheck ($extended.Assets.Count -eq $parts.Assets.Count+1 -and $extended.Sources.Count -eq $parts.Sources.Count+1 -and $extended.Assets.ContainsKey('/cms-inventory-extra.js')) 'additional declared script is captured'
    Assert-FullPageCheck ((Get-FileHash -LiteralPath $extraPath).Hash -ceq @($extended.Sources|Where-Object Path -CEQ 'Ui/cms-inventory-extra.js')[0].Sha256 -and [Text.Encoding]::UTF8.GetString($extended.Assets['/cms-inventory-extra.js'].Bytes) -ceq '// synthetic inventory addition') 'additional script digest and served bytes'
    Assert-FullPageCheck (-not $extended.Assets.ContainsKey('/cms-inventory-unused.js') -and 'Ui/cms-inventory-unused.js' -cnotin $extended.Sources.Path) 'undeclared file is not served'
    [IO.File]::WriteAllText((Join-Path $fixtureRoot Ui/index.html),$extendedDocument.Replace('</body>',"<script src=`"cms-inventory-extra.js`"></script>`n</body>"))
    $rejected=try{$null=Get-CmsFullPageProductParts $fixtureRoot;$false}catch{$_.Exception.Message -ceq 'CMS_FULL_PAGE_ASSET_DECLARATION'}
    Assert-FullPageCheck $rejected 'duplicate declaration remains rejected'
    [IO.File]::WriteAllText((Join-Path $fixtureRoot Ui/index.html),$extendedDocument)
    Remove-Item -LiteralPath $extraPath
    $rejected=try{$null=Get-CmsFullPageProductParts $fixtureRoot;$false}catch{$_.FullyQualifiedErrorId -match 'PathNotFound|ItemNotFound'}
    Assert-FullPageCheck $rejected 'missing declared file remains rejected'
}catch{
    $fixtureFailure=$_
    throw
}finally{
    try{
    $resolvedFixture=[IO.Path]::GetFullPath($fixtureRoot)
    $tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if([IO.Path]::GetDirectoryName($resolvedFixture) -cne $tempParent -or [IO.Path]::GetFileName($resolvedFixture) -cnotmatch '^cms-full-page-inventory-[a-f0-9]{32}$'){throw 'CMS_FULL_PAGE_FIXTURE_CLEANUP_SCOPE'}
    Assert-CmsBrowserPath $resolvedFixture
    if(Test-Path -LiteralPath $resolvedFixture){Remove-Item -LiteralPath $resolvedFixture -Recurse -Force}
    }catch{
        if($fixtureFailure){throw [AggregateException]::new('CMS_FULL_PAGE_FIXTURE_AND_CLEANUP_FAILED',[Exception[]]@($fixtureFailure.Exception,$_.Exception))}
        throw
    }
}
Assert-FullPageCheck (-not(Test-Path -LiteralPath $fixtureRoot)) 'own inventory fixture removed'
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

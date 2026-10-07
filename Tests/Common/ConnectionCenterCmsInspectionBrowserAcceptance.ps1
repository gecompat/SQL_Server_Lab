# Test-only synthetic transport/rendering support. No product module is imported.
function Assert-CmsBrowserPath {
    param([string]$Path)
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor){
        if(Test-Path -LiteralPath $cursor){
            if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'CMS_BROWSER_REPARSE'}
        }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}

function Write-CmsBrowserEvidence {
    param([string]$Path,$Value)
    Assert-CmsBrowserPath $Path
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 8)+"`n")
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
}

function Get-CmsBrowserProductParts {
    param([string]$RepositoryRoot)
    $html=Get-Content -LiteralPath (Join-Path $RepositoryRoot Ui/index.html) -Raw
    $js=Get-Content -LiteralPath (Join-Path $RepositoryRoot Ui/app.js) -Raw
    $button=[regex]::Matches($html,'<button id="cms-inspection-open"[^>]*>[^<]*</button>')
    $dialog=[regex]::Matches($html,'(?s)<dialog id="cms-inspection-dialog">.*?</dialog>')
    $start='let cmsInspectionRevision = 0;'
    # Match the entire final product statement without relying on whitespace/newlines.
    $end=[regex]::Matches($js,"(?m)^for \(const event of \['close', 'cancel'\]\) .*cmsInspectionRevision\+\+;.*updateCmsInspectionControls\(\); \}\);")
    $begins=[regex]::Matches($js,[regex]::Escape($start))
    $selector=[regex]::Matches($js,'(?m)^const \$ = \(selector\) => document\.querySelector\(selector\);')
    if($button.Count -ne 1 -or $dialog.Count -ne 1 -or $begins.Count -ne 1 -or $end.Count -ne 1 -or $selector.Count -ne 1 -or $end[0].Index -le $begins[0].Index){throw 'CMS_BROWSER_PRODUCT_PARTS'}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepositoryRoot Tools/Start-SqlServerLabUi.ps1),[ref]$tokens,[ref]$errors)
    $adapter=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-UiCmsInspectionRequest'},$true))
    $route=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/cms-inspection'"},$true))
    if($errors.Count -or $adapter.Count -ne 1 -or $route.Count -ne 1){throw 'CMS_BROWSER_PRODUCT_ROUTE'}
    [pscustomobject]@{
        Page='<!doctype html><html lang="de"><meta charset="utf-8"><link rel="stylesheet" href="/app.css"><title>CMS Browser Abnahme · synthetisch</title><body>'+$button[0].Value+$dialog[0].Value+'<script src="/cms-fixture.js"></script></body></html>'
        JavaScript=$selector[0].Value+"`n"+$js.Substring($begins[0].Index,$end[0].Index+$end[0].Length-$begins[0].Index)
        Adapter=[scriptblock]::Create([IO.File]::ReadAllText((Join-Path $RepositoryRoot 'Tools/WorkflowUiJsonBody.ps1'))+"`n"+$adapter[0].Extent.Text)
        Dispatch=[scriptblock]::Create('foreach($iteration in 1){'+$route[0].Extent.Text+"`nthrow 'CMS_BROWSER_FALLTHROUGH'"+'}')
    }
}

function Read-CmsBrowserBody {
    param($Request,[ValidateRange(1,5000)][int]$TimeoutMilliseconds=2000)
    $buffer=[byte[]]::new(4097);$count=0;$timer=[Diagnostics.Stopwatch]::StartNew()
    try{
        while($count -lt $buffer.Length){
            $remaining=$TimeoutMilliseconds-[int]$timer.ElapsedMilliseconds
            if($remaining -le 0){throw 'CMS_BROWSER_BODY_TIMEOUT'}
            $pending=$Request.InputStream.ReadAsync($buffer,$count,$buffer.Length-$count)
            if(-not $pending.Wait($remaining)){throw 'CMS_BROWSER_BODY_TIMEOUT'}
            $read=$pending.GetAwaiter().GetResult();if($read -eq 0){break};$count+=$read
        }
        if($count -gt 4096){throw 'CMS_BROWSER_BODY_LIMIT'}
        $bytes=[byte[]]::new($count);[Array]::Copy($buffer,$bytes,$count);return ,$bytes
    }catch{$Request.InputStream.Close();throw}finally{$timer.Stop()}
}

function New-CmsBrowserSyntheticResult {
    param([ValidateSet('docker15','podman16','docker17','not-configured','unknown','hyperv','wrong-binding','unsafe','error','late')][string]$Case,[ValidateSet('GetCmsInspectionState','InspectCms')][string]$Action)
    $view=[ordered]@{ContractVersion='SqlServerLab.CmsInspection/1.0';Status='NOT_CHECKED';Code='CMS_INSPECTION_NOT_CHECKED';RunId='11111111-1111-1111-1111-111111111111';InstanceId='primary';Provider='docker';SelectionKey=('a'*64);ObservedAt=$null;SqlMajor=$null;ManagedGroupCount=$null;ManagedServerCount=$null;Notice='CMS_INSPECTION_READ_ONLY'}
    if($Case -ceq 'podman16'){$view.Provider='podman'}
    if($Case -ceq 'not-configured'){$view.Status='NOT_CONFIGURED';$view.Code='CMS_INSPECTION_NOT_CONFIGURED';$view.RunId=$null;$view.InstanceId=$null;$view.Provider=$null;$view.SelectionKey=$null}
    if($Case -ceq 'unknown'){$view.Status='UNKNOWN';$view.Code='CMS_INSPECTION_SELECTION_UNVERIFIED'}
    if($Case -ceq 'hyperv'){$view.Provider='hyperv';$view.Code='CMS_INSPECTION_PROVIDER_UNSUPPORTED'}
    if($Action -ceq 'InspectCms'){
        if($Case -ceq 'error'){throw 'SYNTHETIC_PRIVATE_SQL_OR_SECRET'}
        $view.Status='OBSERVED';$view.Code='CMS_INSPECTION_OBSERVED';$view.SqlMajor=if($Case -ceq 'docker15'){15}elseif($Case -ceq 'podman16'){16}else{17}
        $view.ManagedGroupCount=3;$view.ManagedServerCount=0;$view.ObservedAt=[DateTime]::UtcNow.ToString('o')
        if($Case -ceq 'wrong-binding'){$view.RunId='22222222-2222-2222-2222-222222222222'}
        if($Case -ceq 'unsafe'){$view.ManagedServerCount=9007199254740992L}
    }
    [pscustomobject]@{Action=$Action;Result=[pscustomobject]$view}
}

function Assert-CmsBrowserCompletion {
    param($Operator,[object[]]$Records)
    $cases=@('docker15','podman16','docker17','not-configured','unknown','hyperv','wrong-binding','unsafe','error','late')
    $properties=@('Contract','RenderedDialog','InitialReadOnly','ExplicitInspection','GenuineZero','NullableUnknown','UnsupportedDisabled','InvalidResultDiscarded','ErrorSanitized','BusyDisabled','RepeatRequiresRead','CloseLateDiscarded','Cases')
    if($Operator -isnot [pscustomobject] -or $Operator.Contract -cne 'SqlServerLab.CmsBrowserOperatorObservation/1.0' -or
        @($Operator.PSObject.Properties.Name).Count -ne $properties.Count -or @($Operator.PSObject.Properties.Name|Where-Object {$_ -cnotin $properties}).Count){throw 'CMS_BROWSER_COMPLETION_INVALID'}
    foreach($name in $properties|Where-Object {$_ -cnotin @('Contract','Cases')}){if($Operator.$name -isnot [bool] -or -not $Operator.$name){throw 'CMS_BROWSER_COMPLETION_INVALID'}}
    if(@($Operator.Cases).Count -ne $cases.Count -or (@($Operator.Cases|Sort-Object) -join '|') -cne (@($cases|Sort-Object) -join '|')){throw 'CMS_BROWSER_CASES_INVALID'}
    foreach($case in $cases){
        $rows=@($Records|Where-Object Case -CEQ $case)
        $expected=if($case -ceq 'docker15'){@('GetCmsInspectionState','InspectCms','GetCmsInspectionState','InspectCms')}elseif($case -cin @('not-configured','unknown','hyperv')){@('GetCmsInspectionState')}else{@('GetCmsInspectionState','InspectCms')}
        if(($rows.Action -join '|') -cne ($expected -join '|') -or @($rows|Where-Object {$_.RuntimeCalls -ne 0 -or $_.SqlCalls -ne 0 -or $_.SecretReads -ne 0 -or $_.Status -ne $(if($case -ceq 'error' -and $_.Action -ceq 'InspectCms'){400}else{200})}).Count){throw 'CMS_BROWSER_HTTP_OBSERVATIONS_INVALID'}
    }
    if($Records.Count -ne 19){throw 'CMS_BROWSER_HTTP_COUNT'}
}

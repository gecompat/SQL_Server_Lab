$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$module=$null
try {
$module=New-Module -ArgumentList $root -ScriptBlock {
    param($root)
    $script:ModuleRoot=$root;$script:CatalogsPath=Join-Path $root 'Catalogs'
    $script:VersionCatalog=Get-Content (Join-Path $root 'Catalogs/sql-server-versions.json') -Raw|ConvertFrom-Json
    $script:RegisteredProviders=@{}
    foreach($provider in @('Docker','Podman')) {
        $definition=Get-Content (Join-Path $root "Providers/$provider/provider.json") -Raw|ConvertFrom-Json
        $script:RegisteredProviders[$definition.name]=@{Definition=$definition}
    }
    foreach($file in @('Private/VersionCatalog.ps1','Private/SoftwareCatalog.ps1','Private/ContainerImageArtifact.ps1','Private/CapabilityEvidence.ps1','Private/ExternalRuntimeCapability.ps1','Public/Get-SqlServerLabExternalRuntimeCapability.ps1','Private/ExternalRuntimeCapabilityHttp.ps1')) {. (Join-Path $root $file)}
    $script:transports=0;$script:tools=0;$script:mode='ready'
    function Initialize-LabHostToolPath {param($Name) $script:tools++;[pscustomobject]@{Available=$true;Invocation=Join-Path ([IO.Path]::GetTempPath()) "synthetic-$Name.exe"}}
    function Invoke-LabDiagnosticBoundedProcess {
        param($StartInfo,$TimeoutSeconds,$MaximumBytes)
        $script:transports++
        if($TimeoutSeconds -ne 20 -or $MaximumBytes -ne 65536 -or $StartInfo.ArgumentList.Count -ne 3 -or $StartInfo.ArgumentList[0] -cne 'info' -or $StartInfo.ArgumentList[1] -cne '--format') {throw 'BAD_TRANSPORT'}
        if($script:mode -ceq 'timeout') {return [pscustomobject]@{Success=$false;Reason='DIAGNOSTIC_READINESS_TIMEOUT';Value=$null}}
        $facts=if($StartInfo.FileName -match 'podman'){[pscustomobject]@{OperatingSystem='linux';CgroupVersion='v1';Rootless=$false}}else{[pscustomobject]@{OperatingSystem='linux';CgroupVersion='1';SecurityOptions=@()}}
        if($script:mode -ceq 'malformedFacts') {
            if($StartInfo.FileName -match 'podman') {$facts.Rootless='false'}else{$facts.SecurityOptions=$null}
        }
        [pscustomobject]@{Success=$true;Value=$facts}
    }
    function New-Request {
        param([string]$Body,[string]$Origin='http://127.0.0.1:8484',[string]$Authority='http://127.0.0.1:8484',[string]$Method='POST',[string]$ContentType='application/json; charset=utf-8',[string]$Address='127.0.0.1')
        [pscustomobject]@{HttpMethod=$Method;ContentType=$ContentType;Headers=@{Origin=$Origin};Url=[uri]"$Authority/api/external-runtime-capability";LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Parse($Address),8484);InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Body))}
    }
    function Assert-Case {param([bool]$Condition,[string]$Name) if(-not $Condition){throw "FIXTURE_FAILED: $Name"};$script:passed++;Write-Host "PASS: $Name"}
    function Send-Request {param($Payload) Invoke-LabExternalRuntimeCapabilityHttpRequest -Request (New-Request ($Payload|ConvertTo-Json -Compress)) -ListenerPort 8484}
    function Reject-Request {param($Request,[string]$Name) $before=$script:transports;try{Invoke-LabExternalRuntimeCapabilityHttpRequest $Request 8484|Out-Null;$caught=$false}catch{$caught=$_.Exception.Message -ceq 'EXTERNAL_RUNTIME_HTTP_INVALID'};Assert-Case ($caught -and $script:transports -eq $before) $Name}
    $script:passed=0
    $read=[ordered]@{Action='ReadOptions';SqlVersion='2022';Provider='docker';OperatingSystem='linux'}
    $view=Send-Request $read
    Assert-Case ($view.Status -ceq 'OPTIONS' -and $view.Options.Count -eq 9 -and $script:tools -eq 0 -and $script:transports -eq 0) 'Actual options resolver/reducer performs no host work'
    Assert-Case (@($view.Options|Where-Object {$_.Decision.CatalogDecision.Status -ceq 'BLOCKED'}).Count -gt 0) 'Blocked catalog options remain visible'
    $selected=@($view.Options|Where-Object {$_.Decision.CatalogDecision.Status -ceq 'DECLARED_SUPPORTED'})[0]
    $evaluate=[ordered]@{Action='Evaluate';SqlVersion='2022';Provider='docker';OperatingSystem='linux';SoftwareId=$selected.SoftwareId;RuntimeVersion=$selected.RuntimeVersion;VariantId=$selected.VariantId;CheckProviderReadiness=$false}
    $view=Send-Request $evaluate
    Assert-Case ($view.Decision.CurrentReadiness.Status -ceq 'NOT_CHECKED' -and $script:transports -eq 0) 'Actual public default is not checked'
    $history=[ordered]@{Action='ReadRecordedEvidence';SqlVersion='2022';Provider='docker';OperatingSystem='linux';SoftwareId=$selected.SoftwareId;RuntimeVersion=$selected.RuntimeVersion;VariantId=$selected.VariantId}
    $historyView=Send-Request $history
    Assert-Case ($historyView.ContractVersion -ceq 'SqlServerLab.ExternalRuntimeCapabilityBrowser/1.1' -and $historyView.Status -ceq 'HISTORY' -and
        $historyView.CurrentReadinessStatus -ceq 'NOT_CHECKED' -and $historyView.SqlLanguageExecution -ceq 'NOT_CHECKED' -and
        -not $historyView.MutationAllowed -and -not $historyView.ExecutionSupported -and $historyView.Actions.Count -eq 0 -and
        $script:transports -eq 0 -and $script:tools -eq 0) 'Actual public history opt-in reads no host and grants no authority'
    $publicHistory=Get-SqlServerLabExternalRuntimeCapability -SqlVersion '2022' -Provider docker -OperatingSystem linux -SoftwareId $selected.SoftwareId -RuntimeVersion $selected.RuntimeVersion -VariantId $selected.VariantId -IncludeRecordedEvidence
    $publicHistory.HistoricalEvidence=New-LabExternalRuntimeHistoricalEvidenceResult 'RECORDED_HISTORY_ONLY' 'DEFINED' 'INDEX_MATCH_RECORDED' -Cells @([pscustomobject]@{RecordCount=2;Reference='PRIVATE_CANARY';Records=@('PRIVATE_CANARY')})
    $summary=Assert-LabExternalRuntimeHttpDecision $publicHistory -IncludeRecordedEvidence
    Assert-Case ($publicHistory.Contract.Version -ceq '1.1' -and $summary.RecordCount -eq 2 -and $summary.Status -ceq 'RECORDED_HISTORY_ONLY' -and
        ($summary|ConvertTo-Json -Depth 8) -notmatch 'PRIVATE_CANARY|Cells|Records|Reference"') 'History projection preserves source1.1 and omits raw records/references'
    foreach($badVersion in @('Number','SingleElementArray')) {
        $candidate=$publicHistory|ConvertTo-Json -Depth 10|ConvertFrom-Json -Depth 10
        if($badVersion -ceq 'Number'){$candidate.Contract.Version=1.1}else{$candidate.Contract.Version=@('1.1')}
        try{Assert-LabExternalRuntimeHttpDecision $candidate -IncludeRecordedEvidence|Out-Null;$caught=$false}catch{$caught=$_.Exception.Message -ceq 'EXTERNAL_RUNTIME_HTTP_INVALID'}
        Assert-Case $caught "Original history contract version must be a string $badVersion"
    }
    foreach($badHistory in @('CountMismatch','CountLimit','CountString','UnknownReason','ExtraProperty','HostReady')) {
        $candidate=$publicHistory|ConvertTo-Json -Depth 10|ConvertFrom-Json -Depth 10
        switch($badHistory) {
            CountMismatch {$candidate.HistoricalEvidence.RecordCount=0}
            CountLimit {$candidate.HistoricalEvidence.RecordCount=129}
            CountString {$candidate.HistoricalEvidence.RecordCount='2'}
            UnknownReason {$candidate.HistoricalEvidence.ReasonCode='PRIVATE_CANARY'}
            ExtraProperty {$candidate.HistoricalEvidence|Add-Member NoteProperty Extra 'PRIVATE_CANARY'}
            HostReady {$candidate.CurrentReadiness.Status='READY';$candidate.CurrentReadiness.ReasonCode='NONE'}
        }
        try{Assert-LabExternalRuntimeHttpDecision $candidate -IncludeRecordedEvidence|Out-Null;$caught=$false}catch{$caught=$_.Exception.Message -ceq 'EXTERNAL_RUNTIME_HTTP_INVALID'}
        Assert-Case $caught "History count/type/shape/authority fails closed $badHistory"
    }
    foreach($extra in @('CheckProviderReadiness','IncludeRecordedEvidence','Apply')) {
        $bad=@{};foreach($key in $history.Keys){$bad[$key]=$history[$key]};$bad[$extra]=$true
        Reject-Request (New-Request ($bad|ConvertTo-Json -Compress)) "History cannot request extra capability $extra"
    }
    foreach($provider in @('docker','podman')) {
        $evaluate.Provider=$provider;$evaluate.CheckProviderReadiness=$true;$before=$script:transports
        $view=Send-Request $evaluate
        Assert-Case ($view.Decision.CurrentReadiness.Status -ceq 'READY' -and $script:transports -eq $before+1) "Actual public bounded adapter and classifier $provider"
        Assert-Case ($view.Decision.SqlLanguageExecution -ceq 'NOT_CHECKED' -and -not $view.Decision.ExecutionSupported -and -not $view.Decision.MutationAllowed -and $view.Decision.Actions.Count -eq 0) "Readiness does not grant execution $provider"
    }
    $script:mode='malformedFacts'
    foreach($provider in @('docker','podman')) {
        $evaluate.Provider=$provider;$before=$script:transports
        $view=Send-Request $evaluate
        Assert-Case ($script:transports -eq $before+1 -and $view.Decision.CurrentReadiness.Status -ceq 'BLOCKED' -and
            $view.Decision.CurrentReadiness.ReasonCode -ceq 'PROVIDER_RESPONSE_INVALID' -and -not $view.Decision.MutationAllowed) "Actual shared facts parser keeps unknown $provider blocked with fixed reason"
    }
    $script:mode='timeout';$view=Send-Request $evaluate
    Assert-Case ($view.Decision.CurrentReadiness.ReasonCode -ceq 'PROVIDER_PROBE_TIMEOUT') 'Transport timeout remains fixed BLOCKED'
    $evaluate.VariantId='PRIVATE_CANARY';$before=$script:transports;$view=Send-Request $evaluate
    Assert-Case ($view.Decision.Identity -eq $null -and ($view|ConvertTo-Json -Depth 8) -notmatch 'PRIVATE_CANARY' -and $script:transports -eq $before) 'Unknown catalog does not probe or reflect input'
    $body=$read|ConvertTo-Json -Compress
    foreach($variant in @(
        @{Origin=''},@{Origin='http://localhost:8484'},@{Authority='http://127.0.0.1:8485'},@{Address='::1'},@{Method='GET'},@{ContentType='text/plain'})) {
        Reject-Request (New-Request -Body $body @variant) ('Strict origin/listener/method/content boundary '+$script:passed)
    }
    foreach($bad in @('{"Action":"ReadOptions","action":"ReadOptions"}','{"Action":"ReadOptions","SqlVersion":null}','{"Action":"ReadOptions","Provider":{}}','[]',($body -replace '"2022"','2022'),($body -replace '"linux"','"linux","HostFacts":true'),(' '*8193),('{"Action":"'+('界'*3000)+'"}'))) {Reject-Request (New-Request $bad) ('Strict JSON bound/shape '+$script:passed)}
    foreach($field in @('Contract','Identity','CurrentReadiness','Actions')) {
        $decision=New-LabExternalRuntimeCapabilityDecision -SqlVersion '2022' -Provider docker -OperatingSystem linux -SoftwareId $selected.SoftwareId -RuntimeVersion $selected.RuntimeVersion -VariantId $selected.VariantId
        if($field -eq 'Actions') {$decision.Actions=@('PRIVATE_CANARY')} else {$decision.$field|Add-Member NoteProperty Extra 'PRIVATE_CANARY'}
        try {Assert-LabExternalRuntimeHttpDecision $decision;$caught=$false}catch{$caught=$true}
        Assert-Case $caught "Unexpected response property rejected $field"
    }
    foreach($badType in @('ContractArray','BoolString','UnknownReason','IdentityDrift')) {
        $decision=New-LabExternalRuntimeCapabilityDecision -SqlVersion '2022' -Provider docker -OperatingSystem linux -SoftwareId $selected.SoftwareId -RuntimeVersion $selected.RuntimeVersion -VariantId $selected.VariantId
        switch($badType) {
            ContractArray {$decision.Contract.Name=@($decision.Contract.Name)}
            BoolString {$decision.ExecutionSupported='false'}
            UnknownReason {$decision.CurrentReadiness.ReasonCode='PRIVATE_CANARY'}
            IdentityDrift {$decision.Identity.VariantId='foreign-runtime'}
        }
        try {Assert-LabExternalRuntimeHttpDecision $decision;$caught=$false}catch{$caught=$true}
        Assert-Case $caught "Closed typed result rejects $badType"
    }
    $evaluate.VariantId=$selected.VariantId;$evaluate.CheckProviderReadiness='false'
    Reject-Request (New-Request ($evaluate|ConvertTo-Json -Compress)) 'String boolean cannot authorize provider read'
    $evaluate.CheckProviderReadiness=$false
    $html=Get-Content (Join-Path $root 'Ui/index.html') -Raw
    foreach($id in @('open','dialog','provider','sql','choice','read','evaluate','host','history','close','result','history-result','status')) {
        Assert-Case ([regex]::Matches($html,'id="external-runtime-'+$id+'"').Count -eq 1) "UI element exists exactly once $id"
    }
    $script:mode='ready';$evaluate.VariantId=$selected.VariantId;$evaluate.Provider='docker';$evaluate.CheckProviderReadiness=$false
    # Execute the actual dedicated route, with only server response/module lookup seams.
    $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$parseErrors)
    $route=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '$path -eq ''/api/external-runtime-capability'''},$true))
    Assert-Case ($route.Count -eq 1 -and $parseErrors.Count -eq 0) 'Actual dedicated route AST is unique'
    function Get-Module {param($Name) $script:fixtureModule}
    function Write-UiResponse {param($Context,$Body,$ContentType,$StatusCode=200) $script:routeResponse=[pscustomobject]@{Body=$Body;Status=$StatusCode}}
    $Port=8484;$context=[pscustomobject]@{Request=New-Request ($evaluate|ConvertTo-Json -Compress)}
    $script:fixtureModule=$ExecutionContext.SessionState.Module
    foreach($once in 1) { & ([scriptblock]::Create($route[0].Clauses[0].Item2.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))) }
    Assert-Case ($script:routeResponse.Status -eq 200 -and ($script:routeResponse.Body|ConvertFrom-Json).Decision.CurrentReadiness.Status -ceq 'NOT_CHECKED') 'Actual route reaches helper/public/core in same module'
    $context=[pscustomobject]@{Request=New-Request ($history|ConvertTo-Json -Compress)};$before=$script:transports
    foreach($once in 1) { & ([scriptblock]::Create($route[0].Clauses[0].Item2.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))) }
    Assert-Case ($script:routeResponse.Status -eq 200 -and ($script:routeResponse.Body|ConvertFrom-Json).Status -ceq 'HISTORY' -and $script:transports -eq $before) 'Actual route dispatches explicit history without native work'
    Write-Host "HTTP TOTAL: $script:passed PASS; real provider/process/import: 0"
}
& $module {}
} finally {
    if($module){Remove-Module $module -ErrorAction Stop}
    $module=$null
}

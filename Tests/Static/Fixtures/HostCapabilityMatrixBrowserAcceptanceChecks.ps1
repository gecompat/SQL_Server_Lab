$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo Tests/Common/HostCapabilityMatrixBrowserAcceptance.ps1)
. (Join-Path $repo Private/HostCapabilityMatrixHttp.ps1)
$parts=Get-HostMatrixBrowserProductParts $repo
$module=New-HostMatrixBrowserModule $repo
$script:checks=0;$script:response=$null;$script:writes=0
function Check([bool]$Condition,[string]$Name) {if(-not $Condition){throw "HOST_MATRIX_BROWSER_FIXTURE: $Name"};$script:checks++}
function Reject([scriptblock]$Body,[string]$Name) {$failed=$false;try{& $Body}catch{$failed=$true};Check $failed $Name}
function Copy-Observation($Value) {$Value|ConvertTo-Json -Depth 25|ConvertFrom-Json -Depth 25}
function Get-Module {param($Name) if($Name -cne 'SqlServerLab'){throw 'UNEXPECTED_MODULE'};$module}
function Write-UiResponse {param($Context,$Body,$ContentType,[int]$StatusCode=200) $Context.Response.StatusCode=$StatusCode;$script:response=$Body;$script:writes++}
try {
    $declared=Get-CmsFullPageProductParts $repo
    Check ($parts.Assets.Count -eq $declared.Assets.Count -and $parts.Assets.ContainsKey('/host-capability-matrix.js') -and
        @(Compare-Object @($declared.Assets.Keys|Sort-Object -CaseSensitive) @($parts.Assets.Keys|Sort-Object -CaseSensitive) -CaseSensitive).Count -eq 0) 'all current product assets captured'
    Assert-HostMatrixBrowserSources $repo $parts.Sources;Check $true 'all actual loaded-reader/catalogue/metadata/source hashes match'
    $records=@(foreach($asset in $parts.Assets.Keys) {[pscustomobject]@{Path=$asset;Method='GET';Status=200;Payload=$null;View=$null}})
    $records+=@(foreach($path in @('/api/config','/api/commands','/api/jobs','/api/workflow','/api/tls-created-targets')) {
        [pscustomobject]@{Path=$path;Method='GET';Status=200;Payload=$null;View=$null}
    })
    foreach($case in @(Get-HostMatrixBrowserCases)) {
        $payload=if($case.Action -ceq 'ReadVersions'){[pscustomobject]@{Action='ReadVersions'}}else{
            [pscustomobject]@{Action='ReadMatrix';SqlVersion=$case.SqlVersion;Provider=$case.Provider;CheckProviderReadiness=$false}
        }
        Assert-HostMatrixBrowserPayload $payload $case
        $body=[Text.Encoding]::UTF8.GetBytes(($payload|ConvertTo-Json -Compress))
        $request=[pscustomobject]@{HttpMethod='POST';ContentType='application/json';Headers=@{Origin='http://127.0.0.1:8484'};
            Url=[uri]'http://127.0.0.1:8484/api/host-capability-matrix';LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,8484);InputStream=[IO.MemoryStream]::new($body)}
        $context=[pscustomobject]@{Request=$request;Response=[pscustomobject]@{StatusCode=0}};$path='/api/host-capability-matrix';$Port=8484
        $before=$script:writes;try {& $parts.Dispatch}finally{$request.InputStream.Dispose()}
        Check ($script:writes -eq $before+1 -and $context.Response.StatusCode -eq 200) ("actual extracted dispatch: {0}/{1}/{2}; status={3}; responses={4}" -f $case.Action,$case.SqlVersion,$case.Provider,$context.Response.StatusCode,($script:writes-$before))
        $view=$script:response|ConvertFrom-Json -Depth 20
        Assert-HostMatrixBrowserResult $view $case;Check $true 'actual response has expected scoped catalogue outcome'
        $records+=@([pscustomobject]@{Path=$path;Method='POST';Status=200;Payload=$payload;View=$view})
    }
    $operator=[ordered]@{Contract='SqlServerLab.HostMatrixBrowserOperator/1.0'}
    $flags=@('FullDocument','AllScriptsLoaded','BootstrapRendered','AllProviderRowsRendered','HyperVRowsRendered','DeferredVisible',
        'BlockedRowsVisible','ExplicitVariantVisible','SingleProviderProbeEnabled','AllProviderProbeDisabled','SelectionClears','CloseReopenClears','NoScriptErrors')
    foreach($flag in $flags) {$operator[$flag]=$true}
    $operator=[pscustomobject]$operator
    $calls=@(& $module {@($script:BrowserCalls)});$effects=& $module {$script:BrowserEffects}
    Assert-HostMatrixBrowserCompletion $operator $records @($parts.Assets.Keys) $calls $effects;Check $true 'synthetic complete record accepted without claiming rendered execution'
    foreach($flag in $flags) {
        $copy=Copy-Observation $operator;$copy.$flag=$false
        Reject {Assert-HostMatrixBrowserCompletion $copy $records @($parts.Assets.Keys) $calls 0} "missing operator observation rejected: $flag"
    }
    $copy=Copy-Observation $operator;$copy.NoScriptErrors='true'
    Reject {Assert-HostMatrixBrowserCompletion $copy $records @($parts.Assets.Keys) $calls 0} 'operator string does not become a boolean proof'
    Reject {Assert-HostMatrixBrowserCompletion $operator $records @($parts.Assets.Keys) $calls 1} 'forbidden effect count vetoes completion'
    Reject {Assert-HostMatrixBrowserCompletion $operator @($records|Where-Object Path -CNE '/host-capability-matrix.js') @($parts.Assets.Keys) $calls 0} 'missing actual asset load vetoes completion'
    foreach($path in @('/api/config','/api/commands','/api/jobs','/api/workflow','/api/tls-created-targets')) {
        Reject {Assert-HostMatrixBrowserCompletion $operator @($records|Where-Object Path -CNE $path) @($parts.Assets.Keys) $calls 0} "missing measured bootstrap vetoes completion: $path"
    }
    foreach($change in @('Method','Status')) {
        $copy=Copy-Observation $records;$record=@($copy|Where-Object Path -CEQ '/api/workflow')[0]
        if($change -eq 'Method'){$record.Method='POST'}else{$record.Status=500}
        Reject {Assert-HostMatrixBrowserCompletion $operator $copy @($parts.Assets.Keys) $calls 0} "wrong bootstrap method/status vetoes completion: $change"
    }
    Reject {Assert-HostMatrixBrowserCompletion $operator $records @($parts.Assets.Keys) @($calls|Select-Object -First 3) 0} 'missing public call vetoes completion'
    $copy=Copy-Observation $calls;$copy[0].CheckProviderReadiness=$true
    Reject {Assert-HostMatrixBrowserCompletion $operator $records @($parts.Assets.Keys) $copy 0} 'hidden host opt-in vetoes completion'
    $copy=Copy-Observation $records;@($copy|Where-Object Path -CEQ '/api/host-capability-matrix')[1].Payload.Provider='podman'
    Reject {Assert-HostMatrixBrowserCompletion $operator $copy @($parts.Assets.Keys) $calls 0} 'wire/public query mismatch vetoes completion'
    $copy=Copy-Observation $parts.Sources;$copy[0].Sha256='0'*64
    Reject {Assert-HostMatrixBrowserSources $repo $copy} 'source drift vetoes completion'
    $copy=Copy-Observation $parts.Sources;$copy[0].Path='../PRIVATE_HOST_CANARY'
    Reject {Assert-HostMatrixBrowserSources $repo $copy} 'source escape vetoes before file access'
    $bad=[pscustomobject]@{Action='ReadMatrix';SqlVersion='2022';Provider='docker';CheckProviderReadiness=$true}
    $caught=$false
    try {& $module {param($payload) Get-SqlServerLabHostCapabilityMatrix -SqlVersion $payload.SqlVersion -Provider $payload.Provider -CheckProviderReadiness:$payload.CheckProviderReadiness} $bad|Out-Null}
    catch {$caught=$_.Exception.Message -ceq 'HOST_MATRIX_BROWSER_PROBE_FORBIDDEN'}
    Check ($caught -and (& $module {$script:BrowserEffects}) -eq 1) 'instrumented provider opt-in is actually blocked before native work'
    foreach($entry in @('Tests/Common/HostCapabilityMatrixBrowserAcceptance.ps1','Tests/Integration/Invoke-HostCapabilityMatrixBrowserAcceptance.ps1')) {
        $tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $entry),[ref]$tokens,[ref]$errors)|Out-Null
        Check ($errors.Count -eq 0) "actual acceptance source parses: $entry"
    }
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Tests/Integration/Invoke-HostCapabilityMatrixBrowserAcceptance.ps1'),[ref]$tokens,[ref]$errors)
    $writer=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Write-UiResponse'},$true))
    Check ($writer.Count -eq 1) 'exact actual integration response writer discovered'
    $writerModule=New-Module -ArgumentList ([scriptblock]::Create($writer[0].Extent.Text)) -ScriptBlock {
        param($definition)
        . $definition
        $script:HostMatrixBrowserResponses=0
        $bodies=[Collections.Generic.List[object]]::new();$bodies.Add([byte[]]::new(0));$bodies.Add([byte[]](1,2,3));$bodies.Add('text')
        foreach($body in $bodies) {
            $stream=[IO.MemoryStream]::new()
            try {
                $context=[pscustomobject]@{Request=[pscustomobject]@{Url=[uri]'http://127.0.0.1:8484/favicon.ico'};
                    Response=[pscustomobject]@{StatusCode=0;ContentType='';ContentLength64=0;OutputStream=$stream}}
                Write-UiResponse -Context $context -Body $body -ContentType 'application/octet-stream'
                $expected=if($body -is [byte[]]){$body.Length}else{[Text.Encoding]::UTF8.GetByteCount($body)}
                if($stream.Length -ne $expected -or $context.Response.ContentLength64 -ne $expected) {throw 'HOST_MATRIX_BROWSER_RESPONSE_BYTES'}
            } finally {$stream.Dispose()}
        }
        $script:HostMatrixBrowserResponses
    }
    try {Check ((& $writerModule {$script:HostMatrixBrowserResponses}) -eq 3) 'actual writer preserves empty, binary and text response buffers'}
    finally {Remove-Module $writerModule -Force -ErrorAction SilentlyContinue}
    [pscustomobject]@{Passed=$script:checks;Assets=$parts.Assets.Count;Sources=$parts.Sources.Count;PublicCalls=$calls.Count;ExecutedProviderEffects=0;InjectedForbiddenAttempt=1;RenderedBrowser='NOT_EXECUTED'}|ConvertTo-Json -Compress
} finally {Remove-Module $module -Force -ErrorAction SilentlyContinue}

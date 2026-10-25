#Requires -Version 7.2
# Synthetic bootstrap capability is not evidence for the product's operator guard.
<#
.SYNOPSIS
    Serves the full product page and actual read-only host matrix route in an isolated test listener.
.DESCRIPTION
    Bootstrap is synthetic. Actual catalogue/public/HTTP decisions are instrumented;
    provider, SQL, State and secret operations are forbidden. Four-minute own listener.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceRoot,[ValidateRange(1025,65535)][int]$ListenerPort=19549)
$ErrorActionPreference='Stop'
if($ListenerPort -eq 14336) {throw 'HOST_MATRIX_BROWSER_PRODUCT_PORT'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo Tests/Common/HostCapabilityMatrixBrowserAcceptance.ps1)
$evidence=[IO.Path]::GetFullPath($EvidenceRoot);$parent=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/test-runs'))
if([IO.Path]::GetDirectoryName($evidence) -cne $parent -or [IO.Path]::GetFileName($evidence) -cnotmatch '^host-matrix-browser-[a-f0-9]{32}$' -or
    (Test-Path -LiteralPath $evidence)) {throw 'HOST_MATRIX_BROWSER_EVIDENCE_SCOPE'}
Assert-CmsBrowserPath $evidence;$null=[IO.Directory]::CreateDirectory($evidence)
Write-CmsBrowserEvidence (Join-Path $evidence owner.private.json) ([pscustomobject]@{Contract='SqlServerLab.HostMatrixBrowserOwner/1.0';Token=[guid]::NewGuid().ToString('N');Root=$evidence;Pid=$PID;StartedUtc=[DateTime]::UtcNow.ToString('o')})
$parts=Get-HostMatrixBrowserProductParts $repo
. (Join-Path $repo Private/HostCapabilityMatrixHttp.ps1)
$script:HostMatrixBrowserModule=New-HostMatrixBrowserModule $repo
function Get-Module {param($Name) if($Name -cne 'SqlServerLab'){throw 'HOST_MATRIX_BROWSER_MODULE'};$script:HostMatrixBrowserModule}
$script:HostMatrixBrowserResponse=$null;$script:HostMatrixBrowserResponses=0
function Write-UiResponse {
    param($Context,$Body,[string]$ContentType,[int]$StatusCode=200)
    $bytes=if($Body -is [byte[]]){,$Body}else{,[Text.Encoding]::UTF8.GetBytes([string]$Body)}
    $Context.Response.StatusCode=$StatusCode;$Context.Response.ContentType=$ContentType;$Context.Response.ContentLength64=$bytes.Length
    $Context.Response.OutputStream.Write($bytes,0,$bytes.Length);$script:HostMatrixBrowserResponses++
    if($Context.Request.Url.AbsolutePath -ceq '/api/host-capability-matrix') {$script:HostMatrixBrowserResponse=[string]$Body}
}
$records=[Collections.Generic.List[object]]::new();$listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://127.0.0.1:$ListenerPort/")
$completion=Join-Path $evidence browser-completed.private.json;$passed=$false;$failure=$null
try {
    $listener.Start()
    Write-CmsBrowserEvidence (Join-Path $evidence browser-ready.private.json) ([pscustomobject]@{Contract='SqlServerLab.HostMatrixBrowserReady/1.0';Url="http://127.0.0.1:$ListenerPort/#sql-lab-operator=$('a'*64)";CompletionFile=$completion;Sources=$parts.Sources;AssetPaths=@($parts.Assets.Keys);Bootstrap='SYNTHETIC';Catalogue='ACTUAL_PUBLIC_READER';HostReadiness='FORBIDDEN';ProductModuleImport='NOT_EXECUTED'})
    $deadline=[DateTime]::UtcNow.AddMinutes(4);$pending=$listener.GetContextAsync()
    while(-not (Test-Path -LiteralPath $completion)) {
        if([DateTime]::UtcNow -ge $deadline) {throw 'HOST_MATRIX_BROWSER_DEADLINE'}
        if(-not $pending.Wait(100)) {continue}
        $context=$pending.GetAwaiter().GetResult()
        try {
            if($records.Count -ge 512 -or -not [Net.IPAddress]::IsLoopback($context.Request.RemoteEndPoint.Address) -or $context.Request.Url.Query) {throw 'HOST_MATRIX_BROWSER_REQUEST_BOUNDARY'}
            $path=$context.Request.Url.AbsolutePath;$payload=$null;$view=$null;$beforeResponses=$script:HostMatrixBrowserResponses
            if($path -ceq '/api/host-capability-matrix') {
                $caseIndex=@($records | Where-Object Path -CEQ $path).Count;$cases=@(Get-HostMatrixBrowserCases)
                if($caseIndex -ge $cases.Count) {throw 'HOST_MATRIX_BROWSER_EXTRA_ACTION'}
                $bytes=Read-CmsBrowserBody $context.Request;$payload=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -Depth 2
                Assert-HostMatrixBrowserPayload $payload $cases[$caseIndex]
                $beforeCalls=& $script:HostMatrixBrowserModule {$script:BrowserCalls.Count}
                $stream=[IO.MemoryStream]::new($bytes,$false);$original=$context;$request=$context.Request
                $context=[pscustomobject]@{Response=$context.Response;Request=[pscustomobject]@{HttpMethod=$request.HttpMethod;ContentType=$request.ContentType;Headers=$request.Headers;Url=$request.Url;LocalEndPoint=$request.LocalEndPoint;InputStream=$stream}}
                $Port=$ListenerPort;$script:HostMatrixBrowserResponse=$null
                try {& $parts.Dispatch} finally {$stream.Dispose();$context=$original}
                $count=(& $script:HostMatrixBrowserModule {$script:BrowserCalls.Count})-$beforeCalls
                if($count -ne $(if($payload.Action -ceq 'ReadMatrix'){1}else{0}) -or $context.Response.StatusCode -ne 200 -or -not $script:HostMatrixBrowserResponse) {throw 'HOST_MATRIX_BROWSER_DISPATCH'}
                $view=$script:HostMatrixBrowserResponse|ConvertFrom-Json -Depth 20
                Assert-HostMatrixBrowserResult $view $cases[$caseIndex]
            } elseif($context.Request.HttpMethod -ceq 'GET' -and $parts.Assets.ContainsKey($path)) {
                $asset=$parts.Assets[$path];Write-UiResponse $context $asset.Bytes $asset.ContentType
            } elseif($context.Request.HttpMethod -ceq 'GET' -and $path -cin @('/api/config','/api/commands','/api/jobs','/api/workflow','/api/tls-created-targets')) {
                $body=if($path -ceq '/api/tls-created-targets'){'{"CreationBlocked":true,"Targets":[]}'}else{Get-CmsFullPageBootstrapResponse $path}
                Write-UiResponse $context $body 'application/json; charset=utf-8'
            } elseif($context.Request.HttpMethod -ceq 'GET' -and $path -ceq '/favicon.ico') {Write-UiResponse $context ([byte[]]::new(0)) 'image/x-icon' 204}
            else {throw 'HOST_MATRIX_BROWSER_ENDPOINT_NOT_ALLOWED'}
            if($script:HostMatrixBrowserResponses -ne $beforeResponses+1) {throw 'HOST_MATRIX_BROWSER_RESPONSE_COUNT'}
            $records.Add([pscustomobject]@{Path=$path;Method=$context.Request.HttpMethod;Status=$context.Response.StatusCode;Payload=$payload;View=$view})
        } finally {$context.Response.Close()}
        $pending=$listener.GetContextAsync()
    }
    Assert-CmsBrowserPath $completion
    if((Get-Item -LiteralPath $completion).Length -gt 4096) {throw 'HOST_MATRIX_BROWSER_COMPLETION_LIMIT'}
    $operator=Get-Content -LiteralPath $completion -Raw|ConvertFrom-Json -Depth 4
    $calls=@(& $script:HostMatrixBrowserModule {@($script:BrowserCalls)});$effects=& $script:HostMatrixBrowserModule {$script:BrowserEffects}
    Assert-HostMatrixBrowserCompletion $operator @($records) @($parts.Assets.Keys) $calls $effects
    Assert-HostMatrixBrowserSources $repo $parts.Sources
    $passed=$true
} catch {$failure=$_} finally {
    $listener.Close()
    $calls=@(& $script:HostMatrixBrowserModule {@($script:BrowserCalls)});$effects=& $script:HostMatrixBrowserModule {$script:BrowserEffects}
    $failureCode=if($failure){if($failure.Exception.Message -cmatch '^HOST_MATRIX_BROWSER_[A-Z_]+$'){$failure.Exception.Message}else{'HOST_MATRIX_BROWSER_FIXTURE_FAILED'}}else{$null}
    Write-CmsBrowserEvidence (Join-Path $evidence result.private.json) ([pscustomobject]@{Contract='SqlServerLab.HostMatrixBrowserAcceptance/1.0';Status=$(if($passed){'PASS'}else{'FAIL'});FailureCode=$failureCode;Sources=$parts.Sources;AssetPaths=@($parts.Assets.Keys);Requests=@($records);Calls=$calls;ForbiddenEffects=$effects;ListenerClosed=$true;Bootstrap='SYNTHETIC';Catalogue='ACTUAL_PUBLIC_READER';HostReadiness='NOT_EXECUTED';Provider='NOT_EXECUTED';Sql='NOT_EXECUTED';State='NOT_EXECUTED';Secret='NOT_EXECUTED';ProductModuleImport='NOT_EXECUTED'})
    Remove-Module $script:HostMatrixBrowserModule -Force -ErrorAction SilentlyContinue
}
if($failure) {throw $failure}
Write-Host 'PASS: rendered host matrix, actual route/public reader, own listener closed.'

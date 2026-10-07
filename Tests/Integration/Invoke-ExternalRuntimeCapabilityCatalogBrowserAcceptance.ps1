#Requires -Version 7.2
<#
.SYNOPSIS
    Serves the full product page and actual read-only external runtime catalogue route.
.DESCRIPTION
    Four page bootstrap reads are synthetic. The isolated module loads only the
    actual catalogue/recipe reader, public decision and HTTP helper. No product module
    import, State, provider, secret or SQL operation. The bounded own listener
    closes on every outcome; private observations remain in the owned test root.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceRoot,[ValidateRange(1025,65535)][int]$ListenerPort=19547)
$ErrorActionPreference='Stop'
if($ListenerPort -eq 14336){throw 'EXTERNAL_CATALOG_BROWSER_PRODUCT_PORT'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo Tests/Common/ExternalRuntimeCapabilityCatalogBrowserAcceptance.ps1)
$evidence=[IO.Path]::GetFullPath($EvidenceRoot);$parent=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/test-runs'))
if([IO.Path]::GetDirectoryName($evidence) -cne $parent -or [IO.Path]::GetFileName($evidence) -cnotmatch '^external-catalog-browser-[a-f0-9]{32}$' -or (Test-Path -LiteralPath $evidence)){throw 'EXTERNAL_CATALOG_BROWSER_EVIDENCE_SCOPE'}
Assert-CmsBrowserPath $evidence;$null=[IO.Directory]::CreateDirectory($evidence)
$parts=Get-ExternalCatalogBrowserProductParts $repo
. (Join-Path $repo Private/ExternalRuntimeCapabilityHttp.ps1)
$script:ExternalCatalogBrowserModule=New-ExternalCatalogBrowserModule $repo
function Get-Module {param($Name);if($Name -cne 'SqlServerLab'){throw 'EXTERNAL_CATALOG_BROWSER_MODULE'};$script:ExternalCatalogBrowserModule}
$script:ExternalCatalogBrowserResponse=$null;$script:ExternalCatalogBrowserResponses=0
function Write-UiResponse {
    param($Context,$Body,[string]$ContentType,[int]$StatusCode=200)
    if($Body -is [byte[]]){[byte[]]$bytes=$Body}else{[byte[]]$bytes=[Text.Encoding]::UTF8.GetBytes([string]$Body)}
    if($bytes.Length -gt 256KB){throw 'EXTERNAL_CATALOG_BROWSER_RESPONSE_LIMIT'}
    $Context.Response.StatusCode=$StatusCode;$Context.Response.ContentType=$ContentType;$Context.Response.ContentLength64=$bytes.Length
    $Context.Response.OutputStream.Write($bytes,0,$bytes.Length)
    $script:ExternalCatalogBrowserResponses++
    if($ContentType -ceq 'application/json; charset=utf-8' -and $Context.Request.Url.AbsolutePath -ceq '/api/external-runtime-capability'){$script:ExternalCatalogBrowserResponse=[string]$Body}
}
$records=[Collections.Generic.List[object]]::new();$listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://127.0.0.1:$ListenerPort/")
$completion=Join-Path $evidence browser-completed.private.json;$failure=$null;$passed=$false;$calls=@();$effects=$null
try{
    $listener.Start()
    Write-CmsBrowserEvidence (Join-Path $evidence browser-ready.private.json) ([pscustomobject]@{Contract='SqlServerLab.ExternalCatalogBrowserReady/1.0';Url="http://127.0.0.1:$ListenerPort/";CompletionFile=$completion;Sources=$parts.Sources;AssetPaths=@($parts.Assets.Keys);Bootstrap='SYNTHETIC';Catalogue='ACTUAL_PUBLIC_READER';HostReadiness='NOT_EXECUTED';RecordedEvidence='NOT_EXECUTED';Sql='NOT_EXECUTED';Provider='NOT_EXECUTED'})
    $deadline=[DateTime]::UtcNow.AddMinutes(4);$pending=$listener.GetContextAsync()
    while(-not(Test-Path -LiteralPath $completion)){
        if([DateTime]::UtcNow -ge $deadline){throw 'EXTERNAL_CATALOG_BROWSER_DEADLINE'}
        if(-not $pending.Wait(100)){continue}
        $context=$pending.GetAwaiter().GetResult()
        try{
            if($records.Count -ge 512 -or -not [Net.IPAddress]::IsLoopback($context.Request.RemoteEndPoint.Address) -or $context.Request.Url.Query){throw 'EXTERNAL_CATALOG_BROWSER_REQUEST_BOUNDARY'}
            $path=$context.Request.Url.AbsolutePath;$publicCalls=0;$view=$null;$payload=$null;$beforeResponses=$script:ExternalCatalogBrowserResponses
            if($path -ceq '/api/external-runtime-capability'){
                $beforeCalls=& $script:ExternalCatalogBrowserModule {$script:BrowserCalls.Count}
                $caseIndex=@($records | Where-Object Path -CEQ '/api/external-runtime-capability').Count
                $cases=@(Get-ExternalCatalogBrowserCases)
                if($caseIndex -ge $cases.Count){throw 'EXTERNAL_CATALOG_BROWSER_EXTRA_ACTION'}
                $bytes=Read-CmsBrowserBody $context.Request
                $payload=[Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -Depth 2
                Assert-ExternalCatalogBrowserPayload $payload $cases[$caseIndex]
                $stream=[IO.MemoryStream]::new($bytes,$false);$original=$context;$request=$context.Request
                $context=[pscustomobject]@{Response=$context.Response;Request=[pscustomobject]@{HttpMethod=$request.HttpMethod;ContentType=$request.ContentType;Headers=$request.Headers;Url=$request.Url;LocalEndPoint=$request.LocalEndPoint;InputStream=$stream}}
                $Port=$ListenerPort;$script:ExternalCatalogBrowserResponse=$null
                try{& $parts.Dispatch}finally{$stream.Dispose();$context=$original}
                $publicCalls=(& $script:ExternalCatalogBrowserModule {$script:BrowserCalls.Count})-$beforeCalls
                if($publicCalls -ne $(if($cases[$caseIndex].Action -ceq 'Evaluate'){1}else{0}) -or $context.Response.StatusCode -ne 200 -or -not $script:ExternalCatalogBrowserResponse){throw 'EXTERNAL_CATALOG_BROWSER_DISPATCH'}
                $view=$script:ExternalCatalogBrowserResponse | ConvertFrom-Json -Depth 6
                Assert-ExternalCatalogBrowserResult $script:ExternalCatalogBrowserModule $view $cases[$caseIndex]
            }elseif($context.Request.HttpMethod -ceq 'GET' -and $parts.Assets.ContainsKey($path)){
                $asset=$parts.Assets[$path];Write-UiResponse $context $asset.Bytes $asset.ContentType
            }elseif($context.Request.HttpMethod -ceq 'GET' -and $path -cin @('/api/config','/api/commands','/api/jobs','/api/workflow')){
                Write-UiResponse $context (Get-CmsFullPageBootstrapResponse $path) 'application/json; charset=utf-8'
            }elseif($context.Request.HttpMethod -ceq 'GET' -and $path -ceq '/favicon.ico'){
                Write-UiResponse $context ([byte[]]::new(0)) 'image/x-icon' 204
            }else{throw 'EXTERNAL_CATALOG_BROWSER_ENDPOINT_NOT_ALLOWED'}
            if($script:ExternalCatalogBrowserResponses -ne $beforeResponses+1){throw 'EXTERNAL_CATALOG_BROWSER_RESPONSE_COUNT'}
            $status=$context.Response.StatusCode
            $context.Response.Close()
            $records.Add([pscustomobject]@{Path=$path;Method=$context.Request.HttpMethod;Status=$status;Transport='SENT';PublicCalls=$publicCalls;Payload=$payload;Result=$view})
        }finally{$context.Response.Close()}
        $pending=$listener.GetContextAsync()
    }
    Assert-CmsBrowserPath $completion
    if((Get-Item -LiteralPath $completion).Length -gt 4096){throw 'EXTERNAL_CATALOG_BROWSER_COMPLETION_LIMIT'}
    $operator=Get-Content -LiteralPath $completion -Raw | ConvertFrom-Json -Depth 4
    $calls=@(& $script:ExternalCatalogBrowserModule {@($script:BrowserCalls)})
    $effects=& $script:ExternalCatalogBrowserModule {$script:BrowserEffects}
    Assert-ExternalCatalogBrowserCompletion $script:ExternalCatalogBrowserModule $operator @($records) @($parts.Assets.Keys) $calls $effects
    foreach($source in $parts.Sources){if((Get-FileHash -LiteralPath (Join-Path $repo $source.Path) -Algorithm SHA256).Hash -cne $source.Sha256){throw 'EXTERNAL_CATALOG_BROWSER_SOURCE_DRIFT'}}
    $passed=$true
}catch{$failure=$_}finally{
    $listener.Close()
    $calls=@(& $script:ExternalCatalogBrowserModule {@($script:BrowserCalls)})
    $effects=& $script:ExternalCatalogBrowserModule {$script:BrowserEffects}
    Write-CmsBrowserEvidence (Join-Path $evidence result.private.json) ([pscustomobject]@{Contract='SqlServerLab.ExternalCatalogBrowserAcceptance/1.0';Status=$(if($passed){'PASS'}else{'FAIL'});Sources=$parts.Sources;AssetPaths=@($parts.Assets.Keys);Requests=@($records);Calls=$calls;ForbiddenEffects=$effects;ListenerClosed=$true;Bootstrap='SYNTHETIC';Catalogue='ACTUAL_PUBLIC_READER';HostReadiness='NOT_EXECUTED';RecordedEvidence='NOT_EXECUTED';ProductModuleImport='NOT_EXECUTED';State='NOT_EXECUTED';Provider='NOT_EXECUTED';Secret='NOT_EXECUTED';Sql='NOT_EXECUTED';OtherUiOperations='NOT_EXECUTED'})
}
if($failure){throw $failure}
Write-Host 'PASS: rendered full-page external runtime catalogue decisions, actual route/public reader, own listener closed.'

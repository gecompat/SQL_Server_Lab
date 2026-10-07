#Requires -Version 7.2
<#
.SYNOPSIS
    Serves the complete product UI with synthetic bootstrap reads and CMS answers.
.DESCRIPTION
    No module, State, provider, secret or SQL access. The actual CMS HTTP adapter
    and dispatch remain intact. All other endpoints fail closed except four fixed
    read-only bootstrap responses. The operator observes navigation and rendering,
    then writes the fixed completion record. Own listener closes on every outcome.
    Native browser-to-SQL and other UI operations are not validated by this test.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceRoot,[ValidateRange(1025,65535)][int]$ListenerPort=19544)
$ErrorActionPreference='Stop'
if($ListenerPort -eq 14336){throw 'CMS_FULL_PAGE_PRODUCT_PORT'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo Tests/Common/ConnectionCenterCmsFullPageAcceptance.ps1)
$evidence=[IO.Path]::GetFullPath($EvidenceRoot);$parent=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/test-runs'))
if([IO.Path]::GetDirectoryName($evidence) -cne $parent -or [IO.Path]::GetFileName($evidence) -cnotmatch '^cms-full-page-[a-f0-9]{32}$' -or (Test-Path -LiteralPath $evidence)){throw 'CMS_FULL_PAGE_EVIDENCE_SCOPE'}
Assert-CmsBrowserPath $evidence;$null=[IO.Directory]::CreateDirectory($evidence)
$parts=Get-CmsFullPageProductParts $repo
. $parts.Adapter
$script:cmsFullPageAction=$null;$script:cmsFullPageCalls=0
function Invoke-SqlServerLabWorkflowAction {
    param([string]$Action,[string]$ExpectedPlanKey)
    if($script:cmsFullPageCalls -ne 0 -or $Action -cnotin @('GetCmsInspectionState','InspectCms') -or ($Action -ceq 'InspectCms' -and $ExpectedPlanKey -cne ('a'*64))){throw 'CMS_FULL_PAGE_WORKFLOW_ACTION_INVALID'}
    $script:cmsFullPageCalls++;$script:cmsFullPageAction=$Action
    New-CmsBrowserSyntheticResult -Case docker17 -Action $Action
}
function Write-UiResponse {
    param($Context,$Body,[string]$ContentType,[int]$StatusCode=200)
    [byte[]]$bytes=if($Body -is [byte[]]){$Body}else{[Text.Encoding]::UTF8.GetBytes([string]$Body)}
    if($bytes.Length -gt 256KB){throw 'CMS_FULL_PAGE_RESPONSE_LIMIT'}
    $Context.Response.StatusCode=$StatusCode;$Context.Response.ContentType=$ContentType
    $Context.Response.ContentLength64=$bytes.Length;$Context.Response.OutputStream.Write($bytes,0,$bytes.Length)
}
$records=[Collections.Generic.List[object]]::new();$listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://127.0.0.1:$ListenerPort/")
$completion=Join-Path $evidence browser-completed.private.json;$failure=$null;$passed=$false
try{
    $listener.Start()
    Write-CmsBrowserEvidence (Join-Path $evidence browser-ready.private.json) ([pscustomobject]@{Contract='SqlServerLab.CmsFullPageReady/1.0';Url="http://127.0.0.1:$ListenerPort/";CompletionFile=$completion;Sources=$parts.Sources;AssetPaths=@($parts.Assets.Keys);Runtime='NOT_EXECUTED';Sql='NOT_EXECUTED'})
    $deadline=[DateTime]::UtcNow.AddMinutes(4);$pending=$listener.GetContextAsync()
    while(-not(Test-Path -LiteralPath $completion)){
        if([DateTime]::UtcNow -ge $deadline){throw 'CMS_FULL_PAGE_DEADLINE'}
        if(-not $pending.Wait(100)){continue}
        $context=$pending.GetAwaiter().GetResult()
        try{
            if($records.Count -ge 512 -or -not [Net.IPAddress]::IsLoopback($context.Request.RemoteEndPoint.Address) -or $context.Request.Url.Query){throw 'CMS_FULL_PAGE_REQUEST_BOUNDARY'}
            $path=$context.Request.Url.AbsolutePath;$action=$null
            if($path -ceq '/api/cms-inspection'){
                $script:cmsFullPageCalls=0;$script:cmsFullPageAction=$null;$original=$context;$stream=$null
                if($context.Request.HttpMethod -ceq 'POST'){
                    $bytes=Read-CmsBrowserBody $context.Request;$stream=[IO.MemoryStream]::new($bytes,$false);$request=$context.Request
                    $context=[pscustomobject]@{Response=$context.Response;Request=[pscustomobject]@{HttpMethod=$request.HttpMethod;ContentType=$request.ContentType;Headers=$request.Headers;Url=$request.Url;InputStream=$stream;ContentEncoding=$request.ContentEncoding}}
                }
                try{& $parts.Dispatch}finally{if($stream){$stream.Dispose()};$context=$original}
                $action=$script:cmsFullPageAction
                if($script:cmsFullPageCalls -ne 1){throw 'CMS_FULL_PAGE_DISPATCH_COUNT'}
            }elseif($context.Request.HttpMethod -ceq 'GET' -and $parts.Assets.ContainsKey($path)){
                $asset=$parts.Assets[$path];Write-UiResponse $context $asset.Bytes $asset.ContentType
            }elseif($context.Request.HttpMethod -ceq 'GET' -and $path -cin @('/api/config','/api/commands','/api/jobs','/api/workflow')){
                Write-UiResponse $context (Get-CmsFullPageBootstrapResponse $path) 'application/json; charset=utf-8'
            }elseif($context.Request.HttpMethod -ceq 'GET' -and $path -ceq '/favicon.ico'){
                Write-UiResponse $context '' 'image/x-icon' 204
            }else{throw 'CMS_FULL_PAGE_ENDPOINT_NOT_ALLOWED'}
            $records.Add([pscustomobject]@{Path=$path;Method=$context.Request.HttpMethod;Status=$context.Response.StatusCode;Action=$action})
        }finally{$context.Response.Close()}
        $pending=$listener.GetContextAsync()
    }
    Assert-CmsBrowserPath $completion
    if((Get-Item -LiteralPath $completion).Length -gt 4096){throw 'CMS_FULL_PAGE_COMPLETION_LIMIT'}
    $operator=Get-Content -LiteralPath $completion -Raw|ConvertFrom-Json -Depth 4
    Assert-CmsFullPageCompletion $operator @($records) @($parts.Assets.Keys)
    foreach($source in $parts.Sources){if((Get-FileHash -LiteralPath (Join-Path $repo $source.Path)).Hash -cne $source.Sha256){throw 'CMS_FULL_PAGE_SOURCE_DRIFT'}}
    $passed=$true
}catch{$failure=$_}finally{
    $listener.Close()
    Write-CmsBrowserEvidence (Join-Path $evidence result.private.json) ([pscustomobject]@{Contract='SqlServerLab.CmsFullPageAcceptance/1.0';Status=$(if($passed){'PASS'}else{'FAIL'});Sources=$parts.Sources;AssetPaths=@($parts.Assets.Keys);Requests=@($records);ListenerClosed=$true;Runtime='NOT_EXECUTED';Sql='NOT_EXECUTED';NativeBrowserToSql='NOT_EXECUTED';OtherUiOperations='NOT_EXECUTED'})
}
if($failure){throw $failure}
Write-Host 'PASS: full product UI bootstrap, navigation and synthetic CMS HTTP inspection; own listener closed.'

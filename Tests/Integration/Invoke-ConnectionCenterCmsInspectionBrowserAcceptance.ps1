#Requires -Version 7.2
<#
.SYNOPSIS
    Serves the actual CMS dialog, JavaScript and HTTP dispatch with synthetic responses.
.DESCRIPTION
    No module, registered State, secret, provider or SQL is accessed. The operator
    observes the rendered browser and writes the fixed local completion record.
    The listener independently verifies the exact action sequence. Evidence is
    retained under this checkout's .artifacts/test-runs/cms-browser-<GUID N>.
    This does not prove native browser-to-SQL, whole-page bootstrap, sync or auth.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceRoot,[ValidateRange(1025,65535)][int]$ListenerPort=19543)
$ErrorActionPreference='Stop'
if($ListenerPort -eq 14336){throw 'CMS_BROWSER_PRODUCT_PORT'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo Tests/Common/ConnectionCenterCmsInspectionBrowserAcceptance.ps1)
$evidence=[IO.Path]::GetFullPath($EvidenceRoot)
$parent=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/test-runs'))
if([IO.Path]::GetDirectoryName($evidence) -cne $parent -or [IO.Path]::GetFileName($evidence) -cnotmatch '^cms-browser-[a-f0-9]{32}$' -or (Test-Path -LiteralPath $evidence)){throw 'CMS_BROWSER_EVIDENCE_SCOPE'}
Assert-CmsBrowserPath $evidence
$null=[IO.Directory]::CreateDirectory($evidence)
$sources=@('Ui/index.html','Ui/app.js','Ui/app.css','Tools/Start-SqlServerLabUi.ps1')
$hashes=@(foreach($source in $sources){[pscustomobject]@{Path=$source;Sha256=(Get-FileHash -LiteralPath (Join-Path $repo $source)).Hash}})
$parts=Get-CmsBrowserProductParts $repo
foreach($source in $hashes){if((Get-FileHash -LiteralPath (Join-Path $repo $source.Path)).Hash -cne $source.Sha256){throw 'CMS_BROWSER_PRODUCT_SOURCE_DRIFT'}}
. $parts.Adapter
$script:cmsBrowserCase='docker15';$script:cmsBrowserAction=$null;$script:cmsBrowserCalls=0
function Invoke-SqlServerLabWorkflowAction {
    param([string]$Action,[string]$ExpectedPlanKey)
    if($Action -cnotin @('GetCmsInspectionState','InspectCms') -or ($Action -ceq 'InspectCms' -and $ExpectedPlanKey -cne ('a'*64))){throw 'CMS_BROWSER_ACTION_INVALID'}
    if($script:cmsBrowserCalls -ge 1){throw 'CMS_BROWSER_DUPLICATE_DISPATCH'}
    $script:cmsBrowserCalls++;$script:cmsBrowserAction=$Action
    if($script:cmsBrowserCase -ceq 'late' -and $Action -ceq 'InspectCms'){
        Write-CmsBrowserEvidence (Join-Path $evidence late-pending.private.json) ([pscustomobject]@{Status='WAITING_FOR_OPERATOR_CLOSE'})
        $release=Join-Path $evidence late-release.private.json;$wait=[DateTime]::UtcNow.AddSeconds(45)
        while(-not(Test-Path -LiteralPath $release)){if([DateTime]::UtcNow -ge $wait){throw 'CMS_BROWSER_LATE_TIMEOUT'};Start-Sleep -Milliseconds 50}
        Assert-CmsBrowserPath $release
        if((Get-Item -LiteralPath $release).Length -gt 128 -or (Get-Content -LiteralPath $release -Raw|ConvertFrom-Json).Status -cne 'RELEASE'){throw 'CMS_BROWSER_LATE_RELEASE_INVALID'}
    }
    New-CmsBrowserSyntheticResult -Case $script:cmsBrowserCase -Action $Action
}
function Write-UiResponse {
    param($Context,[string]$Body,[string]$ContentType,[int]$StatusCode=200)
    $bytes=[Text.Encoding]::UTF8.GetBytes($Body)
    if($bytes.Length -gt 256KB){throw 'CMS_BROWSER_RESPONSE_LIMIT'}
    $Context.Response.StatusCode=$StatusCode;$Context.Response.ContentType=$ContentType
    $Context.Response.ContentLength64=$bytes.Length;$Context.Response.OutputStream.Write($bytes)
}
$records=[Collections.Generic.List[object]]::new();$listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://127.0.0.1:$ListenerPort/")
$completion=Join-Path $evidence browser-completed.private.json;$failure=$null;$passed=$false;$requests=0
try{
    $listener.Start()
    Write-CmsBrowserEvidence (Join-Path $evidence browser-ready.private.json) ([pscustomobject]@{Contract='SqlServerLab.CmsBrowserReady/1.0';Url="http://127.0.0.1:$ListenerPort/?case=docker15";CompletionFile=$completion;Sources=$hashes;Runtime='NOT_EXECUTED';Sql='NOT_EXECUTED'})
    $deadline=[DateTime]::UtcNow.AddMinutes(15);$pending=$listener.GetContextAsync()
    while(-not(Test-Path -LiteralPath $completion)){
        if([DateTime]::UtcNow -ge $deadline){throw 'CMS_BROWSER_DEADLINE'}
        if(-not $pending.Wait(100)){continue}
        $context=$pending.GetAwaiter().GetResult();$requests++
        try{
            if($requests -gt 128 -or -not [Net.IPAddress]::IsLoopback($context.Request.RemoteEndPoint.Address)){throw 'CMS_BROWSER_REQUEST_BOUNDARY'}
            $path=$context.Request.Url.AbsolutePath
            if($path -ceq '/api/cms-inspection' -and -not $context.Request.Url.Query){
                $script:cmsBrowserCalls=0;$script:cmsBrowserAction=$null;$original=$context;$stream=$null
                if($context.Request.HttpMethod -ceq 'POST'){
                    $bytes=Read-CmsBrowserBody $context.Request
                    $stream=[IO.MemoryStream]::new($bytes,$false);$request=$context.Request
                    $context=[pscustomobject]@{Response=$context.Response;Request=[pscustomobject]@{HttpMethod=$request.HttpMethod;ContentType=$request.ContentType;Headers=$request.Headers;Url=$request.Url;InputStream=$stream;ContentEncoding=$request.ContentEncoding}}
                }
                try{& $parts.Dispatch}finally{if($stream){$stream.Dispose()};$context=$original}
                $records.Add([pscustomobject]@{Case=$script:cmsBrowserCase;Action=$script:cmsBrowserAction;Status=$context.Response.StatusCode;RuntimeCalls=0;SqlCalls=0;SecretReads=0})
                if($script:cmsBrowserCalls -ne 1 -or $records.Count -gt 24){throw 'CMS_BROWSER_DISPATCH_COUNT'}
            }elseif($context.Request.HttpMethod -ceq 'GET' -and $path -ceq '/'){
                $case=[string]$context.Request.QueryString['case']
                if(@($context.Request.QueryString.AllKeys|Where-Object {$_ -cne 'case'}).Count -or $case -cnotin @('docker15','podman16','docker17','not-configured','unknown','hyperv','wrong-binding','unsafe','error','late')){throw 'CMS_BROWSER_CASE_INVALID'}
                $script:cmsBrowserCase=$case;Write-UiResponse $context $parts.Page 'text/html; charset=utf-8'
            }elseif($context.Request.HttpMethod -ceq 'GET' -and -not $context.Request.Url.Query -and $path -cin @('/app.css','/cms-fixture.js')){
                if($path -ceq '/app.css'){Write-UiResponse $context (Get-Content -LiteralPath (Join-Path $repo Ui/app.css) -Raw) 'text/css; charset=utf-8'}else{Write-UiResponse $context $parts.JavaScript 'application/javascript; charset=utf-8'}
            }else{Write-UiResponse $context '{"Code":"NOT_FOUND"}' 'application/json' 404}
        }finally{$context.Response.Close()}
        $pending=$listener.GetContextAsync()
    }
    Assert-CmsBrowserPath $completion
    if((Get-Item -LiteralPath $completion).Length -gt 4096){throw 'CMS_BROWSER_COMPLETION_LIMIT'}
    $operator=Get-Content -LiteralPath $completion -Raw|ConvertFrom-Json -Depth 4
    Assert-CmsBrowserCompletion $operator @($records)
    foreach($source in $hashes){if((Get-FileHash -LiteralPath (Join-Path $repo $source.Path)).Hash -cne $source.Sha256){throw 'CMS_BROWSER_PRODUCT_SOURCE_DRIFT'}}
    $passed=$true
}catch{$failure=$_}finally{
    $listener.Close()
    Write-CmsBrowserEvidence (Join-Path $evidence result.private.json) ([pscustomobject]@{Contract='SqlServerLab.CmsBrowserAcceptance/1.0';Status=$(if($passed){'PASS'}else{'FAIL'});Sources=$hashes;Requests=@($records);RenderedDialog=$(if($passed){'OPERATOR_OBSERVED'}else{'NOT_CONFIRMED'});ListenerClosed=$true;Runtime='NOT_EXECUTED';Sql='NOT_EXECUTED';WholePage='NOT_EXECUTED';NativeBrowserToSql='NOT_EXECUTED';Sync='NOT_EXECUTED';Ssms='NOT_EXECUTED';MemberConnections='NOT_EXECUTED';LeastPrivilege='NOT_EXECUTED'})
}
if($failure){throw $failure}
Write-Host 'PASS: actual CMS dialog/JavaScript and HTTP dispatch with synthetic responses; own listener closed.'

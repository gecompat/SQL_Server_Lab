# Test-only native CMS HTTP composition; all other bootstrap reads stay synthetic.
. (Join-Path $PSScriptRoot ConnectionCenterCmsFullPageAcceptance.ps1)
. (Join-Path $PSScriptRoot ConnectionCenterCmsInspectionAcceptance.ps1)

function Test-CmsNativeBrowserBootstrapDisconnect {
    param([string]$Path,[string]$Method,[Exception]$Exception)
    if($Method -cne 'GET' -or $Path -cnotin @('/api/config','/api/commands','/api/workflow','/api/jobs') -or -not $Exception){return $false}
    $cause=$Exception.GetBaseException()
    ($cause -is [Net.HttpListenerException] -and $cause.NativeErrorCode -in @(64,995))
}

function Assert-CmsNativeBrowserCompletion {
    param($Operator,[object[]]$Records,[string[]]$AssetPaths)
    $flags=@('FullDocument','AllScriptsLoaded','BootstrapRendered','NavigationToCms','InitialNotChecked','FirstNativeInspection','SecondNativeInspection','NoScriptErrors','DialogClosed')
    if($Operator -isnot [pscustomobject] -or $Operator.Contract -cne 'SqlServerLab.CmsNativeBrowserOperator/1.0' -or @($Operator.PSObject.Properties.Name).Count -ne 10 -or @($Operator.PSObject.Properties.Name|Where-Object {$_ -cnotin (@('Contract')+$flags)}).Count){throw 'CMS_NATIVE_BROWSER_OPERATOR_INVALID'}
    foreach($name in $flags){if($Operator.$name -isnot [bool] -or -not $Operator.$name){throw 'CMS_NATIVE_BROWSER_OPERATOR_INVALID'}}
    if($AssetPaths.Count -ne 12 -or @($AssetPaths|Sort-Object -Unique).Count -ne 12){throw 'CMS_NATIVE_BROWSER_ASSET_SET'}
    $allowed=@($AssetPaths)+@('/api/config','/api/commands','/api/workflow','/api/jobs','/api/cms-inspection','/favicon.ico')
    if($Records.Count -gt 512 -or @($Records|Where-Object {$_.Path -cnotin $allowed -or $_.Status -ne $(if($_.Path -ceq '/favicon.ico'){204}else{200}) -or ($_.Method -cne 'GET' -and $_.Path -cne '/api/cms-inspection') -or $_.Transport -cnotin @('SENT','CLIENT_DISCONNECTED') -or ($_.Transport -ceq 'CLIENT_DISCONNECTED' -and ($_.Method -cne 'GET' -or $_.Path -cnotin @('/api/config','/api/commands','/api/workflow','/api/jobs')))}).Count){throw 'CMS_NATIVE_BROWSER_REQUEST_INVALID'}
    foreach($path in $AssetPaths){if(@($Records|Where-Object Path -CEQ $path).Count -ne 1){throw 'CMS_NATIVE_BROWSER_ASSET_MISSING_OR_DUPLICATE'}}
    foreach($path in @('/api/config','/api/commands','/api/workflow','/api/jobs')){if(@($Records|Where-Object {$_.Path -ceq $path -and $_.Transport -ceq 'SENT'}).Count -lt $(if($path -ceq '/api/jobs'){2}else{1})){throw 'CMS_NATIVE_BROWSER_BOOTSTRAP_MISSING'}}
    $cms=@($Records|Where-Object Path -CEQ '/api/cms-inspection')
    if($cms.Count -ne 4 -or ($cms.Action -join '|') -cne 'GetCmsInspectionState|InspectCms|GetCmsInspectionState|InspectCms' -or ($cms.Method -join '|') -cne 'GET|POST|GET|POST' -or ($cms.CmsStatus -join '|') -cne 'NOT_CHECKED|OBSERVED|NOT_CHECKED|OBSERVED'){throw 'CMS_NATIVE_BROWSER_SEQUENCE'}
}

function Invoke-CmsNativeBrowserWorkflow {
    param($Module,$Scope,$Custody,[string]$Provider,[string]$SelectionKey,[string]$Action,[string]$ExpectedPlanKey)
    if($Action -cnotin @('GetCmsInspectionState','InspectCms') -or ($Action -ceq 'GetCmsInspectionState' -and $ExpectedPlanKey) -or ($Action -ceq 'InspectCms' -and $ExpectedPlanKey -cne $SelectionKey)){throw 'CMS_NATIVE_BROWSER_ACTION_INVALID'}
    Assert-CmsInspectionAcceptanceRoute $Module $Scope $Provider
    # Resolve inside the original module; the HTTP proxy never replaces its Core.
    $answer=& $Module {
        param($Action,$Key)
        if($Action -ceq 'InspectCms'){Invoke-SqlServerLabWorkflowAction -Action $Action -ExpectedPlanKey $Key}
        else{Invoke-SqlServerLabWorkflowAction -Action $Action}
    } $Action $ExpectedPlanKey
    $status=if($Action -ceq 'InspectCms'){'OBSERVED'}else{'NOT_CHECKED'}
    $code=if($Action -ceq 'InspectCms'){'CMS_INSPECTION_OBSERVED'}else{'CMS_INSPECTION_NOT_CHECKED'}
    Assert-CmsInspectionAcceptanceResult $answer.Result $Custody $Provider $SelectionKey $status $code -Version 2025
    if($Action -ceq 'GetCmsInspectionState' -and $null -ne $answer.Result.ObservedAt){throw 'CMS_NATIVE_BROWSER_GET_OBSERVATION'}
    Assert-CmsInspectionAcceptanceRoute $Module $Scope $Provider
    $answer
}

function Invoke-CmsNativeBrowserSession {
    param($Module,$Scope,$Custody,[string]$Provider,[string]$SelectionKey,[string]$RepositoryRoot,[string]$EvidenceRoot,[ValidateRange(1025,65535)][int]$ListenerPort=19545)
    if($ListenerPort -eq 14336){throw 'CMS_NATIVE_BROWSER_PRODUCT_PORT'}
    Assert-CmsBrowserPath $EvidenceRoot
    $parts=Get-CmsFullPageProductParts $RepositoryRoot
    . $parts.Adapter
    $session=[pscustomobject]@{Calls=0;Action=$null;Result=$null;Ordinal=0}
    $expectedActions=@('GetCmsInspectionState','InspectCms','GetCmsInspectionState','InspectCms')
    function Invoke-SqlServerLabWorkflowAction {
        param([string]$Action,[string]$ExpectedPlanKey)
        if($session.Calls -ne 0 -or $session.Ordinal -ge 4 -or $Action -cne $expectedActions[$session.Ordinal]){throw 'CMS_NATIVE_BROWSER_ACTION_SEQUENCE'}
        $session.Calls++;$session.Action=$Action
        $answer=Invoke-CmsNativeBrowserWorkflow $Module $Scope $Custody $Provider $SelectionKey $Action $ExpectedPlanKey
        $session.Result=$answer.Result;$session.Ordinal++
        $answer
    }
    function Write-UiResponse {
        param($Context,$Body,[string]$ContentType,[int]$StatusCode=200)
        if($Body -is [byte[]]){[byte[]]$bytes=$Body}else{[byte[]]$bytes=[Text.Encoding]::UTF8.GetBytes([string]$Body)}
        if($bytes.Length -gt 256KB){throw 'CMS_NATIVE_BROWSER_RESPONSE_LIMIT'}
        $Context.Response.StatusCode=$StatusCode;$Context.Response.ContentType=$ContentType
        $Context.Response.ContentLength64=$bytes.Length;$Context.Response.OutputStream.Write($bytes,0,$bytes.Length)
    }
    $records=[Collections.Generic.List[object]]::new();$observations=[Collections.Generic.List[object]]::new()
    $listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://127.0.0.1:$ListenerPort/")
    $completion=Join-Path $EvidenceRoot browser-completed.private.json;$passed=$false
    try{
        $listener.Start()
        Write-CmsBrowserEvidence (Join-Path $EvidenceRoot browser-ready.private.json) ([pscustomobject]@{Contract='SqlServerLab.CmsNativeBrowserReady/1.0';Url="http://127.0.0.1:$ListenerPort/";CompletionFile=$completion;Provider=$Provider;Sources=$parts.Sources;AssetPaths=@($parts.Assets.Keys);Bootstrap='SYNTHETIC';Cms='NATIVE_WORKFLOW_WORKER_SQL'})
        $deadline=[DateTime]::UtcNow.AddMinutes(4);$pending=$listener.GetContextAsync()
        while(-not(Test-Path -LiteralPath $completion)){
            if([DateTime]::UtcNow -ge $deadline){throw 'CMS_NATIVE_BROWSER_DEADLINE'}
            if(-not $pending.Wait(100)){continue}
            $context=$pending.GetAwaiter().GetResult()
            try{
                if($records.Count -ge 512 -or -not [Net.IPAddress]::IsLoopback($context.Request.RemoteEndPoint.Address) -or $context.Request.Url.Query){throw 'CMS_NATIVE_BROWSER_REQUEST_BOUNDARY'}
                $path=$context.Request.Url.AbsolutePath;$action=$null;$cmsStatus=$null;$transport='SENT'
                if($path -ceq '/api/cms-inspection'){
                    $session.Calls=0;$session.Result=$null;$original=$context;$stream=$null
                    if($context.Request.HttpMethod -ceq 'POST'){
                        $bytes=Read-CmsBrowserBody $context.Request;$stream=[IO.MemoryStream]::new($bytes,$false);$request=$context.Request
                        $context=[pscustomobject]@{Response=$context.Response;Request=[pscustomobject]@{HttpMethod=$request.HttpMethod;ContentType=$request.ContentType;Headers=$request.Headers;Url=$request.Url;InputStream=$stream;ContentEncoding=$request.ContentEncoding}}
                    }
                    try{& $parts.Dispatch}finally{if($stream){$stream.Dispose()};$context=$original}
                    if($session.Calls -ne 1 -or -not $session.Result){throw 'CMS_NATIVE_BROWSER_DISPATCH_COUNT'}
                    $action=$session.Action;$cmsStatus=$session.Result.Status
                    $observations.Add($session.Result)
                }elseif($context.Request.HttpMethod -ceq 'GET' -and $parts.Assets.ContainsKey($path)){
                    $asset=$parts.Assets[$path];Write-UiResponse $context $asset.Bytes $asset.ContentType
                }elseif($context.Request.HttpMethod -ceq 'GET' -and $path -cin @('/api/config','/api/commands','/api/jobs','/api/workflow')){
                    $bootstrap=Get-CmsFullPageBootstrapResponse $path
                    if($path -ceq '/api/workflow'){
                        $view=$bootstrap|ConvertFrom-Json -Depth 8
                        $view.Host.HyperV.Message='CMS-Browserabnahme: Bootstrap synthetisch; nur CMS-Prüfung nativ.'
                        $bootstrap=$view|ConvertTo-Json -Depth 8 -Compress
                    }
                    try{Write-UiResponse $context $bootstrap 'application/json; charset=utf-8'}catch{
                        if(-not(Test-CmsNativeBrowserBootstrapDisconnect $path $context.Request.HttpMethod $_.Exception)){throw}
                        $transport='CLIENT_DISCONNECTED'
                    }
                }elseif($context.Request.HttpMethod -ceq 'GET' -and $path -ceq '/favicon.ico'){
                    Write-UiResponse $context '' 'image/x-icon' 204
                }else{throw 'CMS_NATIVE_BROWSER_ENDPOINT_NOT_ALLOWED'}
            }finally{
                try{$context.Response.Close()}catch{
                    if(-not(Test-CmsNativeBrowserBootstrapDisconnect $path $context.Request.HttpMethod $_.Exception)){throw}
                    $transport='CLIENT_DISCONNECTED'
                }
            }
            $records.Add([pscustomobject]@{Path=$path;Method=$context.Request.HttpMethod;Status=$context.Response.StatusCode;Action=$action;CmsStatus=$cmsStatus;Transport=$transport})
            $pending=$listener.GetContextAsync()
        }
        Assert-CmsBrowserPath $completion
        if((Get-Item -LiteralPath $completion).Length -gt 4096){throw 'CMS_NATIVE_BROWSER_COMPLETION_LIMIT'}
        $operator=Get-Content -LiteralPath $completion -Raw|ConvertFrom-Json -Depth 4
        Assert-CmsNativeBrowserCompletion $operator @($records) @($parts.Assets.Keys)
        foreach($source in $parts.Sources){if((Get-FileHash -LiteralPath (Join-Path $RepositoryRoot $source.Path)).Hash -cne $source.Sha256){throw 'CMS_NATIVE_BROWSER_SOURCE_DRIFT'}}
        $passed=$true
    }finally{
        $listener.Close()
        Write-CmsBrowserEvidence (Join-Path $EvidenceRoot browser-result.private.json) ([pscustomobject]@{Contract='SqlServerLab.CmsNativeBrowserTransport/1.0';Status=$(if($passed){'PASS'}else{'FAIL'});Sources=$parts.Sources;AssetPaths=@($parts.Assets.Keys);Requests=@($records);Observations=@($observations);ListenerClosed=$true;Bootstrap='SYNTHETIC';OtherUiOperations='NOT_EXECUTED'})
    }
    @($observations)
}

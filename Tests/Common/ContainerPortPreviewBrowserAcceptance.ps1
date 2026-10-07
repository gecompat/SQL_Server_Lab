# Test-only, bounded loopback listener. Browser interaction belongs to the
# operator; the listener independently measures actual HTTP/core effects.
function Read-PortPreviewBrowserRequestBody {
    param([Parameter(Mandatory)]$Request,[ValidateRange(1,10000)][int]$TimeoutMilliseconds=10000)
    $buffer=[byte[]]::new(2049);$count=0;$timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        while($count -lt $buffer.Length){
            $remaining=$TimeoutMilliseconds-[int]$timer.ElapsedMilliseconds
            if($remaining -le 0){throw 'PORT_BROWSER_BODY_TIMEOUT'}
            $pending=$Request.InputStream.ReadAsync($buffer,$count,$buffer.Length-$count)
            if(-not $pending.Wait($remaining)){throw 'PORT_BROWSER_BODY_TIMEOUT'}
            $read=$pending.GetAwaiter().GetResult()
            if($read -eq 0){break};$count+=$read
        }
        $bytes=[byte[]]::new($count);[Array]::Copy($buffer,$bytes,$count)
        return ,$bytes
    } catch {
        # Closing the owned request stream releases an outstanding transport read.
        # No product dispatch/native observation has started at this boundary.
        $Request.InputStream.Close()
        throw
    } finally {$timer.Stop()}
}

function Assert-PortPreviewBrowserObservation {
    param($Module,[object[]]$Records,[object[]]$Plans,[string]$Provider,$Operator)
    & $Module {
        param($Records,$Plans,$Provider,$Operator)
        Assert-LabOwnedHostProperties $Operator @('Contract','RenderedDialog','InvalidPortVeto','EditingClearedResult','CloseClearedDialog')
        if($Operator.Contract -cne 'SqlServerLab.PortBrowserOperatorObservation/1.0'){throw 'PORT_BROWSER_COMPLETION_INVALID'}
        foreach($name in @('RenderedDialog','InvalidPortVeto','EditingClearedResult','CloseClearedDialog')){
            if($Operator.$name -isnot [bool] -or -not $Operator.$name){throw 'PORT_BROWSER_COMPLETION_INVALID'}
        }
        if($Records.Count -ne 5 -or $Plans.Count -ne 3){throw 'PORT_BROWSER_CASE_COUNTS'}
        $expected=@(0,1,1,1,0)
        for($index=0;$index -lt $Records.Count;$index++){
            $record=$Records[$index]
            Assert-LabOwnedHostProperties $record @('Status','PublicCalls','PinnedReads','StateEqual')
            if($record.Status -isnot [int] -or $record.Status -ne 200 -or
                $record.PublicCalls -isnot [int] -or $record.PublicCalls -ne $expected[$index] -or
                $record.PinnedReads -isnot [int] -or $record.PinnedReads -lt 0 -or $record.PinnedReads -gt 512 -or
                ($record.PublicCalls -eq 0 -and $record.PinnedReads -ne 0) -or
                ($record.PublicCalls -eq 1 -and $record.PinnedReads -eq 0) -or
                $record.StateEqual -isnot [bool] -or -not $record.StateEqual){throw 'PORT_BROWSER_CASE_COUNTS'}
        }
        foreach($plan in $Plans){$null=ConvertTo-LabContainerPortBrowserPlan $plan $Provider;if($plan.Status -cne 'PLAN_ONLY'){throw 'PORT_BROWSER_PLAN_BLOCKED'}}
        if($Plans[0].NoChange -or -not $Plans[1].NoChange -or $Plans[2].NoChange -or
            $Plans[0].ObservationKey -cne $Plans[2].ObservationKey -or $Plans[0].ObservationKey -ceq $Plans[1].ObservationKey){throw 'PORT_BROWSER_CONTENT_BINDING'}
    } $Records $Plans $Provider $Operator
}

function Invoke-PortPreviewBrowserAcceptance {
    param($Module,$Scope,[string]$RunId,[string]$Provider,[string]$RepositoryRoot,
        [string]$EvidenceRoot,[ValidateRange(1025,65535)][int]$ListenerPort)
    if($ListenerPort -eq 14336){throw 'PORT_BROWSER_PRODUCT_PORT'}
    $bindings=${function:Get-PortPreviewAcceptanceFileBinding}
    $validator=${function:Assert-PortPreviewBrowserObservation}
    $bodyReader=${function:Read-PortPreviewBrowserRequestBody}
    & $Module {
        param($Scope,$RunId,$Provider,$Repo,$Evidence,$Port,$Bindings,$Validator,$BodyReader)
        $null=Assert-LabOwnedHostPath $Evidence
        $policy=Get-LabOwnedHostRunPolicy -StateRoot $Scope.StateRoot -RunId $RunId
        $targets=@(Get-LabContainerPortConsoleTargets -DataRoot $Scope.DataRoot)
        if((Get-LabDataRootDefault) -cne $Scope.DataRoot -or -not $policy -or $policy.ParentOperationId -cne $Scope.ParentOperationId -or
            $targets.Count -ne 1 -or $targets[0].RunId -cne $RunId -or
            $targets[0].InstanceId -cne 'primary' -or $targets[0].Provider -cne $Provider -or
            $targets[0].StateRoot -cne $Scope.StateRoot){throw 'PORT_BROWSER_SCOPE'}
        $nativeBefore=Get-LabContainerReconcileContext -RunId $RunId -InstanceId primary -StateRoot $Scope.StateRoot
        $current=[int]$nativeBefore.CurrentPort
        if($current -lt 1024 -or $current -gt 65535){throw 'PORT_BROWSER_CURRENT_PORT'}
        $requested=if($current -eq 65535){65534}else{$current+1}
        $html=Get-Content -LiteralPath (Join-Path $Repo Ui/index.html) -Raw
        $button=[regex]::Matches($html,'<button id="port-preview-open"[^>]*>[^<]*</button>')
        $dialog=[regex]::Matches($html,'(?s)<dialog id="port-preview-dialog">.*?</dialog>')
        if($button.Count -ne 1 -or $dialog.Count -ne 1){throw 'PORT_BROWSER_MARKUP'}
        # Exact product markup/assets, isolated from unrelated page/API workflows.
        $page='<!doctype html><html lang="de"><meta charset="utf-8"><link rel="stylesheet" href="/app.css"><title>SQL-Portvorschau Abnahme</title><body>'+
            $button[0].Value+$dialog[0].Value+'<script src="/container-port-preview.js"></script></body></html>'
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo Tools/Start-SqlServerLabUi.ps1),[ref]$tokens,[ref]$errors)
        $routes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/container-port-preview'"},$true))
        if($errors.Count -or $routes.Count -ne 1){throw 'PORT_BROWSER_ROUTE'}
        $dispatch=[scriptblock]::Create('foreach($iteration in 1){'+$routes[0].Extent.Text+"`nthrow 'PORT_BROWSER_FALLTHROUGH'"+'}')
        $saved=@{}
        $names=@('Get-SqlServerLabReconcilePlan','Invoke-LabOwnedHostNativeProcess','Get-LabSecret','Invoke-SqlQuery','Test-LabEndpointBinding',
            'Repair-LabContainerReconcileJournal','New-LabContainerReconcileJournal','Invoke-LabContainerReconcileCommand','Update-SqlServerLabContainer','Invoke-SqlServerLabWorkflowAction','Invoke-LabActionWithResult')
        foreach($name in $names){$saved[$name]=(Get-Item ('Function:'+$name) -ErrorAction SilentlyContinue).ScriptBlock}
        $script:portBrowserPublic=$saved['Get-SqlServerLabReconcilePlan'];$script:portBrowserNative=$saved['Invoke-LabOwnedHostNativeProcess']
        $script:portBrowserRun=$RunId;$script:portBrowserState=$Scope.StateRoot
        $script:portBrowserCalls=0;$script:portBrowserReads=0;$script:portBrowserPlans=[Collections.Generic.List[object]]::new()
        $listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://127.0.0.1:$Port/")
        $records=[Collections.Generic.List[object]]::new();$completion=Join-Path $Evidence browser-completed.private.json
        function Write-UiResponse {
            param($Context,[string]$Body,[string]$ContentType,[int]$StatusCode=200)
            $bytes=[Text.Encoding]::UTF8.GetBytes($Body)
            $Context.Response.StatusCode=$StatusCode;$Context.Response.ContentType=$ContentType
            $Context.Response.ContentLength64=$bytes.Length
            $Context.Response.OutputStream.Write($bytes,0,$bytes.Length)
        }
        try {
            foreach($name in $names|Where-Object {$_ -cnotin @('Get-SqlServerLabReconcilePlan','Invoke-LabOwnedHostNativeProcess')}){
                Set-Item ('Function:script:'+$name) {throw 'PORT_BROWSER_FORBIDDEN_EFFECT'}
            }
            function script:Get-SqlServerLabReconcilePlan {
                param($RunId,$InstanceId,$StateRoot,[switch]$ContainerPortPreview,[int]$Port)
                if($RunId -cne $script:portBrowserRun -or $InstanceId -cne 'primary' -or
                    $StateRoot -cne $script:portBrowserState -or -not $ContainerPortPreview){throw 'PORT_BROWSER_PUBLIC_SCOPE'}
                $script:portBrowserCalls++
                $plan=& $script:portBrowserPublic @PSBoundParameters
                $script:portBrowserPlans.Add($plan);return $plan
            }
            function script:Invoke-LabOwnedHostNativeProcess {
                param($StartInfo,[int]$TimeoutSeconds,[int]$MaximumBytes)
                $script:portBrowserReads++
                & $script:portBrowserNative @PSBoundParameters
            }
            $listener.Start()
            $ready=[ordered]@{Contract='SqlServerLab.PortBrowserReady/1.0';Url="http://127.0.0.1:$Port/";CurrentPort=$current;RequestedPort=$requested;CompletionFile=$completion}
            $readyPath=Join-Path $Evidence browser-ready.private.json
            $null=Assert-LabOwnedHostPath $readyPath
            $stream=[IO.File]::Open($readyPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$bytes=[Text.Encoding]::UTF8.GetBytes(($ready|ConvertTo-Json -Compress));$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
            Write-Host ('PORT_BROWSER_READY: '+$readyPath)
            $deadline=[DateTime]::UtcNow.AddMinutes(12);$pending=$listener.GetContextAsync()
            while(-not (Test-Path -LiteralPath $completion -ErrorAction Stop)){
                if([DateTime]::UtcNow -ge $deadline){throw 'PORT_BROWSER_DEADLINE'}
                if(-not $pending.Wait(100)){continue}
                $context=$pending.GetAwaiter().GetResult()
                try {
                    $path=$context.Request.Url.AbsolutePath
                    if($path -ceq '/api/container-port-preview'){
                        $before=& $Bindings $Scope.DataRoot;$calls=$script:portBrowserCalls;$reads=$script:portBrowserReads
                        $remaining=[Math]::Min(10000,[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds)
                        if($remaining -le 0){throw 'PORT_BROWSER_DEADLINE'}
                        $bytes=& $BodyReader $context.Request $remaining
                        $bodyStream=[IO.MemoryStream]::new($bytes,$false)
                        $originalContext=$context
                        # Retain exact native origin/address/header metadata. Only
                        # the fully bounded body stream is adapted for dispatch.
                        $request=$context.Request
                        $context=[pscustomobject]@{Response=$context.Response;Request=[pscustomobject]@{
                            HttpMethod=$request.HttpMethod;ContentType=$request.ContentType;LocalEndPoint=$request.LocalEndPoint;
                            RemoteEndPoint=$request.RemoteEndPoint;Url=$request.Url;Headers=$request.Headers;InputStream=$bodyStream}}
                        try{& $dispatch}finally{$bodyStream.Dispose();$context=$originalContext}
                        $after=& $Bindings $Scope.DataRoot
                        if(($before|ConvertTo-Json -Depth 5 -Compress) -cne ($after|ConvertTo-Json -Depth 5 -Compress)){throw 'PORT_BROWSER_STATE_WRITE'}
                        $delta=$script:portBrowserCalls-$calls;$native=$script:portBrowserReads-$reads
                        if($delta -gt 1 -or ($delta -eq 0 -and $native -ne 0)){throw 'PORT_BROWSER_HTTP_EFFECT'}
                        $records.Add([pscustomobject]@{Status=$context.Response.StatusCode;PublicCalls=$delta;PinnedReads=$native;StateEqual=$true})
                        if($records.Count -gt 16){throw 'PORT_BROWSER_REQUEST_LIMIT'}
                    } elseif($context.Request.HttpMethod -ceq 'GET' -and -not $context.Request.Url.Query -and $path -cin @('/','/app.css','/container-port-preview.js')){
                        $body=if($path -ceq '/'){$page}else{Get-Content -LiteralPath (Join-Path $Repo ('Ui'+$path)) -Raw}
                        $type=if($path -ceq '/app.css'){'text/css'}elseif($path -ceq '/container-port-preview.js'){'application/javascript'}else{'text/html'}
                        Write-UiResponse $context $body ($type+'; charset=utf-8')
                    } else {Write-UiResponse $context '{"Code":"NOT_FOUND"}' 'application/json' 404}
                } finally {$context.Response.Close()}
                $pending=$listener.GetContextAsync()
            }
            $null=Assert-LabOwnedHostPath $completion
            if((Get-Item -LiteralPath $completion).Length -gt 2048){throw 'PORT_BROWSER_COMPLETION_INVALID'}
            $operator=Get-Content -LiteralPath $completion -Raw|ConvertFrom-Json -Depth 3
            # Operator flags are UI observations, never runtime/cleanup authority.
            & $Validator $ExecutionContext.SessionState.Module @($records) @($script:portBrowserPlans) $Provider $operator
            $nativeAfter=Get-LabContainerReconcileContext -RunId $RunId -InstanceId primary -StateRoot $Scope.StateRoot
            $sourceBefore=@($nativeBefore.ContainerId,$nativeBefore.Inspect.Image,$nativeBefore.Inspect.Config,$nativeBefore.Inspect.HostConfig,$nativeBefore.Inspect.Mounts)|ConvertTo-Json -Depth 50 -Compress
            $sourceAfter=@($nativeAfter.ContainerId,$nativeAfter.Inspect.Image,$nativeAfter.Inspect.Config,$nativeAfter.Inspect.HostConfig,$nativeAfter.Inspect.Mounts)|ConvertTo-Json -Depth 50 -Compress
            if($sourceBefore -cne $sourceAfter){throw 'PORT_BROWSER_NATIVE_SOURCE_DRIFT'}
            [pscustomobject]@{Contract='SqlServerLab.PortBrowserNetworkAcceptance/1.0';Status='PASS';HttpRequests=@($records);
                PublicPreviewCalls=3;RenderedDialog='OPERATOR_OBSERVED';InvalidPortVeto='OPERATOR_OBSERVED';EditingClearedResult='OPERATOR_OBSERVED';CloseClearedDialog='OPERATOR_OBSERVED';
                NativeSourceUnchanged=$true;Endpoint='NOT_CHECKED';SQL='NOT_CHECKED';Apply='NOT_IMPLEMENTED';WholeUiServer='NOT_EXECUTED'}
        } finally {
            try{
                $path=Assert-LabOwnedHostPath (Join-Path $Evidence browser-http-observations.private.json)
                $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try{$bytes=[Text.Encoding]::UTF8.GetBytes((@($records)|ConvertTo-Json -Depth 4 -Compress));$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
            } finally {
                try{$listener.Close()}finally{
                    foreach($name in $saved.Keys){if($saved[$name]){Set-Item ('Function:script:'+$name) $saved[$name]}else{Remove-Item ('Function:script:'+$name) -ErrorAction SilentlyContinue}}
                }
            }
        }
    } $Scope $RunId $Provider $RepositoryRoot $EvidenceRoot $ListenerPort $bindings $validator $bodyReader
}

#Requires -Version 7.2
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
$root=Join-Path $repo ('.artifacts/test-runs/run-artifact-http-'+[guid]::NewGuid().ToString('N'))
$script:checks=0
function Check([bool]$Value,[string]$Name) { if(-not $Value){throw "RUN_ARTIFACT_HTTP_CHECK_FAILED: $Name"};$script:checks++;Write-Host "PASS: $Name" }
try {
    & $module {
        param($Root)
        $script:httpRoot=$Root;$script:httpState=Join-Path $Root 'State';$script:httpRun='11111111-2222-4333-8444-555555555555'
        $script:httpKey='a'*64;$script:httpMode='READY';$script:httpPlans=0;$script:httpApplies=0
        $path=Join-Path $script:httpState ('runs/'+$script:httpRun+'/run-state.json')
        $null=New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force
        [IO.File]::WriteAllText($path,(@{runId=$script:httpRun;state='REMOVED';metadata=@{name='PRIVATE_NAME_CANARY'}}|ConvertTo-Json))
        function script:Get-LabDataRootDefault { if($script:httpMode -ceq 'ROOT_CHANGED'){Join-Path $script:httpRoot 'changed'}else{$script:httpRoot} }
        function script:Get-LabStateRoot { $script:httpState }
        function script:Get-LabStorageConfiguration { param($DataRoot)
            [pscustomobject]@{LabDataLocations=@([pscustomobject]@{LabDataRoot=if($script:httpMode -ceq 'UNREGISTERED'){'other'}else{$script:httpRoot}})}
        }
        function script:Get-LabRunArtifactRemovalContext { param($RunId,$StateRoot,$DataRoot)
            $script:httpPlans++
            if($RunId -cne $script:httpRun -or $StateRoot -cne $script:httpState -or $DataRoot -cne $script:httpRoot){throw 'WRONG_PUBLIC_BINDING'}
            if($script:httpMode -ceq 'BLOCKED'){throw 'RUN_ARTIFACT_HYPERV_ABSENCE_UNVERIFIABLE'}
            if($script:httpMode -ceq 'RAW_ERROR'){throw 'PRIVATE_ERROR_CANARY'}
            [pscustomobject]@{Status=if($script:httpMode -ceq 'RECOVERY'){'RECOVERY_REQUIRED'}elseif($script:httpMode -ceq 'REMOVED'){'REMOVED'}else{'READY'};CanApply=if($script:httpMode -ceq 'STRING_BOOL'){'true'}else{$script:httpMode -cne 'REMOVED'};PlanKey=$script:httpKey;FileCount=3}
        }
        function script:Invoke-LabRunArtifactRemoval { param($RunId,$StateRoot,$DataRoot,$ExpectedPlanKey)
            $script:httpApplies++
            if($RunId -cne $script:httpRun -or $StateRoot -cne $script:httpState -or $DataRoot -cne $script:httpRoot -or $ExpectedPlanKey -cne $script:httpKey){throw 'WRONG_PUBLIC_BINDING'}
            if($script:httpMode -ceq 'DRIFT'){throw 'RUN_ARTIFACT_PREVIEW_STALE'}
            [pscustomobject]@{RunId=if($script:httpMode -ceq 'FOREIGN_RESULT'){'PRIVATE_RESULT_CANARY'}else{$RunId};Status='REMOVED';Changed=$true}
        }
    } $root
    $statePath=Join-Path $root 'State/runs/11111111-2222-4333-8444-555555555555/run-state.json'
    $before=(Get-FileHash -LiteralPath $statePath).Hash
    $script:held=$module
    function Get-Module {param($Name);if($Name -cne 'SqlServerLab'){throw 'WRONG_MODULE'};$script:held}
    function Write-UiResponse {param($Context,$Body,$ContentType,$StatusCode=200);$script:response=[pscustomobject]@{Status=$StatusCode;Body=$Body}}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$errors)
    $route=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq "`$path -eq '/api/run-artifact-removal'"},$true))
    Check ($errors.Count -eq 0 -and $route.Count -eq 1) 'actual dedicated server route exists and parses once'
    $dispatch=[scriptblock]::Create('foreach($iteration in 1){'+$route[0].Extent.Text+"`nthrow 'FALLTHROUGH'"+'}')
    $script:runArtifactRemovalPreviews=@{}
    function Send([string]$Body,$Override=@{},[byte[]]$Bytes=$null) {
        if($null -eq $Bytes){$Bytes=[Text.Encoding]::UTF8.GetBytes($Body)}
        $stream=[IO.MemoryStream]::new($Bytes,$false);$Port=19499;$path='/api/run-artifact-removal'
        $request=[pscustomobject]@{HttpMethod='POST';ContentType='application/json; charset=utf-8';Headers=@{Origin='http://127.0.0.1:19499'};Url=[uri]'http://127.0.0.1:19499/api/run-artifact-removal';LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19499);RemoteEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19000);InputStream=$stream}
        foreach($key in $Override.Keys){$request.$key=$Override[$key]}
        try{$context=[pscustomobject]@{Request=$request};& $dispatch;$script:response}finally{$stream.Dispose()}
    }
    function Reject([string]$Body,[string]$Name,$Override=@{},[byte[]]$Bytes=$null) {
        $beforeApply=& $module {$script:httpApplies};$beforePlan=& $module {$script:httpPlans}
        $r=Send $Body $Override $Bytes
        Check ($r.Status -eq 400 -and $r.Body -ceq '{"Code":"RUN_ARTIFACT_HTTP_UNCONFIRMED"}') $Name
        Check ((& $module {$script:httpApplies}) -eq $beforeApply -and (& $module {$script:httpPlans}) -eq $beforePlan) "$Name has no public invocation"
    }
    $run='11111111-2222-4333-8444-555555555555'
    $previewBody=@{Action='Preview';RunId=$run}|ConvertTo-Json -Compress
    $read=Send '{"Action":"Read"}'
    $view=$read.Body|ConvertFrom-Json
    Check ($read.Status -eq 200 -and $view.Status -ceq 'METADATA_ONLY' -and $view.Targets.Count -eq 1 -and $view.Targets[0].RunId -ceq $run -and -not $view.CanApply) 'Read returns only logical candidate metadata'
    Check ((& $module {$script:httpPlans}) -eq 0 -and $read.Body -notmatch 'PRIVATE|StateRoot|DataRoot|PlanKey') 'opening metadata performs no public preview and projects no private values'
    foreach($body in @('{"Action":"Read","StateRoot":"PRIVATE"}','{"Action":"Read","action":"Read"}','{"Action":"Preview","RunId":["'+$run+'"]}','{"Action":"Preview","RunId":"ffffffff-ffff-4fff-8fff-ffffffffffff"}','{"Action":"Apply"}','{"Action":"read"}','[]','null')){Reject $body 'closed payload and target selection'}
    foreach($override in @(@{HttpMethod='GET'},@{ContentType='text/plain'},@{Headers=@{Origin='http://evil.invalid'}},@{Url=[uri]'http://127.0.0.1:19499/api/run-artifact-removal?x=1'},@{LocalEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19498)},@{RemoteEndPoint=[Net.IPEndPoint]::new([Net.IPAddress]::Parse('192.0.2.1'),19000)})){Reject '{"Action":"Read"}' 'loopback origin/method/media/query boundary' $override}
    Reject '' 'bounded request body' @{} ([byte[]]::new(2049))
    Reject '' 'strict UTF8' @{} ([byte[]]@(0xc3,0x28))
    & $module {$script:httpMode='UNREGISTERED'};Reject '{"Action":"Read"}' 'unregistered server StateRoot veto';& $module {$script:httpMode='READY'}
    foreach($mode in @('BLOCKED','RAW_ERROR','REMOVED','STRING_BOOL')) {
        & $module {param($Mode)$script:httpMode=$Mode} $mode
        $r=Send $previewBody;$v=$r.Body|ConvertFrom-Json
        Check (($r.Status -eq 400 -or ($v.CanApply -eq $false -and $null -eq $v.PreviewToken)) -and $r.Body -notmatch 'PRIVATE|PlanKey|StateRoot') "$mode cannot mint Apply authority or leak evidence"
    }
    foreach($mode in @('READY','RECOVERY')) {
        & $module {param($Mode)$script:httpMode=$Mode} $mode
        $r=Send $previewBody;$v=$r.Body|ConvertFrom-Json
        Check ($r.Status -eq 200 -and $v.CanApply -eq $true -and $v.FileCount -eq 3 -and $v.PreviewToken -cmatch '^[a-f0-9]{32}$' -and $r.Body -notmatch 'PRIVATE|PlanKey|StateRoot|DataRoot') "$mode preview projects a server-owned expiring token"
        $applyBody=@{Action='Apply';RunId=$run;PreviewToken=$v.PreviewToken;Confirmed=$true}|ConvertTo-Json -Compress
        Reject ($applyBody.Replace('true','false')) 'explicit true confirmation required'
        Reject ($applyBody.Replace('true','"true"')) 'confirmation cannot be a string'
        Reject ($applyBody.Replace($run,'ffffffff-ffff-4fff-8fff-ffffffffffff')) 'token bound to exactly selected RunId'
        $beforeApply=& $module {$script:httpApplies}
        $result=Send $applyBody;$rv=$result.Body|ConvertFrom-Json
        Check ($result.Status -eq 200 -and $rv.RunId -ceq $run -and $rv.Status -ceq 'REMOVED' -and $rv.Changed -eq $true -and (& $module {$script:httpApplies}) -eq ($beforeApply+1)) "$mode calls bound public Apply once"
        Reject $applyBody 'single-use token prevents duplicate Apply'
    }
    foreach($mode in @('EXPIRED','ROOT_CHANGED','DRIFT','FOREIGN_RESULT')) {
        & $module {$script:httpMode='READY'};$r=Send $previewBody;$v=$r.Body|ConvertFrom-Json
        $applyBody=@{Action='Apply';RunId=$run;PreviewToken=$v.PreviewToken;Confirmed=$true}|ConvertTo-Json -Compress
        if($mode -ceq 'EXPIRED'){$script:runArtifactRemovalPreviews[$v.PreviewToken].ExpiresAtUtc=[datetime]::UtcNow.AddSeconds(-1)}else{& $module {param($Mode)$script:httpMode=$Mode} $mode}
        $r=Send $applyBody
        Check ($r.Status -eq 400 -and $r.Body -notmatch 'PRIVATE|PlanKey|StateRoot') "$mode is unconfirmed and sanitized"
        & $module {$script:httpMode='READY'};Reject $applyBody "$mode token cannot be replayed after failure"
    }
    $r=Send $previewBody;$v=$r.Body|ConvertFrom-Json;$null=Send '{"Action":"Read"}'
    Reject (@{Action='Apply';RunId=$run;PreviewToken=$v.PreviewToken;Confirmed=$true}|ConvertTo-Json -Compress) 'explicit metadata refresh invalidates prior previews'
    Check ((Get-FileHash -LiteralPath $statePath).Hash -ceq $before) 'synthetic HTTP leaves preserve real metadata bytes'
    Write-Host "RUN ARTIFACT HTTP CHECKS: $script:checks PASS; actual route/module/public functions, synthetic private Core leaves"
} finally {
    $boundary=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/test-runs')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if([IO.Path]::GetFullPath($root).StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $root)){Remove-Item -LiteralPath $root -Recurse -Force}
    Remove-Module $module.Name -Force
}

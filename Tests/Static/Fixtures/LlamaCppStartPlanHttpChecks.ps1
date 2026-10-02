# Actual dedicated HTTP -> public -> files-only reader composition, with synthetic files.
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-start-http-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Check([string]$Name,[bool]$Value){if(-not$Value){throw ('FIXTURE_FAILED: '+$Name)};$script:checks++;Write-Host "PASS $Name"}
$module=New-Module {
    param($root)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Private/AiExternalModelAcceleration.ps1'),[ref]$tokens,[ref]$errors)
    foreach($name in @('Get-LabLlamaCppRuntimeCandidate','Find-LabLlamaCppRuntime')){
        $fn=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$name},$true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    . (Join-Path $root 'Private/LlamaCppStartPlan.ps1')
    . (Join-Path $root 'Public/Get-SqlServerLabLlamaCppStartPlan.ps1')
    . (Join-Path $root 'Private/LlamaCppStartPlanConsole.ps1')
    . (Join-Path $root 'Private/LlamaCppStartPlanHttp.ps1')
    $script:publicBody=(Get-Command Get-SqlServerLabLlamaCppStartPlan).ScriptBlock
    $script:Calls=0;$script:Forbidden=0;$script:ResultMode='NORMAL'
    function Get-SqlServerLabLlamaCppStartPlan {
        param($RuntimeDirectory,$Backend,$Accelerator,$ModelPath,[int]$Dimension,$Pooling,[int]$Port,[int]$StartTimeoutSeconds,[int]$LeaseSeconds,[int]$ContextSize)
        $script:Calls++;$actual=@{};foreach($key in $PSBoundParameters.Keys){$actual[$key]=$PSBoundParameters[$key]}
        $script:LastArguments=$actual
        if($script:ResultMode-ceq'RAW'){throw 'PRIVATE_PATH_CALLER_CANARY'}
        $plan=& $script:publicBody @actual
        switch($script:ResultMode){'EXEC'{$plan.ExecutionSupported=$true};'EXTRA'{$plan|Add-Member NoteProperty PrivatePath 'PRIVATE_PATH_CALLER_CANARY'};'STRINGBOOL'{$plan.MutationAllowed='false'}}
        $plan
    }
    foreach($name in @('Start-SqlServerLabLlamaCppRuntime','Stop-SqlServerLabLlamaCppRuntime','Start-LabLlamaCppOwnedRuntime','Resolve-LabLlamaCppComputeSelection','Get-LabAiComputeInventory','Get-LabSecret','Get-LabDataRootDefault','Get-LabStateRoot','Invoke-SqlServerLabWorkflowAction','Start-ThreadJob','Invoke-LabAiExternalModelHttpTransport','Invoke-LabAiBenchmarkProcess','Get-LabAiExternalModelFileSha256')){
        Set-Item -Path "Function:script:$name" -Value {$script:Forbidden++;throw 'FORBIDDEN_NATIVE_BOUNDARY'}
    }
} -ArgumentList $repo
function Request($Payload,[string]$Method='POST',[string]$Origin='http://localhost:8080',[string]$Type='application/json'){
    $bytes=if($Payload-is[byte[]]){$Payload}elseif($Payload-is[string]){[Text.Encoding]::UTF8.GetBytes($Payload)}else{[Text.Encoding]::UTF8.GetBytes(($Payload|ConvertTo-Json -Depth 8 -Compress))}
    $stream=[IO.MemoryStream]::new([byte[]]$bytes)
    $req=[pscustomobject]@{HttpMethod=$Method;ContentType=$Type;Headers=@{Origin=$Origin};Url=[uri]'http://localhost:8080/api/llama-start-plan';InputStream=$stream}
    try{& $module {param($r)Invoke-LabLlamaCppStartPlanHttpRequest -Request $r} $req}finally{$stream.Dispose()}
}
function Reject($Payload,[string]$Name,[string]$Code='LLAMA_START_PLAN_HTTP_INVALID',[string]$Method='POST',[string]$Origin='http://localhost:8080',[string]$Type='application/json',[bool]$NoDispatch=$true){
    $prior=&$module {$script:Calls};$codeSeen=$null;try{$null=Request $Payload $Method $Origin $Type}catch{$codeSeen=$_.Exception.Message}
    Check $Name ($codeSeen-ceq$Code-and(-not$NoDispatch-or(&$module {$script:Calls})-eq$prior))
}
try{
    $null=New-Item -ItemType Directory -Path $fixture
    $runtime=Join-Path $fixture 'runtime';$null=New-Item -ItemType Directory -Path $runtime
    [IO.File]::WriteAllText((Join-Path $runtime 'llama-server.exe'),'synthetic-not-executable')
    [IO.File]::WriteAllText((Join-Path $runtime 'ggml-cuda.dll'),'synthetic')
    $model=Join-Path $fixture 'PRIVATE_PATH_CALLER_CANARY.gguf';[IO.File]::WriteAllBytes($model,[Text.Encoding]::ASCII.GetBytes('GGUFsynthetic'))
    $inputs=@{RuntimeDirectory=$runtime;ModelPath=$model;Backend='LlamaCppCuda';Accelerator='CPU';Dimension=768;Pooling='mean';Port=19435;StartTimeoutSeconds=120;LeaseSeconds=900;ContextSize=512}
    $request=@{Action='Preview';Parameters=$inputs};$beforeModel=(Get-FileHash -LiteralPath $model).Hash
    $plan=Request $request
    Check 'Actual HTTP -> public -> existing files-only readers with exact ten inputs' ($plan.Status-ceq'BLOCKED'-and$plan.Mode-ceq'PLAN_ONLY'-and(&$module {$script:LastArguments.Count})-eq10)
    Check 'Sanitized nonexecutable DTO has no caller/path/secret text' ($plan.Actions.Count-eq0-and-not$plan.ExecutionSupported-and-not$plan.MutationAllowed-and($plan|ConvertTo-Json -Depth 6)-notmatch'PRIVATE_PATH_CALLER_CANARY|RuntimeDirectory|ModelPath|PlanKey'-and-not($plan|ConvertTo-Json -Depth 6).Contains($fixture))
    Check 'Files remain unchanged after four-byte observations' ((Get-FileHash -LiteralPath $model).Hash-ceq$beforeModel)
    foreach($method in @('GET','PUT')){Reject $request "Wrong method $method" -Method $method}
    Reject $request 'Foreign Origin denied before public' -Origin 'http://foreign.invalid'
    Reject $request 'Non-JSON denied' -Type 'text/plain'
    Reject $request 'Non-UTF8 content type denied' -Type 'application/json; charset=utf-16'
    Check 'Explicit UTF8 JSON supported' ((Request $request -Type 'application/json; charset=utf-8').Status-ceq'BLOCKED')
    $json=$request|ConvertTo-Json -Depth 5 -Compress
    Reject ($json.Replace('"Action":"Preview"','"Action":"Preview","action":"Preview"')) 'Duplicate case alias rejected'
    Reject ($json.Replace('"Action":"Preview"','"Action":"Preview","Action":"Preview"')) 'Duplicate exact key rejected'
    foreach($extra in @('StateRoot','ApiKey','CertificatePath','SelectedCompute')){
        $bad=@{}+$inputs;$bad[$extra]='PRIVATE_PATH_CALLER_CANARY';Reject @{Action='Preview';Parameters=$bad} "Unknown parameter $extra denied"
    }
    $bad=@{}+$inputs;$bad.Remove('Port');Reject @{Action='Preview';Parameters=$bad} 'Missing input denied'
    $bad=@{}+$inputs;$bad.Port='19435';Reject @{Action='Preview';Parameters=$bad} 'Numeric string coercion denied'
    $bad=@{}+$inputs;$bad.Dimension=$null;Reject @{Action='Preview';Parameters=$bad} 'Null scalar denied'
    $bad=@{}+$inputs;$bad.Backend='llamacppcuda';Reject @{Action='Preview';Parameters=$bad} 'Case-changed enum denied'
    foreach($key in @('Dimension','Port','StartTimeoutSeconds','LeaseSeconds','ContextSize')){$bad=@{}+$inputs;$bad[$key]=0;Reject @{Action='Preview';Parameters=$bad} "Range $key denied"}
    Reject ($json.Replace('"Port":19435','"Port":19435.0')) 'Fractional JSON number denied'
    Reject ($json.Replace('"Port":19435','"Port":1e4')) 'Exponent coercion denied'
    $bad=@{}+$inputs;$bad.Accelerator='NPU';Reject @{Action='Preview';Parameters=$bad} 'CUDA NPU pre-dispatch veto' 'LLAMA_START_PLAN_ACCELERATOR_UNSUPPORTED'
    $bad=@{}+$inputs;$bad.LeaseSeconds=120;Reject @{Action='Preview';Parameters=$bad} 'Lease relation pre-dispatch veto' 'LLAMA_START_PLAN_LEASE_INVALID'
    Reject (' '*16385) 'Character count bound'
    Reject ([byte[]]::new(65537)) 'Byte count bound'
    Reject ([byte[]]@(195,40)) 'Malformed UTF8 fails before JSON'
    Reject ('{"Action":"Preview","Parameters":{"Extra":[[[[1]]]]}}') 'Depth bound'
    Reject ('{"Action":"Preview","Parameters":{"Extra":['+(('1,'*33)+'1')+']}}') 'Node count bound'
    $bad=@{}+$inputs;$bad.RuntimeDirectory=('界'*4096);$bad.ModelPath=('界'*4096)
    $priorCalls=&$module {$script:Calls}
    Reject @{Action='Preview';Parameters=$bad} 'Multibyte maximum strings reach actual public, not body rejection' 'LLAMA_START_PLAN_PATH_INVALID' -NoDispatch $false
    Check 'Unicode body reaches public exactly once' ((&$module {$script:Calls})-eq($priorCalls+1))
    foreach($mode in @('EXEC','EXTRA','STRINGBOOL')){&$module {param($m)$script:ResultMode=$m} $mode;Reject $request "Unsafe DTO $mode rejected" 'LLAMA_START_PLAN_HTTP_RESULT_INVALID' -NoDispatch $false}
    &$module {$script:ResultMode='RAW'};Reject $request 'Raw exception mapped to fixed code' -NoDispatch $false
    &$module {$script:ResultMode='NORMAL'}
    [IO.File]::WriteAllBytes($model,[Text.Encoding]::ASCII.GetBytes('NOPEsynthetic'));Reject $request 'Actual GGUF reader veto' 'LLAMA_START_PLAN_GGUF_REQUIRED' -NoDispatch $false
    [IO.File]::WriteAllBytes($model,[Text.Encoding]::ASCII.GetBytes('GGUFsynthetic'))
    &$module {
        $script:observationBody=(Get-Command Get-LabLlamaStartPlanObservation).ScriptBlock;$script:Observations=0
        function script:Get-LabLlamaStartPlanObservation {param($RuntimeDirectory,$ModelPath);$script:Observations++;if($script:Observations-eq2){[IO.File]::AppendAllText($ModelPath,'visible-drift')}; &$script:observationBody -RuntimeDirectory $RuntimeDirectory -ModelPath $ModelPath}
    }
    Reject $request 'Actual second observation detects visible drift' 'LLAMA_START_PLAN_INPUT_DRIFT' -NoDispatch $false
    &$module {Set-Item Function:script:Get-LabLlamaStartPlanObservation $script:observationBody}
    $link=Join-Path $fixture 'linked-runtime';$kind=if($IsWindows){'Junction'}else{'SymbolicLink'}
    $null=New-Item -ItemType $kind -Path $link -Target $runtime
    try{$bad=@{}+$inputs;$bad.RuntimeDirectory=$link;Reject @{Action='Preview';Parameters=$bad} 'Actual reparse veto' 'LLAMA_START_PLAN_REPARSE_REJECTED' -NoDispatch $false}finally{Remove-Item -LiteralPath $link -Force}
    # Exact production route, substituting only module and response transport leaves.
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$errors)
    $route=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and$n.Clauses[0].Item1.Extent.Text-ceq"`$path -eq '/api/llama-start-plan'"},$true))
    if($route.Count-ne1){throw 'FIXTURE_ROUTE_BOUNDARY_INVALID'}
    function Get-Module {param($Name);if($Name-cne'SqlServerLab'){throw 'FORBIDDEN_MODULE'};return $module}
    function Write-UiResponse {param($Context,$Body,$ContentType,$StatusCode=200);$script:response=[pscustomobject]@{Body=$Body;StatusCode=$StatusCode}}
    $routeBody=[scriptblock]::Create('foreach($routeIteration in @(1)){'+$route[0].Extent.Text+'}')
    $routeStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($json));$context=[pscustomobject]@{Request=[pscustomobject]@{HttpMethod='POST';ContentType='application/json';Headers=@{};Url=[uri]'http://localhost:8080/api/llama-start-plan';InputStream=$routeStream}};$path='/api/llama-start-plan'
    try{. $routeBody;Check 'Actual extracted route reaches pure HTTP/Core and sanitized response' ($response.StatusCode-eq200-and($response.Body|ConvertFrom-Json).Mode-ceq'PLAN_ONLY')}finally{$routeStream.Dispose()}
    $routeStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('{"PrivatePath":"PRIVATE_PATH_CALLER_CANARY"}'));$context.Request.InputStream=$routeStream
    try{. $routeBody;Check 'Actual route error projection fixed without private text' ($response.StatusCode-eq400-and($response.Body|ConvertFrom-Json).Code-ceq'LLAMA_START_PLAN_HTTP_INVALID'-and$response.Body-notmatch'PRIVATE_PATH_CALLER_CANARY')}finally{$routeStream.Dispose()}
    Check 'Native/runtime/jobs/secrets/default veto boundaries never reached' ((&$module {$script:Forbidden})-eq0)
    Write-Host "LLAMA_START_PLAN_HTTP_CHECKS: $checks PASS; 0 FAIL"
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not$resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($resolved)-notlike'sql-lab-start-http-*'){throw 'FIXTURE_CLEANUP_SCOPE_INVALID'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force};Write-Host 'OWN_FIXTURE_CLEANUP_SUCCEEDED'
}

#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-session-check-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$errors=$null;$tokens=$null
. (Join-Path $repo 'Tools/WorkflowUiJsonBody.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Tools/Start-SqlServerLabUi.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'UI_SYNTAX_INVALID'}
foreach($name in @('Import-UiSqlServerLabModule','Invoke-UiLlamaSessionRequest')) {
    $fn=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
try {
    & $module {
        param($Root,$Repo)
        $script:checks=0;$script:stops=0
        function Assert-Session($Ok,$Name){if(-not $Ok){throw "ASSERT: $Name"};$script:checks++}
        function Reject([scriptblock]$Body,[string]$Code){try{& $Body|Out-Null;return $false}catch{return $_.Exception.Message -like ('*'+$Code+'*')}}
        function Get-LabDataRootDefault {$Root}
        $script:currentStateRoot=$Root
        function Get-LabStateRoot {$script:currentStateRoot}
        function Get-LabTestEnvironmentExportDirectory {param($OutputDirectory)$Root}
        function Stop-LabLlamaCppOwnedRuntime {param($OperationId)$script:stops++;$script:LlamaCppOwnedSessions.Remove($OperationId);[pscustomobject]@{Status='CLEANUP_SUCCEEDED';OperationId=$OperationId}}
        function Start-LockProbe([string]$Mode) {
            $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            foreach($arg in @('-NoProfile','-NonInteractive','-File',(Join-Path $Repo 'Tests/Static/Fixtures/LlamaCppSessionLockChild.ps1'),'-Repository',$Repo,'-Root',(Join-Path $Root '.'),'-Mode',$Mode)){$start.ArgumentList.Add($arg)}
            [Diagnostics.Process]::Start($start)
        }
        function Complete-LockProbe($Process,[string]$Expected) {
            try {
                if(-not $Process.WaitForExit(40000)){throw 'LOCK_PROBE_TIMEOUT'}
                $out=$Process.StandardOutput.ReadToEnd();$err=$Process.StandardError.ReadToEnd()
                if($Process.ExitCode -ne 0 -or $out -notmatch $Expected){throw ('LOCK_PROBE_FAILED: '+$err)}
            } finally {if(-not $Process.HasExited){$Process.Kill();if(-not $Process.WaitForExit(5000)){throw 'LOCK_PROBE_CLEANUP_FAILED'}};$Process.Dispose()}
        }
        $script:LlamaCppOwnedSessions=@{};$script:LlamaCppStopPlans=@{}
        Assert-Session ((Get-LabLlamaCppSessionView).Items.Count -eq 0) 'empty scope'
        $id=[guid]::NewGuid().ToString('D');$neighbor=[guid]::NewGuid().ToString('D')
        $session=@{Worker=[pscustomobject]@{HasExited=$false};Port=19435}
        $script:LlamaCppOwnedSessions[$id]=$session;$script:LlamaCppOwnedSessions[$neighbor]=@{Worker=[pscustomobject]@{HasExited=$false};Port=19436}
        $plan=(Invoke-SqlServerLabWorkflowAction -Action PlanLlamaSessionStop -LlamaSessionOperationId $id).Result
        Assert-Session ($plan.ConsumerCoverage -ceq 'UNKNOWN' -and $plan.KnownConsumerCount -eq 0 -and $plan.Rights -ceq 'OWNED_WORKER_CONTROL') 'unknown consumer coverage and owned control'
        Assert-Session ((Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId).Status -ceq 'CANCELLED' -and $script:stops -eq 0) 'cancel without writes'
        $null=Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed -WhatIf
        Assert-Session ($script:stops -eq 0) 'WhatIf does not stop'
        $script:LlamaCppOwnedSessions[$id]=@{Worker=$session.Worker;Port=19435}
        Assert-Session (Reject {Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed} 'LLAMA_SESSION_PREVIEW_STALE') 'replaced session with same identity blocked'
        $script:LlamaCppOwnedSessions[$id]=$session
        $session.Port=19438
        Assert-Session (Reject {Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed} 'LLAMA_SESSION_PREVIEW_STALE') 'changed port blocked'
        $session.Port=19435
        $heldWorker=$session.Worker;$session.Worker=[pscustomobject]@{HasExited=$false}
        Assert-Session (Reject {Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed} 'LLAMA_SESSION_PREVIEW_STALE') 'changed worker object blocked'
        $session.Worker=$heldWorker
        $alternate=Join-Path $Root 'alternate-state';$null=New-Item -ItemType Directory -Path $alternate
        $script:currentStateRoot=$alternate
        Assert-Session (Reject {Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed} 'LLAMA_SESSION_PREVIEW_STALE') 'changed root authority cannot bypass the lock captured by the preview'
        $script:currentStateRoot=$Root
        $script:LlamaCppStopPlans[$plan.PlanId].Expires=[datetime]::UtcNow.AddSeconds(-1)
        Assert-Session (Reject {Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed} 'LLAMA_SESSION_PREVIEW_EXPIRED') 'expired preview blocked'
        $plan=New-LabLlamaCppSessionStopPlan $id
        $path=Join-Path $Root 'TestUmgebung.registry.json'
        $null=New-Item -ItemType Directory -Path $path
        Assert-Session (Reject {New-LabLlamaCppSessionStopPlan $id} 'LLAMA_SESSION_PROTECTION_INVALID') 'directory protection authority blocks preview'
        Assert-Session (Reject {Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed} 'LLAMA_SESSION_PROTECTION_INVALID') 'directory protection authority blocks apply'
        Remove-Item -LiteralPath $path
        [IO.File]::WriteAllText($path,'{broken')
        Assert-Session (Reject {Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed} 'JSON') 'corrupt protection authority blocks'
        Remove-Item -LiteralPath $path
        $target=Join-Path $Root 'registry-target';$null=New-Item -ItemType Directory -Path $target
        if($IsWindows){$null=New-Item -ItemType Junction -Path $path -Target $target}
        else{$null=[IO.Directory]::CreateSymbolicLink($path,$target)}
        try {
            Assert-Session (Reject {New-LabLlamaCppSessionStopPlan $id} 'REPARSE') 'reparse protection authority blocks preview'
            Assert-Session (Reject {Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed} 'REPARSE') 'reparse protection authority blocks apply'
        } finally {Remove-Item -LiteralPath $path -Force}
        [IO.File]::WriteAllText($path,'{"contractVersion":"SqlServerLab.TestEnvironmentRegistry/1.0","environments":[{"runId":null}]}')
        Assert-Session ((New-LabLlamaCppSessionStopPlan $id).ConsumerCoverage -ceq 'UNKNOWN') 'unprovisioned null runId is a normal registry entry'
        $readLock=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {Assert-Session (Reject {New-LabLlamaCppSessionStopPlan $id} '') 'unreadable configured protection authority blocks'} finally {$readLock.Dispose()}
        Remove-Item -LiteralPath $path
        $run=[guid]::NewGuid().ToString('D')
        $gateway=Join-Path $Root 'shared-ai-gateways/test';$null=New-Item -ItemType Directory -Path $gateway
        $consumer=[pscustomobject]@{RunId=$run;InstanceId='primary';DatabaseId=[guid]::NewGuid().ToString('D');ExternalModelName='Synthetic';ApiKeyReference='SQL_SERVER_LAB_SECRET_TEST'}
        $shared=New-LabAiSharedGatewayPlan -GatewayId test -Location 'https://127.0.0.1:19437/v1/embeddings' -UpstreamBackend LlamaCppCpu -UpstreamLocation 'http://127.0.0.1:19435/v1/embeddings' -RuntimeModel synthetic -Dimension 8 -ModelSha256 ('a'*64) -RuntimeSha256 ('b'*64) -ServerCertificateSha256 ('c'*64) -CertificateAuthoritySha256 ('d'*64) -Consumer @($consumer)
        [IO.File]::WriteAllText((Join-Path $gateway 'plan.json'),($shared|ConvertTo-Json -Depth 30))
        Assert-Session (Reject {Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed} 'LLAMA_SESSION_PREVIEW_STALE') 'new declared consumer invalidates preview'
        $plan=New-LabLlamaCppSessionStopPlan $id
        Assert-Session ($plan.KnownConsumerCount -eq 1 -and $plan.ConsumerCoverage -ceq 'UNKNOWN') 'declared consumer does not imply complete coverage'
        [IO.File]::WriteAllText($path,(@{contractVersion='SqlServerLab.TestEnvironmentRegistry/1.0';environments=@(@{runId=$run})}|ConvertTo-Json -Depth 10))
        Assert-Session (Reject {Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed} 'LLAMA_SESSION_PROTECTED_CONSUMER') 'late protection blocks before stop'
        Remove-Item -LiteralPath $path
        $publicationLock=Enter-LabAiSharedGatewayLifecycleLock -StateRoot $Root
        try {Complete-LockProbe (Start-LockProbe Writer) 'WRITER_LOCKED'} finally {Exit-LabAiSharedGatewayLifecycleLock $publicationLock}
        Assert-Session ($script:stops -eq 0) 'separate real registrar cannot publish through held lifecycle lock using a root alias'
        $probe=Start-LockProbe Stop
        try {
            $watch=[Diagnostics.Stopwatch]::StartNew()
            while(-not(Test-Path (Join-Path $Root 'stop-ready'))){if($probe.HasExited -or $watch.Elapsed.TotalSeconds -gt 20){throw 'LOCK_STOP_READY_TIMEOUT'};Start-Sleep -Milliseconds 20}
            $publicationLock=Enter-LabAiSharedGatewayLifecycleLock -StateRoot $Root
            try {[IO.File]::WriteAllText((Join-Path $Root 'stop-go'),'GO');Complete-LockProbe $probe 'STOP_LOCKED';$probe=$null} finally {Exit-LabAiSharedGatewayLifecycleLock $publicationLock}
        } finally {if($probe){if(-not $probe.HasExited){$probe.Kill();$null=$probe.WaitForExit(5000)};$probe.Dispose()}}
        Assert-Session ($script:stops -eq 0) 'separate actual guidance stop cannot pass a held registrar-publication lock'
        $plan=New-LabLlamaCppSessionStopPlan $id
        $script:realConsumerContext=(Get-Command Get-LabLlamaCppSessionConsumerContext).ScriptBlock
        $script:observationCount=0
        function Get-LabLlamaCppSessionConsumerContext {
            param($Port)
            $result=& $script:realConsumerContext -Port $Port
            $script:observationCount++
            if($script:observationCount -eq 2){Complete-LockProbe (Start-LockProbe Writer) 'WRITER_LOCKED'}
            $result
        }
        $result=(Invoke-SqlServerLabWorkflowAction -Action StopLlamaSession -LlamaSessionPlanId $plan.PlanId -ConfirmLlamaSessionStop).Result
        Assert-Session ($script:observationCount -eq 2) 'real competing publication after last observation is excluded before stop primitive'
        Set-Item Function:Get-LabLlamaCppSessionConsumerContext -Value $script:realConsumerContext
        Assert-Session ($result.Status -eq 'CLEANUP_SUCCEEDED' -and $script:stops -eq 1 -and $script:LlamaCppOwnedSessions.ContainsKey($neighbor)) 'exact stop preserves neighbor'
        Assert-Session (Reject {Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed} 'LLAMA_SESSION_PREVIEW_NOT_FOUND') 'consumed preview cannot replay'
        Assert-Session (Reject {New-LabLlamaCppSessionStopPlan $id} 'LLAMA_OWNERSHIP_NOT_FOUND') 'missing session not adopted'
        # Keep a held object for the real UI import function below.
        $script:testHeldSession=$script:LlamaCppOwnedSessions[$neighbor]
        Write-Host "LLAMA SESSION CORE: PASS ($script:checks)"
    } $root $repo
    $before=& $module {$script:testHeldSession}
    Import-UiSqlServerLabModule -ModulePath (Join-Path $repo 'SqlServerLab.psd1')
    if(-not [object]::ReferenceEquals($module,(Get-Module SqlServerLab)) -or -not [object]::ReferenceEquals($before,(& $module {$script:testHeldSession}))){throw 'UI_IMPORT_LOST_SESSION'}
    Write-Host 'PASS: real UI import preserves exact caller module and held session'
    function Request($Body,$Method='POST',$Origin='http://127.0.0.1:19439') {
        [pscustomobject]@{HttpMethod=$Method;ContentType='application/json';Headers=@{Origin=$Origin};Url=[uri]'http://127.0.0.1:19439/api/llama-sessions';InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Body));ContentEncoding=[Text.Encoding]::UTF8}
    }
    $view=Invoke-UiLlamaSessionRequest (Request '' GET)
    if($view.Items.Count -ne 1){throw 'HTTP_VIEW_INVALID'}
    $id=$view.Items[0].OperationId
    $plan=Invoke-UiLlamaSessionRequest (Request (@{action='preview';operationId=$id}|ConvertTo-Json))
    if($plan.OperationId -cne $id){throw 'HTTP_PREVIEW_INVALID'}
    foreach($request in @((Request '{"action":"stop","planId":"x","confirmed":true}'),(Request '{"action":"preview","operationId":"x","pid":123}'),(Request '{}' POST 'https://foreign.invalid'),(Request ('x'*1025)))) {
        $rejected=$false;try{Invoke-UiLlamaSessionRequest $request|Out-Null}catch{$rejected=$true}
        if(-not $rejected){throw 'HTTP_BOUNDARY_NOT_ENFORCED'}
    }
    Write-Host 'PASS: real HTTP view/preview and foreign-origin/oversize/shape boundaries'
    & $module {
        $script:choices=[Collections.Generic.Queue[object]]::new()
        $script:choices.Enqueue(@{Status='Refresh'})
        $script:choices.Enqueue(@{Status='Selected';SelectedItem=@{Id=$script:LlamaCppOwnedSessions.Keys[0]}})
        $script:choices.Enqueue(@{Status='Cancelled'})
        function Invoke-LabConsoleMenu {param($ScreenId,$Title,$Subtitle,$Items)$script:choices.Dequeue()}
        function Read-LabConfirm {param($Prompt,$Default)$false}
        function Wait-LabConsoleAcknowledgement {}
        function Write-LabWarning {param($Message)throw $Message}
        Show-LabLlamaCppSessionStopInteractive
        if($script:stops -ne 1 -or $script:choices.Count){throw 'CLI_CANCEL_FAILED'}
        Write-Host 'PASS: real CLI refresh/preview/cancel without stop'
        $script:LlamaCppOwnedSessions=@{};$script:LlamaCppStopPlans=@{}
    }
} finally {
    & $module {$script:LlamaCppOwnedSessions=@{};$script:LlamaCppStopPlans=@{}}
    Remove-Module $module -Force
    $full=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'sql-lab-session-check-*'){throw 'TEST_CLEANUP_SCOPE_INVALID'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
Write-Host 'LLAMA SESSION GUIDANCE: PASS; synthetic/offline only'

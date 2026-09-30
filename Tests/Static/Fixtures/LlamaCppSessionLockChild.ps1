#Requires -Version 7.2
[CmdletBinding()]param([string]$Repository,[string]$Root,[ValidateSet('Writer','Stop')][string]$Mode)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $Repository 'SqlServerLab.psd1') -Force -PassThru
try {
    & $module {
        param($Root,$Mode)
        $script:lockProbeRoot=$Root
        function Get-LabDataRootDefault {$script:lockProbeRoot}
        function Get-LabStateRoot {$script:lockProbeRoot}
        function Get-LabTestEnvironmentExportDirectory {param($OutputDirectory)$script:lockProbeRoot}
        if($Mode -eq 'Writer') {
            # Synthetic preflight boundary only; execute the real registrar and publication lock.
            function Test-LabAiSharedGatewayPreflight {[pscustomobject]@{ReceiptKey=('a'*64)}}
            $plan=Get-Content (Join-Path $Root 'shared-ai-gateways/test/plan.json') -Raw|ConvertFrom-Json -Depth 30
            $arguments=@{Plan=$plan;RuntimePath='synthetic';ModelPath='synthetic';CertificatePath='synthetic';PrivateKeyPath='synthetic';CertificateAuthorityPath='synthetic';StateRoot=$Root}
            $blocked=$false;try{Register-LabAiSharedGatewayStorage @arguments|Out-Null}catch{$blocked=$_.Exception.Message -ceq 'AI_SHARED_GATEWAY_STORAGE_LOCKED'}
            if(-not $blocked){throw 'WRITER_BYPASSED_LIFECYCLE_LOCK'}
            Write-Output 'WRITER_LOCKED'
        } else {
            function Stop-LabLlamaCppOwnedRuntime {throw 'STOP_PRIMITIVE_MUST_NOT_RUN'}
            $id=[guid]::NewGuid().ToString('D');$script:LlamaCppOwnedSessions=@{}
            $script:LlamaCppOwnedSessions[$id]=@{Worker=[pscustomobject]@{HasExited=$false};Port=19436}
            $plan=New-LabLlamaCppSessionStopPlan $id
            [IO.File]::WriteAllText((Join-Path $Root 'stop-ready'),'READY')
            $watch=[Diagnostics.Stopwatch]::StartNew()
            while(-not(Test-Path -LiteralPath (Join-Path $Root 'stop-go'))){if($watch.Elapsed.TotalSeconds -gt 20){throw 'STOP_PROBE_GO_TIMEOUT'};Start-Sleep -Milliseconds 20}
            $blocked=$false;try{Invoke-LabLlamaCppSessionStopPlan -PlanId $plan.PlanId -Confirmed|Out-Null}catch{$blocked=$_.Exception.Message -ceq 'AI_SHARED_GATEWAY_STORAGE_LOCKED'}
            if(-not $blocked){throw 'STOP_BYPASSED_PUBLICATION_LOCK'}
            $script:LlamaCppOwnedSessions=@{};$script:LlamaCppStopPlans=@{}
            Write-Output 'STOP_LOCKED'
        }
    } $Root $Mode
} finally {& $module {$script:LlamaCppOwnedSessions=@{};$script:LlamaCppStopPlans=@{}};Remove-Module $module -Force}

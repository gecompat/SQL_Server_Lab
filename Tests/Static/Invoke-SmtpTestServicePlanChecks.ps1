#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
 $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$config=& $module {ConvertTo-LabSmtpTestServiceConfig @{id='acceptance';senderInstanceIds=@('primary');maxStoredMessages=2;maxStoredBytes=1048576;maxMessageMiB=1;acceptedMessagesPerUtc60Seconds=3;MemoryMiB=128;CPUs=0.5}}
$runId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';$scopeId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
$plan=& $module {param($c,$r,$s)New-LabSmtpTestServicePlan -Config $c -RunId $r -ScopeId $s -Provider docker} $config $runId $scopeId
$badRun=$false;try{& $module {param($c,$r,$s)New-LabSmtpTestServicePlan -Config $c -RunId $r.ToUpperInvariant() -ScopeId $s -Provider docker} $config $runId $scopeId|Out-Null}catch{$badRun=$_.Exception.Message -ceq 'SMTP_TEST_SERVICE_BINDING_INVALID'}
$disabled=$false;try{& $module {param($r,$s)New-LabSmtpTestServicePlan -Config @{enabled=$false} -RunId $r -ScopeId $s -Provider docker} $runId $scopeId|Out-Null}catch{$disabled=$_.Exception.Message -ceq 'SMTP_TEST_SERVICE_BINDING_INVALID'}
$checks=@(
    ($plan.Contract.Name -ceq 'SqlServerLab.SmtpTestServicePlan')
    ($plan.NetworkName -ceq "sql-lab-smtp-$runId-$scopeId-acceptance")
    ($plan.Gateway.MaxStoredBytes -eq 1048576 -and $plan.Gateway.CPUs -eq 0.5)
    ($plan.Receiver.Image -cmatch '^ghcr\.io/axllent/mailpit:v1\.31\.3@sha256:[a-f0-9]{64}$')
    $badRun
    $disabled
)
if(@($checks|Where-Object {$_}).Count -ne $checks.Count){Write-Host 'SMTP service plan: FAIL' -ForegroundColor Red;exit 1}
Write-Host 'SMTP service plan: PASS (6/6)'

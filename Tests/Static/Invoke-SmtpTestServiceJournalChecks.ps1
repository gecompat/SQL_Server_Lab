#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$root=Join-Path ([IO.Path]::GetTempPath()) ('smtp-journal-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $plan=& $module {New-LabSmtpTestServicePlan -Config @{id='smtp';senderInstanceIds=@('primary')} -RunId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -ScopeId 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' -Provider docker}
    $created=& $module {param($p,$r)New-LabSmtpTestServiceJournal -Plan $p -RunDirectory $r} $plan $root
    $cleanup=& $module {param($j)Get-LabSmtpTestServiceCleanupPlan -Journal $j} $created.Journal
    $calls=[Collections.Generic.List[string]]::new();$command={param($provider,$arguments)$calls.Add(($provider+':'+($arguments -join ' ')));[pscustomobject]@{ExitCode=0}}.GetNewClosure()
    $cleaned=& $module {param($j,$path,$state,$command)Invoke-LabSmtpTestServiceCleanup -Journal $j -JournalPath $path -StateRoot $state -RuntimeCommand $command} $created.Journal $created.Path $root $command
    $collision=$false;try{& $module {param($p,$r)New-LabSmtpTestServiceJournal -Plan $p -RunDirectory $r} $plan $root|Out-Null}catch{$collision=$_.Exception.Message -ceq 'SMTP_TEST_SERVICE_JOURNAL_COLLISION'}
    $checks=@((Test-Path -LiteralPath $created.Path -PathType Leaf);($created.Journal.Status -ceq 'CLEANED');($cleaned.Recovery.Status -ceq 'NOT_REQUIRED');($cleanup.Steps.Count -eq 4 -and $cleanup.Steps[0].Id -ceq 'remove-gateway' -and $cleanup.Steps[3].Id -ceq 'remove-sender-network');($calls.Count -eq 4 -and $calls[0] -match ':rm -f ' -and $calls[3] -match ':network rm ');$collision)
    if(@($checks|Where-Object {$_}).Count -ne 6){throw 'SMTP_TEST_SERVICE_JOURNAL_CHECK_FAILED'}
    Write-Host 'SMTP service journal: PASS (6/6)'
}finally{Remove-Item -LiteralPath $root -Force -Recurse -ErrorAction SilentlyContinue}

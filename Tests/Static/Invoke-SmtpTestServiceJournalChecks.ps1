#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$root=Join-Path ([IO.Path]::GetTempPath()) ('smtp-journal-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $plan=& $module {New-LabSmtpTestServicePlan -Config @{id='smtp';senderInstanceIds=@('primary')} -RunId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -ScopeId 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' -Provider docker}
    $created=& $module {param($p,$r)New-LabSmtpTestServiceJournal -Plan $p -RunDirectory $r} $plan $root
    $cleanup=& $module {param($j)Get-LabSmtpTestServiceCleanupPlan -Journal $j} $created.Journal
    $collision=$false;try{& $module {param($p,$r)New-LabSmtpTestServiceJournal -Plan $p -RunDirectory $r} $plan $root|Out-Null}catch{$collision=$_.Exception.Message -ceq 'SMTP_TEST_SERVICE_JOURNAL_COLLISION'}
    $checks=@((Test-Path -LiteralPath $created.Path -PathType Leaf);($created.Journal.Status -ceq 'PREPARED');($created.Journal.Recovery.Status -ceq 'REMOVE_CREATED_RESOURCES');($cleanup.Steps.Count -eq 3 -and $cleanup.Steps[0].Id -ceq 'remove-gateway' -and $cleanup.Steps[2].Id -ceq 'remove-network');$collision)
    if(@($checks|Where-Object {$_}).Count -ne 5){throw 'SMTP_TEST_SERVICE_JOURNAL_CHECK_FAILED'}
    Write-Host 'SMTP service journal: PASS (5/5)'
}finally{Remove-Item -LiteralPath $root -Force -Recurse -ErrorAction SilentlyContinue}

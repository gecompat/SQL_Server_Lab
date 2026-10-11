#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$root=Join-Path ([IO.Path]::GetTempPath()) ('smtp-journal-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    $plan=& $module {New-LabSmtpTestServicePlan -Config @{id='smtp';senderInstanceIds=@('primary')} -RunId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -ScopeId 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' -Provider docker}
    $created=& $module {param($p,$r)New-LabSmtpTestServiceJournal -Plan $p -RunDirectory $r} $plan $root
    $collision=$false;try{& $module {param($p,$r)New-LabSmtpTestServiceJournal -Plan $p -RunDirectory $r} $plan $root|Out-Null}catch{$collision=$_.Exception.Message -ceq 'SMTP_TEST_SERVICE_JOURNAL_COLLISION'}
    $checks=@((Test-Path -LiteralPath $created.Path -PathType Leaf);($created.Journal.Status -ceq 'PREPARED');($created.Journal.Recovery.Status -ceq 'REMOVE_CREATED_RESOURCES');$collision)
    if(@($checks|Where-Object {$_}).Count -ne 4){throw 'SMTP_TEST_SERVICE_JOURNAL_CHECK_FAILED'}
    Write-Host 'SMTP service journal: PASS (4/4)'
}finally{Remove-Item -LiteralPath $root -Force -Recurse -ErrorAction SilentlyContinue}

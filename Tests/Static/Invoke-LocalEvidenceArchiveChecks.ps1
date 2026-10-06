#Requires -Version 7.2
# Local synthetic archive only. No provider, secret, or existing evidence access.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$id=[guid]::NewGuid().ToString('N')
$root=Join-Path $repo ('.artifacts/test-runs/local-evidence-archive-'+$id)
$archiveRoot=Join-Path $root '.artifacts/orchestrator/preserved'
$tool=Join-Path $root 'Tools/Manage-LocalEvidenceArchive.ps1'
$passed=0
function Assert-Archive([bool]$Condition,[string]$Name){if(-not $Condition){throw "LOCAL_ARCHIVE_CHECK_FAILED: $Name"};$script:passed++}
try{
    $null=New-Item -ItemType Directory -Path (Split-Path $tool -Parent),$archiveRoot -Force
    Copy-Item -LiteralPath (Join-Path $repo 'Tools/Manage-LocalEvidenceArchive.ps1') -Destination $tool
    foreach($name in @('fixture-valid','fixture-tamper')){
        $dir=Join-Path $archiveRoot $name
        $null=New-Item -ItemType Directory -Path (Join-Path $dir 'nested') -Force
        [IO.File]::WriteAllText((Join-Path $dir 'nested/evidence.txt'),'synthetic-only',[Text.UTF8Encoding]::new($false))
    }
    $unregistered=@(& $tool -Action List)
    Assert-Archive (@($unregistered|Where-Object{$_.Status -ceq 'UNREGISTERED'}).Count -eq 2) 'unregistered archives visible'
    $valid=& $tool -Action Register -ArchiveId fixture-valid -Purpose 'Synthetic validation fixture' -RelatedPr 'https://github.com/gecompat/SQL_Server_Lab/pull/698' -SourceCommit ('a'*40) -Confirm:$false
    $tamper=& $tool -Action Register -ArchiveId fixture-tamper -Purpose 'Synthetic tamper fixture' -Confirm:$false
    Assert-Archive ($valid.Status -ceq 'VALID' -and $valid.FileCount -eq 1 -and $tamper.Status -ceq 'VALID') 'registration is verified'
    $listed=@(& $tool -Action List)
    Assert-Archive (@($listed|Where-Object{$_.Status -ceq 'REGISTERED_UNVERIFIED'}).Count -eq 2) 'registered inventory explicit'
    $verified=& $tool -Action Verify -ArchiveId fixture-valid
    Assert-Archive ($verified.Status -ceq 'VALID' -and $verified.ManifestSha256 -ceq $valid.ManifestSha256) 'hash verification'
    $restore=& $tool -Action Restore -ArchiveId fixture-valid -ExpectedManifestSha256 $valid.ManifestSha256 -Confirm:$false
    Assert-Archive ($restore.Status -ceq 'RESTORED_EVIDENCE_ONLY' -and
        (Test-Path -LiteralPath (Join-Path $restore.Destination 'restore-receipt.json')) -and
        ([IO.File]::ReadAllText((Join-Path $restore.Destination 'nested/evidence.txt')) -ceq 'synthetic-only')) 'evidence-only restore'
    $listedRestores=@(& $tool -Action ListRestores)
    $restoreItem=@($listedRestores|Where-Object{$_.Status -ceq 'RESTORED_EVIDENCE_ONLY'})[0]
    Assert-Archive ($listedRestores.Count -eq 1 -and $restoreItem.ArchiveId -ceq 'fixture-valid' -and
        $restoreItem.RestoreId -ceq [IO.Path]::GetFileName($restore.Destination)) 'restore inventory explicit'
    try{& $tool -Action RemoveRestore -RestoreId $restoreItem.RestoreId -ExpectedReceiptSha256 ('0'*64) -Confirm:$false|Out-Null;throw 'EXPECTED_ERROR_MISSING'}
    catch{Assert-Archive ($_.Exception.Message -match 'LOCAL_EVIDENCE_RESTORE_EXACT_RECEIPT_REQUIRED') 'stale receipt blocks restored-copy removal'}
    [IO.File]::WriteAllText((Join-Path $restore.Destination 'unexpected.txt'),'must-survive',[Text.UTF8Encoding]::new($false))
    try{& $tool -Action RemoveRestore -RestoreId $restoreItem.RestoreId -ExpectedReceiptSha256 $restoreItem.ReceiptSha256 -Confirm:$false|Out-Null;throw 'EXPECTED_ERROR_MISSING'}
    catch{Assert-Archive ($_.Exception.Message -match 'LOCAL_EVIDENCE_RESTORE_CONTENT_CHANGED' -and (Test-Path -LiteralPath (Join-Path $restore.Destination 'unexpected.txt'))) 'foreign content blocks restored-copy removal'}
    Remove-Item -LiteralPath (Join-Path $restore.Destination 'unexpected.txt') -Force
    $removedRestore=& $tool -Action RemoveRestore -RestoreId $restoreItem.RestoreId -ExpectedReceiptSha256 $restoreItem.ReceiptSha256 -Confirm:$false
    Assert-Archive ($removedRestore.Status -ceq 'REMOVED' -and -not(Test-Path -LiteralPath $restore.Destination)) 'exact restored-copy removal'
    $reserved=Join-Path $archiveRoot 'fixture-reserved'
    $null=New-Item -ItemType Directory -Path $reserved
    [IO.File]::WriteAllText((Join-Path $reserved 'Restore-Receipt.json'),'synthetic evidence',[Text.UTF8Encoding]::new($false))
    try{& $tool -Action Register -ArchiveId fixture-reserved -Purpose 'Reserved name fixture' -Confirm:$false|Out-Null;throw 'EXPECTED_ERROR_MISSING'}
    catch{Assert-Archive ($_.Exception.Message -match 'LOCAL_EVIDENCE_ARCHIVE_RESERVED_FILENAME' -and -not(Test-Path -LiteralPath (Join-Path $reserved 'evidence-archive.json'))) 'receipt collision blocks registration'}
    try{& $tool -Action Remove -ArchiveId fixture-valid -ExpectedManifestSha256 ('0'*64) -Confirm:$false|Out-Null;throw 'EXPECTED_ERROR_MISSING'}
    catch{Assert-Archive ($_.Exception.Message -match 'LOCAL_EVIDENCE_ARCHIVE_EXACT_MANIFEST_REQUIRED') 'stale digest blocks removal'}
    $removed=& $tool -Action Remove -ArchiveId fixture-valid -ExpectedManifestSha256 $valid.ManifestSha256 -Confirm:$false
    Assert-Archive ($removed.Status -ceq 'REMOVED' -and -not(Test-Path -LiteralPath (Join-Path $archiveRoot 'fixture-valid'))) 'exact registered removal'
    [IO.File]::WriteAllText((Join-Path $archiveRoot 'fixture-tamper/nested/evidence.txt'),'changed',[Text.UTF8Encoding]::new($false))
    $changed=& $tool -Action Verify -ArchiveId fixture-tamper
    Assert-Archive ($changed.Status -ceq 'MISMATCH') 'tampered payload detected'
    try{& $tool -Action Remove -ArchiveId fixture-tamper -ExpectedManifestSha256 $tamper.ManifestSha256 -Confirm:$false|Out-Null;throw 'EXPECTED_ERROR_MISSING'}
    catch{Assert-Archive ($_.Exception.Message -match 'LOCAL_EVIDENCE_ARCHIVE_INTEGRITY_REQUIRED') 'tampered payload blocks removal'}
    Write-Output "LOCAL EVIDENCE ARCHIVE CHECKS: $passed PASS"
}
finally{
    $absolute=[IO.Path]::GetFullPath($root)
    $boundary=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/test-runs')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($absolute) -cnotmatch '^local-evidence-archive-[a-f0-9]{32}$' -or
        @(Get-ChildItem -LiteralPath $absolute -Recurse -Force|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){
        throw 'LOCAL_ARCHIVE_FIXTURE_CLEANUP_SCOPE_INVALID'
    }
    Remove-Item -LiteralPath $absolute -Recurse -Force
}

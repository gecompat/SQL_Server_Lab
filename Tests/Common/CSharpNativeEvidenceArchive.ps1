# Archive only completed, supervisor-bound evidence while the elevated owner
# still holds deletion rights. Unknown child/cleanup outcomes stay recoverable.
function Complete-CSharpNativeEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$WorkflowRun,[string]$ArchiveParent)
    $binding=Get-CSharpNativeEvidence -Root $Root -Commit $Commit -WorkflowRun $WorkflowRun
    $receiptPath=Join-Path $Root 'receipt.json'
    Assert-CSharpNativeProfilePath $receiptPath
    $receipt=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json -ErrorAction Stop
    if($receipt.Contract -cne 'SqlServerLab.CSharpNativeAcceptance/1.0' -or $receipt.Commit -cne $Commit -or
        $receipt.Status -cnotin @('PASSED','FAILED') -or $receipt.CleanupFailure -or $receipt.EvidenceFailure){throw 'CSHARP_NATIVE_ARCHIVE_RECOVERY_REQUIRED'}
    # Keep the existing strict ancestry/ACL contract. A user-profile ancestor
    # is not trusted merely because its final archive directory is protected.
    if(-not $ArchiveParent){$ArchiveParent=Join-Path (Get-CSharpNativeRequestVolumeRoot) 'SqlServerLab-CSharpEvidenceArchive'}
    Assert-CSharpNativeRequestDirectory ([IO.Path]::GetDirectoryName($ArchiveParent)) -AncestorsOnly
    if(-not(Test-Path -LiteralPath $ArchiveParent)){New-CSharpNativeTemporaryDirectory $ArchiveParent -CurrentIdentityRead}
    Assert-CSharpNativeRequestDirectory $ArchiveParent
    $archive=Join-Path $ArchiveParent ($binding.OperationId+'.zip')
    if(Test-Path -LiteralPath $archive){throw 'CSHARP_NATIVE_ARCHIVE_COLLISION'}
    $entries=@(Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop)
    if(@($entries|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'CSHARP_NATIVE_ARCHIVE_REPARSE'}
    $files=@($entries|Where-Object {-not $_.PSIsContainer})
    if($files.Count -gt 10000 -or ($files|Measure-Object Length -Sum).Sum -gt 2GB){throw 'CSHARP_NATIVE_ARCHIVE_LIMIT'}
    $pins=@{}
    foreach($file in $files){$pins[[IO.Path]::GetRelativePath($Root,$file.FullName).Replace('\','/')]=[pscustomobject]@{Bytes=$file.Length;Hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}}
    [IO.Compression.ZipFile]::CreateFromDirectory($Root,$archive,[IO.Compression.CompressionLevel]::Optimal,$false)
    $zip=[IO.Compression.ZipFile]::OpenRead($archive)
    try{
        $archived=@($zip.Entries|Where-Object {$_.Name.Length -gt 0})
        if($archived.Count -ne $files.Count){throw 'CSHARP_NATIVE_ARCHIVE_FILE_COUNT'}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($entry in $archived){
            if(-not $seen.Add($entry.FullName) -or -not $pins.ContainsKey($entry.FullName) -or $entry.Length -ne $pins[$entry.FullName].Bytes){throw 'CSHARP_NATIVE_ARCHIVE_ENTRY_DRIFT'}
            $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
            try{$hash=[Convert]::ToHexString($sha.ComputeHash($stream))}finally{$sha.Dispose();$stream.Dispose()}
            if($hash -cne $pins[$entry.FullName].Hash){throw 'CSHARP_NATIVE_ARCHIVE_HASH_DRIFT'}
        }
    }finally{$zip.Dispose()}
    # Revalidate the protected source and exact bytes before the destructive step.
    $null=Get-CSharpNativeEvidence -Root $Root -Commit $Commit -WorkflowRun $WorkflowRun
    $now=@(Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop)
    if(@($now|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count -or @($now|Where-Object {-not $_.PSIsContainer}).Count -ne $files.Count){throw 'CSHARP_NATIVE_ARCHIVE_SOURCE_DRIFT'}
    foreach($file in $files){if((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -cne $pins[[IO.Path]::GetRelativePath($Root,$file.FullName).Replace('\','/')].Hash){throw 'CSHARP_NATIVE_ARCHIVE_SOURCE_DRIFT'}}
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction Stop
    if(Test-Path -LiteralPath $Root){throw 'CSHARP_NATIVE_ARCHIVE_SOURCE_REMAINS'}
    [pscustomobject]@{Status='ARCHIVED';OperationId=$binding.OperationId;Archive=$archive}
}

function Remove-CSharpNativeConsumedRequest {
    param([Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][string]$ExpectedHash)
    if($ExpectedHash -cnotmatch '^[a-f0-9]{64}$'){throw 'CSHARP_NATIVE_REQUEST_BINDING'}
    $root=[IO.Path]::GetDirectoryName($RequestPath)
    if([IO.Path]::GetFileName($root) -cne ('SqlServerLab-CSharpRequest-'+$ExpectedHash) -or [IO.Path]::GetFileName($RequestPath) -cne 'request.json'){throw 'CSHARP_NATIVE_REQUEST_BINDING'}
    Assert-CSharpNativeRequestDirectory $root
    $entries=@(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)
    if($entries.Count -ne 1 -or $entries[0].PSIsContainer -or $entries[0].Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'CSHARP_NATIVE_REQUEST_CLEANUP_CONTENTS'}
    $null=Read-CSharpNativeRequestBytes -Path $RequestPath -ExpectedHash $ExpectedHash
    Remove-Item -LiteralPath $RequestPath -Force -ErrorAction Stop
    [IO.Directory]::Delete($root,$false)
}

#Requires -Version 7.2
<#
.SYNOPSIS
    Verwaltet explizit registrierte, lokale und ignorierte Orchestrator-Evidenz.
.DESCRIPTION
    Restore erstellt ausschliesslich eine neue Evidenzkopie. Weder Lab-State
    noch Container/Volumes werden dadurch wiederhergestellt. Nicht registrierte
    Verzeichnisse sind sichtbar, aber weder Restore- noch Loeschziel.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][ValidateSet('List','Register','Verify','Restore','Remove','ListRestores','RemoveRestore')][string]$Action,
    [ValidatePattern('^[a-z0-9][a-z0-9-]{2,100}$')][string]$ArchiveId,
    [ValidatePattern('^[a-z0-9][a-z0-9-]{2,100}-[a-f0-9]{32}$')][string]$RestoreId,
    [string]$Purpose,
    [ValidatePattern('^https://github\.com/gecompat/SQL_Server_Lab/pull/[0-9]+$')][string]$RelatedPr,
    [ValidatePattern('^[a-fA-F0-9]{40}$')][string]$SourceCommit,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedManifestSha256,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedReceiptSha256
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$artifactRoot=Join-Path $repo '.artifacts'
$orchestrator=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/orchestrator'))
$archives=Join-Path $orchestrator 'preserved'
$restored=Join-Path $orchestrator 'restored'
$manifestName='evidence-archive.json'

function Assert-LocalArchiveDirectory([string]$Path,[string]$Parent) {
    $absolute=[IO.Path]::GetFullPath($Path)
    $boundary=[IO.Path]::GetFullPath($Parent).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetDirectoryName($absolute).TrimEnd('\','/') -cne $boundary.TrimEnd('\','/')) {
        throw 'LOCAL_EVIDENCE_ARCHIVE_SCOPE_INVALID'
    }
    foreach($itemPath in @($repo,$artifactRoot,$orchestrator,$Parent,$absolute)) {
        if(Test-Path -LiteralPath $itemPath){
            $item=Get-Item -LiteralPath $itemPath -Force
            if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'LOCAL_EVIDENCE_ARCHIVE_REPARSE_OR_FILE'
            }
        }
    }
    return $absolute
}

function Read-LocalRestoreReceipt([string]$Directory) {
    $path=Join-Path $Directory 'restore-receipt.json'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'LOCAL_EVIDENCE_RESTORE_RECEIPT_MISSING'}
    $item=Get-Item -LiteralPath $path -Force
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 10485760){throw 'LOCAL_EVIDENCE_RESTORE_RECEIPT_INVALID'}
    $data=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -Depth 4
    if($data.Contract -cne 'SqlServerLab.LocalEvidenceRestore/1.0' -or
        $data.Mode -cne 'EVIDENCE_COPY_ONLY' -or
        [string]$data.ArchiveId -cnotmatch '^[a-z0-9][a-z0-9-]{2,100}$' -or
        [IO.Path]::GetFileName($Directory) -cnotmatch ('^'+[regex]::Escape([string]$data.ArchiveId)+'-[a-f0-9]{32}$') -or
        [string]$data.ManifestSha256 -cnotmatch '^[a-f0-9]{64}$' -or
        @($data.Files).Count -lt 1 -or @($data.Files).Count -gt 10000) {throw 'LOCAL_EVIDENCE_RESTORE_RECEIPT_INVALID'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in @($data.Files)){
        $relative=[string]$entry.Path
        if(-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains('\') -or
            $relative.Contains(':') -or @($relative.Split('/')|Where-Object{$_ -in @('','.', '..')}).Count -or
            -not $seen.Add($relative) -or [string]$entry.Sha256 -cnotmatch '^[a-f0-9]{64}$' -or
            [long]$entry.Bytes -lt 0){throw 'LOCAL_EVIDENCE_RESTORE_RECEIPT_INVALID'}
    }
    [pscustomobject]@{ArchiveId=[string]$data.ArchiveId;ReceiptSha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();Files=@($data.Files)}
}

function Get-LocalArchiveFiles([string]$Directory,[string]$ExcludedRootFile=$manifestName) {
    $entries=@(Get-ChildItem -LiteralPath $Directory -Recurse -Force)
    if(@($entries|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count) {
        throw 'LOCAL_EVIDENCE_ARCHIVE_REPARSE'
    }
    $files=@($entries|Where-Object{-not $_.PSIsContainer})
    $rows=@(foreach($file in $files){
        $relative=[IO.Path]::GetRelativePath($Directory,$file.FullName).Replace('\','/')
        if($relative -ceq $ExcludedRootFile){continue}
        if([IO.Path]::IsPathRooted($relative) -or @($relative.Split('/')|Where-Object{$_ -in @('','.', '..')}).Count -or
            $relative.Contains(':')){throw 'LOCAL_EVIDENCE_ARCHIVE_ENTRY_INVALID'}
        [pscustomobject]@{Path=$relative;Bytes=[long]$file.Length;Sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    return @($rows|Sort-Object -Property Path -CaseSensitive)
}

function Read-LocalArchiveManifest([string]$Directory) {
    $path=Join-Path $Directory $manifestName
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'LOCAL_EVIDENCE_ARCHIVE_UNREGISTERED'}
    $item=Get-Item -LiteralPath $path -Force
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 10485760){throw 'LOCAL_EVIDENCE_ARCHIVE_MANIFEST_INVALID'}
    $manifest=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -Depth 8
    if($manifest.Contract -cne 'SqlServerLab.LocalEvidenceArchive/1.0' -or
        $manifest.ArchiveId -cne [IO.Path]::GetFileName($Directory) -or
        [string]::IsNullOrWhiteSpace([string]$manifest.Purpose) -or
        $manifest.RestoreMode -cne 'EVIDENCE_COPY_ONLY' -or
        @($manifest.Files).Count -lt 1 -or @($manifest.Files).Count -gt 10000){
        throw 'LOCAL_EVIDENCE_ARCHIVE_MANIFEST_INVALID'
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in @($manifest.Files)){
        $relative=[string]$entry.Path
        if(-not $relative -or $relative -ieq 'restore-receipt.json' -or
            [IO.Path]::IsPathRooted($relative) -or $relative.Contains('\') -or
            $relative.Contains(':') -or @($relative.Split('/')|Where-Object{$_ -in @('','.', '..')}).Count -or
            -not $seen.Add($relative) -or [string]$entry.Sha256 -cnotmatch '^[a-f0-9]{64}$' -or
            [long]$entry.Bytes -lt 0){throw 'LOCAL_EVIDENCE_ARCHIVE_MANIFEST_INVALID'}
    }
    return [pscustomobject]@{Data=$manifest;Sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}

function Test-LocalArchive([string]$Directory) {
    $record=Read-LocalArchiveManifest $Directory
    $actual=@(Get-LocalArchiveFiles $Directory)
    $expected=@($record.Data.Files|Sort-Object -Property Path -CaseSensitive)
    $valid=$actual.Count -eq $expected.Count
    if($valid){
        for($i=0;$i -lt $actual.Count;$i++){
            if($actual[$i].Path -cne [string]$expected[$i].Path -or
                $actual[$i].Bytes -ne [long]$expected[$i].Bytes -or
                $actual[$i].Sha256 -cne [string]$expected[$i].Sha256){$valid=$false;break}
        }
    }
    [pscustomobject]@{ArchiveId=[string]$record.Data.ArchiveId;Status=$(if($valid){'VALID'}else{'MISMATCH'});
        Purpose=[string]$record.Data.Purpose;RelatedPr=[string]$record.Data.RelatedPr;
        FileCount=$actual.Count;ManifestSha256=$record.Sha256;Manifest=$record.Data}
}

if($Action -eq 'List'){
    if(-not(Test-Path -LiteralPath $archives -PathType Container)){return}
    $null=Assert-LocalArchiveDirectory (Join-Path $archives '__scope_check__') $archives
    foreach($directory in @(Get-ChildItem -LiteralPath $archives -Directory -Force|Sort-Object Name)){
        try {
            $path=Assert-LocalArchiveDirectory $directory.FullName $archives
            $manifest=Join-Path $path $manifestName
            if(Test-Path -LiteralPath $manifest -PathType Leaf){
                $record=Read-LocalArchiveManifest $path
                [pscustomobject]@{ArchiveId=$directory.Name;Status='REGISTERED_UNVERIFIED';Purpose=[string]$record.Data.Purpose;
                    RelatedPr=[string]$record.Data.RelatedPr;ManifestSha256=$record.Sha256}
            }else{[pscustomobject]@{ArchiveId=$directory.Name;Status='UNREGISTERED';Purpose='';RelatedPr='';ManifestSha256=''}}
        }catch{[pscustomobject]@{ArchiveId=$directory.Name;Status='INVALID';Purpose='';RelatedPr='';ManifestSha256=''}}
    }
    return
}
if($Action -eq 'ListRestores'){
    if(-not(Test-Path -LiteralPath $restored -PathType Container)){return}
    $null=Assert-LocalArchiveDirectory (Join-Path $restored '__scope_check__') $restored
    foreach($item in @(Get-ChildItem -LiteralPath $restored -Directory -Force|Sort-Object Name)){
        try{$path=Assert-LocalArchiveDirectory $item.FullName $restored
            $receipt=Read-LocalRestoreReceipt $path
            [pscustomobject]@{RestoreId=$item.Name;ArchiveId=$receipt.ArchiveId;Status='RESTORED_EVIDENCE_ONLY';ReceiptSha256=$receipt.ReceiptSha256}
        }catch{[pscustomobject]@{RestoreId=$item.Name;ArchiveId='';Status='INVALID';ReceiptSha256=''}}
    }
    return
}
if($Action -eq 'RemoveRestore'){
    if(-not $RestoreId){throw 'LOCAL_EVIDENCE_RESTORE_ID_REQUIRED'}
    $target=Assert-LocalArchiveDirectory (Join-Path $restored $RestoreId) $restored
    if(-not(Test-Path -LiteralPath $target -PathType Container)){throw 'LOCAL_EVIDENCE_RESTORE_NOT_FOUND'}
    $receipt=Read-LocalRestoreReceipt $target
    if(-not $ExpectedReceiptSha256 -or $ExpectedReceiptSha256.ToLowerInvariant() -cne $receipt.ReceiptSha256){
        throw 'LOCAL_EVIDENCE_RESTORE_EXACT_RECEIPT_REQUIRED'
    }
    $entries=@(Get-ChildItem -LiteralPath $target -Recurse -Force)
    if(@($entries|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'LOCAL_EVIDENCE_RESTORE_REPARSE'}
    $actual=@(Get-LocalArchiveFiles $target 'restore-receipt.json')
    $expected=@($receipt.Files|Sort-Object -Property Path -CaseSensitive)
    if($actual.Count -ne $expected.Count){throw 'LOCAL_EVIDENCE_RESTORE_CONTENT_CHANGED'}
    for($i=0;$i -lt $actual.Count;$i++){
        if($actual[$i].Path -cne [string]$expected[$i].Path -or
            $actual[$i].Bytes -ne [long]$expected[$i].Bytes -or
            $actual[$i].Sha256 -cne [string]$expected[$i].Sha256){throw 'LOCAL_EVIDENCE_RESTORE_CONTENT_CHANGED'}
    }
    if($PSCmdlet.ShouldProcess($target,'Permanently remove exact local evidence restore copy')){
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        [pscustomobject]@{RestoreId=$RestoreId;Status='REMOVED';ReceiptSha256=$receipt.ReceiptSha256}
    }
    return
}
if(-not $ArchiveId){throw 'LOCAL_EVIDENCE_ARCHIVE_ID_REQUIRED'}
$directory=Assert-LocalArchiveDirectory (Join-Path $archives $ArchiveId) $archives
if(-not(Test-Path -LiteralPath $directory -PathType Container)){throw 'LOCAL_EVIDENCE_ARCHIVE_NOT_FOUND'}

if($Action -eq 'Register'){
    if([string]::IsNullOrWhiteSpace($Purpose) -or $Purpose.Length -gt 240){throw 'LOCAL_EVIDENCE_ARCHIVE_PURPOSE_REQUIRED'}
    if(Test-Path -LiteralPath (Join-Path $directory $manifestName)){throw 'LOCAL_EVIDENCE_ARCHIVE_ALREADY_REGISTERED'}
    $files=@(Get-LocalArchiveFiles $directory)
    if($files.Count -lt 1 -or $files.Count -gt 10000){throw 'LOCAL_EVIDENCE_ARCHIVE_FILE_COUNT_INVALID'}
    if(@($files|Where-Object{$_.Path -ieq 'restore-receipt.json'}).Count){throw 'LOCAL_EVIDENCE_ARCHIVE_RESERVED_FILENAME'}
    if(-not $PSCmdlet.ShouldProcess($directory,'Register exact local evidence archive')){return}
    $manifest=[ordered]@{Contract='SqlServerLab.LocalEvidenceArchive/1.0';ArchiveId=$ArchiveId;
        Purpose=$Purpose;RelatedPr=$RelatedPr;SourceCommit=$SourceCommit;
        RegisteredAtUtc=[datetime]::UtcNow.ToString('o');RestoreMode='EVIDENCE_COPY_ONLY';Files=$files}
    $path=Join-Path $directory $manifestName
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($manifest|ConvertTo-Json -Depth 8))
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    $result=Test-LocalArchive $directory
    if($result.Status -cne 'VALID'){throw 'LOCAL_EVIDENCE_ARCHIVE_REGISTRATION_VERIFY_FAILED'}
    $result|Select-Object ArchiveId,Status,Purpose,RelatedPr,FileCount,ManifestSha256
    return
}
$verified=Test-LocalArchive $directory
if($Action -eq 'Verify'){$verified|Select-Object ArchiveId,Status,Purpose,RelatedPr,FileCount,ManifestSha256;return}
if($verified.Status -cne 'VALID'){throw 'LOCAL_EVIDENCE_ARCHIVE_INTEGRITY_REQUIRED'}
if(-not $ExpectedManifestSha256 -or $ExpectedManifestSha256.ToLowerInvariant() -cne $verified.ManifestSha256){
    throw 'LOCAL_EVIDENCE_ARCHIVE_EXACT_MANIFEST_REQUIRED'
}
if($Action -eq 'Restore'){
    $destination=Assert-LocalArchiveDirectory (Join-Path $restored ($ArchiveId+'-'+[guid]::NewGuid().ToString('N'))) $restored
    if(Test-Path -LiteralPath $destination){throw 'LOCAL_EVIDENCE_RESTORE_EXISTS'}
    if(-not $PSCmdlet.ShouldProcess($destination,'Create evidence-only restore copy')){return}
    $null=New-Item -ItemType Directory -Path $destination -Force
    try {
        foreach($entry in @($verified.Manifest.Files)){
            $source=Join-Path $directory ([string]$entry.Path).Replace('/',[IO.Path]::DirectorySeparatorChar)
            $target=Join-Path $destination ([string]$entry.Path).Replace('/',[IO.Path]::DirectorySeparatorChar)
            $null=New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
            Copy-Item -LiteralPath $source -Destination $target -ErrorAction Stop
            if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$entry.Sha256){
                throw 'LOCAL_EVIDENCE_RESTORE_VERIFY_FAILED'
            }
        }
        $receipt=[ordered]@{Contract='SqlServerLab.LocalEvidenceRestore/1.0';ArchiveId=$ArchiveId;
            ManifestSha256=$verified.ManifestSha256;RestoredAtUtc=[datetime]::UtcNow.ToString('o');Mode='EVIDENCE_COPY_ONLY';
            Files=@($verified.Manifest.Files)}
        [IO.File]::WriteAllText((Join-Path $destination 'restore-receipt.json'),($receipt|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
    } catch {
        $originalError=$_
        $cleanupTarget=Assert-LocalArchiveDirectory $destination $restored
        $cleanupEntries=@(Get-ChildItem -LiteralPath $cleanupTarget -Recurse -Force)
        if(@($cleanupEntries|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){
            throw 'LOCAL_EVIDENCE_RESTORE_RECOVERY_REQUIRED'
        }
        try {Remove-Item -LiteralPath $cleanupTarget -Recurse -Force -ErrorAction Stop}
        catch {throw 'LOCAL_EVIDENCE_RESTORE_RECOVERY_REQUIRED'}
        throw $originalError
    }
    [pscustomobject]@{ArchiveId=$ArchiveId;Status='RESTORED_EVIDENCE_ONLY';Destination=$destination;ManifestSha256=$verified.ManifestSha256}
    return
}
if($Action -eq 'Remove'){
    if($PSCmdlet.ShouldProcess($directory,'Permanently remove exact registered local evidence archive')){
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction Stop
        [pscustomobject]@{ArchiveId=$ArchiveId;Status='REMOVED';ManifestSha256=$verified.ManifestSha256}
    }
}

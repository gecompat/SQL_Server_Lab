#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft native 7-Zip-Backup- und Attach-Extraktion ohne SQL- oder Providerressourcen.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
foreach($sourceFile in @('ConsoleUi','ActionProgress','TransferProgress','ArchiveProgress','SevenZip','SampleArtifactHandlers')) {
    . (Join-Path $repoRoot "Private/$sourceFile.ps1")
}
$tool=Get-Lab7ZipExecutable
if (-not $tool) { throw 'ARCHIVE_ACCEPTANCE_7ZIP_UNAVAILABLE' }
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-7zip-acceptance-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
Push-Location -LiteralPath $root
try {
    $payload=[byte[]]::new(1MB+7)
    for($index=0;$index -lt $payload.Length;$index+=4096) { $payload[$index]=51 }
    foreach($name in @('sample.bak','sample.mdf','sample.ldf')) { [IO.File]::WriteAllBytes((Join-Path $root $name),$payload) }
    $expected=(Get-FileHash -LiteralPath (Join-Path $root 'sample.bak')).Hash
    $archivePath=Join-Path $root 'sample.7z'
    $created=Invoke-LabProgressNativeCommand -FilePath $tool.Path -ArgumentList @('a','-t7z',$archivePath,'sample.bak','sample.mdf','sample.ldf') -Phase Extract -TimeoutSeconds 30
    if ($created.ExitCode -ne 0) { throw 'ARCHIVE_ACCEPTANCE_CREATE_FAILED' }
    $backup=Get-LabArchiveBackupPayload -ArchivePath $archivePath -PayloadPath 'sample.bak' -ArchiveFormat 7z -RunDirectory $root
    if ((Get-FileHash -LiteralPath $backup.Path).Hash -ne $expected) { throw 'ARCHIVE_ACCEPTANCE_BACKUP_BYTES_CHANGED' }
    Write-Host 'PASS: Native 7-Zip-Backup-Payload bleibt bytegleich'
    $layout=@(@{path='sample.mdf';role='primary'},@{path='sample.ldf';role='log'})
    $attach=Get-LabArchiveAttachPayloads -ArchivePath $archivePath -PayloadLayout $layout -ArchiveFormat 7z -RunDirectory $root
    if (@($attach.Payloads).Count -ne 2) { throw 'ARCHIVE_ACCEPTANCE_ATTACH_COUNT_INVALID' }
    foreach($item in $attach.Payloads) { if ((Get-FileHash -LiteralPath $item.Path).Hash -ne $expected) { throw 'ARCHIVE_ACCEPTANCE_ATTACH_BYTES_CHANGED' } }
    Write-Host 'PASS: Native 7-Zip-MDF-/LDF-Payloads bleiben bytegleich'
    $before=@(Get-ChildItem -LiteralPath (Join-Path $root 'artifact-work') -Directory).Count
    $rejected=$false
    try { Get-LabArchiveBackupPayload -ArchivePath $archivePath -PayloadPath 'missing.bak' -ArchiveFormat 7z -RunDirectory $root | Out-Null }
    catch { $rejected=$_.Exception.Message -like 'SAMPLE_ARCHIVE_PAYLOAD_NOT_FOUND:*' }
    $after=@(Get-ChildItem -LiteralPath (Join-Path $root 'artifact-work') -Directory).Count
    if (-not $rejected -or $before -ne $after) { throw 'ARCHIVE_ACCEPTANCE_MISSING_PAYLOAD_CLEANUP_FAILED' }
    Write-Host 'PASS: Fehlende native Payload hinterlaesst kein Arbeitsverzeichnis'
}
finally {
    Pop-Location
    $resolved=[IO.Path]::GetFullPath($root)
    $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-7zip-acceptance-*') { throw 'ARCHIVE_ACCEPTANCE_CLEANUP_SCOPE_INVALID' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'PASS: Native Archiv-Acceptance und Cleanup'

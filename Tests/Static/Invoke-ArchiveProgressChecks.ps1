#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft ZIP-Fortschritt, bestehende Ziele und Teilfehler mit synthetischen Daten.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
foreach ($sourceFile in @('ConsoleUi','ActionProgress','TransferProgress','ArchiveProgress')) {
    . (Join-Path $repoRoot "Private/$sourceFile.ps1")
}
$reports=[Collections.Generic.List[object]]::new()
$updateProgress=${function:Update-LabActionProgress}
$testClock=[pscustomobject]@{Now=[datetime]::UtcNow}
function Update-LabActionProgress {
    param($Progress,[long]$CompletedBytes=0,[long]$TotalBytes=0)
    $testClock.Now=$testClock.Now.AddSeconds(1)
    & $updateProgress -Progress $Progress -CompletedBytes $CompletedBytes -TotalBytes $TotalBytes -Now $testClock.Now
}
function Write-Progress {
    param($Id,$Activity,$Status,$CurrentOperation,$PercentComplete,[switch]$Completed)
    $reports.Add([pscustomobject]@{Status=$Status;Detail=$CurrentOperation;Percent=$PercentComplete;Completed=[bool]$Completed})
}
function Assert-ArchiveProgress {
    param([bool]$Condition,[string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Host "PASS: $Name"
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-archive-progress-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$archive=$null
try {
    $zipPath=Join-Path $root 'payload.zip'
    $archive=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
    $entry=$archive.CreateEntry('synthetic-payload.bak')
    $entry.LastWriteTime=[datetimeoffset]'2020-01-01T00:00:00Z'
    $payload=[byte[]]::new(3MB+7)
    for($index=0;$index -lt $payload.Length;$index+=4096) { $payload[$index]=91 }
    $stream=$entry.Open()
    $stream.Write($payload,0,$payload.Length); $stream.Dispose()
    $archive.Dispose()
    $archive=[IO.Compression.ZipFile]::OpenRead($zipPath)
    $entry=$archive.Entries[0]
    $target=Join-Path $root 'payload'
    $progress=Start-LabActionProgress -Phase Extract -Now ([datetime]::UtcNow.AddSeconds(-6))
    $progress.Enabled=$true
    $output=@(Expand-LabProgressZipEntry -Entry $entry -Destination $target -Progress $progress)
    $expected=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payload))
    Assert-ArchiveProgress ($output.Count -eq 0 -and (Get-FileHash -LiteralPath $target).Hash -eq $expected) 'ZIP-Payload bleibt bytegleich und Erfolgsstream leer'
    Assert-ArchiveProgress ([IO.File]::GetLastWriteTimeUtc($target) -eq $entry.LastWriteTime.UtcDateTime) 'ZIP-Dateizeitpunkt bleibt erhalten'
    Assert-ArchiveProgress (@($reports | Where-Object {$_.Percent -gt 0 -and $_.Percent -lt 100}).Count -gt 0) 'ZIP meldet echte entpackte Zwischenbytes'
    Assert-ArchiveProgress (-not $progress.Completed) 'Ein Dateischritt beendet den gemeinsamen Archivreporter nicht'
    $rejected=$false
    try { Expand-LabProgressZipEntry -Entry $entry -Destination $target -Progress $progress } catch { $rejected=$true }
    Assert-ArchiveProgress ($rejected -and (Get-FileHash -LiteralPath $target).Hash -eq $expected) 'Vorhandene ZIP-Zieldatei wird weder ersetzt noch entfernt'
    $copyFunction=${function:Copy-LabProgressStream}
    function Copy-LabProgressStream { param($Source,$Destination,$Progress,$Length); $Destination.WriteByte(1); throw 'SYNTHETIC_ARCHIVE_FAILURE' }
    $partial=Join-Path $root 'partial'
    $rejected=$false
    try { Expand-LabProgressZipEntry -Entry $entry -Destination $partial -Progress $progress } catch { $rejected=$_.Exception.Message -eq 'SYNTHETIC_ARCHIVE_FAILURE' }
    Assert-ArchiveProgress ($rejected -and -not [IO.File]::Exists($partial)) 'Teilfehler entfernt ausschliesslich die neu erzeugte Datei'
    Set-Item Function:Copy-LabProgressStream -Value $copyFunction
    $native=Invoke-LabProgressNativeCommand -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','exit 0') -Phase Extract -Progress $progress
    Assert-ArchiveProgress ($native.ExitCode -eq 0 -and -not $progress.Completed) 'Native Archivphase bewahrt den gemeinsamen Reporter'
    Stop-LabActionProgress -Progress $progress
    Assert-ArchiveProgress ($reports[-1].Completed) 'Archivbesitzer beendet die Anzeige nach allen Schritten'
}
finally {
    if ($archive) { $archive.Dispose() }
    $resolved=[IO.Path]::GetFullPath($root)
    $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-archive-progress-*') { throw 'TEST_ARCHIVE_PROGRESS_CLEANUP_SCOPE_INVALID' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

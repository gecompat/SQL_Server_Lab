#Requires -Version 7.2
<#
.SYNOPSIS Prueft Streaming, Integritaet und Cleanup ohne VM oder grosse Dateien.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'Private/ConsoleUi.ps1')
. (Join-Path $repoRoot 'Private/ActionProgress.ps1')
. (Join-Path $repoRoot 'Private/TransferProgress.ps1')
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
$startProgress=${function:Start-LabActionProgress}
function Start-LabActionProgress {
    param($Phase)
    $context=& $startProgress -Phase $Phase -Now ([datetime]::UtcNow.AddSeconds(-6))
    $context.Enabled=$true
    $context
}
function Assert-Transfer {
    param([bool]$Condition,[string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Host "PASS: $Name"
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-transfer-' + [guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
try {
    $source=Join-Path $root 'source'
    $target=Join-Path $root 'target'
    $payload=[byte[]]::new(3MB + 7)
    for ($index=0; $index -lt $payload.Length; $index+=4096) { $payload[$index]=127 }
    [IO.File]::WriteAllBytes($source,$payload)
    [IO.File]::SetLastWriteTimeUtc($source,[datetime]'2020-01-01T00:00:00Z')
    $expected=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $output=@(Copy-LabProgressFile -LiteralPath $source -Destination $target)
    Assert-Transfer ($output.Count -eq 0 -and (Get-FileHash -LiteralPath $target).Hash -eq $expected) 'Mehrere Bloecke und Restbytes werden unveraendert kopiert'
    Assert-Transfer ([IO.File]::GetLastWriteTimeUtc($source) -eq [IO.File]::GetLastWriteTimeUtc($target)) 'Kopie bewahrt den Dateizeitpunkt'
    Assert-Transfer (@($reports | Where-Object {$_.Percent -gt 0 -and $_.Percent -lt 100}).Count -gt 0 -and $reports[-1].Completed) 'Kopierfortschritt stammt aus tatsaechlich geschriebenen Bytes'
    $reports.Clear()
    $observed=Get-LabProgressFileHash -LiteralPath $source
    Assert-Transfer ($observed.Hash -eq $expected -and $observed.Algorithm -eq 'SHA256' -and $observed.Path -eq $source) 'Streaming-Hash entspricht Get-FileHash'
    Assert-Transfer ($reports[-1].Completed -and @($reports | Where-Object {-not $_.Completed}).Count -gt 0) 'Hashphase meldet Fortschritt und wird beendet'
    $rejected=$false
    try { Copy-LabProgressFile -LiteralPath $source -Destination $target } catch { $rejected=$_.Exception.Message -eq 'LAB_TRANSFER_TARGET_EXISTS' }
    Assert-Transfer ($rejected -and (Get-FileHash -LiteralPath $target).Hash -eq $expected) 'Vorhandenes Ziel bleibt ohne Force unveraendert'
    $rejected=$false
    try { Copy-LabProgressFile -LiteralPath $source -Destination $source -Force } catch { $rejected=$_.Exception.Message -eq 'LAB_TRANSFER_SAME_FILE' }
    Assert-Transfer ($rejected -and (Get-FileHash -LiteralPath $source).Hash -eq $expected) 'Gleicher Quell- und Zielpfad wird vor Mutation abgewiesen'
    [IO.File]::WriteAllText($target,'synthetic-old-target')
    $oldTargetHash=(Get-FileHash -LiteralPath $target).Hash
    $originalStreamCopy=${function:Copy-LabProgressStream}
    function Copy-LabProgressStream { param($Source,$Destination,$Progress,$Length); $Destination.WriteByte(1); throw 'SYNTHETIC_TRANSFER_FAILURE' }
    $rejected=$false
    try { Copy-LabProgressFile -LiteralPath $source -Destination $target -Force } catch { $rejected=$_.Exception.Message -eq 'SYNTHETIC_TRANSFER_FAILURE' }
    Assert-Transfer ($rejected -and (Get-FileHash -LiteralPath $target).Hash -eq $oldTargetHash -and @(Get-ChildItem -LiteralPath $root -Force -Filter '.sql-lab-copy-*').Count -eq 0) 'Teilfehler erhaelt das alte Ziel und entfernt nur seine temporaere Kopie'
    Set-Item Function:Copy-LabProgressStream -Value $originalStreamCopy
    Copy-LabProgressFile -LiteralPath $source -Destination $target -Force
    Assert-Transfer ((Get-FileHash -LiteralPath $target).Hash -eq $expected) 'Wiederholung ersetzt das Ziel erst nach vollstaendigem Transfer'
    $empty=Join-Path $root 'empty'
    [IO.File]::WriteAllBytes($empty,[byte[]]::new(0))
    Assert-Transfer ((Get-LabProgressFileHash -LiteralPath $empty).Hash -eq (Get-FileHash -LiteralPath $empty).Hash) 'Leere Datei besitzt korrekten SHA-256'
    $hardlink=Join-Path $root 'hardlink'
    $null=New-Item -ItemType HardLink -Path $hardlink -Target $source
    Copy-LabProgressFile -LiteralPath $source -Destination $hardlink -Force
    Assert-Transfer ((Get-FileHash -LiteralPath $source).Hash -eq $expected -and (Get-FileHash -LiteralPath $hardlink).Hash -eq $expected) 'Atomare Ersetzung kann die Quelle ueber einen Hardlink nicht kuerzen'
}
finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-transfer-*') { throw 'TEST_TRANSFER_CLEANUP_SCOPE_INVALID' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

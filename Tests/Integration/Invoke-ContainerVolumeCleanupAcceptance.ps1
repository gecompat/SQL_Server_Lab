#Requires -Version 7.2
<#
.SYNOPSIS
    Belegt die labelgebundene Volume-Löschgrenze gegen eine echte Container-Runtime.
.DESCRIPTION
    Erstellt je ein test-eigenes und ein fremdes Runtime-Volume. Der Produktpfad
    muss das fremde Volume vor dem Remove-Aufruf ablehnen und darf ausschließlich
    das mit Run- und Scope-Label gebundene Volume entfernen. Beide Testvolumes
    werden im finally-Block explizit bereinigt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop
$failures = [Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

$mutexName = if ($IsWindows) { 'Global\SQL_Server_Lab_Runtime_Smoke' } else { 'SQL_Server_Lab_Runtime_Smoke' }
$mutex = [Threading.Mutex]::new($false, $mutexName)
$acquired = $false
$runtime = $null
$ownedName = $null
$foreignName = $null

function Test-VolumePresent {
    param([Parameter(Mandatory)][string]$Name)

    & $runtime volume inspect $Name 1>$null 2>$null
    return $LASTEXITCODE -eq 0
}

try {
    $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(10))
    if (-not $acquired) { throw 'CONTAINER_VOLUME_CLEANUP_MUTEX_TIMEOUT' }

    $resolution = & $module { param($p) Resolve-LabHostTool -Name $p } $Provider
    if (-not $resolution.Available) { throw "CONTAINER_VOLUME_CLEANUP_RUNTIME_UNAVAILABLE: $Provider" }
    $runtime = & $module { param($p) Get-LabHostToolInvocation -Name $p } $Provider

    $runId = [guid]::NewGuid().ToString('D')
    $scopeId = [guid]::NewGuid().ToString('D')
    $foreignRunId = [guid]::NewGuid().ToString('D')
    $suffix = ([guid]::NewGuid().ToString('N')).Substring(0, 12)
    $ownedName = "sql-lab-cleanup-owned-volume-$suffix"
    $foreignName = "sql-lab-cleanup-foreign-volume-$suffix"

    & $runtime volume create --label "sql-server-lab.run-id=$runId" --label "sql-server-lab.scope-id=$scopeId" $ownedName 1>$null
    if ($LASTEXITCODE -ne 0) { throw 'CONTAINER_VOLUME_CLEANUP_OWNED_CREATE_FAILED' }
    & $runtime volume create --label "sql-server-lab.run-id=$foreignRunId" --label "sql-server-lab.scope-id=$scopeId" $foreignName 1>$null
    if ($LASTEXITCODE -ne 0) { throw 'CONTAINER_VOLUME_CLEANUP_FOREIGN_CREATE_FAILED' }

    $foreignBlocked = $false
    try {
        & $module {
            param($p, $name, $expectedRun, $expectedScope)
            Remove-LabRuntimeResourceForCleanup -Provider $p -ResourceType volume -ResourceId $name -ExpectedRunId $expectedRun -ExpectedScopeId $expectedScope
        } $Provider $foreignName $runId $scopeId
    }
    catch { $foreignBlocked = $_.Exception.Message -match '^RUNTIME_VOLUME_OWNERSHIP_MISMATCH:' }
    Add-CheckResult -Name "$Provider blockiert die Löschung eines fremden Volumes" -Success ($foreignBlocked -and (Test-VolumePresent -Name $foreignName))

    & $module {
        param($p, $name, $expectedRun, $expectedScope)
        Remove-LabRuntimeResourceForCleanup -Provider $p -ResourceType volume -ResourceId $name -ExpectedRunId $expectedRun -ExpectedScopeId $expectedScope
    } $Provider $ownedName $runId $scopeId
    Add-CheckResult -Name "$Provider entfernt ausschließlich das eigene Volume" -Success (-not (Test-VolumePresent -Name $ownedName))
    $ownedName = $null

    & $runtime volume rm $foreignName 1>$null 2>$null
    Add-CheckResult -Name "$Provider bereinigt das geschützte Testvolume explizit" -Success ($LASTEXITCODE -eq 0 -and -not (Test-VolumePresent -Name $foreignName))
    $foreignName = $null
}
finally {
    foreach ($name in @($ownedName, $foreignName) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
        if ($runtime) { & $runtime volume rm $name 1>$null 2>$null }
    }
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) { exit 1 }

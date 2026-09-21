#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft synthetisches SQL-2025-PITR auf einem neuen eigenen Docker-/Podman-Run.
.DESCRIPTION
    Der Parent begrenzt Arrange und Cleanup in getrennten verborgenen Prozessen.
    Rohmeldungen und Recovery-State bleiben lokal. Nur feste Statuscodes gelangen
    in CI. Vorhandene Datenbanken, Backups und Runs sind keine Eingabeparameter.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [ValidateSet('2025')][string]$Version='2025',
    [ValidateRange(60,1800)][int]$TimeoutSeconds=900,
    [switch]$RuntimeMutexAlreadyHeld
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/PointInTimeRecoverySupervisor.ps1')
$mutex=$null; $acquired=$false; $failed=$true
try {
    if (-not $RuntimeMutexAlreadyHeld) {
        $name=if ($IsWindows) { 'Global\SQL_Server_Lab_Runtime_Smoke' } else { 'SQL_Server_Lab_Runtime_Smoke' }
        $mutex=[Threading.Mutex]::new($false,$name)
        try { $acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10)) }
        catch [Threading.AbandonedMutexException] { $acquired=$true }
        if (-not $acquired) { throw 'PITR_LOCK_TIMEOUT' }
    }
    $root=New-PitrSupervisorRoot
    $operation=[guid]::NewGuid().ToString('N')
    $result=Invoke-PitrSupervisor -AcceptanceRunner (Join-Path $PSScriptRoot 'Invoke-PointInTimeRecoveryChild.ps1') `
        -Provider $Provider -StateRoot (Join-Path $root 'state') -OperationId $operation -EvidenceRoot $root -TimeoutSeconds $TimeoutSeconds
    Write-Host ('PITR: '+$result.Status+'; PRIMARY='+$result.PrimaryReason+
        '; CLEANUP='+$result.CleanupStatus+'; CLEANUP_REASON='+$result.CleanupReason)
    $failed=$result.Status -cne 'COMPLETED'
}
catch { Write-Host 'PITR: FAILED; PRIMARY=SUPERVISOR_FAILED; LOCAL_RECOVERY_EVIDENCE_REQUIRED' }
finally {
    if ($mutex) { if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
if ($failed) { exit 1 }
exit 0

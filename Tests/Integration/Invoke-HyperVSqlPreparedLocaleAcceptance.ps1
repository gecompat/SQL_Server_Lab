#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft US-Locale und SQL nach Kaltstart eines eigenen Prepared-Manifest-Childs.
.DESCRIPTION
    Nutzt ausschließlich ein explizites verifiziertes englisches SQL-2025-Artifact.
    Operations-, Run-, Scope- und VM-ID-Bindungen gelten vor jeder Kaltstartgrenze.
    Gast- und SQL-Proben bleiben zeitlich begrenzt. Der Parent bleibt unverändert;
    jeder begonnene Arrange erhält ausschließlich operationseigenen Cleanup.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^hyperv-sql-prepared-sealed-[a-f0-9]{64}$')][string]$ArtifactId,
    [string]$StateRoot,
    [ValidateScript({ $_ -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -and [guid]$_ -ne [guid]::Empty })]
    [string]$OperationId=([guid]::NewGuid().ToString('D')),
    [switch]$DeferCleanup,
    [switch]$CleanupOnly
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'PREPARED_LOCALE_ELEVATED_RUNNER_REQUIRED'
}
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke')
$acquired=$false
try {
    try { $acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10)) }
    catch [Threading.AbandonedMutexException] { $acquired=$true }
    if (-not $acquired) { throw 'PREPARED_LOCALE_LOCK_TIMEOUT' }
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $workingDirectory=Join-Path $repoRoot ('.artifacts/test-runs/prepared-locale-'+$OperationId)
    & $module {
        param($Repo,$Id,$Root,$Operation,$Work,$Defer,$Cleanup)
        . (Join-Path $Repo 'Tests/Common/HyperVPreparedLocaleAcceptance.ps1')
        if (-not $Root) { $Root=Get-LabStateRoot }
        if ($Cleanup) { Remove-HyperVPreparedLocaleOwnRun -OperationId $Operation -StateRoot $Root }
        else {
            Invoke-HyperVPreparedLocaleScenario -ArtifactId $Id -StateRoot $Root -OperationId $Operation -WorkingDirectory $Work -DeferCleanup:$Defer
        }
    } $repoRoot $ArtifactId $StateRoot $OperationId $workingDirectory $DeferCleanup $CleanupOnly | Out-Null
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
if ($CleanupOnly) { Write-Host 'HYPERV SQL PREPARED LOCALE CLEANUP: PASS' }
else { Write-Host 'HYPERV SQL PREPARED LOCALE ACCEPTANCE: PASS' }

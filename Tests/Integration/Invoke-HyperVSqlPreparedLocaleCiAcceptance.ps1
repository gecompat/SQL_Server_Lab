#Requires -Version 7.2
<#
.SYNOPSIS
    Bindet die manuelle Prepared-Locale-Abnahme an Repository und exakten Checkout.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArtifactId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StateRoot,
    [ValidateRange(60,7200)][int]$RunnerTimeoutSeconds=5400
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/HyperVPreparedLocaleAcceptance.ps1')
. (Join-Path $repoRoot 'Tests/Common/HyperVPreparedLocaleSupervisor.ps1')
$checkout=@(& git -C $repoRoot rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or $checkout.Count -ne 1) { throw 'PREPARED_LOCALE_CHECKOUT_UNAVAILABLE' }
Assert-HyperVPreparedLocaleDispatch -Context ([pscustomobject]@{
    EventName=$env:GITHUB_EVENT_NAME; EventRepository=$env:SQL_SERVER_LAB_CI_EVENT_REPOSITORY
    Repository=$env:GITHUB_REPOSITORY; ExpectedCommit=$env:GITHUB_SHA; CheckoutCommit=([string]$checkout[0]).Trim()
    ArtifactId=$ArtifactId; CloneSourceRunId=$env:SQL_SERVER_LAB_CI_CLONE_SOURCE_RUN_ID
})
$operationId=[guid]::NewGuid().ToString('D')
try {
    $evidence=New-HyperVPreparedLocaleSupervisorRoot
    $result=Invoke-HyperVPreparedLocaleSupervisor -AcceptanceRunner (Join-Path $PSScriptRoot 'Invoke-HyperVSqlPreparedLocaleAcceptance.ps1') `
        -ArtifactId $ArtifactId -StateRoot ([IO.Path]::GetFullPath($StateRoot)) -OperationId $operationId `
        -EvidenceRoot $evidence -TimeoutSeconds $RunnerTimeoutSeconds
    # These values are constructed from closed enums, never native output or exception text.
    Write-Host ('PREPARED_LOCALE_CI: '+$result.Status+'; PRIMARY='+$result.PrimaryReason+
        '; CLEANUP='+$result.CleanupStatus+'; CLEANUP_REASON='+$result.CleanupReason)
    if ($result.Status -cne 'COMPLETED') { throw 'PREPARED_LOCALE_CI_FAILED' }
}
catch { throw 'PREPARED_LOCALE_CI_FAILED_LOCAL_RECOVERY_EVIDENCE' }

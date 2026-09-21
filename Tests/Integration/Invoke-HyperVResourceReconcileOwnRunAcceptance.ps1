#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ArtifactId,[string]$StateRoot)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/HyperVResourceReconcileOwnRunAcceptance.ps1')
if([string]::IsNullOrWhiteSpace([string]$env:RUNNER_TEMP)){throw 'HYPERV_RESOURCE_OWN_RUN_RECEIPT_ROOT_MISSING'}
$checkoutOutput=& git -C $repoRoot rev-parse HEAD
if($LASTEXITCODE -ne 0){throw 'HYPERV_RESOURCE_OWN_RUN_CHECKOUT_UNAVAILABLE'}
$checkoutCommit=([string]$checkoutOutput).Trim().ToLowerInvariant()
$guard=Assert-HyperVResourceReconcileOwnRunAcceptanceGuard -Context ([pscustomobject]@{EventName=[string]$env:GITHUB_EVENT_NAME;EventRepository=[string]$env:SQL_SERVER_LAB_CI_EVENT_REPOSITORY;Repository=[string]$env:GITHUB_REPOSITORY;ExpectedCommit=[string]$env:GITHUB_SHA;CheckoutCommit=$checkoutCommit;ArtifactId=$ArtifactId;CloneSourceRunId=[string]$env:SQL_SERVER_LAB_CI_CLONE_SOURCE_RUN_ID})
$receiptPath=Join-Path $env:RUNNER_TEMP 'sql-server-lab-hyperv-resource-own-run-receipt.json'
$null=Write-HyperVResourceReconcileOwnRunReceipt -Path $receiptPath -ArtifactId $guard.ArtifactId -CheckoutCommit $guard.CheckoutCommit -Status PREPARED
& (Join-Path $PSScriptRoot 'Invoke-HyperVResourceReconcileCiAcceptance.ps1') -ArtifactId $guard.ArtifactId -StateRoot $StateRoot
$null=Write-HyperVResourceReconcileOwnRunReceipt -Path $receiptPath -ArtifactId $guard.ArtifactId -CheckoutCommit $guard.CheckoutCommit -Status COMPLETED
[pscustomobject]@{Contract='SqlServerLab.HyperVResourceReconcileOwnRunAcceptance/1.0';Status='PASSED';ArtifactId=$guard.ArtifactId;CheckoutCommit=$guard.CheckoutCommit;ReceiptPath=$receiptPath}

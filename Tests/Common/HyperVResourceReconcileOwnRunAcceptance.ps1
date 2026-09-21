function Assert-HyperVResourceReconcileOwnRunAcceptanceGuard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context
    )
    foreach($name in @('EventName','EventRepository','Repository','ExpectedCommit','CheckoutCommit','ArtifactId','CloneSourceRunId')) {
        if(-not $Context.PSObject.Properties[$name]) { throw "HYPERV_RESOURCE_OWN_RUN_CONTEXT_PROPERTY_MISSING: $name" }
    }
    if([string]$Context.EventName -cne 'workflow_dispatch') { throw 'HYPERV_RESOURCE_OWN_RUN_MANUAL_DISPATCH_REQUIRED' }
    if([string]::IsNullOrWhiteSpace([string]$Context.EventRepository) -or [string]$Context.EventRepository -cne [string]$Context.Repository) { throw 'HYPERV_RESOURCE_OWN_RUN_REPOSITORY_MISMATCH' }
    if(-not [string]::IsNullOrWhiteSpace([string]$Context.CloneSourceRunId)) { throw 'HYPERV_RESOURCE_OWN_RUN_CLONE_SOURCE_FORBIDDEN' }
    if([string]$Context.ArtifactId -cnotmatch '^hyperv-sql-prepared-sealed-[a-f0-9]{64}$') { throw 'HYPERV_RESOURCE_OWN_RUN_EXPLICIT_PREPARED_ARTIFACT_REQUIRED' }
    if([string]$Context.ExpectedCommit -cnotmatch '^[a-f0-9]{40}$' -or [string]$Context.CheckoutCommit -cnotmatch '^[a-f0-9]{40}$' -or [string]$Context.ExpectedCommit -cne [string]$Context.CheckoutCommit) { throw 'HYPERV_RESOURCE_OWN_RUN_CHECKOUT_COMMIT_MISMATCH' }
    [PSCustomObject]@{ArtifactId=[string]$Context.ArtifactId;CheckoutCommit=[string]$Context.CheckoutCommit}
}

function Write-HyperVResourceReconcileOwnRunReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ArtifactId,[Parameter(Mandatory)][string]$CheckoutCommit,[Parameter(Mandatory)][ValidateSet('PREPARED','COMPLETED')][string]$Status)
    $receipt=[ordered]@{contract='SqlServerLab.HyperVResourceReconcileOwnRunReceipt/1.0';status=$Status;artifactId=$ArtifactId;checkoutCommit=$CheckoutCommit}
    [IO.File]::WriteAllText($Path,($receipt|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    return $receipt
}

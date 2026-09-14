# Prozessvertrag mit synthetischen Daten; keine Providerressourcen.
param([Parameter(Mandatory)][string]$CiPath)
$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile($CiPath,[ref]$null,[ref]$null)
foreach($name in @('New-HyperVResourceReconcileCiSupervisorRoot','Test-HyperVResourceReconcileCiStageReceipt','Stop-HyperVResourceReconcileCiChildProcessTree','Invoke-HyperVResourceReconcileCiSupervisor')){
    $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($f.Extent.Text))
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-slot-supervisor-contract-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
try {
    $runner=Join-Path $root 'synthetic-runner.ps1'
    @'
param($ArtifactId,$CloneSourceRunId,$MediaRoot,$MediaEdition,$StateRoot,$Run1OperationId,$Run2OperationId,[switch]$DeferCleanup)
if($ArtifactId -or $CloneSourceRunId -ne '11111111-1111-1111-1111-111111111111' -or $MediaRoot -ne $StateRoot -or $MediaEdition -ne 'Eval' -or -not $DeferCleanup -or $Run1OperationId -ne 'github-1-1-resource-r1' -or $Run2OperationId -ne 'github-1-1-resource-r2'){
    throw 'HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_INITIALIZATION_FAILED'
}
$global:LASTEXITCODE=0
'@ | Set-Content -LiteralPath $runner -Encoding utf8
    $result=Invoke-HyperVResourceReconcileCiSupervisor -AcceptanceRunner $runner -ArtifactId '' -CloneSourceRunId '11111111-1111-1111-1111-111111111111' -MediaRoot $root -MediaEdition Eval -StateRoot $root -Run1OperationId github-1-1-resource-r1 -Run2OperationId github-1-1-resource-r2 -TimeoutSeconds 20 -Synthetic
    if($result.Status -ne 'COMPLETED' -or -not $result.TerminationConfirmed){throw 'SLOT_SUPERVISOR_SUCCESS_CONTRACT_FAILED'}
    $receipt=Join-Path $root 'receipt.json'
    @{status='COMPLETED';stage='RUNNER_COMPLETED';reasonCode='HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_STAGE_INITIALIZATION_FAILED';activationReasonCode=$null;provisionReasonCode=$null}|ConvertTo-Json|Set-Content $receipt
    if(Test-HyperVResourceReconcileCiStageReceipt $receipt){throw 'SLOT_SUPERVISOR_INCONSISTENT_SUCCESS_ACCEPTED'}
    $true
} finally {
    $expected=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) (Split-Path $root -Leaf)))
    if($expected -cne [IO.Path]::GetFullPath($root) -or (Split-Path $root -Leaf) -notlike 'sql-lab-slot-supervisor-contract-*'){throw 'SLOT_SUPERVISOR_FIXTURE_CLEANUP_SCOPE_INVALID'}
    Remove-Item -LiteralPath $root -Recurse -Force
}

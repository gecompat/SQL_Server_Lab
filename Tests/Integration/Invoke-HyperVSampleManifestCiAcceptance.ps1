#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Fuehrt die manuelle, operationsgebundene CI-Akzeptanz fuer Hyper-V-Sample-Manifeste aus.
.DESCRIPTION
    Der CI-Einstieg akzeptiert keine Run-ID, keine Clone-Quelle und keinen freien
    Testdatenpfad. Er bindet die zwei sequenziellen frischen Runs an abgeleitete
    Workflow-Operations-IDs. Auf Erfolg und Fehlern werden nur exakt dazu passende
    Hyper-V-Runs mit valide gebundenem Cleanup-Plan entfernt.
#>
[CmdletBinding()]
param([string]$ArtifactId,[string]$StateRoot)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath=Join-Path $repoRoot 'SqlServerLab.psd1'
$acceptanceRunner=Join-Path $PSScriptRoot 'Invoke-HyperVSampleManifestAcceptance.ps1'
$operationId=[string]$env:SQL_SERVER_LAB_TEST_OPERATION_ID
$module=$null;$primaryFailure=$null;$cleanupFailure=$null;$previousStateRoot=$env:SQL_SERVER_LAB_STATE
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_HyperV_Sample_Manifest_CI_Acceptance');$mutexAcquired=$false

function Assert-HyperVSampleManifestCiAcceptance {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$ReasonCode)
    if(-not $Condition){throw $ReasonCode}
}
function Get-HyperVSampleManifestCiOwnedRun {
    param([Parameter(Mandatory)]$Module,[Parameter(Mandatory)][string]$OperationId,[Parameter(Mandatory)][string]$StateRoot)
    & $Module {
        param($ExpectedOperationId,$Root)
        $owned=Get-LabOperationOwnedRun -OperationId $ExpectedOperationId -StateRoot $Root
        if(-not $owned){return $null}
        if([string]$owned.runId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
           [string]$owned.scopeId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
           [string]$owned.metadata.workflowOperationId -cne $ExpectedOperationId -or
           (-not [string]::IsNullOrWhiteSpace([string]$owned.metadata.workflowKind) -and [string]$owned.metadata.workflowKind -cne 'hyperv-lab')){throw 'HYPERV_SAMPLE_MANIFEST_CI_OWNED_RUN_STATE_INVALID'}
        $subRuns=@(Get-LabProviderSubRuns -RunId ([string]$owned.runId) -StateRoot $Root)
        if($subRuns.Count -ne 1 -or [string]$subRuns[0].provider -cne 'hyperv'){throw 'HYPERV_SAMPLE_MANIFEST_CI_OWNED_RUN_PROVIDER_INVALID'}
        $runDirectory=Join-Path (Join-Path $Root 'runs') ([string]$owned.runId)
        $plan=Get-CleanupPlan -RunDir $runDirectory
        $vmSteps=@($plan.steps|Where-Object{[string]$_.resourceType -eq 'vm'})
        if([string]$plan.runId -cne [string]$owned.runId -or [string]$plan.scopeId -cne [string]$owned.scopeId -or
           @($plan.steps|Where-Object{[string]$_.provider -ne 'hyperv' -or [string]$_.resourceType -notin @('vm','vhdx','ipam-lease')}).Count -gt 0 -or $vmSteps.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$vmSteps[0].resourceId)){throw 'HYPERV_SAMPLE_MANIFEST_CI_OWNED_RUN_CLEANUP_PLAN_INVALID'}
        $plannedVmName=[string]$vmSteps[0].resourceId
        $connectionPath=Join-Path $runDirectory 'connection-info.json'
        if(Test-Path -LiteralPath $connectionPath -PathType Leaf){
            $context=Get-HyperVLabWorkflowRun -RunId ([string]$owned.runId) -StateRoot $Root
            if([string]$context.Run.scopeId -cne [string]$owned.scopeId -or [string]$context.Instance.provider -cne 'hyperv' -or [string]::IsNullOrWhiteSpace([string]$context.Instance.vmName) -or [string]::IsNullOrWhiteSpace([string]$context.Instance.vmId)){throw 'HYPERV_SAMPLE_MANIFEST_CI_OWNED_RUN_CONNECTION_INVALID'}
            $contextVmId=[guid]::Empty
            if([string]$context.Instance.vmName -cne $plannedVmName -or -not [guid]::TryParse([string]$context.Instance.vmId,[ref]$contextVmId)){throw 'HYPERV_SAMPLE_MANIFEST_CI_OWNED_VM_OWNERSHIP_INVALID'}
            $managed=Get-HyperVManagedVM -VMName $plannedVmName -ExpectedRunId ([string]$owned.runId) -ExpectedScopeId ([string]$owned.scopeId)
            if(-not $managed -or [string]$managed.VM.Id -cne $contextVmId.ToString()){throw 'HYPERV_SAMPLE_MANIFEST_CI_OWNED_VM_OWNERSHIP_INVALID'}
        } else {
            $existingVm=@(Get-VM -Name $plannedVmName -ErrorAction SilentlyContinue)
            if($existingVm.Count -ne 0 -and -not (Get-HyperVManagedVM -VMName $plannedVmName -ExpectedRunId ([string]$owned.runId) -ExpectedScopeId ([string]$owned.scopeId))){throw 'HYPERV_SAMPLE_MANIFEST_CI_OWNED_VM_OWNERSHIP_INVALID'}
        }
        [pscustomobject]@{RunId=[string]$owned.runId;ScopeId=[string]$owned.scopeId;VmName=$plannedVmName;VhdxPaths=@($plan.steps|Where-Object{[string]$_.resourceType -eq 'vhdx'}|ForEach-Object{[string]$_.resourceId}|Where-Object{$_})}
    } $OperationId $StateRoot
}
function Invoke-HyperVSampleManifestCiCleanup {
    param([Parameter(Mandatory)]$Module,[Parameter(Mandatory)][string]$OperationId,[Parameter(Mandatory)][string]$StateRoot)
    $owned=Get-HyperVSampleManifestCiOwnedRun -Module $Module -OperationId $OperationId -StateRoot $StateRoot
    if(-not $owned){return $null}
    $result=& $Module {param($RunId,$Root)Remove-SqlServerLab -RunId $RunId -StateRoot $Root -Force -Confirm:$false} $owned.RunId $StateRoot
    if([string]$result.RunId -cne $owned.RunId -or [string]$result.Status -notin @('REMOVED','COMPLETED','ALREADY_REMOVED')){throw 'HYPERV_SAMPLE_MANIFEST_CI_OWNED_RUN_CLEANUP_FAILED'}
    & $Module {param($CleanupOwned)if(@(Get-VM -Name $CleanupOwned.VmName -ErrorAction SilentlyContinue).Count -ne 0){throw 'HYPERV_SAMPLE_MANIFEST_CI_CLEANUP_VM_POSTCONDITION_FAILED'};foreach($path in @($CleanupOwned.VhdxPaths|Sort-Object -Unique)){if(Test-Path -LiteralPath $path){throw 'HYPERV_SAMPLE_MANIFEST_CI_CLEANUP_VHDX_POSTCONDITION_FAILED'}}} $owned
    return $result
}

try {
    Assert-HyperVSampleManifestCiAcceptance ($operationId -match '^github-[0-9]+-[0-9]+$') 'HYPERV_SAMPLE_MANIFEST_CI_OPERATION_CONTEXT_INVALID'
    $run1OperationId="$operationId-sample-r1";$run2OperationId="$operationId-sample-r2"
    $mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(15));Assert-HyperVSampleManifestCiAcceptance $mutexAcquired 'HYPERV_SAMPLE_MANIFEST_CI_HOST_LOCK_TIMEOUT'
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());Assert-HyperVSampleManifestCiAcceptance $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) 'HYPERV_SAMPLE_MANIFEST_CI_RUNNER_NOT_ELEVATED'
    Get-Command Get-VM -ErrorAction Stop|Out-Null
    $module=Import-Module $modulePath -Force -PassThru
    if(-not $StateRoot){$StateRoot=& $module {Get-LabStateRoot}};$env:SQL_SERVER_LAB_STATE=$StateRoot
    if($ArtifactId){$artifact=& $module {param($Id,$Root)Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root} $ArtifactId $StateRoot}
    else {$artifact=& $module {param($Root)@(Get-HyperVImageArtifact -StateRoot $Root|Where-Object{[string]$_.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$_.sql.version -eq '2025' -and [string]$_.licenseType -ne 'test-only'}|Sort-Object{[datetime]$_.registeredAt} -Descending|Select-Object -First 1)[0]} $StateRoot}
    Assert-HyperVSampleManifestCiAcceptance ([bool]$artifact) 'HYPERV_SAMPLE_MANIFEST_CI_SQL_PREPARED_ARTIFACT_INVALID'
    $eligibility=& $module {param($Candidate)[pscustomobject]@{Evaluation=Test-HyperVImageArtifactEvaluationEligibility -Artifact $Candidate;Child=Test-HyperVImageArtifactChildValidationEligibility -Artifact $Candidate}} $artifact
    Assert-HyperVSampleManifestCiAcceptance ([string]$artifact.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$artifact.sql.version -eq '2025' -and [string]$artifact.integrityVerification.status -in @('VERIFIED_CACHE','VERIFIED_HASH') -and [bool]$eligibility.Evaluation.Eligible -and [bool]$eligibility.Child.Eligible) 'HYPERV_SAMPLE_MANIFEST_CI_SQL_PREPARED_ARTIFACT_INVALID'
    $arguments=@{ArtifactId=[string]$artifact.artifactId;StateRoot=$StateRoot;Run1OperationId=$run1OperationId;Run2OperationId=$run2OperationId}
    $runnerOutput=@(& $acceptanceRunner @arguments *>&1)
    if($LASTEXITCODE -ne 0 -or @($runnerOutput|Where-Object{$_ -is [Management.Automation.ErrorRecord]}).Count -gt 0){throw 'HYPERV_SAMPLE_MANIFEST_CI_RUNNER_FAILED'}
    Write-Host 'PASS: Isolierte Hyper-V-Mehrfach-Sample-Manifest-Akzeptanz wurde ausgefuehrt.' -ForegroundColor Green
}
catch{$primaryFailure=$_}
finally {
    if($module){
        foreach($childOperationId in @("$operationId-sample-r1","$operationId-sample-r2")){
            try{$null=Invoke-HyperVSampleManifestCiCleanup -Module $module -OperationId $childOperationId -StateRoot $StateRoot}
            catch{$cleanupFailure=$_;break}
        }
    }
    if([string]::IsNullOrWhiteSpace($previousStateRoot)){Remove-Item Env:SQL_SERVER_LAB_STATE -ErrorAction SilentlyContinue}else{$env:SQL_SERVER_LAB_STATE=$previousStateRoot}
    if($module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue};if($mutexAcquired){$mutex.ReleaseMutex()};$mutex.Dispose()
}
if($primaryFailure){Write-Host 'HYPERV_SAMPLE_MANIFEST_CI_FAILURE_KIND=PRIMARY' -ForegroundColor Red}
if($cleanupFailure){Write-Host 'HYPERV_SAMPLE_MANIFEST_CI_FAILURE_KIND=CLEANUP' -ForegroundColor Red}
if($primaryFailure -and $cleanupFailure){throw 'HYPERV_SAMPLE_MANIFEST_CI_EXECUTION_AND_CLEANUP_FAILED'}
if($primaryFailure){throw 'HYPERV_SAMPLE_MANIFEST_CI_EXECUTION_FAILED'}
if($cleanupFailure){throw 'HYPERV_SAMPLE_MANIFEST_CI_CLEANUP_FAILED'}
Write-Host 'Native Hyper-V-Mehrfach-Sample-Manifest-CI-Akzeptanz erfolgreich.' -ForegroundColor Green

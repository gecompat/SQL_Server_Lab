#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop';$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$path=Join-Path $repoRoot 'Tests/Integration/Invoke-HyperVSqlStorageReconcileAcceptance.ps1';$workflow=Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv.yml';$source=Get-Content $path -Raw -Encoding utf8;$errors=$null;$runnerAst=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
# Execute only the runner's pure comparison block; never bootstrap Hyper-V here.
$comparisonStart=$source.IndexOf('    $expected=@($receiptAfter.FileBindings)')
$comparisonEnd=$source.IndexOf('    $resultOk=', $comparisonStart)
if($comparisonStart -lt 0 -or $comparisonEnd -le $comparisonStart){throw 'Acceptance comparison block not found'}
$comparison=[scriptblock]::Create($source.Substring($comparisonStart,$comparisonEnd-$comparisonStart)+"`n[pscustomobject]@{Defaults=`$defaultsOk;TempDb=`$tempOk}")
function Test-ComparisonCase {
 param([string]$Case)
 $bindings=@(
  [pscustomobject]@{Role='default-data';SqlPhysicalPath='F:\SQLData'}
  [pscustomobject]@{Role='default-log';SqlPhysicalPath='F:\SQLLog'}
  [pscustomobject]@{Role='backup';SqlPhysicalPath='F:\Backup'}
  [pscustomobject]@{Role='tempdb-data';LogicalName='tempdev';SqlPhysicalPath='F:\Temp\tempdb.mdf'}
  [pscustomobject]@{Role='tempdb-log';LogicalName='templog';SqlPhysicalPath='F:\Temp\templog.ldf'}
 )
 $receiptAfter=[pscustomobject]@{FileBindings=$bindings}
 $after=[pscustomobject]@{Defaults=[pscustomobject]@{DefaultData='f:\SQLData\';DefaultLog='F:\SQLLog\';BackupDirectory='F:\Backup'};TempDb=@($bindings|Where-Object Role -like 'tempdb-*'|ForEach-Object{[pscustomobject]@{LogicalName=$_.LogicalName;SqlPhysicalPath=$_.SqlPhysicalPath}})}
 switch($Case){
  'WrongDefault' {$after.Defaults.DefaultData='F:\Other'}
  'EmptyDefault' {$bindings[0].SqlPhysicalPath='';$after.Defaults.DefaultData=''}
  'MissingTempDb' {$after.TempDb=@($after.TempDb[0])}
  'DuplicateTempDb' {$after.TempDb+= $after.TempDb[0]}
  'WrongTempDb' {$after.TempDb[0].SqlPhysicalPath='F:\Other\tempdb.mdf'}
 }
 & $comparison
}
$valid=Test-ComparisonCase 'Valid'
. (Join-Path $PSScriptRoot '../Common/HyperVStorageAcceptanceRecoveryFixture.ps1')
$workflowSource=Get-Content -LiteralPath $workflow -Raw -Encoding utf8
$dispatchStart=$workflowSource.IndexOf('$libraryRestore = $env:SQL_SERVER_LAB_CI_VERIFY_LIBRARY_RESTORE')
$dispatchEnd=$workflowSource.IndexOf('.\Tests\Integration\Invoke-HyperVSqlStorageReconcileAcceptance.ps1 @arguments',$dispatchStart)
if($dispatchStart -lt 0 -or $dispatchEnd -le $dispatchStart){throw 'Library restore dispatch input binding missing'}
$dispatch=[scriptblock]::Create($workflowSource.Substring($dispatchStart,$dispatchEnd-$dispatchStart)+[Environment]::NewLine+'$arguments')
function Test-StorageAcceptanceDispatch {
    param([string]$Prepared,[string]$Clone,[string]$Media,[bool]$Restore,[switch]$Guided,[switch]$SsisCatalog)
    $values=[ordered]@{PREPARED_ARTIFACT_ID=$Prepared;CLONE_SOURCE_RUN_ID=$Clone;MEDIA_ROOT=$Media;MEDIA_EDITION='Enterprise';VERIFY_LIBRARY_RESTORE=$Restore.ToString().ToLowerInvariant();VERIFY_GUIDED_DATABASE_SCRIPT=$Guided.IsPresent.ToString().ToLowerInvariant();VERIFY_SSIS_CATALOG_CAPABILITY=$SsisCatalog.IsPresent.ToString().ToLowerInvariant()}
    $previous=@{}
    try {
        foreach($entry in $values.GetEnumerator()){
            $name='SQL_SERVER_LAB_CI_'+$entry.Key
            $previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
            [Environment]::SetEnvironmentVariable($name,$entry.Value,'Process')
        }
        return & $dispatch
    } catch {
        return $_.Exception.Message
    } finally {
        foreach($name in $previous.Keys){[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')}
    }
}
$artifact='hyperv-sql-prepared-sealed-'+('a'*64)
$preparedArguments=Test-StorageAcceptanceDispatch -Prepared $artifact -Restore $true
$defaultMedia=[regex]::Match($workflowSource,'(?ms)^  workflow_dispatch:\r?\n.*?^      media_root:\r?\n.*?^        default: (?<Default>[^\r\n]+)')
if (-not $defaultMedia.Success) { throw 'Prepared workflow dispatch default missing' }
$preparedDefaultArguments=Test-StorageAcceptanceDispatch -Prepared $artifact -Media $defaultMedia.Groups['Default'].Value -Restore $true
$cloneArguments=Test-StorageAcceptanceDispatch -Clone synthetic-slot -Media synthetic-media -Restore $false
$guidedArguments=Test-StorageAcceptanceDispatch -Prepared $artifact -Guided
$guidedMissingArtifact=Test-StorageAcceptanceDispatch -Clone synthetic-slot -Guided
$guidedConflicting=Test-StorageAcceptanceDispatch -Prepared $artifact -Guided -Restore $true
$guidedCustomMedia=Test-StorageAcceptanceDispatch -Prepared $artifact -Guided -Media synthetic-media
$ssisArguments=Test-StorageAcceptanceDispatch -Prepared $artifact -SsisCatalog
$ssisMissingArtifact=Test-StorageAcceptanceDispatch -Clone synthetic-slot -SsisCatalog
$ssisAmbiguous=Test-StorageAcceptanceDispatch -Prepared $artifact -SsisCatalog -Guided
# Run the actual prepared-manifest transformation without touching a VM or a file.
$manifestStart = $source.IndexOf('    $manifest = Get-Content -LiteralPath $ManifestPath')
$manifestEnd = $source.IndexOf('    $preparedPath = Join-Path $testRoot', $manifestStart)
if ($manifestStart -lt 0 -or $manifestEnd -le $manifestStart) { throw 'Prepared manifest transformation not found' }
$prepareManifest = [scriptblock]::Create($source.Substring($manifestStart,$manifestEnd-$manifestStart) + '$manifest')
$preparedManifest = & {
    $ManifestPath = 'synthetic-manifest.json'
    $PreparedArtifactId = $artifact
    $network = [pscustomobject]@{Name='synthetic-switch'}
    function Get-Content {
        param([string]$LiteralPath,[switch]$Raw,[string]$Encoding)
        if ($LiteralPath -cne $ManifestPath -or -not $Raw -or $Encoding -cne 'utf8') { throw 'Synthetic manifest binding changed' }
        '{"instances":[{"storageIntent":{"placementPolicy":"logical-only","roles":{"backup":{"selector":"default"}}},"hyperv":{},"windowsActivation":{"Strategy":"VerifyOnly","EgressPolicy":"Denied"}}]}'
    }
    & $prepareManifest
}
$preparedInstance = $preparedManifest.instances[0]
$libraryLocator = $runnerAst.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-LabBackupLibraryPaths'
}, $true)
if (-not $libraryLocator) { throw 'Scoped fixture library locator not found' }
$testModule = New-Module -ScriptBlock {
    function Resolve-LabDataRootForUse { param([string]$DataRoot) "resolved-$DataRoot" }
    function Get-LabBackupLibraryPaths { 'original-locator' }
    function Read-ScopedBackupPaths { param([string]$DataRoot) Get-LabBackupLibraryPaths -DataRoot $DataRoot }
}
$libraryScope = & $testModule {
    param([scriptblock]$Locator)
    $registeredDataRoot = 'resolved-current'
    $libraryRoot = Join-Path ([IO.Path]::GetTempPath()) 'synthetic-restore-library'
    . $Locator
    $paths = Read-ScopedBackupPaths -DataRoot current
    $rejected = try { $null = Read-ScopedBackupPaths -DataRoot another; $false }
        catch { $_.Exception.Message -ceq 'HYPERV_LIBRARY_RESTORE_ACCEPTANCE_LIBRARY_SCOPE_INVALID' }
    $rejected -and $paths.DataRoot -ceq $registeredDataRoot -and $paths.LibraryRoot -ceq $libraryRoot -and
        $paths.RegistryPath -ceq (Join-Path $libraryRoot 'backup-library.json') -and
        $paths.ObjectsRoot -ceq (Join-Path $libraryRoot 'Objects')
} ([scriptblock]::Create($libraryLocator.Extent.Text))
$locatorRestored = (& $testModule { Read-ScopedBackupPaths -DataRoot current }) -ceq 'original-locator'
$checks=[ordered]@{
 'Fixture uses only the private backup path while preserving registered-root validation and the original locator'=($libraryScope -and $locatorRestored -and $source -notmatch 'SQL_SERVER_LAB_DATA_ROOT')
 'Prepared manifest preserves backup storage intent and binds only the approved artifact and network'=($preparedInstance.storageIntent.roles.backup.selector -ceq 'default' -and
    $preparedInstance.storageIntent.placementPolicy -ceq 'logical-only' -and $preparedInstance.hyperv.preparedImageId -ceq $artifact -and
    $preparedInstance.hyperv.switchName -ceq 'synthetic-switch' -and $preparedInstance.windowsActivation.Strategy -ceq 'NotRequested' -and
    $preparedInstance.windowsActivation.EgressPolicy -ceq 'Denied')
 'Early clone failure recovers only this operation; unowned, absent and ambiguous runs remain fail-closed'=(Test-HyperVStorageAcceptanceRecovery -RunnerPath $path)
 'Directory delimiters and case do not reject converged SQL paths'=($valid.Defaults -and $valid.TempDb)
 'Different and empty default directories remain rejected'=(-not (Test-ComparisonCase 'WrongDefault').Defaults -and -not (Test-ComparisonCase 'EmptyDefault').Defaults)
 'Missing duplicate and misplaced TempDB files remain rejected'=(-not (Test-ComparisonCase 'MissingTempDb').TempDb -and -not (Test-ComparisonCase 'DuplicateTempDb').TempDb -and -not (Test-ComparisonCase 'WrongTempDb').TempDb)
 'Native SQL storage acceptance is syntactically valid'=($errors.Count -eq 0)
 'Acceptance requires an operation-owned Windows 2025 clone with verified SQL media and denied egress'=($source -match 'Parameter\(Mandatory,ParameterSetName=''Clone''\)\]\[string\]\$CloneSourceRunId' -and $source -match 'Parameter\(Mandatory,ParameterSetName=''Clone''\)\]\[string\]\$MediaRoot' -and $source -match 'New-HyperVResourceAcceptanceSlotClone' -and $source -match "Strategy='VerifyOnly'" -and $source -match "EgressPolicy='Denied'")
 'Host storage is reconciled from a schema-valid bound storage intent and no-op before SQL storage mutation'=($source -match "placementPolicy='logical-only'" -and $source -match "dataFileCount=4" -and $source -match "defaultData=\[ordered\]@\{selector='default'\}" -and $source -match "defaultLog=\[ordered\]@\{selector='default'\}" -and $source -match 'New-LabStorageBoundPlan' -and $source -match 'storage-bound-plan\.json' -and $source -match '\$hostReasonCodes' -and $source -match "HighestChangeClass -in @\('live','restart'\)" -and $source -match 'Actions\[0\]\.Operation' -and $source -match 'Start-VM -VM \$VM' -and $source -match 'HV-603 ist vor SQL-Mutation No-op' -and $source -match 'RepairHyperVSqlStorage')
 'SQL paths are verified solely through the runtime receipt produced after SQL reconciliation'=($source -match 'storage-runtime-receipt\.json' -and $source -match 'HV-603 persistiert noch keinen SQL-Runtime-Receipt' -and $source -match 'receiptAfter\.FileBindings' -and $source -match 'Get-SqlStorageObservation')
 'Applied SQL reconciliation inspects the public execution-plan result'=($source -match 'result\.ExecutionPlan\[0\]\.Result\.ReceiptStatus' -and $source -notmatch 'result\.Actions\[0\]\.Result\.ReceiptStatus')
 'Failed convergence reports component-level evidence without SQL paths'=($source -match '\$convergenceEvidence' -and $source -match 'result=\$resultOk' -and $source -match 'tempdb=\$tempOk' -and $source -match 'defaultsDetail=' -and $source -match 'tempdbDetail=' -and $source -notmatch 'SqlPhysicalPath.*convergenceEvidence')
 'WhatIf, service-only restart, no-op and scope-bound cleanup are explicit'=($source -match 'RepairHyperVSqlStorage.*-WhatIf' -and $source -match 'SqlStartTime -ne' -and $source -match 'bootAfter -eq \$bootBefore' -and $source -match 'Wiederholter HV-603A-Plan ist No-op' -and $source -match 'Remove-SqlServerLab')
 'Synthetic fault resume remains separate and no production injection seam is introduced'=($source -match 'Fault/resume injection remains in the synthetic contract' -and $source -match 'does\s+not add a production fault-injection seam' -and $source -notmatch 'Resize-VHD')
 'Prepared restore uses a verified SQL-2025 artifact on the existing host-only network with activation denied'=($source -match "Parameter\(Mandatory,ParameterSetName='Prepared'\)" -and $source -match 'HYPERV_LIBRARY_RESTORE_ACCEPTANCE_PREPARED_SCOPE_REQUIRED' -and $source -match 'Get-HyperVImageArtifact -ArtifactId \$Id' -and $source -match "'SQL_PREPARED_SEALED'" -and $source -match 'VERIFIED_HASH' -and $source -match 'HYPERV_LIBRARY_RESTORE_ACCEPTANCE_EXISTING_NETWORK_REQUIRED' -and $source -match "Strategy = 'NotRequested'" -and $source -match 'Invoke-WithLabWorkflowOperationContext -OperationId \$Op' -and $source -match 'NonInteractive -RequireExistingHyperVNetwork')
 'Prepared and clone dispatch pass only their own argument sets'=($preparedArguments.Count -eq 2 -and $preparedArguments.VerifyLibraryRestore -eq $true -and $preparedArguments.PreparedArtifactId -ceq $artifact -and $cloneArguments.Count -eq 4 -and $cloneArguments.CloneSourceRunId -ceq 'synthetic-slot' -and $cloneArguments.MediaRoot -ceq 'synthetic-media' -and -not $cloneArguments.VerifyLibraryRestore)
 'Prepared dispatch ignores the inherited workflow media default without opening a media or clone path'=($preparedDefaultArguments.Count -eq 2 -and $preparedDefaultArguments.VerifyLibraryRestore -eq $true -and $preparedDefaultArguments.PreparedArtifactId -ceq $artifact -and -not $preparedDefaultArguments.ContainsKey('MediaRoot') -and -not $preparedDefaultArguments.ContainsKey('CloneSourceRunId'))
 'Prepared dispatch refuses mixed source inputs and unrelated modes'=((Test-StorageAcceptanceDispatch -Prepared $artifact -Clone synthetic-slot -Restore $true) -ceq 'HYPERV_LIBRARY_RESTORE_CI_PREPARED_INPUT_CONFLICT' -and (Test-StorageAcceptanceDispatch -Prepared $artifact -Media synthetic-media -Restore $true) -ceq 'HYPERV_LIBRARY_RESTORE_CI_PREPARED_INPUT_CONFLICT' -and (Test-StorageAcceptanceDispatch -Prepared $artifact -Restore $false) -ceq 'HYPERV_LIBRARY_RESTORE_CI_PREPARED_INPUT_CONFLICT')
 'Guided acceptance binds one prepared artifact and rejects clone, restore and custom-media overlap'=($guidedArguments.Count -eq 3 -and $guidedArguments.VerifyGuidedDatabaseScript -eq $true -and -not $guidedArguments.VerifyLibraryRestore -and $guidedArguments.PreparedArtifactId -ceq $artifact -and $guidedMissingArtifact -ceq 'HYPERV_GUIDED_DATABASE_SCRIPT_CI_PREPARED_ARTIFACT_REQUIRED' -and $guidedConflicting -ceq 'HYPERV_LIBRARY_RESTORE_CI_PREPARED_INPUT_CONFLICT' -and $guidedCustomMedia -ceq 'HYPERV_LIBRARY_RESTORE_CI_PREPARED_INPUT_CONFLICT')
 'SSIS catalog acceptance binds one prepared artifact and refuses other prepared scopes'=($ssisArguments.Count -eq 3 -and $ssisArguments.VerifySsisCatalogCapability -eq $true -and -not $ssisArguments.VerifyLibraryRestore -and -not $ssisArguments.ContainsKey('CloneSourceRunId') -and $ssisArguments.PreparedArtifactId -ceq $artifact -and $ssisMissingArtifact -ceq 'HYPERV_SSIS_CATALOG_CI_PREPARED_ARTIFACT_REQUIRED' -and $ssisAmbiguous -ceq 'HYPERV_LIBRARY_RESTORE_CI_PREPARED_INPUT_CONFLICT')
 'Workflow exposes the acceptance only through manual main dispatch with a clone source'=((Get-Content $workflow -Raw -Encoding utf8) -match '(?m)^\s*- sql-storage-reconcile-acceptance\s*$' -and (Get-Content $workflow -Raw -Encoding utf8) -match 'HYPERV_SQL_STORAGE_RECONCILE_CI_MANUAL_MAIN_REQUIRED' -and (Get-Content $workflow -Raw -Encoding utf8) -match 'HYPERV_SQL_STORAGE_RECONCILE_CI_CLONE_SOURCE_REQUIRED' -and (Get-Content $workflow -Raw -Encoding utf8) -match 'Invoke-HyperVSqlStorageReconcileAcceptance\.ps1 @arguments')
}
$failed=@($checks.GetEnumerator()|Where-Object{-not $_.Value});if($failed){throw "Hyper-V SQL storage reconcile acceptance checks failed: $($failed.Key -join ', ')"};Write-Host "Hyper-V SQL Storage Reconcile Acceptance Checks: $($checks.Count) PASS, 0 FAIL" -ForegroundColor Green

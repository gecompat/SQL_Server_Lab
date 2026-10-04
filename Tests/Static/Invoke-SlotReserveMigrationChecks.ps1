#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
foreach($file in @('LabPreferences','ArtifactResolver','StorageFilePlacement','StorageContract','WindowsPoolClaims')) { . (Join-Path $repoRoot "Private/$file.ps1") }
$originalMigrationCore=${function:Invoke-LabDataMigrationCore}
function Get-LabTimestamp { [datetime]::UtcNow.ToString('o') }
$tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$leaf='sql-lab-preference-migration-'+[guid]::NewGuid().ToString('N')
$fixture=Join-Path $tempParent $leaf
$null=New-Item -ItemType Directory -Path $fixture
$sourceRoot=Join-Path $fixture 'source'; $targetRoot=Join-Path $fixture 'target'
$null=New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'Catalog'),(Join-Path $targetRoot 'Catalog')
$sourcePath=Join-Path $sourceRoot 'Catalog/preferences.json'; $targetPath=Join-Path $targetRoot 'Catalog/preferences.json'
$planPath=Join-Path $fixture 'migration-plan.json'
$script:PreferenceTestPath=$sourcePath
function Get-LabProjectPreferencesPath { $script:PreferenceTestPath }
function Get-LabStateRoot {Join-Path $fixture external-state}
$jobs=@();$count=0
function Assert-MigrationPreference($condition,$name) { if(-not $condition){throw "ASSERT: $name"};$script:count++ }
$jobBody={
    param($repo,$path,$ready,$name)
    $ErrorActionPreference='Stop'
    . (Join-Path $repo 'Private/LabPreferences.ps1'); . (Join-Path $repo 'Private/ArtifactResolver.ps1')
    $script:WorkerPreferencePath=$path
    function Get-LabProjectPreferencesPath { $script:WorkerPreferencePath }
    function Get-LabTimestamp { [datetime]::UtcNow.ToString('o') }
    $actualLock=${function:Invoke-WithLabPreferencesLock}
    function Invoke-WithLabPreferencesLock {
        param($Path,$Body)
        [IO.File]::WriteAllText($ready,'ready')
        & $actualLock -Path $Path -Body $Body
    }
    try { Set-LabProjectPreferenceValue -Name $name -Value 'synthetic'; 'WRITTEN' }
    catch { if($_.Exception.Message -in @('PREFERENCES_PREVIEW_STALE','PREFERENCES_LOCK_TIMEOUT')){$_.Exception.Message}else{throw} }
}
try {
    [IO.File]::WriteAllText($sourcePath,(@{mediaRoot=$sourceRoot;slotReservePolicy=@{WindowsReserve=0;SqlReserve=1;MinimumDaysRemaining=20;WarningDaysRemaining=5};unrelated='keep'}|ConvertTo-Json -Depth 6))
    @{ContractVersion='SqlServerLab.StorageMigrationPlan/1.0';ExecutionImplemented=$true;Status='READY';Source=@{LabDataRoot=$sourceRoot};Target=@{LabDataRoot=$targetRoot}}|ConvertTo-Json -Depth 5|Set-Content $planPath
    # Execute the actual migration wrapper with a controlled filesystem-only core boundary.
    # It performs real Copy, the actual JSON rewrite, and source cleanup while both workers wait.
    function Invoke-LabDataMigrationCore {
        param($PlanPath,$ProcessEnvironmentOnly,$PreferenceAuthorities)
        [IO.File]::Copy($sourcePath,$targetPath)
        $sourceReady=Join-Path $fixture 'source-ready';$targetReady=Join-Path $fixture 'target-ready'
        $script:jobs=@(
            (Start-Job -ScriptBlock $jobBody -ArgumentList $repoRoot,$sourcePath,$sourceReady,'source-writer'),
            (Start-Job -ScriptBlock $jobBody -ArgumentList $repoRoot,$targetPath,$targetReady,'target-writer')
        )
        $deadline=[datetime]::UtcNow.AddSeconds(15)
        while(-not ((Test-Path $sourceReady) -and (Test-Path $targetReady))) {
            if(@($script:jobs | Where-Object State -eq 'Failed').Count){$script:jobs | Receive-Job -ErrorAction Stop;throw 'WORKER_FAILED'}
            if([datetime]::UtcNow -gt $deadline){throw 'WORKER_READY_TIMEOUT'}
            Start-Sleep -Milliseconds 25
        }
        Assert-MigrationPreference (@($script:jobs | Where-Object State -ne 'Running').Count -eq 0) 'writers blocked across Copy'
        $null=Update-LabMigratedJsonReferences -Root $targetRoot -SourceRoot $sourceRoot -TargetRoot $targetRoot -PreferenceAuthorities $PreferenceAuthorities
        [IO.File]::Delete($sourcePath)
        # Keep the old directory deliberately: Exists→Missing must prevent resurrection.
        Assert-MigrationPreference (@($script:jobs | Where-Object State -ne 'Running').Count -eq 0) 'writers blocked across Rewrite and Cleanup'
        [pscustomobject]@{Status='COMPLETED'}
    }
    $result=Invoke-LabDataMigration -PlanPath $planPath -Confirm:$false
    $null=$jobs|Wait-Job -Timeout 15
    $sourceResult=@(Receive-Job $jobs[0] -ErrorAction Stop);$targetResult=@(Receive-Job $jobs[1] -ErrorAction Stop)
    Assert-MigrationPreference ($result.Status -eq 'COMPLETED' -and $sourceResult -contains 'PREFERENCES_PREVIEW_STALE' -and -not (Test-Path $sourcePath)) 'waiting legacy writer cannot recreate source in retained directory'
    $target=Get-LabPreferencesSnapshot -Path $targetPath
    Assert-MigrationPreference ($targetResult -contains 'WRITTEN' -and $target.Document.mediaRoot -eq $targetRoot -and $target.Document.unrelated -eq 'keep' -and $target.Document.'target-writer' -eq 'synthetic' -and $target.Document.slotReservePolicy.WindowsReserve -eq 0) 'target writer merges fresh rewritten content'
    $jobs|Remove-Job;$jobs=@()
    # Another process owns the second sorted authority: failed pair acquisition must
    # release its first mutex, without running the protected body.
    $heldReady=Join-Path $fixture 'held-ready';$releaseHeld=Join-Path $fixture 'release-held'
    $jobs=@(Start-Job -ArgumentList $repoRoot,$targetPath,$heldReady,$releaseHeld -ScriptBlock {
        param($repo,$heldPath,$readyPath,$releasePath)
        . (Join-Path $repo 'Private/LabPreferences.ps1')
        Invoke-WithLabPreferencesLock -Path $heldPath -Body {
            [IO.File]::WriteAllText($readyPath,'ready')
            $until=[datetime]::UtcNow.AddSeconds(25)
            while(-not (Test-Path $releasePath) -and [datetime]::UtcNow -lt $until){Start-Sleep -Milliseconds 25}
        }
    })
    $until=[datetime]::UtcNow.AddSeconds(10)
    while(-not (Test-Path $heldReady)){if([datetime]::UtcNow -gt $until){throw 'HOLDER_TIMEOUT'};Start-Sleep -Milliseconds 25}
    $script:pairBodyRan=$false;$timedOut=$false
    try{Invoke-WithLabPreferencesLock -Path @($targetPath,$sourcePath) -Body {$script:pairBodyRan=$true}}catch{$timedOut=$_.Exception.Message -eq 'PREFERENCES_LOCK_TIMEOUT'}
    Assert-MigrationPreference ($timedOut -and -not $script:pairBodyRan) 'bounded partial acquisition does not enter body'
    $probeReady=Join-Path $fixture 'partial-release-ready'
    $probe=Start-Job -ScriptBlock $jobBody -ArgumentList $repoRoot,$sourcePath,$probeReady,'partial-release'
    $jobs+=@($probe)
    $null=$probe|Wait-Job -Timeout 5
    Assert-MigrationPreference ((@(Receive-Job $probe -ErrorAction Stop)) -contains 'WRITTEN') 'partial acquisition releases first mutex while second remains owned'
    [IO.File]::WriteAllText($releaseHeld,'release')
    $null=$jobs|Wait-Job -Timeout 5
    $jobs|Remove-Job;$jobs=@()
    [IO.File]::WriteAllText($sourcePath,'{"source":"new"}')
    $script:coreReached=$false
    function Invoke-LabDataMigrationCore { $script:coreReached=$true;throw 'CORE_MUST_NOT_RUN' }
    $rejected=$false;try{Invoke-LabDataMigration -PlanPath $planPath -Confirm:$false}catch{$rejected=$_.Exception.Message -eq 'PREFERENCES_MIGRATION_TARGET_CONFLICT'}
    Assert-MigrationPreference ($rejected -and -not $script:coreReached -and (Get-LabPreferencesSnapshot -Path $targetPath).Document.unrelated -eq 'keep') 'target conflict before core mutation'
    [IO.File]::WriteAllText($targetPath,'{malformed')
    $rejected=$false;try{Invoke-LabDataMigration -PlanPath $planPath -Confirm:$false}catch{$rejected=$_.Exception.Message -eq 'PREFERENCES_INVALID'}
    Assert-MigrationPreference ($rejected -and -not $script:coreReached -and [IO.File]::ReadAllText($targetPath) -ceq '{malformed') 'malformed target before copy or journal'
    [IO.File]::WriteAllText($targetPath,'{}')
    # Throw inside an acquired pair, then verify another process can acquire either authority.
    try { Invoke-WithLabPreferencesLock -Path @($sourcePath,$targetPath,$sourcePath) -Body { throw 'SYNTHETIC_PAIR_FAILURE' } } catch { }
    $releaseReady=Join-Path $fixture 'release-ready'
    $jobs=@(Start-Job -ScriptBlock $jobBody -ArgumentList $repoRoot,$sourcePath,$releaseReady,'after-failure')
    $null=$jobs|Wait-Job -Timeout 15
    Assert-MigrationPreference ((@(Receive-Job $jobs[0] -ErrorAction Stop)) -contains 'WRITTEN') 'exception releases deduplicated pair for another process'
    $jobs|Remove-Job;$jobs=@()
    # Early legacy checks use real function bodies; replace only persistent environment writes
    # with a throwing boundary so even a regression cannot alter user environment.
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Private/LabPreferences.ps1'),[ref]$null,[ref]$null)
    foreach($name in @('Set-LabMediaRootDefault','Set-LabTestDataRootDefault','Set-LabHyperVSwitchDefault')) {
        $definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
        if(-not $definition){continue}
        $body=[regex]::Replace($definition.Extent.Text,'(?m)^\s*\[Environment\]::SetEnvironmentVariable\([^\r\n]+',"        throw 'SYNTHETIC_PERSISTENT_ENVIRONMENT_BOUNDARY'")
        Invoke-Expression $body
    }
    [IO.File]::WriteAllText($sourcePath,'{malformed')
    $beforeMedia=$env:SQL_SERVER_LAB_MEDIA_ROOT;$beforeTest=$env:SQL_SERVER_LAB_TEST_DATA_ROOT
    $newTestPath=Join-Path $fixture 'must-not-exist'
    $rejected=$false;try{Set-LabMediaRootDefault -MediaRoot $fixture}catch{$rejected=$_.Exception.Message -eq 'PREFERENCES_INVALID'}
    Assert-MigrationPreference ($rejected -and $env:SQL_SERVER_LAB_MEDIA_ROOT -ceq $beforeMedia) 'media preflight before environment write'
    $rejected=$false;try{Set-LabTestDataRootDefault -TestDataRoot $newTestPath}catch{$rejected=$_.Exception.Message -eq 'PREFERENCES_INVALID'}
    Assert-MigrationPreference ($rejected -and $env:SQL_SERVER_LAB_TEST_DATA_ROOT -ceq $beforeTest -and -not (Test-Path $newTestPath)) 'test-data preflight before directory or environment write'
    # Read-only storage lookups are synthetic; all first mutation boundaries throw.
    # Execute the actual setters so malformed preferences cannot reach those boundaries.
    $script:storageMutationReached=$false
    $locationId='11111111-1111-1111-1111-111111111111'
    function Get-LabDataRootDefault { $targetRoot }
    function Get-LabStorageConfiguration {
        [pscustomobject]@{DefaultLocationId='22222222-2222-2222-2222-222222222222';DefaultDataRoot=$targetRoot;ControllerId='synthetic';LabDataLocations=@([pscustomobject]@{LocationId=$locationId;LabDataRoot=$sourceRoot})}
    }
    function Resolve-LabStorageRootPath { [pscustomobject]@{LabDataParent=$fixture;LabDataRoot=$sourceRoot} }
    function Initialize-LabManagedDataRoot { $script:storageMutationReached=$true;throw 'SYNTHETIC_STORAGE_BOUNDARY' }
    function Write-LabStorageConfiguration { $script:storageMutationReached=$true;throw 'SYNTHETIC_STORAGE_BOUNDARY' }
    $beforeData=$env:SQL_SERVER_LAB_DATA_ROOT
    foreach($operation in @(
        { Set-LabDataRootDefault -DataRoot $sourceRoot },
        { Register-LabDataRoot -DataRoot $sourceRoot -SetDefault },
        { Set-LabDataLocation -LabDataRoot $sourceRoot -SetDefault -Confirm:$false },
        { Set-LabDefaultDataLocation -LocationId $locationId -Confirm:$false }
    )) {
        $rejected=$false;try{& $operation}catch{$rejected=$_.Exception.Message -eq 'PREFERENCES_INVALID'}
        Assert-MigrationPreference ($rejected -and -not $script:storageMutationReached -and $env:SQL_SERVER_LAB_DATA_ROOT -ceq $beforeData) 'storage setter malformed preflight precedes storage/environment mutation'
    }
    # Exercise the actual migration core's pre-mutation boundary for external receipts.
    Set-Item Function:Invoke-LabDataMigrationCore $originalMigrationCore
    function Test-LabDataRootOwnership { $true }
    function Assert-LabStorageMigrationHyperVVMConfigurationPlan { @() }
    $external=Join-Path $fixture 'external';$null=New-Item -ItemType Directory -Path $external
    [IO.File]::WriteAllText((Join-Path $external 'preferences.json'),'{}')
    function Assert-LabStorageMigrationHyperVBindingPlan { @([pscustomobject]@{ReceiptPath=(Join-Path $external 'receipt.json')}) }
    $plan=Get-Content $planPath -Raw|ConvertFrom-Json -AsHashtable
    $plan.ControllerId='synthetic';$plan.Blockers=@();$plan.PlanId='synthetic-migration'
    $plan|ConvertTo-Json -Depth 6|Set-Content $planPath
    [IO.File]::WriteAllText($sourcePath,'{}');[IO.File]::Delete($targetPath)
    $rejected=$false
    try{Invoke-LabDataMigration -PlanPath $planPath -Confirm:$false}catch{$rejected=$_.Exception.Message -eq 'PREFERENCES_MIGRATION_ADDITIONAL_AUTHORITY'}
    Assert-MigrationPreference ($rejected -and -not (Test-Path (Join-Path $fixture 'synthetic-migration.journal.json')) -and -not (Test-Path $targetPath)) 'external preferences authority blocked before copy or journal'
    # Resume uses the existing plan/journal authority and exact preference digests.
    # The controlled core boundary verifies entry without invoking providers or user env.
    function Invoke-LabDataMigrationCore { [pscustomobject]@{Status='RESUMED'} }
    [IO.File]::WriteAllText($sourcePath,'{"unrelated":"keep"}')
    @{unrelated='keep';dataRoot=$targetRoot}|ConvertTo-Json|Set-Content $targetPath
    $journalPath=Join-Path $fixture 'synthetic-migration.journal.json'
    $journal=[pscustomobject]@{
        ContractVersion='SqlServerLab.StorageMigrationJournal/1.0';PlanId=$plan.PlanId
        PlanSha256=(Get-FileHash $planPath -Algorithm SHA256).Hash;Status='RECOVERY_REQUIRED'
        PreferencesCheckpoint=(Get-LabMigrationPreferencesCheckpoint -SourcePath $sourcePath -TargetPath $targetPath -Stage SWITCHED)
    }
    $journal|ConvertTo-Json -Depth 6|Set-Content $journalPath
    Assert-MigrationPreference ((Invoke-LabDataMigration -PlanPath $planPath -Confirm:$false).Status -eq 'RESUMED') 'journal-bound resume accepts default field added after switching'
    $targetBytes=[IO.File]::ReadAllText($targetPath)
    [IO.File]::WriteAllText($targetPath,'{"unrelated":"foreign"}')
    $rejected=$false;try{Invoke-LabDataMigration -PlanPath $planPath -Confirm:$false}catch{$rejected=$_.Exception.Message -eq 'PREFERENCES_MIGRATION_TARGET_CONFLICT'}
    Assert-MigrationPreference $rejected 'checkpoint rejects foreign target mutation'
    [IO.File]::WriteAllText($targetPath,$targetBytes)
    [IO.File]::Delete($sourcePath)
    $rejected=$false;try{Invoke-LabDataMigration -PlanPath $planPath -Confirm:$false}catch{$rejected=$_.Exception.Message -eq 'PREFERENCES_MIGRATION_TARGET_CONFLICT'}
    Assert-MigrationPreference $rejected 'source disappearance before cleanup checkpoint rejected'
    $journal.PreferencesCheckpoint.Stage='CLEANUP_READY'
    $journal|ConvertTo-Json -Depth 6|Set-Content $journalPath
    Assert-MigrationPreference ((Invoke-LabDataMigration -PlanPath $planPath -Confirm:$false).Status -eq 'RESUMED' -and -not (Test-Path $sourcePath)) 'cleanup checkpoint accepts previously removed source preferences'
    $journal.PlanSha256='0'*64;$journal|ConvertTo-Json -Depth 6|Set-Content $journalPath
    $rejected=$false;try{Invoke-LabDataMigration -PlanPath $planPath -Confirm:$false}catch{$rejected=$_.Exception.Message -eq 'PREFERENCES_MIGRATION_TARGET_CONFLICT'}
    Assert-MigrationPreference $rejected 'checkpoint binds exact migration plan'
    Write-Host "Slot Reserve Migration Checks: $count PASS"
}
finally {
    if($jobs){$jobs|Stop-Job;$jobs|Remove-Job}
    $actual=Get-Item -LiteralPath $fixture -Force
    if($actual.FullName -cne [IO.Path]::GetFullPath((Join-Path $tempParent $leaf)) -or $actual.Parent.FullName.TrimEnd('\','/') -cne $tempParent -or $actual.Name -cne $leaf -or ($actual.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'FIXTURE_CLEANUP_BINDING'}
    $items=@(Get-ChildItem -LiteralPath $actual.FullName -Recurse -Force)
    foreach($item in $items){if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $item.FullName.StartsWith($actual.FullName+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal)){throw 'FIXTURE_CLEANUP_CONTENT'}}
    foreach($item in @($items|Where-Object {-not $_.PSIsContainer})){Remove-Item -LiteralPath $item.FullName -Force}
    foreach($item in @($items|Where-Object PSIsContainer|Sort-Object {$_.FullName.Length} -Descending)){Remove-Item -LiteralPath $item.FullName -Force}
    Remove-Item -LiteralPath $actual.FullName -Force
}

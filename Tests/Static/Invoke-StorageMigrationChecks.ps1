#Requires -Version 7.2
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryParent = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-storage-migration-$([Guid]::NewGuid().ToString('N'))"
$sourceRoot = Join-Path (Join-Path $temporaryParent 'source') 'Lab_Data'
$targetParent = Join-Path $temporaryParent 'target'
$targetRoot = Join-Path $targetParent 'Lab_Data'
$externalStateRoot = Join-Path $temporaryParent 'external-state'
$previousDataRoot = $env:SQL_SERVER_LAB_DATA_ROOT
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Storage Migration Checks' -ForegroundColor Cyan

try {
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    & $module {
        Set-Item -Path Function:script:Get-LabHyperVHardDiskDriveInventory -Value { return @() }
    }
    $storageContractText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\StorageContract.ps1') -Raw -Encoding utf8
    Add-CheckResult -Name 'Hyper-V-Diskinventur übergibt den verpflichtenden VM-Namen' -Success (
        $storageContractText -match 'Get-VMHardDiskDrive\s+-VMName\s+'
    )
    $setup = & $module {
        param($source)
        $marker = Initialize-LabManagedDataRoot -DataRoot $source -Confirm:$false
        $volume = Get-LabVolumeIdentity -Path $source
        $configuration = [PSCustomObject]@{
            ContractVersion='SqlServerLab.Storage/2.0'; ControllerId=[string]$marker.ControllerId; DefaultDataRoot=$source
            LabDataLocations=@([PSCustomObject]@{ VolumeId=$volume.VolumeId; DriveLetter=$volume.DriveLetter; LabDataParent=(Split-Path -Parent $source); LabDataRoot=$source })
        }
        Write-LabArtifactJsonAtomic -Path (Join-Path (Join-Path $source 'Catalog') 'storage-locations.json') -InputObject $configuration
        return $configuration
    } $sourceRoot
    $env:SQL_SERVER_LAB_DATA_ROOT = $sourceRoot
    $env:SQL_SERVER_LAB_STATE = $externalStateRoot
    $payloadPath = Join-Path $sourceRoot 'Labs/sample/payload.txt'
    $payloadDirectory = Split-Path -Parent $payloadPath
    New-Item -Path $payloadDirectory -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath $payloadPath -Value 'storage-migration-contract' -Encoding utf8NoBOM
    $referencePath = Join-Path $sourceRoot 'Catalog/reference.json'
    [PSCustomObject]@{ dataRoot=$sourceRoot; payload=$payloadPath } | ConvertTo-Json | Set-Content -LiteralPath $referencePath -Encoding utf8NoBOM
    $sourceHash = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash

    $hyperVFixture = & $module {
        param($source, $stateRootPath)
        $run = New-LabRunState -StateRoot $stateRootPath `
            -Metadata @{ name='storage-migration-fixture'; workflowKind='hyperv-lab' } `
            -ProviderSubRuns @([PSCustomObject]@{ id='provider-hyperv'; provider='hyperv'; instanceIds=@('primary') })
        $stateDirectory = [string]$run.RunDir
        $runStatePath = Join-Path $stateDirectory 'run-state.json'
        $runState = Get-Content -LiteralPath $runStatePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        $runState.state = 'STOPPED'
        Write-LabArtifactJsonAtomic -Path $runStatePath -InputObject $runState
        $binding = Resolve-LabHyperVResourceBinding -ResourceId ([string]$run.RunId) `
            -ResourceClass Run -DataRoot $source
        New-Item -Path ([string]$binding.HyperVResourceRoot) -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path ([string]$binding.HyperVResourceRoot) 'child.vhdx') `
            -Value 'synthetic-bound-vhdx' -Encoding utf8NoBOM
        $receiptPath = Write-LabHyperVResourceBinding -Binding $binding `
            -StateDirectory $stateDirectory -DataRoot $source
        $resourceMigrationPath = Join-Path $stateDirectory 'hyperv-resource-migration.local.journal.json'
        Write-LabArtifactJsonAtomic -Path $resourceMigrationPath -InputObject ([PSCustomObject]@{
            ContractVersion='SqlServerLab.HyperVResourceMigrationJournal/1.0'
            RunId=[string]$run.RunId; Status='RECOVERY_REQUIRED'
        })
        $journalDirectory = Join-Path (Join-Path $source 'Catalog') 'storage-migrations'
        New-Item -Path $journalDirectory -ItemType Directory -Force | Out-Null
        $guardJournalPath = Join-Path $journalDirectory 'guard-fixture.journal.json'
        Write-LabArtifactJsonAtomic -Path $guardJournalPath -InputObject ([PSCustomObject]@{
            ContractVersion='SqlServerLab.StorageMigrationJournal/1.0'
            LocationId=[string]$binding.LocationId; Status='COPYING'
        })
        $blockedGuard = Get-LabStorageMigrationLifecycleGuard `
            -DataRoot $source -LocationId ([string]$binding.LocationId)
        Remove-Item -LiteralPath $guardJournalPath -Force
        [PSCustomObject]@{
            StateDirectory=$stateDirectory; ReceiptPath=$receiptPath
            ResourceId=[string]$binding.ResourceId; ResourceKey=[string]$binding.ResourceKey
            ResourceMigrationPath=$resourceMigrationPath; BlockedGuard=$blockedGuard
        }
    } $sourceRoot $externalStateRoot
    Add-CheckResult -Name 'Nichtterminales Location-Journal blockiert gebundenen Hyper-V-Lifecycle' -Success (
        -not $hyperVFixture.BlockedGuard.Allowed -and
        $hyperVFixture.BlockedGuard.ReasonCode -eq 'STORAGE_MIGRATION_NOT_TERMINAL'
    )
    $specificMigrationBlockedPlan = & $module {
        param($source, $targetParentPath)
        (New-LabDataMigrationPlan -SourceDataRoot $source -TargetParent $targetParentPath).Plan
    } $sourceRoot $targetParent
    Add-CheckResult -Name 'Nichtterminale Run-Migration blockiert die allgemeine Location-Migration' -Success (
        $specificMigrationBlockedPlan.Status -eq 'BLOCKED' -and
        @($specificMigrationBlockedPlan.Blockers | Where-Object {
            $_ -like 'HYPERV_RESOURCE_MIGRATION_NOT_TERMINAL:*:RECOVERY_REQUIRED'
        }).Count -eq 1
    )
    Remove-Item -LiteralPath $hyperVFixture.ResourceMigrationPath -Force

    $migrationContract = & $module {
        param($source, $targetParentPath)
        $plan = New-LabDataMigrationPlan -SourceDataRoot $source -TargetParent $targetParentPath
        if ($plan.Plan.Status -ne 'READY') { throw "Plan ist blockiert: $(@($plan.Plan.Blockers) -join ', ')" }
        $plan.Plan.HyperVBindings[0].ResourceKey = 'tampered-resource-key'
        Write-LabArtifactJsonAtomic -Path $plan.Path -InputObject $plan.Plan
        $tamperedBindingMessage = try {
            Invoke-LabDataMigration -PlanPath $plan.Path -ProcessEnvironmentOnly -Confirm:$false | Out-Null
            ''
        }
        catch { $_.Exception.Message }
        $plan = New-LabDataMigrationPlan -SourceDataRoot $source -TargetParent $targetParentPath
        $script:storageMigrationOriginalBindingWriter = (Get-Item Function:Write-LabHyperVResourceBinding).ScriptBlock
        $script:storageMigrationInterruptOnce = $true
        Set-Item -Path Function:script:Write-LabHyperVResourceBinding -Value {
            param($Binding, $StateDirectory, $DataRoot)
            $bindingPath = & $script:storageMigrationOriginalBindingWriter @PSBoundParameters
            if ($script:storageMigrationInterruptOnce) {
                $script:storageMigrationInterruptOnce = $false
                throw 'SYNTHETIC_STORAGE_BINDING_COMMIT_INTERRUPTION'
            }
            return $bindingPath
        }
        $recoveryMessage = try {
            Invoke-LabDataMigration -PlanPath $plan.Path -ProcessEnvironmentOnly -Confirm:$false | Out-Null
            ''
        }
        catch { $_.Exception.Message }
        finally {
            Set-Item -Path Function:script:Write-LabHyperVResourceBinding `
                -Value $script:storageMigrationOriginalBindingWriter
        }
        $result = Invoke-LabDataMigration -PlanPath $plan.Path -ProcessEnvironmentOnly -Confirm:$false
        return [PSCustomObject]@{
            Plan=$plan.Plan; Result=$result; TamperedBindingMessage=$tamperedBindingMessage
            RecoveryMessage=$recoveryMessage
        }
    } $sourceRoot $targetParent
    $result = $migrationContract.Result

    Add-CheckResult -Name 'Journalisierte Storage-Migration wird abgeschlossen' -Success ($result.Status -eq 'COMPLETED')
    Add-CheckResult -Name 'Storage-Migrationsplan erfüllt das aktuelle JSON-Schema' -Success (
        ($migrationContract.Plan | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/lab-storage-migration-plan.schema.json') -ErrorAction SilentlyContinue
    )
    Add-CheckResult -Name 'Parent-Migration bindet Quelle und Ziel an dieselbe stabile LocationId' -Success (
        [string]$migrationContract.Plan.Source.LocationId -match '^[0-9a-f-]{36}$' -and
        [string]$migrationContract.Plan.Source.LocationId -eq [string]$migrationContract.Plan.Target.LocationId
    )
    Add-CheckResult -Name 'Plan inventarisiert revalidierte Hyper-V-Ressourcenbindungen' -Success (
        @($migrationContract.Plan.HyperVBindings).Count -eq 1 -and
        @($migrationContract.Plan.AffectedRuns).Count -eq 1 -and
        $migrationContract.Plan.AffectedRuns[0].State -eq 'STOPPED' -and
        $migrationContract.Plan.HyperVBindings[0].Valid -and
        [string]$migrationContract.Plan.HyperVBindings[0].ResourceKey -eq [string]$hyperVFixture.ResourceKey
    )
    Add-CheckResult -Name 'Manipuliertes Binding-Inventar blockiert vor Storage-Mutation' -Success (
        $migrationContract.TamperedBindingMessage -match 'LAB_STORAGE_MIGRATION_HYPERV_BINDING_PLAN_STALE'
    )
    Add-CheckResult -Name 'Unterbrochener Binding-Commit bleibt journalisiert und fortsetzbar' -Success (
        $migrationContract.RecoveryMessage -match 'LAB_STORAGE_MIGRATION_RECOVERY_REQUIRED: SYNTHETIC_STORAGE_BINDING_COMMIT_INTERRUPTION' -and
        $result.Status -eq 'COMPLETED'
    )
    Add-CheckResult -Name 'Migrierte Nutzdatei ist hashidentisch' -Success (
        (Test-Path -LiteralPath (Join-Path $targetRoot 'Labs/sample/payload.txt') -PathType Leaf) -and
        (Get-FileHash -LiteralPath (Join-Path $targetRoot 'Labs/sample/payload.txt') -Algorithm SHA256).Hash -eq $sourceHash
    )
    $reference = Get-Content -LiteralPath (Join-Path $targetRoot 'Catalog/reference.json') -Raw -Encoding utf8 | ConvertFrom-Json
    Add-CheckResult -Name 'Absolute JSON-Referenzen zeigen auf den Zielroot' -Success (
        [string]$reference.dataRoot -eq $targetRoot -and [string]$reference.payload -eq (Join-Path $targetRoot 'Labs/sample/payload.txt')
    )
    $storage = Get-Content -LiteralPath (Join-Path $targetRoot 'Catalog/storage-locations.json') -Raw -Encoding utf8 | ConvertFrom-Json
    Add-CheckResult -Name 'Storage-Katalog wird erst auf den Zielroot umgeschaltet' -Success (
        [string]$storage.DefaultDataRoot -eq $targetRoot -and
        [string]$storage.DefaultLocationId -eq [string]$migrationContract.Plan.Source.LocationId -and
        @($storage.LabDataLocations | Where-Object {
            $_.LabDataRoot -eq $targetRoot -and $_.LocationId -eq $migrationContract.Plan.Source.LocationId
        }).Count -eq 1
    )
    Add-CheckResult -Name 'ProcessEnvironmentOnly schreibt keine persistente Projektpräferenz' -Success (
        -not (Test-Path -LiteralPath (Join-Path $targetRoot 'Catalog/preferences.json') -PathType Leaf)
    )
    $journal = Get-Content -LiteralPath $result.JournalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $migratedBinding = & $module {
        param($stateDirectory, $target)
        Read-LabHyperVResourceBinding -StateDirectory $stateDirectory -DataRoot $target
    } $hyperVFixture.StateDirectory $targetRoot
    Add-CheckResult -Name 'Externes Hyper-V-State-Receipt wird atomar auf den Zielroot neu ausgestellt' -Success (
        [string]$migratedBinding.LabDataRoot -eq $targetRoot -and
        [string]$migratedBinding.ResourceId -eq [string]$hyperVFixture.ResourceId -and
        (Test-Path -LiteralPath (Join-Path ([string]$migratedBinding.HyperVResourceRoot) 'child.vhdx') -PathType Leaf)
    )
    Add-CheckResult -Name 'Storage-Migrationsjournal erfüllt das aktuelle JSON-Schema' -Success (
        (Get-Content -LiteralPath $result.JournalPath -Raw -Encoding utf8) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/lab-storage-migration-journal.schema.json') -ErrorAction SilentlyContinue
    )
    Add-CheckResult -Name 'Abschlussjournal bleibt mit Location-Bindung am Ziel erhalten' -Success (
        $journal.Status -eq 'COMPLETED' -and $journal.PlanSha256 -match '^[a-f0-9]{64}$' -and
        [string]$journal.LocationId -eq [string]$migrationContract.Plan.Source.LocationId -and
        @($journal.ReboundBindings).Count -eq 1
    )
    Add-CheckResult -Name 'Verifizierter leerer Quellroot wird entfernt' -Success (-not (Test-Path -LiteralPath $sourceRoot))
}
catch { Add-CheckResult -Name 'Storage-Migration-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally {
    $env:SQL_SERVER_LAB_DATA_ROOT = $previousDataRoot
    $env:SQL_SERVER_LAB_STATE = $previousStateRoot
    if (Test-Path -LiteralPath $temporaryParent) { Remove-Item -LiteralPath $temporaryParent -Recurse -Force }
}
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0

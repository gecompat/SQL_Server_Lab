#Requires -Version 7.2
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$temporaryParent = Join-Path ([IO.Path]::GetTempPath()) "hvr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$dataRoot = Join-Path $temporaryParent 'managed/Lab_Data'
$stateRoot = Join-Path $temporaryParent 'state'
$failures = [Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''; Write-Host 'SQL_Server_Lab - Hyper-V Resource Migration Checks' -ForegroundColor Cyan
try {
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    $result = & $module {
        param($Root, $ManagedRoot, $PlanSchema, $JournalSchema)
        $null = Initialize-LabManagedDataRoot -DataRoot $ManagedRoot -Confirm:$false
        $storageConfiguration = Get-LabStorageConfiguration -DataRoot $ManagedRoot
        $storageConfiguration.LabDataLocations[0].Selectors = @('sqldata')
        $null = Write-LabStorageConfiguration -Configuration $storageConfiguration -AdditionalRoots @($ManagedRoot)
        $run = New-LabRunState -StateRoot $Root -Metadata @{ name='legacy-hyperv-migration'; workflowKind='hyperv-lab' } `
            -ProviderSubRuns @([PSCustomObject]@{ id='provider-hyperv'; provider='hyperv'; instanceIds=@('primary') })
        $runDirectory = Join-Path (Join-Path $Root 'runs') $run.runId
        $legacyRoot = Join-Path $runDirectory 'resources/hyperv'
        New-Item -Path $legacyRoot -ItemType Directory -Force | Out-Null
        $sourceDisk = Join-Path $legacyRoot 'legacy-os.vhdx'
        [IO.File]::WriteAllBytes($sourceDisk, [Text.Encoding]::UTF8.GetBytes('legacy-vhdx-content'))
        [IO.File]::WriteAllBytes((Join-Path $legacyRoot 'legacy-vm-state.bin'), [Text.Encoding]::UTF8.GetBytes('legacy-vm-state'))
        $externalRoot = Join-Path $ManagedRoot 'Labs/external/Instances/hyperv/primary/Storage/sqlData'
        New-Item -Path $externalRoot -ItemType Directory -Force | Out-Null
        $externalDisk = Join-Path $externalRoot 'external-data.vhdx'
        [IO.File]::WriteAllBytes($externalDisk, [Text.Encoding]::UTF8.GetBytes('external-vhdx-content'))
        $legacyImageRoot = Join-Path $Root 'artifacts/hyperv/images'
        $parentBytes = [Text.Encoding]::ASCII.GetBytes('vhdxfile-synthetic-legacy-parent')
        $parentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($parentBytes)).ToLowerInvariant()
        $artifactId = "hyperv-resource-migration-$parentHash"
        $parentRoot = Join-Path $legacyImageRoot $artifactId
        New-Item -Path $parentRoot -ItemType Directory -Force | Out-Null
        $parentDisk = Join-Path $parentRoot 'parent.vhdx'
        [IO.File]::WriteAllBytes($parentDisk, $parentBytes)
        [PSCustomObject]@{ contractVersion='1'; artifactId=$artifactId; sha256=$parentHash; displayName='Legacy migration parent' } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $parentRoot 'metadata.json') -Encoding utf8
        (Get-Item -LiteralPath $parentDisk -Force).IsReadOnly = $true

        $notes = ConvertTo-HyperVLabNotes -RunId $run.runId -ScopeId $run.scopeId -InstanceId primary `
            -ChildVhdxPath $sourceDisk -AdditionalDrives @([PSCustomObject]@{
                Id='data'; Role='sqlData'; SizeBytes=64MB; VhdType='dynamic'; Path=$externalDisk
                DiskIdentifier='22222222-2222-2222-2222-222222222222'; ControllerNumber=0
                ControllerLocation=1; FileSystem='NTFS'; AllocationUnitKB=64; VolumeLabel='SQLDATA'; MaximumIops=0
                HostRoot=$externalRoot; LocationId=[string]$storageConfiguration.LabDataLocations[0].LocationId; Selector='sqldata'
            })
        $script:migrationVm = [PSCustomObject]@{
            Name='sql-lab-legacy'; State='Off'; Path=$legacyRoot
            SmartPagingFilePath=$legacyRoot; SnapshotFileLocation=$legacyRoot; Notes=$notes
        }
        $script:osDrive = [PSCustomObject]@{ Path=$sourceDisk; ControllerType='SCSI'; ControllerNumber=0; ControllerLocation=0 }
        $script:externalDrive = [PSCustomObject]@{ Path=$externalDisk; ControllerType='SCSI'; ControllerNumber=0; ControllerLocation=1 }
        $script:snapshotCount = 1
        $script:failReadiness = $false
        $script:failSetVhdAfterMutation = $false
        $script:moveCalls = 0
        $script:setVhdCalls = 0
        $script:vhdParents = @{}
        $script:vhdParents[[IO.Path]::GetFullPath($sourceDisk)] = [IO.Path]::GetFullPath($parentDisk)

        function Get-VM {
            param([string]$Name, [Parameter(ValueFromPipeline=$true)]$InputObject)
            process { $script:migrationVm }
        }
        function Get-VMHardDiskDrive {
            param([Parameter(ValueFromPipeline=$true)]$VM)
            process { @($script:osDrive, $script:externalDrive) }
        }
        function Get-VMSnapshot { param($VM); if ($script:snapshotCount -gt 0) { [PSCustomObject]@{ Name='unsafe-checkpoint' } } }
        function Get-VHD {
            param([string]$Path)
            $fullPath = [IO.Path]::GetFullPath($Path)
            $parent = if ($script:vhdParents.ContainsKey($fullPath)) { [string]$script:vhdParents[$fullPath] }
                elseif ((Split-Path -Leaf $fullPath) -eq 'legacy-os.vhdx') { [IO.Path]::GetFullPath($parentDisk) }
                else { $null }
            [PSCustomObject]@{
                Path=$fullPath; VhdType=if ($parent) { 'Differencing' } else { 'Fixed' }; Size=64MB
                FileSize=(Get-Item -LiteralPath $Path).Length
                DiskIdentifier='11111111-1111-1111-1111-111111111111'; ParentPath=$parent
            }
        }
        function Set-VHD {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Synthetischer Hyper-V-Mock ohne Hostmutation.')]
            param([string]$Path,[string]$ParentPath)
            $fullPath=[IO.Path]::GetFullPath($Path); $script:vhdParents[$fullPath]=[IO.Path]::GetFullPath($ParentPath)
            [IO.File]::AppendAllText($fullPath, '|reparented|')
            $script:setVhdCalls++
            if ($script:failSetVhdAfterMutation) { $script:failSetVhdAfterMutation=$false; throw 'SYNTHETIC_REPARENT_INTERRUPTION' }
        }
        function Stop-HyperVInstance { param($VMName,$ExpectedRunId,$ExpectedScopeId); $script:migrationVm.State='Off'; [PSCustomObject]@{ State='Off' } }
        function Start-HyperVInstance { param($VMName,$ExpectedRunId,$ExpectedScopeId); $script:migrationVm.State='Running'; [PSCustomObject]@{ State='Running' } }
        function Set-VMHardDiskDrive { param($VMHardDiskDrive,$Path); $VMHardDiskDrive.Path=[IO.Path]::GetFullPath($Path) }
        function Move-VMStorage {
            param($VM,$VirtualMachinePath,$SnapshotFilePath,$SmartPagingFilePath)
            $script:moveCalls++
            $VM.Path=[IO.Path]::GetFullPath($VirtualMachinePath)
            $VM.SnapshotFileLocation=[IO.Path]::GetFullPath($SnapshotFilePath)
            $VM.SmartPagingFilePath=[IO.Path]::GetFullPath($SmartPagingFilePath)
        }
        function Set-VM { param($VM,$Notes); if ($PSBoundParameters.ContainsKey('Notes')) { $VM.Notes=$Notes }; $VM }
        function Wait-HyperVPowerShellDirect {
            param($VMName,$ExpectedRunId,$ExpectedScopeId,$Credential,$TimeoutSeconds)
            if ($script:failReadiness) { throw 'SYNTHETIC_GUEST_READINESS_FAILURE' }
            [PSCustomObject]@{ Ready=$true; Message='' }
        }

        [PSCustomObject]@{ instances=@([PSCustomObject]@{ id='primary'; provider='hyperv'; vmName=$script:migrationVm.Name; childVhdxPath=$sourceDisk }) } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDirectory 'connection-info.json') -Encoding utf8
        $null = New-CleanupPlan -RunDir $runDirectory -RunId $run.runId -ScopeId $run.scopeId `
            -ProviderSubRuns @([PSCustomObject]@{ id='provider-hyperv'; provider='hyperv' })
        $null = Add-CleanupStep -RunDir $runDirectory -ResourceType vhdx -ResourceId $sourceDisk -Action remove `
            -Provider hyperv -ProviderSubRunId provider-hyperv

        $imagePlan = New-LabHyperVImageMigrationPlan -StateRoot $Root -DataRoot $ManagedRoot
        $imageWaiting = Invoke-LabHyperVImageMigration -PlanPath $imagePlan.Path -DataRoot $ManagedRoot -Confirm:$false
        $targetParent = [string]$imagePlan.Plan.Inventory.Artifacts[0].DestinationParentPath

        $blocked = New-LabHyperVResourceMigrationPlan -RunId $run.runId -StateRoot $Root -DataRoot $ManagedRoot
        $script:snapshotCount = 0
        $ready = New-LabHyperVResourceMigrationPlan -RunId $run.runId -StateRoot $Root -DataRoot $ManagedRoot
        $legacyLifecycleGuard = Get-LabHyperVResourceMigrationLifecycleGuard -RunId $run.runId -StateRoot $Root
        $testPassword = [Security.SecureString]::new()
        foreach ($character in 'Migration-Test-Only!'.ToCharArray()) { $testPassword.AppendChar($character) }
        $testPassword.MakeReadOnly()
        $credential = [PSCredential]::new('Administrator', $testPassword)
        $ready.Plan.Inventory.VMs[0].LegacyDisks[0].SourcePath = $externalDisk
        Write-LabArtifactJsonAtomic -Path $ready.Path -InputObject $ready.Plan
        $tamperedPlanMessage = try {
            Invoke-LabHyperVResourceMigration -PlanPath $ready.Path -Credential $credential -DataRoot $ManagedRoot -Confirm:$false | Out-Null
            ''
        } catch { $_.Exception.Message }
        $ready = New-LabHyperVResourceMigrationPlan -RunId $run.runId -StateRoot $Root -DataRoot $ManagedRoot
        $ready.Plan.Inventory.VMs[0].LegacyDisks[0].TargetParentPath = $externalDisk
        Write-LabArtifactJsonAtomic -Path $ready.Path -InputObject $ready.Plan
        $tamperedParentMessage = try {
            Invoke-LabHyperVResourceMigration -PlanPath $ready.Path -Credential $credential -DataRoot $ManagedRoot -Confirm:$false | Out-Null
            ''
        } catch { $_.Exception.Message }
        $ready = New-LabHyperVResourceMigrationPlan -RunId $run.runId -StateRoot $Root -DataRoot $ManagedRoot
        $whatIf = Invoke-LabHyperVResourceMigration -PlanPath $ready.Path -Credential $credential -DataRoot $ManagedRoot -WhatIf
        $whatIfPreservedState = (Test-Path -LiteralPath $sourceDisk -PathType Leaf) -and $script:migrationVm.Path -eq $legacyRoot -and $script:moveCalls -eq 0
        $script:failSetVhdAfterMutation = $true
        $recoveryMessage = try {
            Invoke-LabHyperVResourceMigration -PlanPath $ready.Path -Credential $credential -DataRoot $ManagedRoot -Confirm:$false | Out-Null
            ''
        } catch { $_.Exception.Message }
        $journalAfterFailure = Get-Content -LiteralPath (Join-Path $runDirectory 'hyperv-resource-migration.local.journal.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
        $recoveryLifecycleGuard = Get-LabHyperVResourceMigrationLifecycleGuard -RunId $run.runId -StateRoot $Root
        $recoveryLifecycleMessage = try {
            Assert-LabHyperVResourceMigrationLifecycleAllowed -RunId $run.runId -Operation 'START' -StateRoot $Root | Out-Null
            ''
        } catch { $_.Exception.Message }
        $sourceRetainedAfterFailure = Test-Path -LiteralPath $sourceDisk -PathType Leaf
        $completed = Invoke-LabHyperVResourceMigration -PlanPath $ready.Path -Credential $credential -DataRoot $ManagedRoot -Confirm:$false
        $idempotent = Invoke-LabHyperVResourceMigration -PlanPath $ready.Path -Credential $credential -DataRoot $ManagedRoot -Confirm:$false
        $completedLifecycleGuard = Get-LabHyperVResourceMigrationLifecycleGuard -RunId $run.runId -StateRoot $Root
        $binding = Read-LabHyperVResourceBinding -StateDirectory $runDirectory -DataRoot $ManagedRoot
        $storageMigrationDirectory = Join-Path (Join-Path $ManagedRoot 'Catalog') 'storage-migrations'
        New-Item -Path $storageMigrationDirectory -ItemType Directory -Force | Out-Null
        $storageMigrationJournalPath = Join-Path $storageMigrationDirectory 'lifecycle-guard-fixture.journal.json'
        Write-LabArtifactJsonAtomic -Path $storageMigrationJournalPath -InputObject ([PSCustomObject]@{
            ContractVersion='SqlServerLab.StorageMigrationJournal/1.0'
            LocationId=[string]$binding.LocationId; Status='REBINDING'
        })
        $storageMigrationLifecycleGuard = Get-LabHyperVResourceMigrationLifecycleGuard `
            -RunId $run.runId -StateRoot $Root
        Remove-Item -LiteralPath $storageMigrationJournalPath -Force
        $journalJson = Get-Content -LiteralPath $completed.JournalPath -Raw -Encoding utf8
        $journal = $journalJson | ConvertFrom-Json -Depth 50
        $imageJournal = Get-Content -LiteralPath (Get-LabHyperVImageMigrationPaths -StateRoot $Root).Journal -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
        $cleanup = Get-Content -LiteralPath (Join-Path $runDirectory 'cleanup-plan.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        $identity = ConvertFrom-HyperVLabNotes -Notes ([string]$script:migrationVm.Notes)
        [PSCustomObject]@{
            Blocked=$blocked.Plan; Ready=$ready.Plan
            PlanSchemaValid=(($ready.Plan | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile $PlanSchema -ErrorAction SilentlyContinue)
            TamperedPlanMessage=$tamperedPlanMessage; TamperedParentMessage=$tamperedParentMessage
            WhatIf=$whatIf; WhatIfPreservedState=$whatIfPreservedState
            RecoveryMessage=$recoveryMessage; FailureJournal=$journalAfterFailure
            LegacyLifecycleGuard=$legacyLifecycleGuard; RecoveryLifecycleGuard=$recoveryLifecycleGuard
            RecoveryLifecycleMessage=$recoveryLifecycleMessage; CompletedLifecycleGuard=$completedLifecycleGuard
            StorageMigrationLifecycleGuard=$storageMigrationLifecycleGuard
            SourceRetainedAfterFailure=$sourceRetainedAfterFailure; Completed=$completed; Idempotent=$idempotent
            Binding=$binding; Journal=$journal; JournalSchemaValid=($journalJson | Test-Json -SchemaFile $JournalSchema -ErrorAction SilentlyContinue)
            Cleanup=$cleanup; Identity=$identity; SourceDisk=$sourceDisk; ExternalDisk=$externalDisk
            LegacyRoot=$legacyRoot
            ActualOsDisk=[string]$script:osDrive.Path; ActualExternalDisk=[string]$script:externalDrive.Path
            VM=$script:migrationVm; MoveCalls=$script:moveCalls; SetVhdCalls=$script:setVhdCalls
            SourceParent=$parentDisk; TargetParent=$targetParent; ImageWaiting=$imageWaiting; ImageJournal=$imageJournal
            ActualParent=[string](Get-VHD -Path ([string]$script:osDrive.Path)).ParentPath
        }
    } $stateRoot $dataRoot (Join-Path $repoRoot 'Schemas/hyperv-resource-migration-plan.schema.json') (Join-Path $repoRoot 'Schemas/hyperv-resource-migration-journal.schema.json')

    Add-CheckResult -Name 'Checkpoint blockiert den read-only Legacy-Migrationsplan' -Success (
        $result.Blocked.Status -eq 'BLOCKED' -and @($result.Blocked.Blockers | Where-Object { $_ -match 'CHECKPOINTS_PRESENT' }).Count -eq 1
    )
    Add-CheckResult -Name 'Freier Legacy-Run erzeugt einen schema-validen ausführbaren Plan' -Success (
        $result.Ready.Status -eq 'READY' -and $result.PlanSchemaValid -and $result.Ready.ExecutionImplemented
    )
    Add-CheckResult -Name 'Plan inventarisiert VM-State und trennt externe SQL-Lane' -Success (
        @($result.Ready.Inventory.VMs[0].LegacyDisks).Count -eq 1 -and @($result.Ready.Inventory.VMs[0].ExternalDisks).Count -eq 1 -and
        $result.Ready.Inventory.VMs[0].ExternalDisks[0].Selector -eq 'sqldata'
    )
    Add-CheckResult -Name 'Manipulierter Plan kann keine Quelle außerhalb des Legacy-Roots einschleusen' -Success (
        $result.TamperedPlanMessage -match 'HYPERV_RESOURCE_MIGRATION_SOURCE_SCOPE_INVALID'
    )
    Add-CheckResult -Name 'Manipulierter Plan kann kein anderes Parent-Ziel einschleusen' -Success (
        $result.TamperedParentMessage -match 'HYPERV_RESOURCE_MIGRATION_PARENT_MAPPING_CHANGED'
    )
    Add-CheckResult -Name 'WhatIf bleibt vor jeder Hyper-V- und Dateimutation' -Success (
        $null -eq $result.WhatIf -and $result.WhatIfPreservedState
    )
    Add-CheckResult -Name 'Legacy-Lifecycle bleibt bis zum Start einer Migration zulässig' -Success (
        $result.LegacyLifecycleGuard.Allowed -and $result.LegacyLifecycleGuard.JournalStatus -eq 'ABSENT' -and
        $result.LegacyLifecycleGuard.BindingStatus -eq 'ABSENT_LEGACY'
    )
    Add-CheckResult -Name 'Unterbrochenes Reparent hinterlässt RECOVERY_REQUIRED und bewahrt die Quelle' -Success (
        $result.RecoveryMessage -match 'HYPERV_RESOURCE_MIGRATION_RECOVERY_REQUIRED' -and
        $result.FailureJournal.Status -eq 'RECOVERY_REQUIRED' -and $result.SourceRetainedAfterFailure -and
        @($result.FailureJournal.ParentReparents).Count -eq 1 -and $result.FailureJournal.ParentReparents[0].State -eq 'PENDING'
    )
    Add-CheckResult -Name 'RECOVERY_REQUIRED blockiert konkurrierenden Lifecycle und Repair fail-closed' -Success (
        -not $result.RecoveryLifecycleGuard.Allowed -and
        $result.RecoveryLifecycleGuard.ReasonCode -eq 'HYPERV_RESOURCE_MIGRATION_LIFECYCLE_BLOCKED' -and
        $result.RecoveryLifecycleMessage -match 'HYPERV_RESOURCE_MIGRATION_LIFECYCLE_BLOCKED'
    )
    Add-CheckResult -Name 'Resume schließt dasselbe Journal idempotent ab' -Success (
        $result.Completed.Status -eq 'COMPLETED' -and $result.Idempotent.Status -eq 'COMPLETED' -and $result.Journal.Status -eq 'COMPLETED'
    )
    Add-CheckResult -Name 'Abschlussjournal ist schema-valid und belegt zwei Restart-Zyklen' -Success (
        $result.JournalSchemaValid -and @($result.Journal.ReadinessReceipts).Count -eq 2 -and $result.Journal.BindingCommitted
    )
    Add-CheckResult -Name 'COMPLETED erlaubt Lifecycle nur mit revalidiertem committed Run-Binding' -Success (
        $result.CompletedLifecycleGuard.Allowed -and $result.CompletedLifecycleGuard.JournalStatus -eq 'COMPLETED' -and
        $result.CompletedLifecycleGuard.BindingStatus -eq 'VALID'
    )
    Add-CheckResult -Name 'Nichtterminale allgemeine Storage-Migration blockiert Hyper-V-Lifecycle' -Success (
        -not $result.StorageMigrationLifecycleGuard.Allowed -and
        $result.StorageMigrationLifecycleGuard.ReasonCode -eq 'HYPERV_STORAGE_MIGRATION_LIFECYCLE_BLOCKED'
    )
    Add-CheckResult -Name 'Legacy-Child wird genau einmal auf das verifizierte Lab_Data-Parent umgehängt' -Success (
        $result.ImageWaiting.Status -eq 'WAITING_FOR_CONSUMERS' -and $result.SetVhdCalls -eq 1 -and
        $result.ActualParent -eq $result.TargetParent -and @($result.Journal.ParentReparents).Count -eq 1 -and
        $result.Journal.ParentReparents[0].State -eq 'COMPLETED' -and
        $result.Journal.ParentReparents[0].SourceSha256 -ne $result.Journal.ParentReparents[0].TargetSha256
    )
    Add-CheckResult -Name 'Run-Abschluss setzt Image-Migration fort und entfernt das referenzfreie Legacy-Parent' -Success (
        $result.ImageJournal.Status -eq 'COMPLETED' -and @($result.Journal.ImageMigrationResumes | Where-Object Status -eq 'COMPLETED').Count -eq 1 -and
        -not (Test-Path -LiteralPath $result.SourceParent) -and (Test-Path -LiteralPath $result.TargetParent -PathType Leaf)
    )
    Add-CheckResult -Name 'OS-VHDX, VM-Konfiguration, Paging und Snapshot liegen im gebundenen Root' -Success (
        $result.ActualOsDisk -like "$($result.Binding.HyperVResourceRoot)*" -and
        $result.VM.Path -like "$($result.Binding.HyperVResourceRoot)*" -and
        $result.VM.SmartPagingFilePath -like "$($result.Binding.HyperVResourceRoot)*" -and
        $result.VM.SnapshotFileLocation -like "$($result.Binding.HyperVResourceRoot)*"
    )
    Add-CheckResult -Name 'Selectorgebundene externe SQL-Lane bleibt unverändert' -Success (
        $result.ActualExternalDisk -eq $result.ExternalDisk -and $result.Identity.additionalVhdxPaths -contains $result.ExternalDisk
    )
    Add-CheckResult -Name 'Notes und Cleanup-Plan referenzieren nur noch die migrierte OS-VHDX' -Success (
        $result.Identity.childVhdxPath -eq $result.ActualOsDisk -and
        @($result.Cleanup.steps | Where-Object resourceId -eq $result.ActualOsDisk).Count -eq 1
    )
    Add-CheckResult -Name 'Inventarisierter Legacy-Root wird erst nach erfolgreicher Readiness vollständig entfernt' -Success (
        -not (Test-Path -LiteralPath $result.SourceDisk) -and -not (Test-Path -LiteralPath $result.LegacyRoot) -and
        @($result.Journal.SourceCleanup).Count -eq 2
    )
}
catch { Add-CheckResult -Name 'Hyper-V-Resource-Migration-Testausführung' -Success $false -Message $_.Exception.Message }
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryParent) { Remove-Item -LiteralPath $temporaryParent -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0

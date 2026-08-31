#Requires -Version 7.2
<#
.SYNOPSIS
    Führt die reale erhöhte HVR-008-Legacy-Migration eines gestoppten oder laufenden Hyper-V-Runs aus.
.DESCRIPTION
    Validiert einen exakt benannten projektverwalteten Legacy-Run, veröffentlicht
    dessen Parent-Image hashgebunden im registrierten Lab_Data, migriert und
    reparentet die run-eigenen VHDX, verschiebt VM-Konfiguration, Paging und
    Snapshots, belegt zwei Gast-Restart-Zyklen und prüft den Recovery-/Cleanup-
    Zustand. Der migrierte Run bleibt als beabsichtigter persistenter Endzustand
    erhalten. Shared Parent-Images werden erst nach dem letzten Consumer entfernt.
.PARAMETER RunId
    Exakte Run-ID des zu migrierenden Legacy-Runs.
.PARAMETER ExpectedVMName
    Erwarteter VM-Name als zweite Identitätsgrenze.
.PARAMETER LegacyStateRoot
    Vollqualifizierter bisheriger StateRoot des Legacy-Runs.
.PARAMETER DataRoot
    Registrierter Zielroot Lab_Data.
.PARAMETER ReadinessTimeoutSeconds
    Maximale Wartezeit je Gast-Readiness-Zyklus.
.PARAMETER ExpectedInitialVMState
    Exakter erwarteter VM-Ausgangszustand, der nach der Migration wiederhergestellt wird.
.PARAMETER RequireSqlReadiness
    Verlangt für beide Gastzyklen zusätzlich SQL_READY_RUN.
.PARAMETER ExpectedSqlMajorVersion
    Erwartete SQL-Hauptversion für den SQL-gebundenen Nachweis.
.PARAMETER AdoptLegacySqlIdentity
    Übernimmt bei einem laufenden Legacy-SQL-Run die bereits persistierte
    Windows-Provisionierung erst nach einem erfolgreichen Live-SQL-Probe in
    die aktuelle VM-Identität.
.PARAMETER EvidencePath
    Optionaler Pfad außerhalb des Repositorys für die secretfreie JSON-Evidence.
.EXAMPLE
    .\Tests\Integration\Invoke-HyperVResourceMigrationAcceptance.ps1 `
        -RunId '<run-guid>' -ExpectedVMName '<vm-name>' `
        -LegacyStateRoot "$env:LOCALAPPDATA\SqlServerLab" -DataRoot 'D:\Lab_Data' `
        -EvidencePath "$env:TEMP\hvr008-evidence.json" -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RunId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedVMName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LegacyStateRoot,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DataRoot,
    [ValidateRange(30, 3600)][int]$ReadinessTimeoutSeconds = 600,
    [ValidateSet('Off', 'Running')][string]$ExpectedInitialVMState = 'Off',
    [switch]$RequireSqlReadiness,
    [ValidateRange(0, 99)][int]$ExpectedSqlMajorVersion = 0,
    [switch]$AdoptLegacySqlIdentity,
    [string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'HVR008_ACCEPTANCE_ELEVATION_REQUIRED'
}

$resolvedStateRoot = [IO.Path]::GetFullPath($LegacyStateRoot).TrimEnd('\', '/')
$resolvedDataRoot = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\', '/')
if ([string]::Equals($resolvedStateRoot, $resolvedDataRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'HVR008_ACCEPTANCE_DISTINCT_ROOTS_REQUIRED'
}
if ($RequireSqlReadiness -and $ExpectedSqlMajorVersion -eq 0) {
    throw 'HVR008_ACCEPTANCE_EXPECTED_SQL_MAJOR_REQUIRED'
}
if (-not $PSCmdlet.ShouldProcess(
        "Run $RunId / VM $ExpectedVMName",
        "Legacy-Hyper-V-Parent und Run-Ressourcen nach $resolvedDataRoot migrieren, zweimal neu starten und die verifizierte Legacy-Quelle bereinigen")) {
    return
}

$module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
$result = $null
try {
    $result = & $module {
        param(
            $StateRoot, $TargetDataRoot, $ExpectedRunId, $ExpectedName, $TimeoutSeconds,
            $ExpectedInitialState, $SqlRequired, $ExpectedSqlMajor, $AdoptSqlIdentity
        )

        $run = Get-LabRunState -RunId $ExpectedRunId -StateRoot $StateRoot
        $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $ExpectedRunId
        $resourcePaths = Get-LabHyperVResourceMigrationPaths -RunDirectory $runDirectory
        $resourceJournalBefore = if (Test-Path -LiteralPath $resourcePaths.Journal -PathType Leaf) {
            Get-Content -LiteralPath $resourcePaths.Journal -Raw -Encoding utf8 | ConvertFrom-Json -Depth 60
        } else { $null }
        $connectionPath = Join-Path $runDirectory 'connection-info.json'
        if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) {
            throw 'HVR008_ACCEPTANCE_CONNECTION_INFO_REQUIRED'
        }
        $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
        $instances = @($connection.instances | Where-Object { [string]$_.provider -eq 'hyperv' })
        if ($instances.Count -ne 1 -or [string]$instances[0].vmName -ne $ExpectedName) {
            throw 'HVR008_ACCEPTANCE_CANDIDATE_IDENTITY_MISMATCH'
        }
        $managed = Get-HyperVManagedVM -VMName $ExpectedName -ExpectedRunId $ExpectedRunId `
            -ExpectedScopeId ([string]$run.scopeId)
        $resumeStateAllowed = $ExpectedInitialState -eq 'Running' -and $resourceJournalBefore -and
            [string]$managed.VM.State -eq 'Off'
        if (-not $managed -or
            ([string]$managed.VM.State -ne $ExpectedInitialState -and -not $resumeStateAllowed)) {
            throw "HVR008_ACCEPTANCE_CANDIDATE_STATE_MISMATCH: expected=$ExpectedInitialState"
        }
        $guestSecret = Get-LabSecret -Path $runDirectory -Name 'guest-administrator-password'
        if (-not $guestSecret) {
            throw 'HVR008_ACCEPTANCE_GUEST_SECRET_REQUIRED'
        }
        $credential = [PSCredential]::new('Administrator', $guestSecret)
        $saSecret = $null
        if ($SqlRequired) {
            $saSecret = Get-LabSecret -Path $runDirectory -Name 'generated-sql-sa-password'
            if (-not $saSecret) { $saSecret = Get-LabSecret -Path $runDirectory -Name 'sa-password' }
            if (-not $saSecret) { throw 'HVR008_ACCEPTANCE_SQL_SECRET_REQUIRED' }
            $sqlIdentity = $managed.Identity.sqlReadiness
            if ([string]$sqlIdentity.status -ne 'SQL_READY_RUN' -and $AdoptSqlIdentity) {
                if ($ExpectedInitialState -ne 'Running' -or [string]$managed.VM.State -ne 'Running') {
                    throw 'HVR008_ACCEPTANCE_SQL_IDENTITY_ADOPTION_REQUIRES_RUNNING_VM'
                }
                $legacyWindows = $instances[0].windowsProvisioning
                $legacySqlMajor = switch -Regex ([string]$instances[0].sqlVersion) {
                    '^2019(?:-|$)' { 15; break }
                    '^2022(?:-|$)' { 16; break }
                    '^2025(?:-|$)' { 17; break }
                    default { 0 }
                }
                if ([string]$instances[0].workload -ne 'sql' -or
                    [string]$legacyWindows.state -ne 'COMPLETE' -or
                    [string]$instances[0].hostSqlAccess.state -ne 'READY' -or
                    $legacySqlMajor -ne $ExpectedSqlMajor) {
                    throw 'HVR008_ACCEPTANCE_LEGACY_SQL_ADOPTION_EVIDENCE_INVALID'
                }
                if ([string]$managed.Identity.windowsSpecialization.status -ne 'WINDOWS_SPECIALIZED') {
                    $null = Set-HyperVManagedVMIdentityProperty -ManagedVM $managed `
                        -PropertyName windowsSpecialization -ContractVersion '0.5' `
                        -Value ([PSCustomObject]@{
                            status='WINDOWS_SPECIALIZED'; computerName=[string]$legacyWindows.computerName
                            imageState=[string]$legacyWindows.imageState; rebooted=$false; observedAt=Get-LabTimestamp
                            evidenceSource='legacy-connection-and-live-sql-acceptance'
                        })
                    $managed = Get-HyperVManagedVM -VMName $ExpectedName -ExpectedRunId $ExpectedRunId `
                        -ExpectedScopeId ([string]$run.scopeId)
                }
                $null = Wait-HyperVGuestSqlReady -VMName $ExpectedName -ExpectedRunId $ExpectedRunId `
                    -ExpectedScopeId ([string]$run.scopeId) -Credential $credential -SaPassword $saSecret `
                    -ExpectedMajorVersion $ExpectedSqlMajor -TimeoutSeconds $TimeoutSeconds
                $managed = Get-HyperVManagedVM -VMName $ExpectedName -ExpectedRunId $ExpectedRunId `
                    -ExpectedScopeId ([string]$run.scopeId)
                $sqlIdentity = $managed.Identity.sqlReadiness
            }
            if ([string]$sqlIdentity.status -ne 'SQL_READY_RUN' -or
                [int]$sqlIdentity.majorVersion -ne $ExpectedSqlMajor -or
                [int]$sqlIdentity.onlineSystemDatabases -ne 4) {
                throw 'HVR008_ACCEPTANCE_SQL_IDENTITY_REQUIRED'
            }
        }

        $preview = Get-LabHyperVResourceLocationPreview -ResourceClass Run, Image -DataRoot $TargetDataRoot
        $imagePaths = Get-LabHyperVImageMigrationPaths -StateRoot $StateRoot
        $imagePlanResult = $null
        if (Test-Path -LiteralPath $imagePaths.Journal -PathType Leaf) {
            if (-not (Test-Path -LiteralPath $imagePaths.Plan -PathType Leaf)) {
                throw 'HVR008_ACCEPTANCE_IMAGE_PLAN_REQUIRED_FOR_RESUME'
            }
            $imagePlan = Get-Content -LiteralPath $imagePaths.Plan -Raw -Encoding utf8 | ConvertFrom-Json -Depth 60
        }
        else {
            $imagePlanResult = New-LabHyperVImageMigrationPlan -StateRoot $StateRoot -DataRoot $TargetDataRoot
            $imagePlan = $imagePlanResult.Plan
        }
        if ([string]$imagePlan.Status -eq 'BLOCKED' -or @($imagePlan.Blockers).Count -gt 0) {
            throw "HVR008_ACCEPTANCE_IMAGE_PLAN_BLOCKED: $(@($imagePlan.Blockers) -join ', ')"
        }
        $imageApply = if ([string]$imagePlan.Status -eq 'NOOP') {
            [PSCustomObject]@{ Status = 'NOOP'; JournalPath = $null; ResourceRoot = [string]$imagePlan.Target.ResourceRoot }
        }
        elseif ([string]$resourceJournalBefore.Status -eq 'COMPLETED' -and (Test-Path -LiteralPath $imagePaths.Journal -PathType Leaf)) {
            $completedImageJournal = Get-Content -LiteralPath $imagePaths.Journal -Raw -Encoding utf8 | ConvertFrom-Json -Depth 60
            if ([string]$completedImageJournal.Status -notin @('WAITING_FOR_CONSUMERS', 'COMPLETED')) {
                throw "HVR008_ACCEPTANCE_IMAGE_JOURNAL_INVALID: $([string]$completedImageJournal.Status)"
            }
            [PSCustomObject]@{ Status=[string]$completedImageJournal.Status; JournalPath=$imagePaths.Journal; ResourceRoot=[string]$imagePlan.Target.ResourceRoot }
        }
        else {
            Invoke-LabHyperVImageMigration -PlanPath $imagePaths.Plan -DataRoot $TargetDataRoot -Confirm:$false
        }

        $restoreExpectedRunningState = {
            $null = Start-HyperVInstance -VMName $ExpectedName -ExpectedRunId $ExpectedRunId `
                -ExpectedScopeId ([string]$run.scopeId)
            $ready = Wait-HyperVPowerShellDirect -VMName $ExpectedName -ExpectedRunId $ExpectedRunId `
                -ExpectedScopeId ([string]$run.scopeId) -Credential $credential -TimeoutSeconds $TimeoutSeconds
            if (-not $ready.Ready) { throw 'HVR008_ACCEPTANCE_FINAL_GUEST_READINESS_FAILED' }
            $sqlReady = $false
            if ($SqlRequired) {
                $sqlReceipt = Wait-HyperVGuestSqlReady -VMName $ExpectedName -ExpectedRunId $ExpectedRunId `
                    -ExpectedScopeId ([string]$run.scopeId) -Credential $credential -SaPassword $saSecret `
                    -ExpectedMajorVersion $ExpectedSqlMajor -TimeoutSeconds $TimeoutSeconds
                $sqlReady = [string]$sqlReceipt.Status -eq 'SQL_READY_RUN'
                if (-not $sqlReady) { throw 'HVR008_ACCEPTANCE_FINAL_SQL_READINESS_FAILED' }
            }
            [PSCustomObject]@{ GuestReady=$true; SqlReady=$sqlReady }
        }

        $stoppedForPlanning = $false
        try {
            if (Test-Path -LiteralPath $resourcePaths.Journal -PathType Leaf) {
                if (-not (Test-Path -LiteralPath $resourcePaths.Plan -PathType Leaf)) {
                    throw 'HVR008_ACCEPTANCE_RUN_PLAN_REQUIRED_FOR_RESUME'
                }
                $resourcePlan = Get-Content -LiteralPath $resourcePaths.Plan -Raw -Encoding utf8 | ConvertFrom-Json -Depth 60
            }
            else {
                if ($ExpectedInitialState -eq 'Running') {
                    $managedForPlan = Get-HyperVManagedVM -VMName $ExpectedName -ExpectedRunId $ExpectedRunId `
                        -ExpectedScopeId ([string]$run.scopeId)
                    if ([string]$managedForPlan.VM.State -ne 'Running') {
                        throw 'HVR008_ACCEPTANCE_RUNNING_VM_REQUIRED_BEFORE_PLAN'
                    }
                    $null = Stop-HyperVInstance -VMName $ExpectedName -ExpectedRunId $ExpectedRunId `
                        -ExpectedScopeId ([string]$run.scopeId)
                    $shutdownDeadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
                    do {
                        Start-Sleep -Seconds 2
                        $managedForPlan = Get-HyperVManagedVM -VMName $ExpectedName -ExpectedRunId $ExpectedRunId `
                            -ExpectedScopeId ([string]$run.scopeId)
                    } while ([string]$managedForPlan.VM.State -ne 'Off' -and
                        [DateTimeOffset]::UtcNow -lt $shutdownDeadline)
                    if ([string]$managedForPlan.VM.State -ne 'Off') {
                        throw 'HVR008_ACCEPTANCE_GRACEFUL_SHUTDOWN_TIMEOUT'
                    }
                    $stoppedForPlanning = $true
                }
                $resourcePlanResult = New-LabHyperVResourceMigrationPlan -RunId $ExpectedRunId `
                    -StateRoot $StateRoot -DataRoot $TargetDataRoot
                $resourcePlan = $resourcePlanResult.Plan
            }
            if ([string]$resourcePlan.RunId -ne $ExpectedRunId -or
                @($resourcePlan.Inventory.VMs).Count -ne 1 -or
                [string]$resourcePlan.Inventory.VMs[0].VMName -ne $ExpectedName) {
                throw 'HVR008_ACCEPTANCE_RUN_PLAN_IDENTITY_MISMATCH'
            }
            if ([string]$resourcePlan.Inventory.VMs[0].InitialState -ne 'Off') {
                throw 'HVR008_ACCEPTANCE_RUN_PLAN_REQUIRES_OFF_STATE'
            }
            if ([string]$resourcePlan.Status -ne 'READY' -or @($resourcePlan.Blockers).Count -gt 0) {
                throw "HVR008_ACCEPTANCE_RUN_PLAN_BLOCKED: $(@($resourcePlan.Blockers) -join ', ')"
            }

            $migration = if ([string]$resourceJournalBefore.Status -eq 'COMPLETED') {
                [PSCustomObject]@{
                    Status = 'COMPLETED'
                    JournalPath = $resourcePaths.Journal
                    ResourceRoot = [string]$resourcePlan.Target.ResourceRoot
                }
            }
            else {
                Invoke-LabHyperVResourceMigration -PlanPath $resourcePaths.Plan `
                    -ReadinessTimeoutSeconds $TimeoutSeconds -DataRoot $TargetDataRoot -Confirm:$false
            }
            if ([string]$migration.Status -ne 'COMPLETED') {
                throw "HVR008_ACCEPTANCE_RUN_MIGRATION_INCOMPLETE: $([string]$migration.Status)"
            }
        }
        catch {
            $originalError = $_.Exception
            if ($stoppedForPlanning -and -not (Test-Path -LiteralPath $resourcePaths.Journal -PathType Leaf)) {
                try { $null = & $restoreExpectedRunningState }
                catch {
                    throw "HVR008_ACCEPTANCE_PREFLIGHT_FAILED_AND_RESTORE_FAILED: migration=$($originalError.Message); restore=$($_.Exception.Message)"
                }
            }
            throw $originalError
        }

        $journal = Get-Content -LiteralPath $resourcePaths.Journal -Raw -Encoding utf8 | ConvertFrom-Json -Depth 60
        if ([string]$journal.Status -ne 'COMPLETED' -or -not [bool]$journal.BindingCommitted -or
            @($journal.ReadinessReceipts).Count -ne 2 -or
            @($journal.ReadinessReceipts | Where-Object { -not [bool]$_.GuestReady }).Count -gt 0) {
            throw 'HVR008_ACCEPTANCE_RESTART_EVIDENCE_INVALID'
        }
        $sqlRestartEvidence = @($journal.ReadinessReceipts | Where-Object { [bool]$_.SqlReady })
        if ($SqlRequired -and $sqlRestartEvidence.Count -ne 2) {
            throw 'HVR008_ACCEPTANCE_SQL_RESTART_EVIDENCE_INVALID'
        }
        $binding = Read-LabHyperVResourceBinding -StateDirectory $runDirectory -DataRoot $TargetDataRoot
        if (-not $binding) { throw 'HVR008_ACCEPTANCE_COMMITTED_BINDING_REQUIRED' }
        $null = Assert-LabHyperVResourceBinding -Binding $binding -DataRoot $TargetDataRoot
        $null = Assert-HyperVVMResourceBinding -VMName $ExpectedName -ResourceBinding $binding -DataRoot $TargetDataRoot
        $finalRestoration = if ($ExpectedInitialState -eq 'Running') {
            & $restoreExpectedRunningState
        } else {
            [PSCustomObject]@{ GuestReady=$null; SqlReady=$null }
        }
        $managedAfter = Get-HyperVManagedVM -VMName $ExpectedName -ExpectedRunId $ExpectedRunId `
            -ExpectedScopeId ([string]$run.scopeId)
        if ([string]$managedAfter.VM.State -ne $ExpectedInitialState) { throw 'HVR008_ACCEPTANCE_INITIAL_STATE_NOT_RESTORED' }
        if (Test-Path -LiteralPath ([string]$resourcePlan.Source.Root) -PathType Container) {
            throw 'HVR008_ACCEPTANCE_LEGACY_RUN_ROOT_REMAINS'
        }

        foreach ($disk in @($resourcePlan.Inventory.VMs[0].LegacyDisks)) {
            $targetVhd = Get-VHD -Path ([string]$disk.DestinationPath) -ErrorAction Stop
            if ($disk.TargetParentPath -and -not [string]::Equals(
                    [IO.Path]::GetFullPath([string]$targetVhd.ParentPath),
                    [IO.Path]::GetFullPath([string]$disk.TargetParentPath),
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw 'HVR008_ACCEPTANCE_PARENT_REBIND_INVALID'
            }
        }

        $imageJournal = if (Test-Path -LiteralPath $imagePaths.Journal -PathType Leaf) {
            Get-Content -LiteralPath $imagePaths.Journal -Raw -Encoding utf8 | ConvertFrom-Json -Depth 60
        } else { $null }
        if ($imageJournal -and [string]$imageJournal.Status -notin @('WAITING_FOR_CONSUMERS', 'COMPLETED')) {
            throw "HVR008_ACCEPTANCE_IMAGE_JOURNAL_INVALID: $([string]$imageJournal.Status)"
        }

        [PSCustomObject]@{
            ContractVersion = 'SqlServerLab.HVR008Acceptance/1.0'
            Status = 'PASS'
            RunId = $ExpectedRunId
            VMName = $ExpectedName
            InitialVMState = $ExpectedInitialState
            MigrationPlanInitialVMState = [string]$resourcePlan.Inventory.VMs[0].InitialState
            FinalVMState = [string]$managedAfter.VM.State
            FinalRestorationGuestReady = $finalRestoration.GuestReady
            FinalRestorationSqlReady = $finalRestoration.SqlReady
            LocationId = [string]$preview.LocationId
            VolumeId = [string]$preview.VolumeId
            LabDataRoot = [string]$preview.LabDataRoot
            ResourceRoot = [string]$binding.HyperVResourceRoot
            ImageMigrationStatus = if ($imageJournal) { [string]$imageJournal.Status } else { [string]$imageApply.Status }
            RunMigrationStatus = [string]$journal.Status
            ParentReparentCount = @($journal.ParentReparents | Where-Object { [string]$_.State -eq 'COMPLETED' }).Count
            RestartEvidenceCount = @($journal.ReadinessReceipts).Count
            SqlReadinessRequired = [bool]$SqlRequired
            SqlMajorVersion = if ($SqlRequired) { $ExpectedSqlMajor } else { $null }
            SqlRestartEvidenceCount = $sqlRestartEvidence.Count
            SourceCleanupCount = @($journal.SourceCleanup).Count
            BindingCommitted = [bool]$journal.BindingCommitted
            CompletedAt = Get-LabTimestamp
        }
    } $resolvedStateRoot $resolvedDataRoot $RunId $ExpectedVMName $ReadinessTimeoutSeconds `
        $ExpectedInitialVMState $RequireSqlReadiness.IsPresent $ExpectedSqlMajorVersion $AdoptLegacySqlIdentity.IsPresent
}
catch {
    $result = [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.HVR008Acceptance/1.0'
        Status = 'FAILED'
        RunId = $RunId
        VMName = $ExpectedVMName
        Error = $_.Exception.Message
        FailedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    throw
}
finally {
    if ($EvidencePath -and $result) {
        $evidenceDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($EvidencePath))
        if (-not (Test-Path -LiteralPath $evidenceDirectory -PathType Container)) {
            New-Item -Path $evidenceDirectory -ItemType Directory -Force | Out-Null
        }
        $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $EvidencePath -Encoding utf8NoBOM
    }
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
}

$result

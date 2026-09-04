<#
.SYNOPSIS
    Liefert eine verdichtete, persistente Workflow-Sicht fuer SQL_Server_Lab.
.DESCRIPTION
    Fasst Container-Runs, Windows-OS-Baselines, laufende Hyper-V-Builder,
    SQL-Prepared-Images und run-lokale Abnahmeumgebungen zusammen. Die Ausgabe
    enthaelt keine Geheimnisse und kann von einer Konsole oder einer lokalen UI
    verwendet werden.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Enthält Hostfähigkeiten,
    Workflow-Status, veröffentlichte Images einschließlich ihres read-only
    Evaluation-/Refreshstatus, Abnahmeumgebungen und aktive Labs.
.EXAMPLE
    Get-SqlServerLabWorkflow
.PARAMETER MediaRoot
    Optionaler lokaler Medienordner, dessen SQL-ISOs für die dynamische
    Erkennung untersucht werden. Ohne Angabe wird der gespeicherte Standard
    verwendet.
#>
function Get-SqlServerLabWorkflow {
    [CmdletBinding()]
    param([string]$MediaRoot)

    $stateRoot = Get-LabStateRoot
    if (-not $MediaRoot) { $MediaRoot = Get-LabMediaRootDefault }
    $dataRoot = Get-LabDataRootDefault
    $isElevated = $false
    if ($IsWindows) {
        try {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = [Security.Principal.WindowsPrincipal]::new($identity)
            $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        catch { }
    }

    $hyperV = [PSCustomObject]@{
        Supported = [bool]$IsWindows
        Available = $false
        Message = if ($IsWindows) { 'Hyper-V wird geprueft.' } else { 'Hyper-V ist nur auf einem Windows-Host verfuegbar.' }
    }
    if ($IsWindows) {
        try {
            $availability = Test-HyperVAvailable
            $hyperV.Available = [bool]$availability.Available
            $hyperV.Message = [string]$availability.Message
        }
        catch {
            $hyperV.Message = $_.Exception.Message
        }
    }

    $windowsBuilds = @()
    $sqlBuilds = @()
    $artifacts = @()
    $acceptance = @()
    $activeRuns = @()
    $sqlInstallationMedia = @()
    $windowsInstallationMedia = @()
    $sampleDatabases = @()
    $backupLibrary = @()
    $databasePackageLibrary = @()
    $persistentStorageRemovalCandidates = @()
    $containerInstanceStoreCandidates = @()
    $hyperVPersistentDataCandidates = @()
    $mediaSources = @()
    $hyperVLabs = @()
    $hyperVSwitches = @()
    $hyperVExistingVmSources = @()
    $activeContainerRuns = @()
    $templatePool = [PSCustomObject]@{ MaximumTemplates = 20; UsedTemplates = 0; AvailableTemplates = 20; IsAtCapacity = $false; WindowsBaselines = 0; SqlPreparedImages = 0; Templates = @() }
    if ($hyperV.Supported) {
        try { $windowsBuilds = @(Get-HyperVImageBuildPlans 2>$null) } catch { }
        try { $sqlBuilds = @(Get-HyperVSqlImageBuildPlans 2>$null) } catch { }
        try { $artifacts = @(Get-HyperVImageArtifact -SkipIntegrityCheck 2>$null) } catch { }
        try { $templatePool = Get-HyperVTemplatePoolStatus -Artifacts $artifacts } catch { }
        try { $acceptance = @(Get-HyperVSqlAcceptanceMatrix 2>$null) } catch { }
        if ($hyperV.Available) {
            try {
                $hyperVSwitches = @(Get-VMSwitch -ErrorAction Stop | Sort-Object Name | ForEach-Object {
                    [PSCustomObject]@{ Name = [string]$_.Name; Type = [string]$_.SwitchType }
                })
            }
            catch { }
            try { $hyperVExistingVmSources = @(Get-HyperVExistingVmLabSource) } catch { }
        }
    }
    $artifactInventory = @()
    try { $artifactInventory = @(Get-SqlServerLabHyperVImageArtifact -StateRoot $stateRoot) } catch { }
    $artifactInventoryById = @{}
    foreach ($inventoryItem in $artifactInventory) { $artifactInventoryById[[string]$inventoryItem.ArtifactId] = $inventoryItem }
    try { $activeRuns = @(Get-LabActiveRuns -StateRoot $stateRoot 2>$null) } catch { }
    $activeContainerRuns = @($activeRuns | Where-Object { [string]$_.metadata.workflowKind -ne 'hyperv-lab' })
    try {
        $storageConfiguration = Get-LabStorageConfiguration
        $storageCatalog = Get-LabPersistentStorageCatalog -Configuration $storageConfiguration
        if ([string]$storageCatalog.Status -in @('AVAILABLE', 'EMPTY')) {
            $activeRunIds = @($activeRuns | ForEach-Object { [string]$_.runId })
            $persistentStorageRemovalCandidates = @(
                foreach ($store in @($storageCatalog.Document.Stores)) {
                    $linkedRunIds = @(
                        @($store.References | Where-Object { [string]$_.Kind -eq 'RUN' -and [string]$_.State -eq 'ACTIVE' } | ForEach-Object { [string]$_.TargetId })
                        if ($store.Lease -and $store.Lease.RunId) { [string]$store.Lease.RunId }
                    ) | Where-Object { $_ -in $activeRunIds } | Sort-Object -Unique
                    if (@($linkedRunIds).Count -eq 0) { continue }

                    $allowedPolicies = @()
                    if ([string]$store.StorageClass -eq 'INSTANCE_STORE' -and [string]$store.Retention -eq 'RETAINED' -and [string]$store.CleanupDisposition -eq 'PRESERVE') {
                        $allowedPolicies = @('RETAIN_INSTANCE_STORE', 'BACKUP_ON_REMOVE', 'PACKAGE_ON_REMOVE', 'BACKUP_AND_PACKAGE')
                    }
                    elseif ([string]$store.StorageClass -eq 'INSTANCE_STORE' -and [string]$store.Provider -in @('docker','podman') -and
                        [string]$store.Retention -eq 'RUN_SCOPED' -and [string]$store.CleanupDisposition -eq 'RUN_CLEANUP' -and
                        [string]$store.State -eq 'IN_USE' -and [string]$store.LocationBinding.Residency -eq 'NATIVE_RUNTIME' -and
                        -not [string]::IsNullOrWhiteSpace([string]$store.LocationBinding.ProviderResourceId)) {
                        $allowedPolicies = @('DELETE_WITH_RUN')
                    }
                    elseif ([string]$store.Provider -eq 'external' -and [string]$store.Retention -eq 'EXTERNAL_UNMANAGED' -and [string]$store.CleanupDisposition -eq 'REPORT_ONLY') {
                        $allowedPolicies = @('EXTERNAL_UNMANAGED')
                    }

                    foreach ($linkedRunId in @($linkedRunIds)) {
                        [PSCustomObject]@{
                            RunId = $linkedRunId
                            PersistentStorageId = [string]$store.PersistentStorageId
                            DisplayName = [string]$store.DisplayName
                            StorageClass = [string]$store.StorageClass
                            Provider = [string]$store.Provider
                            State = [string]$store.State
                            Retention = [string]$store.Retention
                            CleanupDisposition = [string]$store.CleanupDisposition
                            PolicyRequired = [bool]([string]$store.StorageClass -notin @('BACKUP_SET', 'DATABASE_PACKAGE'))
                            AllowedPolicies = $allowedPolicies
                            DatabaseReferences = @($store.References | Where-Object {
                                [string]$_.Kind -eq 'DATABASE' -and [string]$_.State -eq 'ACTIVE'
                            } | ForEach-Object {
                                [PSCustomObject]@{
                                    ReferenceId = [string]$_.ReferenceId
                                    DisplayName = [string]$_.TargetId
                                }
                            })
                        }
                    }
                }
            )
            $containerInstanceStoreCandidates = @(
                foreach ($store in @($storageCatalog.Document.Stores | Where-Object {
                    [string]$_.StorageClass -eq 'INSTANCE_STORE' -and
                    [string]$_.Provider -in @('docker','podman') -and
                    [string]$_.State -in @('AVAILABLE','DETACHED') -and -not $_.Lease -and
                    @($_.References | Where-Object State -eq 'ACTIVE').Count -eq 0
                })) {
                    $runtimeStatus = 'UNAVAILABLE'; $sqlMajorVersion = $null; $issues = @('RUNTIME_NOT_INSPECTED')
                    try {
                        $inspection = Get-LabContainerInstanceStoreRuntimeInspection `
                            -Provider ([string]$store.Provider) `
                            -VolumeName ([string]$store.LocationBinding.ProviderResourceId)
                        $runtimeStatus = [string]$inspection.Status
                        $sqlMajorVersion = [string]$inspection.Labels.'sql-server-lab.sql-major-version'
                        $issues = @()
                        if ($runtimeStatus -ne 'AVAILABLE') { $issues += 'SOURCE_VOLUME_NOT_OBSERVED' }
                        if ([string]$inspection.Labels.'sql-server-lab.persistent-storage-id' -ne [string]$store.PersistentStorageId) {
                            $issues += 'SOURCE_STORAGE_LABEL_MISMATCH'
                        }
                        if ($sqlMajorVersion -notmatch '^\d{4}$') { $issues += 'SOURCE_SQL_VERSION_UNVERIFIED' }
                        if (@($inspection.AttachedContainers).Count -gt 0) { $issues += 'SOURCE_VOLUME_ATTACHED' }
                    }
                    catch { $issues = @('RUNTIME_UNAVAILABLE') }
                    [PSCustomObject]@{
                        PersistentStorageId=[string]$store.PersistentStorageId
                        DisplayName=[string]$store.DisplayName
                        Provider=[string]$store.Provider
                        State=[string]$store.State
                        SqlMajorVersion=if ($sqlMajorVersion -match '^\d{4}$') { $sqlMajorVersion } else { $null }
                        RuntimeStatus=$runtimeStatus
                        AvailableActions=if (@($issues).Count -eq 0) { @('CONTINUE','CLONE') } else { @() }
                        Issues=@($issues | Sort-Object -Unique)
                    }
                }
            )
            $hyperVPersistentDataCandidates = @(Get-LabHyperVPersistentDataSelection `
                -Configuration $storageConfiguration -Catalog $storageCatalog `
                -InspectRuntime:([bool]$hyperV.Available))
        }
    }
    catch { $persistentStorageRemovalCandidates = @(); $containerInstanceStoreCandidates = @(); $hyperVPersistentDataCandidates = @() }
    if ($hyperV.Supported) {
        $hyperVLabs = @($activeRuns | Where-Object { [string]$_.metadata.workflowKind -eq 'hyperv-lab' } | ForEach-Object {
            $run = $_
            $connectionInfo = $null
            $resources = $null
            try {
                $connectionPath = Join-Path (Join-Path (Join-Path $stateRoot 'runs') ([string]$run.runId)) 'connection-info.json'
                if (Test-Path -LiteralPath $connectionPath -PathType Leaf) {
                    $connectionInfo = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 8
                }
            }
            catch { }
            try { $resources = Get-LabEnvironmentResources -RunId ([string]$run.runId) -StateRoot $stateRoot } catch { }
            $instance = @($connectionInfo.instances | Where-Object { $_.provider -eq 'hyperv' }) | Select-Object -First 1
            $vmState = 'Unknown'
            $exists = $false
            $autoStart = if ($instance -and $instance.autostart) { [string]$instance.autostart } else { 'off' }
            if ($instance -and $instance.vmName) {
                try {
                    $status = Get-HyperVInstanceStatus -VMName ([string]$instance.vmName) -ExpectedRunId ([string]$run.runId) -ExpectedScopeId ([string]$run.scopeId)
                    $vmState = [string]$status.State; $exists = [bool]$status.Exists
                    if ($status.PSObject.Properties['AutoStart']) { $autoStart = [string]$status.AutoStart }
                }
                catch { $vmState = 'Unavailable' }
            }
            $workload = if ($instance -and $instance.workload) { [string]$instance.workload } elseif ($run.metadata.workload) { [string]$run.metadata.workload } elseif ($instance -and $instance.sqlVersion) { 'sql' } else { 'windows' }
            $isSqlLab = $workload -eq 'sql'
            [PSCustomObject]@{
                RunId = [string]$run.runId; Name = [string]$run.metadata.name; State = [string]$run.state
                VMName = if ($instance) { [string]$instance.vmName } else { $null }; VMState = $vmState; Exists = $exists
                InstanceId = if ($instance) { [string]$instance.id } else { $null }
                AutoStart = $autoStart
                Workload = $workload
                SqlVersion = if ($instance) { [string]$instance.sqlVersion } else { $null }
                SqlEdition = if ($instance) { [string]$instance.sqlEdition } else { $null }
                SqlCompleted = [bool]($isSqlLab -and $instance -and $instance.sqlCompletion -and [string]$instance.sqlCompletion.state -eq 'COMPLETE')
                SqlCompletionState = if (-not $isSqlLab) { 'NOT_APPLICABLE' } elseif ($instance -and $instance.sqlCompletion) { [string]$instance.sqlCompletion.state } else { 'PENDING_COMPLETE_IMAGE' }
                ConnectionString = if ($isSqlLab -and $instance) { [string]$instance.connectionString } else { $null }
                SqlInstances = if ($isSqlLab) { @($instance.sqlInstances | ForEach-Object {
                    [PSCustomObject]@{
                        Name = [string]$_.Name; InstanceId = [string]$_.InstanceId; IsDefault = [bool]$_.IsDefault
                        ServiceName = [string]$_.ServiceName; ServiceStatus = [string]$_.ServiceStatus; TcpPort = $_.TcpPort
                        ConnectionString = [string]$_.ConnectionString
                    }
                }) } else { @() }
                SqlInstancesInspectedAt = if ($isSqlLab -and $instance) { [string]$instance.sqlInstancesInspectedAt } else { $null }
                PersistentStorage = if ($instance) { $instance.persistentStorage } else { $null }
                ArtifactId = [string]$run.metadata.imageArtifactId
                BaseKind = [string]$run.metadata.baseKind
                SourceVMName = [string]$run.metadata.sourceVMName
                SourceLicenseNotice = [string]$run.metadata.sourceLicenseNotice
                Resources = $resources
            }
        })
    }
    try {
        $sampleDatabases = @(Get-LabExecutableSampleVariant | ForEach-Object {
            [PSCustomObject]@{
                SampleId = $_.SampleId; Variant = $_.Variant; DisplayName = $_.DisplayName
                Description = $_.Description; ExpectedDatabase = $_.ExpectedDatabase
                ArtifactType = $_.ArtifactType; DownloadSizeMB = $_.DownloadSizeMB; MinSqlVersion = $_.MinSqlVersion
                TrustStatus = if ($_.ExpectedSha256) { 'catalog-verified' } else { 'TRUST_REQUIRED' }
                CacheStatus = 'UNKNOWN'
            }
        })
    }
    catch { }
    if ($dataRoot) {
        try { $backupLibrary = @(Get-LabDatabaseBackupSelection -DataRoot $dataRoot) } catch { }
        try { $databasePackageLibrary = @(Get-LabDatabasePackageSelection -DataRoot $dataRoot) } catch { }
    }
    $testDataRoot = Get-LabTestDataRootDefault
    try { $mediaSources = @(Get-LabMediaSourceCatalog -MediaRoot $MediaRoot -TestDataRoot $testDataRoot) } catch { }
    if ($MediaRoot -and $IsWindows) {
        try { $sqlInstallationMedia = @(Get-HyperVSqlInstallationMediaCandidates -MediaRoot $MediaRoot) } catch { }
        try { $windowsInstallationMedia = @(Get-HyperVWindowsInstallationMediaCandidates -MediaRoot $MediaRoot) } catch { }
    }

    $windowsItems = @($windowsBuilds | ForEach-Object {
        $state = [string]$_.state
        $next = switch ($state) {
            'BUILDER_READY' { 'VM starten und Windows in VMConnect installieren.' }
            'MANUAL_ACTION_REQUIRED' { 'Windows-Installation abschliessen und anschliessend verifizieren.' }
            'REBOOT_REQUIRED' { 'Warten, bis der Sysprep-Shutdown abgeschlossen ist; danach erneut pruefen.' }
            'RESUME_PENDING' { 'Windows-Image veroeffentlichen.' }
            'OS_SEALED' { 'Fertig: OS-Baseline ist veroeffentlicht.' }
            'FAILED' { 'Fehlerdetails pruefen oder den Builder aufraeumen.' }
            default { 'Status pruefen.' }
        }
        [PSCustomObject]@{
            BuildId = [string]$_.buildId; State = $state
            OperatingSystem = [string]$_.operatingSystem.id
            Edition = [string]$_.operatingSystem.edition
            InstallationType = [string]$_.operatingSystem.installationType
            VMName = if ($_.builder) { [string]$_.builder.vmName } else { $null }
            ArtifactId = if ($_.artifact) { [string]$_.artifact.artifactId } else { $null }
            InstallationVerified = [bool]($_.installationEvidence -and $_.installationEvidence.verified)
            SuggestedEvaluationExpiresAt = ((Get-Date).Date.AddDays(180)).ToString('yyyy-MM-dd')
            NextStep = $next
        }
    })

    $sqlItems = @($sqlBuilds | ForEach-Object {
        $state = [string]$_.state
        $fresh = [string]$_.provisioningMode -eq 'fresh-windows-media'
        $next = switch ($state) {
            'MANUAL_ACTION_REQUIRED' {
                if ($fresh -and -not ($_.installationEvidence -and $_.installationEvidence.verified)) {
                    "Windows $($_.operatingSystem.version) $($_.operatingSystem.edition) / $($_.operatingSystem.installationType) installieren, anmelden und anschließend die Edition prüfen."
                }
                elseif ($fresh) { 'Windows-Edition bestätigt: SQL PrepareImage und finalen Sysprep ausführen.' }
                else { 'VM starten, OOBE der OS-Baseline abschließen und lokales Administratorpasswort setzen; danach SQL PrepareImage ausführen.' }
            }
            'REBOOT_REQUIRED' { 'VM starten, vollstaendig booten lassen; danach SQL PrepareImage fortsetzen.' }
            'RESUME_PENDING' { 'Prepared-Image veroeffentlichen.' }
            'SQL_PREPARED_SEALED' { 'Fertig: SQL-Prepared-Image ist veroeffentlicht.' }
            'SQL_READY_RUN' { 'SQL-Abnahmetest ausfuehren.' }
            'TESTS_PASSED' { 'Fertig: Abnahme ist bestanden.' }
            'FAILED' { 'Fehlerdetails pruefen; danach Recovery oder Cleanup waehlen.' }
            default { 'Status pruefen.' }
        }
        [PSCustomObject]@{
            BuildId = [string]$_.buildId; State = $state
            OperatingSystem = [string]$_.operatingSystem.id
            WindowsEdition = [string]$_.operatingSystem.edition
            InstallationType = [string]$_.operatingSystem.installationType
            SqlVersion = [string]$_.sql.version; SqlEdition = [string]$_.sql.edition
            ProvisioningMode = [string]$_.provisioningMode
            DisplayName = [string]$_.displayName
            InstallationVerified = [bool]($_.installationEvidence -and $_.installationEvidence.verified)
            VMName = if ($_.builder) { [string]$_.builder.vmName } else { $null }
            ArtifactId = if ($_.artifact) { [string]$_.artifact.artifactId } else { $null }
            SuggestedEvaluationExpiresAt = ((Get-Date).Date.AddDays(180)).ToString('yyyy-MM-dd')
            NextStep = $next
        }
    })

    $acceptanceItems = @($acceptance | ForEach-Object {
        $entry = $_
        $build = @($sqlBuilds | Where-Object { [string]$_.buildId -eq [string]$entry.BuildId }) | Select-Object -First 1
        $provisioningMode = if ($build) { [string]$build.provisioningMode } else { $null }
        $next = switch ([string]$entry.State) {
            'MANUAL_ACTION_REQUIRED' { 'VM starten, danach OOBE und SQL-Setup ausführen.' }
            'OOBE_AUTOMATION_RUNNING' { 'OOBE und SQL-Setup fortsetzen.' }
            'OOBE_COMPLETED' { 'SQL-Setup ausführen.' }
            'SQL_INSTALL_REBOOT_REQUIRED' { 'Gast vollständig booten lassen, danach SQL-Setup fortsetzen.' }
            'SQL_READY_RUN' { 'SQL-Abnahme mit Create, Backup, Restore-Prüfung und Cleanup ausführen.' }
            'TESTS_PASSED' { 'Fertig: Die SQL-Abnahme ist bestanden.' }
            'RESUME_PENDING' { 'Prepared-Image veröffentlichen; eine Abnahmeumgebung wird separat aus einem Test-Build betrieben.' }
            'SQL_PREPARED_SEALED' { 'Prepared-Image ist final; für die Abnahme eine run-lokale Testumgebung verwenden.' }
            default { 'Status prüfen.' }
        }
        [PSCustomObject]@{
            BuildId = [string]$entry.BuildId; SqlVersion = [string]$entry.SqlVersion
            Edition = [string]$entry.Edition; ProductVersion = [string]$entry.ProductVersion
            VMName = [string]$entry.VMName; ComputerName = [string]$entry.ComputerName
            State = [string]$entry.State; Ready = [bool]$entry.Ready; TestsPassed = [bool]$entry.TestsPassed
            NetworkAttached = [bool]$entry.NetworkAttached; AcceptanceAt = [string]$entry.AcceptanceAt
            ProvisioningMode = $provisioningMode; NextStep = $next
        }
    })

    $batches = @()
    $operations = @()
    $queue = $null
    try { $batches = @(Get-SqlServerLabBatch -StateRoot $stateRoot) } catch { }
    try { $operations = @(Get-SqlServerLabOperation -StateRoot $stateRoot) } catch { }
    try { $queue = Get-SqlServerLabQueue -StateRoot $stateRoot } catch { }

    [PSCustomObject]@{
        GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
        Host = [PSCustomObject]@{
            Platform = if ($IsWindows) { 'Windows' } else { 'Linux/macOS' }
            IsElevated = $isElevated
            HyperV = $hyperV
            Providers = @(Get-AvailableLabProviders | Sort-Object)
            ProviderCapabilities = @(Get-LabProviderCapabilityContract)
        }
        Defaults = [PSCustomObject]@{ MediaRoot = $MediaRoot; DataRoot = $dataRoot; TestDataRoot = $testDataRoot }
        Batches = $batches
        Operations = $operations
        Queue = $queue
        SqlInstallationMedia = $sqlInstallationMedia
        WindowsInstallationMedia = $windowsInstallationMedia
        SampleDatabases = $sampleDatabases
        BackupLibrary = $backupLibrary
        DatabasePackageLibrary = $databasePackageLibrary
        PersistentStorageRemovalCandidates = $persistentStorageRemovalCandidates
        ContainerInstanceStoreCandidates = $containerInstanceStoreCandidates
        HyperVPersistentDataCandidates = $hyperVPersistentDataCandidates
        MediaSources = $mediaSources
        TemplatePool = $templatePool
        HyperVLabs = $hyperVLabs
        HyperVSwitches = $hyperVSwitches
        HyperVExistingVmSources = $hyperVExistingVmSources
        Summary = [PSCustomObject]@{
            WindowsBaselines = @($artifacts | Where-Object artifactState -eq 'OS_SEALED').Count
            SqlPreparedImages = @($artifacts | Where-Object artifactState -eq 'SQL_PREPARED_SEALED').Count
            TemplatePoolUsed = $templatePool.UsedTemplates
            TemplatePoolCapacity = $templatePool.MaximumTemplates
            ActiveContainerLabs = $activeContainerRuns.Count
            PendingWindowsBuilds = @($windowsItems | Where-Object State -notin @('OS_SEALED', 'TEST_ARTIFACT_PUBLISHED')).Count
            PendingSqlBuilds = @($sqlItems | Where-Object State -notin @('SQL_PREPARED_SEALED', 'TESTS_PASSED')).Count
            ActiveBatches = @($batches | Where-Object status -notin @('Completed', 'CompletedWithErrors', 'Cancelled')).Count
            RunningWorkers = if ($queue) { [int]$queue.runningWorkers } else { 0 }
            WaitingUserGates = if ($queue) { [int]$queue.waitingUserGates } else { 0 }
            QueueLength = if ($queue) { [int]$queue.length } else { 0 }
        }
        WindowsBaselines = @($artifacts | Where-Object artifactState -eq 'OS_SEALED' | ForEach-Object {
            $inventoryItem = $artifactInventoryById[[string]$_.artifactId]
            [PSCustomObject]@{
                ArtifactId = [string]$_.artifactId; OperatingSystem = [string]$_.operatingSystem.id
                Version = [string]$_.operatingSystem.version; Edition = [string]$_.operatingSystem.edition
                InstallationType = [string]$_.operatingSystem.installationType; DisplayName = [string]$_.displayName; PublishedAt = [string]$_.registeredAt
                EvaluationStatus = if ($inventoryItem) { [string]$inventoryItem.Evaluation.Status } else { 'UNKNOWN' }
                RefreshAction = if ($inventoryItem) { [string]$inventoryItem.Refresh.Action } else { 'UNKNOWN' }
                AutomaticFallbackEligible = if ($inventoryItem) { [bool]$inventoryItem.ManifestFallback.Eligible } else { $false }
                AutomaticFallbackReasons = if ($inventoryItem) { @($inventoryItem.ManifestFallback.Reasons) } else { @('inventory-unavailable') }
            }
        })
        SqlPreparedImages = @($artifacts | Where-Object artifactState -eq 'SQL_PREPARED_SEALED' | ForEach-Object {
            $inventoryItem = $artifactInventoryById[[string]$_.artifactId]
            [PSCustomObject]@{
                ArtifactId = [string]$_.artifactId; OperatingSystem = [string]$_.operatingSystem.id
                WindowsEdition = [string]$_.operatingSystem.edition; InstallationType = [string]$_.operatingSystem.installationType
                SqlVersion = [string]$_.sql.version; SqlEdition = [string]$_.sql.edition
                SqlBuild = [string]$_.sql.build; DisplayName = [string]$_.displayName; PublishedAt = [string]$_.registeredAt
                EvaluationStatus = if ($inventoryItem) { [string]$inventoryItem.Evaluation.Status } else { 'UNKNOWN' }
                RefreshAction = if ($inventoryItem) { [string]$inventoryItem.Refresh.Action } else { 'UNKNOWN' }
                AutomaticFallbackEligible = if ($inventoryItem) { [bool]$inventoryItem.ManifestFallback.Eligible } else { $false }
                AutomaticFallbackReasons = if ($inventoryItem) { @($inventoryItem.ManifestFallback.Reasons) } else { @('inventory-unavailable') }
            }
        })
        WindowsBuilds = $windowsItems
        SqlBuilds = $sqlItems
        AcceptanceEnvironments = $acceptanceItems
        ActiveLabs = @($activeContainerRuns | ForEach-Object {
            $connectionInfo = $null
            $resources = $null
            try {
                $connectionPath = Join-Path (Join-Path (Join-Path $stateRoot 'runs') ([string]$_.runId)) 'connection-info.json'
                if (Test-Path -LiteralPath $connectionPath -PathType Leaf) {
                    $connectionInfo = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 8
                }
            }
            catch { }
            try { $resources = Get-LabEnvironmentResources -RunId ([string]$_.runId) -StateRoot $stateRoot } catch { }
            [PSCustomObject]@{
                RunId = [string]$_.runId; Name = [string]$_.metadata.name; State = [string]$_.state
                Resources = $resources
                Instances = @($connectionInfo.instances | ForEach-Object {
                    [PSCustomObject]@{
                        Id = [string]$_.id; Provider = [string]$_.provider; Host = [string]$_.host
                        Port = $_.port; SqlVersion = if ($_.sqlVersion) { [string]$_.sqlVersion } else { [string]$_.version }
                        AutoStart = if ($_.autostart) { [string]$_.autostart } else { 'off' }
                        ConnectionString = [string]$_.connectionString
                        PersistentStorage = $_.persistentStorage
                        ResourceSettings = $_.resourceSettings
                    }
                })
            }
        })
    }
}

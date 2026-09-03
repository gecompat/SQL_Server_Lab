<#
.SYNOPSIS
    Inventarisiert alle bekannten SQL_Server_Lab-Daten und Runtime-Ressourcen.
.DESCRIPTION
    Der Audit ist read-only. Fremde, verwaiste oder wegen eines nicht erreichbaren
    Providers unpruefbare Ressourcen werden gemeldet, aber niemals entfernt. Der
    persistente Storage-Katalog und exklusive Leases werden gegen das Inventar
    geprüft; nicht katalogisierte retained Objekte bleiben ID-lose Kandidaten.
    Bewusst retained Objekte, unerwartete Residuen, Recovery-Befunde und
    unverifizierbare Evidence werden mit Reason-Code und Handlungshinweis
    getrennt ausgegeben; daraus folgt niemals automatische Mutationsautorität.
    Aktive Docker-Contexts und Podman-Connections/Machines werden sanitisiert
    als read-only Runtime-Scope ausgegeben. Das Residency-Inventar ergänzt
    providerseitige Host-Backings, Konfigurationen, verwaltete Images und
    normalisierte Runtime-Speichernutzung ohne Mutationsautorität.
.PARAMETER NoWrite
    Gibt den Audit nur zurueck und schreibt kein JSON-Artefakt.
.PARAMETER StateRoot
    Optionaler State-Root für einen isolierten Audit.
.PARAMETER DataRoot
    Optionaler registrierter Lab_Data-Root, dessen controllerweiter Katalog
    inventarisiert wird.
.OUTPUTS
    PSCustomObject mit Path und Audit. Audit enthaelt Status, Zusammenfassung,
    Datenwurzeln, aktive Runs, gefundene oder unpruefbare Providerressourcen
    sowie Runtime-Scopes, Runtime-Speichernutzung, verwaltete Images,
    Storage-Residency, Persistent-Storage-Katalog und read-only Plan sowie
    getrennte Cleanup-Findings.
#>
function Get-SqlServerLabCleanupAudit {
    [CmdletBinding()]
    param(
        [switch]$NoWrite,
        [string]$StateRoot,
        [string]$DataRoot
    )

    $configuration = Get-LabStorageConfiguration -DataRoot $DataRoot
    $knownRoots = @($configuration.LabDataLocations | ForEach-Object { [string]$_.LabDataRoot } | Where-Object { $_ })
    $rootResults = @()
    foreach ($location in @($configuration.LabDataLocations)) {
        $root = [string]$location.LabDataRoot
        $marker = if ($root -and (Test-Path -LiteralPath $root -PathType Container)) { Get-LabDataRootMarker -DataRoot $root } else { $null }
        $fileCount = 0; $totalBytes = [long]0
        if ($root -and (Test-Path -LiteralPath $root -PathType Container)) {
            $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue)
            $fileCount = $files.Count
            $totalBytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
        }
        $rootResults += [PSCustomObject]@{
            LocationId=[string]$location.LocationId; VolumeId=[string]$location.VolumeId
            DriveLetter=[string]$location.DriveLetter; LabDataRoot=$root
            Exists=[bool]($root -and (Test-Path -LiteralPath $root -PathType Container))
            Owned=[bool]($marker -and [string]$marker.ManagedBy -eq 'SQL_Server_Lab' -and [string]$marker.ControllerId -eq [string]$configuration.ControllerId)
            ContractVersion=if ($marker) { [string]$marker.ContractVersion } else { $null }
            FileCount=$fileCount; TotalBytes=$totalBytes
        }
    }

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $stateRoot = [IO.Path]::GetFullPath($StateRoot)
    $activeRuns = @(Get-LabActiveRuns -StateRoot $stateRoot)
    $knownRunIds = @($activeRuns | ForEach-Object { [string]$_.runId })
    $runtimeResults = @(); $runtimeScopes = @(); $runtimeStorageUsage = @(); $managedImages = @()
    $containers = @(); $managedVolumes = @(); $managedNetworks = @()
    foreach ($runtime in @('docker', 'podman')) {
        $runtimeScope = Get-LabContainerRuntimeScope -Provider $runtime
        $runtimeScopes += $runtimeScope
        try {
            $runtimeResolution = Resolve-LabHostTool -Name $runtime
        }
        catch {
            $runtimeResults += [PSCustomObject]@{ Provider=$runtime; Status='UNAVAILABLE'; Message='Runtime-Aufloesung ist konfiguriert, aber ungueltig.' }
            continue
        }
        if (-not $runtimeResolution.Available) {
            $runtimeResults += [PSCustomObject]@{ Provider=$runtime; Status='NOT_INSTALLED'; Message=$null }
            continue
        }
        try {
            $runtimeInvocation = Get-LabHostToolInvocation -Name $runtime
        }
        catch {
            throw "HOST_TOOL_RESOLUTION_INCONSISTENT: $runtime"
        }
        try {
            & $runtimeInvocation info 1>$null 2>$null
        }
        catch {
            $runtimeResults += [PSCustomObject]@{ Provider=$runtime; Status='UNAVAILABLE'; Message='Runtime ist installiert, aber im aktuellen Prozess nicht ausfuehrbar.' }
            continue
        }
        if ($LASTEXITCODE -ne 0) {
            $runtimeResults += [PSCustomObject]@{ Provider=$runtime; Status='UNAVAILABLE'; Message='Runtime ist installiert, aber nicht pruefbar.' }
            continue
        }
        $runtimeResults += [PSCustomObject]@{ Provider=$runtime; Status='AVAILABLE'; Message=$null }
        $runtimeStorageUsage += @(Get-LabRuntimeStorageUsage -Provider $runtime)
        $managedImages += @(Get-LabManagedRuntimeImageInventory -Provider $runtime)
        $providerContainers = if ($runtime -eq 'docker') { @(Get-DockerLabContainers) } else { @(Get-PodmanLabContainers) }
        foreach ($container in $providerContainers) {
            $containers += [PSCustomObject]@{
                Provider=$runtime; Id=[string]$container.ContainerId; Name=[string]$container.Name; Status=[string]$container.Status
                RunId=[string]$container.RunId; ScopeId=[string]$container.ScopeId; Orphan=[bool](-not $container.RunId -or [string]$container.RunId -notin $knownRunIds)
            }
        }
        foreach ($name in @(& $runtimeInvocation volume ls --format '{{.Name}}' 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^sql-lab-' })) {
            $managedVolumes += [PSCustomObject]@{ Provider=$runtime; Name=$name }
        }
        foreach ($name in @(& $runtimeInvocation network ls --format '{{.Name}}' 2>$null | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^sql-lab-' })) {
            $managedNetworks += [PSCustomObject]@{ Provider=$runtime; Name=$name }
        }
    }

    $hyperVStatus = 'NOT_INSTALLED'; $hyperVResources = @()
    if ($IsWindows -and (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        try {
            $hyperVResources = @(Get-HyperVLabVMs | ForEach-Object {
                $storageBindings = @(); $storageStatus = 'VERIFIED'
                try {
                    $vm = Get-VM -Name ([string]$_.VMName) -ErrorAction Stop
                    foreach ($binding in @(
                        [PSCustomObject]@{ ResourceKind='VM_CONFIGURATION'; Path=[string]$vm.ConfigurationLocation },
                        [PSCustomObject]@{ ResourceKind='CHECKPOINT'; Path=[string]$vm.SnapshotFileLocation },
                        [PSCustomObject]@{ ResourceKind='SMART_PAGING'; Path=[string]$vm.SmartPagingFilePath }
                    )) {
                        if ($binding.Path) { $storageBindings += $binding }
                    }
                    foreach ($drive in @(Get-VMHardDiskDrive -VMName ([string]$_.VMName) -ErrorAction Stop)) {
                        if ($drive.Path) { $storageBindings += [PSCustomObject]@{ ResourceKind='VHDX'; Path=[string]$drive.Path } }
                    }
                }
                catch { $storageStatus = 'UNVERIFIABLE' }
                [PSCustomObject]@{
                    Name=[string]$_.VMName; State=[string]$_.State; RunId=[string]$_.RunId; ScopeId=[string]$_.ScopeId
                    Orphan=[bool](-not $_.RunId -or [string]$_.RunId -notin $knownRunIds)
                    StorageStatus=$storageStatus; StorageBindings=@($storageBindings)
                }
            })
            $hyperVStatus = 'AVAILABLE'
        }
        catch { $hyperVStatus = 'UNAVAILABLE' }
    }

    $hyperVRunScopes = @(); $hyperVUntrackedFiles = @()
    $runsDirectory = Join-Path $stateRoot 'runs'
    if (Test-Path -LiteralPath $runsDirectory -PathType Container) {
        foreach ($runDirectory in @(Get-ChildItem -LiteralPath $runsDirectory -Directory -Force -ErrorAction SilentlyContinue)) {
            $runState = $null; $runStateStatus = 'MISSING'
            $runStatePath = Join-Path $runDirectory.FullName 'run-state.json'
            if (Test-Path -LiteralPath $runStatePath -PathType Leaf) {
                try {
                    $runState = Get-Content -LiteralPath $runStatePath -Raw -Encoding utf8 |
                        ConvertFrom-Json -Depth 20 -ErrorAction Stop
                    $runStateStatus = 'VALID'
                }
                catch { $runStateStatus = 'INVALID' }
            }

            $binding = $null; $bindingStatus = 'NONE'; $bindingError = $null
            $bindingPath = Join-Path $runDirectory.FullName 'hyperv-resource-binding.local.json'
            if (Test-Path -LiteralPath $bindingPath -PathType Leaf) {
                try {
                    $binding = Read-LabHyperVResourceBinding -StateDirectory $runDirectory.FullName
                    $bindingStatus = if ($runState -and [string]$binding.ResourceClass -eq 'Run' -and
                        [string]::Equals([string]$binding.ResourceId, [string]$runState.runId, [StringComparison]::OrdinalIgnoreCase)) { 'VALID' } else { 'IDENTITY_MISMATCH' }
                }
                catch { $bindingStatus = 'INVALID'; $bindingError = $_.Exception.Message }
            }

            $migrationStatus = 'NONE'; $migrationError = $null
            $migrationPath = Join-Path $runDirectory.FullName 'hyperv-resource-migration.local.journal.json'
            if (Test-Path -LiteralPath $migrationPath -PathType Leaf) {
                try {
                    $migration = Get-Content -LiteralPath $migrationPath -Raw -Encoding utf8 |
                        ConvertFrom-Json -Depth 50 -ErrorAction Stop
                    $migrationStatus = if ($migration.Status) { [string]$migration.Status } else { 'INVALID' }
                }
                catch { $migrationStatus = 'INVALID'; $migrationError = $_.Exception.Message }
            }

            $cleanupResources = @(); $protectedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $managedVmConfigurationRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            if ($runState) {
                foreach ($configurationBinding in @($hyperVResources | Where-Object {
                    -not $_.Orphan -and $_.StorageStatus -eq 'VERIFIED' -and
                    [string]$_.RunId -eq [string]$runState.runId -and [string]$_.ScopeId -eq [string]$runState.scopeId
                } | ForEach-Object { @($_.StorageBindings | Where-Object ResourceKind -eq 'VM_CONFIGURATION') })) {
                    if ($configurationBinding.Path) {
                        $null = $managedVmConfigurationRoots.Add([IO.Path]::GetFullPath([string]$configurationBinding.Path).TrimEnd('\', '/'))
                    }
                }
            }
            $cleanupPath = Join-Path $runDirectory.FullName 'cleanup-plan.json'
            if (Test-Path -LiteralPath $cleanupPath -PathType Leaf) {
                try {
                    $cleanupPlan = Get-Content -LiteralPath $cleanupPath -Raw -Encoding utf8 |
                        ConvertFrom-Json -Depth 30 -ErrorAction Stop
                    foreach ($step in @($cleanupPlan.steps | Where-Object { [string]$_.provider -eq 'hyperv' -and [string]$_.resourceType -eq 'vhdx' })) {
                        $safetyRoot = if ($step.PSObject.Properties['safetyRoot']) { [string]$step.safetyRoot } else { $null }
                        $scope = Test-HyperVVhdxCleanupScope -Path ([string]$step.resourceId) `
                            -ExpectedRunDirectory $runDirectory.FullName -SafetyRoot $safetyRoot
                        $cleanupResources += [PSCustomObject]@{
                            Order=[int]$step.order; Path=[string]$scope.Path; State=[string]$step.state
                            ProtectionStatus=if ($scope.Valid) { 'PROTECTED' } else { 'UNSAFE' }
                            ScopeKind=[string]$scope.ScopeKind; Code=[string]$scope.Code
                        }
                        if ($scope.Valid) { $null = $protectedPaths.Add([IO.Path]::GetFullPath([string]$scope.Path)) }
                    }
                }
                catch {
                    $cleanupResources += [PSCustomObject]@{
                        Order=0; Path=$cleanupPath; State='INVALID'; ProtectionStatus='UNSAFE'
                        ScopeKind='NONE'; Code="HYPERV_CLEANUP_PLAN_INVALID: $($_.Exception.Message)"
                    }
                }
            }

            $resourceRoots = [Collections.Generic.List[object]]::new()
            if ($binding -and $bindingStatus -eq 'VALID') {
                $resourceRoots.Add([PSCustomObject]@{ Kind='BOUND_RUN_ROOT'; Path=[string]$binding.HyperVResourceRoot })
            }
            $legacyRoot = Join-Path (Join-Path $runDirectory.FullName 'resources') 'hyperv'
            if (Test-Path -LiteralPath $legacyRoot -PathType Container) {
                $resourceRoots.Add([PSCustomObject]@{ Kind='LEGACY_RUN_ROOT'; Path=[IO.Path]::GetFullPath($legacyRoot) })
            }
            $fileCount = 0
            foreach ($resourceRoot in @($resourceRoots)) {
                if (-not (Test-Path -LiteralPath $resourceRoot.Path -PathType Container)) { continue }
                foreach ($file in @(Get-ChildItem -LiteralPath $resourceRoot.Path -File -Recurse -Force -ErrorAction SilentlyContinue)) {
                    $fileCount++
                    $fullFilePath = [IO.Path]::GetFullPath($file.FullName)
                    $isManagedVmConfiguration = @($managedVmConfigurationRoots | Where-Object {
                        $fullFilePath.StartsWith($_ + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
                    }).Count -gt 0
                    if (-not $protectedPaths.Contains($fullFilePath) -and -not $isManagedVmConfiguration) {
                        $entry = [PSCustomObject]@{
                            RunId=if ($runState) { [string]$runState.runId } else { $runDirectory.Name }
                            RootKind=[string]$resourceRoot.Kind; Path=$file.FullName
                            Preservation='PRESERVE_UNTRACKED'
                        }
                        $hyperVUntrackedFiles += $entry
                    }
                }
            }
            if ($bindingStatus -ne 'NONE' -or $migrationStatus -ne 'NONE' -or $cleanupResources.Count -gt 0 -or $fileCount -gt 0) {
                $hyperVRunScopes += [PSCustomObject]@{
                    RunId=if ($runState) { [string]$runState.runId } else { $runDirectory.Name }
                    RunDirectory=$runDirectory.FullName; RunStateStatus=$runStateStatus
                    BindingStatus=$bindingStatus; BindingError=$bindingError
                    ResourceRoot=if ($binding) { [string]$binding.HyperVResourceRoot } else { $null }
                    MigrationStatus=$migrationStatus; MigrationError=$migrationError
                    CleanupResources=$cleanupResources; ResourceFileCount=$fileCount
                }
            }
        }
    }

    $hyperVSharedRoots = @()
    foreach ($resourceClass in @('Image','Staging')) {
        foreach ($root in @(Get-LabHyperVResourceDiscoveryRoots -ResourceClass $resourceClass -StateRoot $stateRoot)) {
            $files = if (Test-Path -LiteralPath $root.Path -PathType Container) {
                @(Get-ChildItem -LiteralPath $root.Path -File -Recurse -Force -ErrorAction SilentlyContinue)
            } else { @() }
            $hyperVSharedRoots += [PSCustomObject]@{
                ResourceClass=$resourceClass; RootKind=[string]$root.RootKind; Path=[string]$root.Path
                Exists=[bool](Test-Path -LiteralPath $root.Path -PathType Container)
                FileCount=$files.Count; Preservation='PRESERVE_SHARED'
            }
        }
    }

    $externalReferences = @()
    foreach ($run in $activeRuns) {
        foreach ($candidate in @([string]$run.metadata.dataRoot) + @($run.instances | ForEach-Object { [string]$_.persistentStorage.hostPath }) + @($run.instances | ForEach-Object { @($_.drives | ForEach-Object { [string]$_.hostPath }) })) {
            if (-not $candidate -or -not [System.IO.Path]::IsPathRooted($candidate)) { continue }
            $insideKnownRoot = @($knownRoots | Where-Object {
                $root = [System.IO.Path]::GetFullPath($_).TrimEnd('\', '/')
                $path = [System.IO.Path]::GetFullPath($candidate)
                $path.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
            if (-not $insideKnownRoot) { $externalReferences += [PSCustomObject]@{ RunId=[string]$run.runId; Path=$candidate } }
        }
    }

    $repositoryResidues = @()
    foreach ($relative in @('.local', '.runtime', '.state', '.secrets', '.artifacts', '.cache')) {
        $path = Join-Path $script:ModuleRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        $files = @(Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('.gitignore', 'README.md') })
        if ($files.Count -gt 0) { $repositoryResidues += [PSCustomObject]@{ Path=$path; FileCount=$files.Count } }
    }

    $legacyStateRoots = @()
    $legacyState = if ($IsWindows) { Join-Path $env:LOCALAPPDATA 'SqlServerLab' } else { Join-Path (Resolve-Path '~') '.sql-server-lab' }
    if ((Test-Path -LiteralPath $legacyState -PathType Container) -and -not [string]::Equals([System.IO.Path]::GetFullPath($legacyState), [System.IO.Path]::GetFullPath($stateRoot), [StringComparison]::OrdinalIgnoreCase)) {
        $legacyRunCount = @(Get-ChildItem -LiteralPath (Join-Path $legacyState 'runs') -Filter 'run-state.json' -File -Recurse -ErrorAction SilentlyContinue).Count
        $legacyStateRoots += [PSCustomObject]@{ Path=$legacyState; RunCount=$legacyRunCount }
    }

    $runtimeHostBackings = @($runtimeScopes | ForEach-Object {
        Get-LabContainerRuntimeHostBackingEvidence -Scope $_ -KnownRoots $knownRoots
    })

    $persistentStorageCatalog = Get-LabPersistentStorageCatalog -Configuration $configuration
    $storageResidency = Get-LabStorageResidencyInventory -Configuration $configuration -StateRoot $stateRoot `
        -DataRoots $rootResults -ActiveRuns $activeRuns -RuntimeResults $runtimeResults `
        -RuntimeHostBackings $runtimeHostBackings -RuntimeStorageUsage $runtimeStorageUsage `
        -ManagedImages $managedImages -ManagedVolumes $managedVolumes -PersistentStorageStores @($persistentStorageCatalog.Document.Stores) `
        -HyperVStatus $hyperVStatus -HyperVResources $hyperVResources -HyperVRunScopes $hyperVRunScopes -HyperVSharedRoots $hyperVSharedRoots `
        -HyperVUntrackedFiles $hyperVUntrackedFiles -ExternalReferences $externalReferences `
        -RepositoryResidues $repositoryResidues -LegacyStateRoots $legacyStateRoots
    $persistentStoragePlan = Get-LabPersistentStoragePlan -Catalog $persistentStorageCatalog -ResidencyInventory $storageResidency
    $findings = Get-LabCleanupAuditFindings -ResidencyInventory $storageResidency `
        -PersistentStorageCatalog $persistentStorageCatalog -HyperVRunScopes $hyperVRunScopes -Containers $containers

    $unverifiable = @($runtimeScopes | Where-Object Status -ne 'AVAILABLE').Count +
        @($runtimeHostBackings | Where-Object Status -eq 'UNVERIFIABLE').Count +
        $(if ($hyperVStatus -eq 'UNAVAILABLE') { 1 } else { 0 })
    $hyperVProtectionIssues = @($hyperVRunScopes | Where-Object {
        $_.BindingStatus -in @('INVALID','IDENTITY_MISMATCH') -or
        $_.MigrationStatus -in @('RECOVERY_REQUIRED','INVALID') -or
        @($_.CleanupResources | Where-Object ProtectionStatus -eq 'UNSAFE').Count -gt 0
    }).Count
    $residualCount = @($activeRuns).Count + @($containers).Count + @($managedVolumes).Count + @($managedNetworks).Count + @($hyperVResources).Count + @($externalReferences).Count + @($repositoryResidues).Count + @($legacyStateRoots | Where-Object RunCount -gt 0).Count + @($rootResults | Where-Object { -not $_.Exists -or -not $_.Owned }).Count + @($hyperVUntrackedFiles).Count + $hyperVProtectionIssues
    $status = if ($residualCount -gt 0) { 'RESIDUALS' } elseif ($unverifiable -gt 0) { 'UNVERIFIABLE' } else { 'CLEAN' }
    $audit = [PSCustomObject]@{
        ContractVersion='SqlServerLab.CleanupAudit/1.0'; AuditId=[Guid]::NewGuid().ToString('D'); CreatedAt=Get-LabTimestamp; Status=$status
        ControllerId=[string]$configuration.ControllerId; StateRoot=$stateRoot; DataRoots=$rootResults; ActiveRuns=$activeRuns
        Runtimes=$runtimeResults; RuntimeScopes=$runtimeScopes; RuntimeStorageUsage=$runtimeStorageUsage
        Containers=$containers; ManagedImages=$managedImages; ManagedVolumes=$managedVolumes; ManagedNetworks=$managedNetworks
        HyperV=[PSCustomObject]@{
            Status=$hyperVStatus; Resources=$hyperVResources; RunScopes=$hyperVRunScopes
            SharedRoots=$hyperVSharedRoots; UntrackedFiles=$hyperVUntrackedFiles
        }
        StorageResidency=$storageResidency
        PersistentStorage=[PSCustomObject]@{
            CatalogStatus=[string]$persistentStorageCatalog.Status
            Catalog=$persistentStorageCatalog.Document
            Sources=@($persistentStorageCatalog.Sources)
            Issues=@($persistentStorageCatalog.Issues)
            Plan=$persistentStoragePlan
        }
        Findings=$findings
        ExternalReferences=$externalReferences; RepositoryResidues=$repositoryResidues; LegacyStateRoots=$legacyStateRoots
        Summary=[PSCustomObject]@{
            ResidualCount=$residualCount; UnverifiableProviders=$unverifiable
            ManagedImages=@($managedImages).Count; RuntimeBackingStores=@($runtimeHostBackings.Items | Where-Object Kind -eq 'BACKING_STORE').Count
            HyperVProtectionIssues=$hyperVProtectionIssues; HyperVUntrackedFiles=@($hyperVUntrackedFiles).Count
        }
    }
    $path = $null
    if (-not $NoWrite -and $configuration.DefaultDataRoot) {
        $directory = Join-Path (Join-Path ([string]$configuration.DefaultDataRoot) 'Catalog') 'cleanup-audits'
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -Path $directory -ItemType Directory -Force | Out-Null }
        $path = Join-Path $directory "$($audit.AuditId).json"
        Write-LabArtifactJsonAtomic -Path $path -InputObject $audit
    }
    return [PSCustomObject]@{ Path=$path; Audit=$audit }
}

<#
.SYNOPSIS
    Journalisierte Übernahme des Legacy-Hyper-V-Image-Stores nach Lab_Data.
.DESCRIPTION
    Veröffentlicht Legacy-Image-Artefakte zunächst hashidentisch im gebundenen
    Image-Store. Legacy-Parents bleiben erhalten, solange irgendeine Child-VHDX
    sie referenziert. Ein späterer Resume entfernt ausschließlich vollständig
    inventarisierte und referenzfreie Quellen.
#>

function Get-LabHyperVImageMigrationPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)

    $root = [IO.Path]::GetFullPath($StateRoot)
    $controlRoot = Join-Path $root 'artifacts/hyperv'
    $stateDirectory = Join-Path $controlRoot 'image-store-state'
    return [PSCustomObject]@{
        StateRoot = $root
        StateDirectory = $stateDirectory
        LegacyRoot = Join-Path $controlRoot 'images'
        Binding = Join-Path $stateDirectory 'hyperv-resource-binding.local.json'
        Plan = Join-Path $stateDirectory 'hyperv-image-migration.local.plan.json'
        Journal = Join-Path $stateDirectory 'hyperv-image-migration.local.journal.json'
    }
}

function Resolve-LabHyperVMigratedParentImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParentPath,
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$DataRoot
    )

    $sourceParent = [IO.Path]::GetFullPath($ParentPath)
    $paths = Get-LabHyperVImageMigrationPaths -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $paths.Plan -PathType Leaf) -or
        -not (Test-Path -LiteralPath $paths.Journal -PathType Leaf) -or
        -not (Test-Path -LiteralPath $paths.Binding -PathType Leaf)) { return $null }

    try {
        $plan = Get-Content -LiteralPath $paths.Plan -Raw -Encoding utf8 | ConvertFrom-Json -Depth 60 -ErrorAction Stop
        $journal = Get-Content -LiteralPath $paths.Journal -Raw -Encoding utf8 | ConvertFrom-Json -Depth 60 -ErrorAction Stop
    } catch { throw "HYPERV_IMAGE_MIGRATION_PARENT_MAPPING_INVALID: $($_.Exception.Message)" }
    if ([string]$plan.ContractVersion -ne 'SqlServerLab.HyperVImageMigrationPlan/1.0' -or
        [string]$journal.ContractVersion -ne 'SqlServerLab.HyperVImageMigrationJournal/1.0' -or
        -not [bool]$journal.BindingCommitted) { return $null }
    $planHash = (Get-FileHash -LiteralPath $paths.Plan -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]$journal.PlanId -ne [string]$plan.PlanId -or [string]$journal.PlanSha256 -ne $planHash) {
        throw 'HYPERV_IMAGE_MIGRATION_PARENT_MAPPING_PLAN_CHANGED'
    }

    $binding = Read-LabHyperVResourceBinding -StateDirectory $paths.StateDirectory -DataRoot $DataRoot
    if (-not $binding -or [string]$binding.ResourceClass -ne 'Image' -or [string]$binding.ResourceId -ne 'hyperv-image-store') {
        throw 'HYPERV_IMAGE_MIGRATION_PARENT_MAPPING_BINDING_INVALID'
    }
    foreach ($property in @('ResourceKey','ControllerId','LocationId','VolumeId','LabDataRoot')) {
        if (-not [string]::Equals([string]$binding.$property, [string]$plan.Target.$property, [StringComparison]::OrdinalIgnoreCase)) {
            throw "HYPERV_IMAGE_MIGRATION_PARENT_MAPPING_TARGET_CHANGED: $property"
        }
    }
    if (-not [string]::Equals([string]$binding.HyperVResourceRoot, [string]$plan.Target.ResourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'HYPERV_IMAGE_MIGRATION_PARENT_MAPPING_TARGET_CHANGED: ResourceRoot'
    }

    $artifactMatches = @($plan.Inventory.Artifacts | Where-Object {
        $_.SourceParentPath -and [string]::Equals([IO.Path]::GetFullPath([string]$_.SourceParentPath), $sourceParent, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($artifactMatches.Count -eq 0) { return $null }
    if ($artifactMatches.Count -ne 1) { throw "HYPERV_IMAGE_MIGRATION_PARENT_MAPPING_AMBIGUOUS: $sourceParent" }
    $artifact = $artifactMatches[0]
    $expectedSource = [IO.Path]::GetFullPath((Join-Path $paths.LegacyRoot ([string]$artifact.ArtifactId)))
    $expectedSourceParent = [IO.Path]::GetFullPath((Join-Path $expectedSource 'parent.vhdx'))
    $expectedTarget = Assert-LabHyperVBoundPath -Binding $binding `
        -Path (Join-Path ([string]$binding.HyperVResourceRoot) ([string]$artifact.ArtifactId)) -DataRoot $DataRoot
    $targetParent = Assert-LabHyperVBoundPath -Binding $binding -Path (Join-Path $expectedTarget 'parent.vhdx') -DataRoot $DataRoot
    if (-not [string]::Equals($sourceParent, $expectedSourceParent, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$artifact.SourceDirectory), $expectedSource, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$artifact.DestinationDirectory), $expectedTarget, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$artifact.DestinationParentPath), $targetParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "HYPERV_IMAGE_MIGRATION_PARENT_MAPPING_SCOPE_INVALID: $sourceParent"
    }
    if (-not (Test-Path -LiteralPath $targetParent -PathType Leaf) -or
        (Get-FileHash -LiteralPath $targetParent -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$artifact.ParentSha256 -or
        -not (Get-Item -LiteralPath $targetParent -Force).IsReadOnly -or -not (Test-HyperVVhdxSignature -Path $targetParent)) {
        throw "HYPERV_IMAGE_MIGRATION_PARENT_MAPPING_TARGET_INVALID: $targetParent"
    }
    return [PSCustomObject]@{
        ArtifactId=[string]$artifact.ArtifactId; SourceParentPath=$sourceParent
        DestinationParentPath=$targetParent; ParentSha256=[string]$artifact.ParentSha256
        PlanPath=$paths.Plan; JournalPath=$paths.Journal; LocationId=[string]$binding.LocationId
    }
}

function Get-LabHyperVLegacyImageConsumers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParentPath,
        [Parameter(Mandatory)][string]$StateRoot,
        [string]$DataRoot
    )

    $parent = [IO.Path]::GetFullPath($ParentPath)
    $configuration = Get-LabStorageConfiguration -DataRoot $DataRoot
    $roots = @(
        [IO.Path]::GetFullPath($StateRoot)
        @($configuration.LabDataLocations | ForEach-Object { Join-Path ([string]$_.LabDataRoot) 'HyperV' })
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique

    $attached = @{}
    foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue)) {
        foreach ($drive in @(Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue)) {
            if ($drive.Path) { $attached[[IO.Path]::GetFullPath([string]$drive.Path)] = [string]$vm.Name }
        }
    }

    $results = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $roots) {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.vhdx' -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            $candidate = [IO.Path]::GetFullPath($file.FullName)
            if ([string]::Equals($candidate, $parent, [StringComparison]::OrdinalIgnoreCase) -or -not $seen.Add($candidate)) { continue }
            try { $vhd = Get-VHD -Path $candidate -ErrorAction Stop } catch { continue }
            if (-not $vhd.ParentPath -or -not [string]::Equals([IO.Path]::GetFullPath([string]$vhd.ParentPath), $parent, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $results.Add([PSCustomObject]@{
                ChildPath = $candidate
                VMName = if ($attached.ContainsKey($candidate)) { [string]$attached[$candidate] } else { $null }
                Attached = $attached.ContainsKey($candidate)
            })
        }
    }
    return @($results | Sort-Object ChildPath)
}

function New-LabHyperVImageMigrationPlan {
    [CmdletBinding()]
    param([string]$StateRoot, [string]$LocationId, [string]$DataRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $paths = Get-LabHyperVImageMigrationPaths -StateRoot $StateRoot
    $binding = Resolve-LabHyperVResourceBinding -ResourceId 'hyperv-image-store' -ResourceClass Image `
        -LocationId $LocationId -DataRoot $DataRoot
    $blockers = [Collections.Generic.List[string]]::new()
    $artifacts = [Collections.Generic.List[object]]::new()
    $copyBytes = 0L

    if (Test-Path -LiteralPath $paths.LegacyRoot -PathType Container) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $paths.LegacyRoot -Directory -Force -ErrorAction Stop)) {
            $artifactId = [string]$directory.Name
            if ($artifactId -notmatch '^hyperv-[a-z0-9-]+-[a-f0-9]{64}$') {
                $blockers.Add("HYPERV_IMAGE_MIGRATION_UNKNOWN_DIRECTORY: $($directory.FullName)")
                continue
            }
            $metadataPath = Join-Path $directory.FullName 'metadata.json'
            $parentPath = Join-Path $directory.FullName 'parent.vhdx'
            if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf) -or -not (Test-Path -LiteralPath $parentPath -PathType Leaf)) {
                $blockers.Add("HYPERV_IMAGE_MIGRATION_ARTIFACT_INCOMPLETE: $artifactId")
                continue
            }
            try { $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40 -ErrorAction Stop }
            catch { $blockers.Add("HYPERV_IMAGE_MIGRATION_METADATA_INVALID: $artifactId"); continue }
            $parentHash = (Get-FileHash -LiteralPath $parentPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ([string]$metadata.artifactId -ne $artifactId -or [string]$metadata.sha256 -ne $parentHash -or
                -not (Get-Item -LiteralPath $parentPath -Force).IsReadOnly -or -not (Test-HyperVVhdxSignature -Path $parentPath)) {
                $blockers.Add("HYPERV_IMAGE_MIGRATION_ARTIFACT_INTEGRITY_INVALID: $artifactId")
            }
            $destinationDirectory = Assert-LabHyperVBoundPath -Binding $binding `
                -Path (Join-Path ([string]$binding.HyperVResourceRoot) $artifactId) -DataRoot $DataRoot
            $files = @(
                Get-ChildItem -LiteralPath $directory.FullName -File -Recurse -Force -ErrorAction Stop | ForEach-Object {
                    $relative = [IO.Path]::GetRelativePath($directory.FullName, $_.FullName)
                    $destination = Assert-LabHyperVBoundPath -Binding $binding -Path (Join-Path $destinationDirectory $relative) -DataRoot $DataRoot
                    [PSCustomObject]@{
                        RelativePath = $relative; DestinationPath = $destination; Length = [long]$_.Length
                        Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                    }
                }
            )
            $targetState = 'COPY_REQUIRED'
            if (Test-Path -LiteralPath $destinationDirectory -PathType Container) {
                $targetFiles = @(Get-ChildItem -LiteralPath $destinationDirectory -File -Recurse -Force -ErrorAction Stop)
                $matches = $targetFiles.Count -eq $files.Count
                foreach ($file in $files) {
                    $target = Join-Path $destinationDirectory ([string]$file.RelativePath)
                    if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or
                        (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$file.Sha256) { $matches = $false; break }
                }
                if ($matches -and -not (Get-Item -LiteralPath (Join-Path $destinationDirectory 'parent.vhdx') -Force).IsReadOnly) { $matches = $false }
                if ($matches) { $targetState = 'VERIFIED_COPY_PRESENT' }
                else { $blockers.Add("HYPERV_IMAGE_MIGRATION_TARGET_CONFLICT: $destinationDirectory") }
            }
            if ($targetState -eq 'COPY_REQUIRED') { $copyBytes += [long](($files | Measure-Object Length -Sum).Sum) }
            $consumers = @(Get-LabHyperVLegacyImageConsumers -ParentPath $parentPath -StateRoot $paths.StateRoot -DataRoot $DataRoot)
            $artifacts.Add([PSCustomObject]@{
                ArtifactId=$artifactId; SourceDirectory=[IO.Path]::GetFullPath($directory.FullName)
                SourceParentPath=[IO.Path]::GetFullPath($parentPath); DestinationDirectory=$destinationDirectory
                DestinationParentPath=Join-Path $destinationDirectory 'parent.vhdx'; ParentSha256=$parentHash
                Files=$files; TargetState=$targetState; Consumers=$consumers
            })
        }
    }

    $requiredBytes = if ($copyBytes -gt 0) { [long][Math]::Max(1GB, [Math]::Ceiling([double]$copyBytes * 1.10)) } else { 0L }
    if ([long]$binding.ObservedFreeBytes -lt $requiredBytes) {
        $blockers.Add("HYPERV_IMAGE_MIGRATION_INSUFFICIENT_SPACE: required=$requiredBytes; available=$([long]$binding.ObservedFreeBytes)")
    }
    $plan = [PSCustomObject]@{
        ContractVersion='SqlServerLab.HyperVImageMigrationPlan/1.0'; PlanId=[Guid]::NewGuid().ToString('D')
        CreatedAt=Get-LabTimestamp; Status=if ($blockers.Count) { 'BLOCKED' } elseif ($artifacts.Count) { 'READY' } else { 'NOOP' }
        Source=[PSCustomObject]@{ Kind='LEGACY_IMAGE_STORE'; Root=[string]$paths.LegacyRoot }
        Target=[PSCustomObject]@{
            ResourceKey=[string]$binding.ResourceKey; ControllerId=[string]$binding.ControllerId
            LocationId=[string]$binding.LocationId; VolumeId=[string]$binding.VolumeId
            LabDataRoot=[string]$binding.LabDataRoot; ResourceRoot=[string]$binding.HyperVResourceRoot
        }
        Inventory=[PSCustomObject]@{
            ArtifactCount=$artifacts.Count; CopyBytes=$copyBytes; RequiredBytes=$requiredBytes
            AvailableBytes=[long]$binding.ObservedFreeBytes; Artifacts=@($artifacts)
        }
        RequiredActions=@('copy-and-verify','publish-binding','retain-referenced-source','resume-source-cleanup')
        Blockers=@($blockers); ExecutionImplemented=$true
    }
    if (-not (Test-Path -LiteralPath $paths.StateDirectory -PathType Container)) { New-Item -Path $paths.StateDirectory -ItemType Directory -Force | Out-Null }
    Write-LabArtifactJsonAtomic -Path $paths.Plan -InputObject $plan
    return [PSCustomObject]@{ Path=$paths.Plan; Plan=$plan }
}

function Write-LabHyperVImageMigrationJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Journal)
    $Journal.UpdatedAt = Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
}

function Invoke-LabHyperVImageMigration {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$PlanPath, [string]$DataRoot)

    $resolvedPlanPath = (Resolve-Path -LiteralPath $PlanPath -ErrorAction Stop).Path
    $plan = Get-Content -LiteralPath $resolvedPlanPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 60
    if ([string]$plan.ContractVersion -ne 'SqlServerLab.HyperVImageMigrationPlan/1.0' -or -not [bool]$plan.ExecutionImplemented) { throw 'HYPERV_IMAGE_MIGRATION_PLAN_NOT_EXECUTABLE' }
    if ([string]$plan.Status -eq 'NOOP') { return [PSCustomObject]@{ Status='NOOP'; PlanPath=$resolvedPlanPath } }
    if ([string]$plan.Status -ne 'READY' -or @($plan.Blockers).Count) { throw "HYPERV_IMAGE_MIGRATION_PLAN_BLOCKED: $(@($plan.Blockers) -join ', ')" }
    $stateDirectory = Split-Path -Parent $resolvedPlanPath
    $stateRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $stateDirectory))
    $paths = Get-LabHyperVImageMigrationPaths -StateRoot $stateRoot
    if (-not [string]::Equals($paths.Plan, $resolvedPlanPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'HYPERV_IMAGE_MIGRATION_PLAN_LOCATION_INVALID' }
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$plan.Source.Root), $paths.LegacyRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'HYPERV_IMAGE_MIGRATION_SOURCE_ROOT_CHANGED' }
    $binding = Resolve-LabHyperVResourceBinding -ResourceId 'hyperv-image-store' -ResourceClass Image `
        -LocationId ([string]$plan.Target.LocationId) -DataRoot $DataRoot
    foreach ($property in @('ResourceKey','ControllerId','LocationId','VolumeId','LabDataRoot')) {
        if (-not [string]::Equals([string]$binding.$property, [string]$plan.Target.$property, [StringComparison]::OrdinalIgnoreCase)) { throw "HYPERV_IMAGE_MIGRATION_TARGET_CHANGED: $property" }
    }
    if (-not [string]::Equals([string]$binding.HyperVResourceRoot, [string]$plan.Target.ResourceRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'HYPERV_IMAGE_MIGRATION_TARGET_CHANGED: ResourceRoot' }

    foreach ($artifact in @($plan.Inventory.Artifacts)) {
        $sourceDirectory = [IO.Path]::GetFullPath([string]$artifact.SourceDirectory)
        $expectedSource = Join-Path $paths.LegacyRoot ([string]$artifact.ArtifactId)
        $expectedTarget = Assert-LabHyperVBoundPath -Binding $binding -Path (Join-Path ([string]$binding.HyperVResourceRoot) ([string]$artifact.ArtifactId)) -DataRoot $DataRoot
        if (-not [string]::Equals($sourceDirectory, [IO.Path]::GetFullPath($expectedSource), [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([IO.Path]::GetFullPath([string]$artifact.DestinationDirectory), $expectedTarget, [StringComparison]::OrdinalIgnoreCase)) {
            throw "HYPERV_IMAGE_MIGRATION_ARTIFACT_SCOPE_INVALID: $($artifact.ArtifactId)"
        }
        foreach ($file in @($artifact.Files)) {
            $source = [IO.Path]::GetFullPath((Join-Path $sourceDirectory ([string]$file.RelativePath)))
            if (-not (Test-LabPathWithinRoot -Root $sourceDirectory -Path $source).Valid) { throw "HYPERV_IMAGE_MIGRATION_SOURCE_SCOPE_INVALID: $source" }
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$file.Sha256) { throw "HYPERV_IMAGE_MIGRATION_SOURCE_CHANGED: $source" }
            }
        }
    }
    if (-not $PSCmdlet.ShouldProcess([string]$binding.HyperVResourceRoot, 'Legacy-Hyper-V-Images hashidentisch veröffentlichen und referenzfreie Quellen entfernen')) { return $null }

    $mutex = [Threading.Mutex]::new($false, 'SqlServerLab.HyperVImageMigration')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'HYPERV_IMAGE_MIGRATION_LOCK_TIMEOUT' }
        $planHash = (Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $journal = if (Test-Path -LiteralPath $paths.Journal -PathType Leaf) {
            Get-Content -LiteralPath $paths.Journal -Raw -Encoding utf8 | ConvertFrom-Json -Depth 60
        } else {
            [PSCustomObject]@{
                ContractVersion='SqlServerLab.HyperVImageMigrationJournal/1.0'; PlanId=[string]$plan.PlanId
                PlanSha256=$planHash; Status='PREPARING'; CurrentStep='validate'; CreatedAt=Get-LabTimestamp
                UpdatedAt=Get-LabTimestamp; CompletedAt=$null; CopiedArtifacts=@(); BindingCommitted=$false
                SourceRetention=@(); SourceCleanup=@(); Errors=@()
            }
        }
        if ([string]$journal.PlanId -ne [string]$plan.PlanId -or [string]$journal.PlanSha256 -ne $planHash) { throw 'HYPERV_IMAGE_MIGRATION_PLAN_CHANGED' }
        if ([string]$journal.Status -eq 'COMPLETED') { return [PSCustomObject]@{ Status='COMPLETED'; JournalPath=$paths.Journal; ResourceRoot=[string]$binding.HyperVResourceRoot } }
        try {
            $journal.Status='COPYING'; $journal.CurrentStep='copy-and-verify'
            Write-LabHyperVImageMigrationJournal -Path $paths.Journal -Journal $journal
            foreach ($artifact in @($plan.Inventory.Artifacts)) {
                $targetDirectory=[IO.Path]::GetFullPath([string]$artifact.DestinationDirectory)
                if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
                    $stagingDirectory = Assert-LabHyperVBoundPath -Binding $binding `
                        -Path (Join-Path ([string]$binding.HyperVResourceRoot) ('.m-' + ([string]$plan.PlanId).Replace('-','').Substring(0,12))) -DataRoot $DataRoot
                    if (Test-Path -LiteralPath $stagingDirectory) { throw "HYPERV_IMAGE_MIGRATION_STAGING_CONFLICT: $stagingDirectory" }
                    New-Item -Path $stagingDirectory -ItemType Directory -Force | Out-Null
                    try {
                        foreach ($file in @($artifact.Files)) {
                            $source=Join-Path ([string]$artifact.SourceDirectory) ([string]$file.RelativePath)
                            $destination=Join-Path $stagingDirectory ([string]$file.RelativePath)
                            $destinationParent=Split-Path -Parent $destination
                            if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) { New-Item -Path $destinationParent -ItemType Directory -Force | Out-Null }
                            Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
                            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$file.Sha256) { throw "HYPERV_IMAGE_MIGRATION_COPY_HASH_MISMATCH: $source" }
                        }
                        (Get-Item -LiteralPath (Join-Path $stagingDirectory 'parent.vhdx') -Force).IsReadOnly=$true
                        Move-Item -LiteralPath $stagingDirectory -Destination $targetDirectory -ErrorAction Stop
                    } finally { if (Test-Path -LiteralPath $stagingDirectory) { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force } }
                }
                foreach ($file in @($artifact.Files)) {
                    $target=Join-Path $targetDirectory ([string]$file.RelativePath)
                    if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$file.Sha256) { throw "HYPERV_IMAGE_MIGRATION_TARGET_INTEGRITY_FAILED: $target" }
                }
                $targetParent=Join-Path $targetDirectory 'parent.vhdx'
                if (-not (Get-Item -LiteralPath $targetParent -Force).IsReadOnly -or -not (Test-HyperVVhdxSignature -Path $targetParent)) { throw "HYPERV_IMAGE_MIGRATION_TARGET_INTEGRITY_FAILED: $targetParent" }
                if ([string]$artifact.ArtifactId -notin @($journal.CopiedArtifacts)) { $journal.CopiedArtifacts += [string]$artifact.ArtifactId }
                Write-LabHyperVImageMigrationJournal -Path $paths.Journal -Journal $journal
            }
            $journal.Status='COMMITTING'; $journal.CurrentStep='publish-binding'
            $null=Write-LabHyperVResourceBinding -Binding $binding -StateDirectory $paths.StateDirectory -DataRoot $DataRoot
            $journal.BindingCommitted=$true
            Write-LabHyperVImageMigrationJournal -Path $paths.Journal -Journal $journal

            $journal.Status='CLEANING'; $journal.CurrentStep='reference-safe-source-cleanup'; $journal.SourceRetention=@()
            foreach ($artifact in @($plan.Inventory.Artifacts)) {
                $consumers=@(Get-LabHyperVLegacyImageConsumers -ParentPath ([string]$artifact.SourceParentPath) -StateRoot $paths.StateRoot -DataRoot $DataRoot)
                if ($consumers.Count) {
                    $journal.SourceRetention += [PSCustomObject]@{ ArtifactId=[string]$artifact.ArtifactId; ConsumerCount=$consumers.Count; Consumers=$consumers }
                    continue
                }
                $sourceDirectory=[IO.Path]::GetFullPath([string]$artifact.SourceDirectory)
                if (Test-Path -LiteralPath $sourceDirectory -PathType Container) {
                    foreach ($file in @($artifact.Files)) {
                        $source=Join-Path $sourceDirectory ([string]$file.RelativePath)
                        $target=Join-Path ([string]$artifact.DestinationDirectory) ([string]$file.RelativePath)
                        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or -not (Test-Path -LiteralPath $target -PathType Leaf) -or
                            (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$file.Sha256 -or
                            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$file.Sha256) { throw "HYPERV_IMAGE_MIGRATION_SOURCE_CLEANUP_INTEGRITY_FAILED: $source" }
                    }
                    (Get-Item -LiteralPath ([string]$artifact.SourceParentPath) -Force).IsReadOnly=$false
                    Remove-Item -LiteralPath $sourceDirectory -Recurse -Force -ErrorAction Stop
                }
                if ([string]$artifact.ArtifactId -notin @($journal.SourceCleanup)) { $journal.SourceCleanup += [string]$artifact.ArtifactId }
            }
            if ((Test-Path -LiteralPath $paths.LegacyRoot -PathType Container) -and -not (Get-ChildItem -LiteralPath $paths.LegacyRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $paths.LegacyRoot -Force }
            if (@($journal.SourceRetention).Count) {
                $journal.Status='WAITING_FOR_CONSUMERS'; $journal.CurrentStep='resume-after-child-reparent'
            } else {
                $journal.Status='COMPLETED'; $journal.CurrentStep='complete'; $journal.CompletedAt=Get-LabTimestamp
            }
            Write-LabHyperVImageMigrationJournal -Path $paths.Journal -Journal $journal
            return [PSCustomObject]@{ Status=[string]$journal.Status; JournalPath=$paths.Journal; ResourceRoot=[string]$binding.HyperVResourceRoot; RetainedArtifacts=@($journal.SourceRetention).Count }
        } catch {
            $journal.Status='RECOVERY_REQUIRED'; $journal.CurrentStep='failed'; $journal.Errors += [PSCustomObject]@{ At=Get-LabTimestamp; Message=$_.Exception.Message }
            try { Write-LabHyperVImageMigrationJournal -Path $paths.Journal -Journal $journal } catch { }
            throw "HYPERV_IMAGE_MIGRATION_RECOVERY_REQUIRED: $($_.Exception.Message)"
        }
    } finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

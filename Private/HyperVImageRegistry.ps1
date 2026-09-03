<#
.SYNOPSIS
    Immutable lokale Registry fuer Hyper-V-Parent-VHDX.
.DESCRIPTION
    Importiert bereits vorbereitete Baselines in einen inhaltsadressierten
    Store, verifiziert SHA-256 und VHDX-Signatur und waehlt kompatible
    Aufsetzpunkte deterministisch. Diese Komponente baut oder generalisiert
    noch kein Windows- beziehungsweise SQL-Image.
#>

function Get-HyperVImageStorePaths {
    [CmdletBinding()]
    param([string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $controlRoot = Join-Path $StateRoot 'artifacts/hyperv'
    $registryStateDirectory = Join-Path $controlRoot 'image-store-state'
    $stagingStateDirectory = Join-Path $controlRoot 'staging-store-state'
    $registryBinding = if (Test-Path -LiteralPath $registryStateDirectory -PathType Container) {
        Read-LabHyperVResourceBinding -StateDirectory $registryStateDirectory
    }
    $stagingBinding = if (Test-Path -LiteralPath $stagingStateDirectory -PathType Container) {
        Read-LabHyperVResourceBinding -StateDirectory $stagingStateDirectory
    }
    return [PSCustomObject]@{
        StateRoot    = $StateRoot
        ControlRoot = $controlRoot
        RegistryStateDirectory = $registryStateDirectory
        StagingStateDirectory = $stagingStateDirectory
        RegistryRoot = if ($registryBinding) { [string]$registryBinding.HyperVResourceRoot } else { Join-Path $StateRoot 'artifacts/hyperv/images' }
        StagingRoot  = if ($stagingBinding) { [string]$stagingBinding.HyperVResourceRoot } else { Join-Path $StateRoot 'artifacts/hyperv/staging' }
        RegistryBinding = $registryBinding
        StagingBinding = $stagingBinding
    }
}

function Initialize-HyperVImageStore {
    [CmdletBinding()]
    param([string]$StateRoot)

    $null = Initialize-LabStateRoot -StateRoot $StateRoot
    $paths = Get-HyperVImageStorePaths -StateRoot $StateRoot
    foreach ($directory in @($paths.RegistryStateDirectory, $paths.StagingStateDirectory)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
    }
    $registryBinding = Initialize-LabHyperVResourceBinding -ResourceId 'hyperv-image-store' -ResourceClass Image `
        -StateDirectory $paths.RegistryStateDirectory
    $stagingBinding = Initialize-LabHyperVResourceBinding -ResourceId 'hyperv-staging-store' -ResourceClass Staging `
        -StateDirectory $paths.StagingStateDirectory
    $paths.RegistryRoot = [string]$registryBinding.HyperVResourceRoot
    $paths.StagingRoot = [string]$stagingBinding.HyperVResourceRoot
    $paths.RegistryBinding = $registryBinding
    $paths.StagingBinding = $stagingBinding
    foreach ($directory in @($paths.RegistryRoot, $paths.StagingRoot)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
    }
    return $paths
}

function Get-HyperVImageArtifactDirectories {
    [CmdletBinding()]
    param([string]$ArtifactId, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $storeKey = Get-LabHyperVShortResourceKey -ResourceId 'hyperv-image-store' -ResourceClass Image
    $storeRoots = @(
        foreach ($root in @(Get-LabHyperVResourceDiscoveryRoots -ResourceClass Image -StateRoot $StateRoot)) {
            if ([string]$root.RootKind -eq 'REGISTERED') { Join-Path ([string]$root.Path) $storeKey }
            else { [string]$root.Path }
        }
    ) | Select-Object -Unique
    if ($ArtifactId) { return @($storeRoots | ForEach-Object { Join-Path $_ $ArtifactId }) }
    return @(
        foreach ($root in $storeRoots) {
            if (Test-Path -LiteralPath $root -PathType Container) {
                Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
            }
        }
    )
}

function Get-HyperVTemplatePoolStatus {
    <#
    .SYNOPSIS
        Liefert den begrenzten, unveränderlichen Vorlagenpool für Hyper-V-Labs.
    .DESCRIPTION
        Der Pool enthält ausschließlich veröffentlichte OS- und SQL-Prepared-
        Images. Run-lokale Children, Builder und synthetische Testartefakte
        zählen bewusst nicht. Die Obergrenze begrenzt den dauerhaft zu
        wartenden Imagebestand; ein volles Pool erfordert eine explizite,
        referenzsichere Bereinigung über die Expertenaktion.
    #>
    [CmdletBinding()]
    param(
        [string]$StateRoot,
        [ValidateRange(1, 100)][int]$MaximumTemplates = 20,
        [array]$Artifacts
    )

    if (-not $PSBoundParameters.ContainsKey('Artifacts')) {
        $Artifacts = @(Get-HyperVImageArtifact -StateRoot $StateRoot -SkipIntegrityCheck)
    }

    $templates = @($Artifacts | Where-Object {
        $_ -and [string]$_.artifactState -in @('OS_SEALED', 'SQL_PREPARED_SEALED')
    } | Sort-Object artifactState, registeredAt, artifactId)
    $windowsBaselines = @($templates | Where-Object { $_.artifactState -eq 'OS_SEALED' })
    $sqlPreparedImages = @($templates | Where-Object { $_.artifactState -eq 'SQL_PREPARED_SEALED' })

    return [PSCustomObject]@{
        MaximumTemplates = $MaximumTemplates
        UsedTemplates = $templates.Count
        AvailableTemplates = [Math]::Max(0, $MaximumTemplates - $templates.Count)
        IsAtCapacity = $templates.Count -ge $MaximumTemplates
        WindowsBaselines = $windowsBaselines.Count
        SqlPreparedImages = $sqlPreparedImages.Count
        Templates = $templates
    }
}

function Test-HyperVVhdxSignature {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $buffer = [byte[]]::new(8)
        if ($stream.Read($buffer, 0, 8) -ne 8) { return $false }
        return [System.Text.Encoding]::ASCII.GetString($buffer) -eq 'vhdxfile'
    }
    finally { $stream.Dispose() }
}

function Get-HyperVImageArtifact {
    [CmdletBinding()]
    param(
        [string]$ArtifactId,
        [string]$StateRoot,
        [switch]$SkipIntegrityCheck
    )

    $directories = if ($ArtifactId) {
        if ($ArtifactId -notmatch '^hyperv-[a-z0-9-]+-[a-f0-9]{64}$') {
            throw 'HYPERV_ARTIFACT_ID_INVALID'
        }
        @(Get-HyperVImageArtifactDirectories -ArtifactId $ArtifactId -StateRoot $StateRoot)
    }
    else { @(Get-HyperVImageArtifactDirectories -StateRoot $StateRoot) }

    $results = @()
    foreach ($directory in $directories) {
        $metadataPath = Join-Path $directory 'metadata.json'
        $vhdxPath = Join-Path $directory 'parent.vhdx'
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $vhdxPath -PathType Leaf)) { continue }

        $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
        if (-not $SkipIntegrityCheck) {
            $observed = (Get-FileHash -LiteralPath $vhdxPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($observed -ne [string]$metadata.sha256 -or -not (Get-Item -LiteralPath $vhdxPath).IsReadOnly) {
                throw "HYPERV_ARTIFACT_INTEGRITY_MISMATCH: $($metadata.artifactId)"
            }
        }
        $metadata | Add-Member -NotePropertyName Path -NotePropertyValue $vhdxPath -Force
        $results += $metadata
    }
    if ($ArtifactId) { return @($results)[0] }
    return @($results | Sort-Object artifactId)
}

function Import-HyperVImageArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
        [Parameter(Mandatory)][ValidateSet('OS_SEALED', 'SQL_PREPARED_SEALED', 'LIFECYCLE_TEST_ONLY')][string]$ArtifactState,
        [Parameter(Mandatory)][string]$OperatingSystemId,
        [Parameter(Mandatory)][string]$OperatingSystemVersion,
        [Parameter(Mandatory)][string]$Edition,
        [ValidateSet('core', 'desktop-experience', 'synthetic')][string]$InstallationType = 'core',
        [string]$Language = 'en-US',
        [ValidateSet('x64')][string]$Architecture = 'x64',
        [Parameter(Mandatory)][ValidateSet('licensed', 'evaluation', 'test-only')][string]$LicenseType,
        [Parameter(Mandatory)][ValidateSet('catalog-verified', 'user-verified-local', 'generated-by-runtime', 'synthetic-test')][string]$IntegrityOrigin,
        [ValidateSet('none', 'space')][string]$InitialMediaKey = 'none',
        [switch]$Generalized,
        [switch]$SqlPrepared,
        [string]$SqlVersion,
        [string]$SqlEdition,
        [string]$SqlBuild,
        [string[]]$SqlFeatures = @(),
        [ValidateSet('licensed', 'evaluation', 'developer')][string]$SqlLicenseType,
        [Nullable[datetime]]$SqlEvaluationExpiresAt,
        [Nullable[datetime]]$EvaluationExpiresAt,
        [ValidateLength(1, 80)][string]$DisplayName,
        [string]$StateRoot
    )

    $source = (Resolve-Path -LiteralPath $VhdxPath -ErrorAction Stop).Path
    if ([System.IO.Path]::GetExtension($source) -ne '.vhdx' -or -not (Test-HyperVVhdxSignature -Path $source)) {
        throw 'HYPERV_ARTIFACT_NOT_VHDX'
    }
    if (-not (Get-Item -LiteralPath $source -Force).IsReadOnly) {
        throw 'HYPERV_ARTIFACT_SOURCE_NOT_READ_ONLY'
    }
    $sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha256 -ne $ExpectedSha256.ToLowerInvariant()) { throw 'HYPERV_ARTIFACT_INTEGRITY_MISMATCH' }
    if ($ArtifactState -in @('OS_SEALED', 'SQL_PREPARED_SEALED') -and -not $Generalized) {
        throw 'HYPERV_ARTIFACT_NOT_GENERALIZED'
    }
    if ($ArtifactState -eq 'SQL_PREPARED_SEALED' -and
        (-not $SqlPrepared -or -not $SqlVersion -or -not $SqlEdition -or -not $SqlLicenseType)) {
        throw 'HYPERV_SQL_PREPARED_EVIDENCE_REQUIRED'
    }
    if ($ArtifactState -eq 'LIFECYCLE_TEST_ONLY' -and
        ($LicenseType -ne 'test-only' -or $IntegrityOrigin -ne 'synthetic-test')) {
        throw 'HYPERV_TEST_ARTIFACT_METADATA_INVALID'
    }
    $evaluationExpiresAtUtc = if ($EvaluationExpiresAt) {
        ([datetime]$EvaluationExpiresAt).ToUniversalTime().ToString('o')
    }
    else { $null }
    $sqlEvaluationExpiresAtUtc = if ($SqlEvaluationExpiresAt) {
        ([datetime]$SqlEvaluationExpiresAt).ToUniversalTime().ToString('o')
    }
    else { $null }
    if ($SqlLicenseType -eq 'evaluation' -and $SqlEvaluationExpiresAt -and
        ([datetime]$SqlEvaluationExpiresAt).ToUniversalTime() -le [datetime]::UtcNow) {
        throw 'HYPERV_SQL_EVALUATION_EXPIRED'
    }

    $stateToken = $ArtifactState.ToLowerInvariant().Replace('_', '-')
    $artifactId = "hyperv-$stateToken-$sha256"
    return Invoke-LabArtifactStoreLock -StateRoot $StateRoot -ScriptBlock {
        $paths = Initialize-HyperVImageStore -StateRoot $StateRoot
        $existing = Get-HyperVImageArtifact -ArtifactId $artifactId -StateRoot $StateRoot
        if ($existing) {
            $metadataCompatible =
                [string]$existing.operatingSystem.id -eq $OperatingSystemId -and
                [string]$existing.operatingSystem.version -eq $OperatingSystemVersion -and
                [string]$existing.operatingSystem.edition -eq $Edition -and
                [string]$existing.operatingSystem.installationType -eq $InstallationType -and
                [string]$existing.operatingSystem.language -eq $Language -and
                [string]$existing.operatingSystem.architecture -eq $Architecture -and
                [string]$existing.license.type -eq $LicenseType -and
                [string]$existing.license.evaluationExpiresAt -eq [string]$evaluationExpiresAtUtc -and
                [bool]$existing.generalized -eq [bool]$Generalized -and
                [bool]$existing.sqlPrepared -eq [bool]$SqlPrepared -and
                [string]$existing.sql.version -eq [string]$SqlVersion -and
                [string]$existing.sql.edition -eq [string]$SqlEdition -and
                [string]$existing.sql.license.type -eq [string]$SqlLicenseType -and
                [string]$existing.sql.license.evaluationExpiresAt -eq [string]$sqlEvaluationExpiresAtUtc -and
                (@($existing.sql.features | Sort-Object -Unique) -join '|') -eq (@($SqlFeatures | Sort-Object -Unique) -join '|')
            if (-not $metadataCompatible) { throw 'HYPERV_ARTIFACT_METADATA_CONFLICT' }
            return $existing
        }

        if ($ArtifactState -in @('OS_SEALED', 'SQL_PREPARED_SEALED')) {
            $pool = Get-HyperVTemplatePoolStatus -StateRoot $StateRoot
            if ($pool.IsAtCapacity) {
                throw "HYPERV_TEMPLATE_POOL_CAPACITY_EXCEEDED: Der Vorlagenpool enthält bereits $($pool.UsedTemplates) von maximal $($pool.MaximumTemplates) veröffentlichten OS-/SQL-Prepared-Images. Entfernen Sie zuerst bewusst eine nicht referenzierte Vorlage."
            }
        }

        $stagingDirectory = Join-Path $paths.StagingRoot (New-LabGuid)
        $targetDirectory = Join-Path $paths.RegistryRoot $artifactId
        $null = Assert-LabHyperVBoundPath -Binding $paths.StagingBinding -Path (Join-Path $stagingDirectory '.path-check')
        $null = Assert-LabHyperVBoundPath -Binding $paths.RegistryBinding -Path (Join-Path $targetDirectory '.path-check')
        New-Item -Path $stagingDirectory -ItemType Directory -Force | Out-Null
        try {
            $stagedVhdx = Join-Path $stagingDirectory 'parent.vhdx'
            Copy-Item -LiteralPath $source -Destination $stagedVhdx -Force
            if (-not (Test-Path -LiteralPath $stagedVhdx -PathType Leaf)) { throw 'HYPERV_ARTIFACT_STAGE_POSTCONDITION_FAILED' }
            (Get-Item -LiteralPath $stagedVhdx).IsReadOnly = $true
            $copiedSha = (Get-FileHash -LiteralPath $stagedVhdx -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($copiedSha -ne $sha256) { throw 'HYPERV_ARTIFACT_COPY_INTEGRITY_MISMATCH' }

            $metadata = [PSCustomObject]@{
                contractVersion       = '1'
                artifactId            = $artifactId
                # Ein optionaler, benutzervergebener Name erleichtert die
                # Auswahl in der Oberfläche; die technische ArtifactId bleibt
                # weiterhin ausschließlich hashbasiert und unveränderlich.
                displayName           = $DisplayName
                artifactState         = $ArtifactState
                sha256                = $sha256
                integrityOrigin       = $IntegrityOrigin
                bootInteraction       = [PSCustomObject]@{
                    initialMediaKey = $InitialMediaKey
                    purpose = 'build-provenance'
                }
                registeredAt          = Get-LabTimestamp
                generalized           = [bool]$Generalized
                sqlPrepared           = [bool]$SqlPrepared
                operatingSystem       = [PSCustomObject]@{
                    id = $OperatingSystemId; version = $OperatingSystemVersion; edition = $Edition
                    installationType = $InstallationType; language = $Language; architecture = $Architecture
                }
                sql                   = if ($SqlVersion) { [PSCustomObject]@{
                    version = $SqlVersion; edition = $SqlEdition; build = $SqlBuild; features = @($SqlFeatures | Sort-Object -Unique)
                    license = [PSCustomObject]@{
                        type = $SqlLicenseType
                        evaluationStartsAt = if ($SqlLicenseType -eq 'evaluation' -and -not $sqlEvaluationExpiresAtUtc) { 'complete-image' } else { $null }
                        evaluationExpiresAt = $sqlEvaluationExpiresAtUtc
                    }
                }} else { $null }
                license               = [PSCustomObject]@{
                    type = $LicenseType
                    evaluationExpiresAt = $evaluationExpiresAtUtc
                }
            }
            Write-LabArtifactJsonAtomic -Path (Join-Path $stagingDirectory 'metadata.json') -InputObject $metadata
            Move-Item -LiteralPath $stagingDirectory -Destination $targetDirectory
            if (-not (Test-Path -LiteralPath (Join-Path $targetDirectory 'parent.vhdx') -PathType Leaf) -or
                -not (Test-Path -LiteralPath (Join-Path $targetDirectory 'metadata.json') -PathType Leaf)) {
                throw 'HYPERV_ARTIFACT_PUBLISH_POSTCONDITION_FAILED'
            }
        }
        finally {
            if (Test-Path -LiteralPath $stagingDirectory) { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force }
        }
        return Get-HyperVImageArtifact -ArtifactId $artifactId -StateRoot $StateRoot
    }
}

function Remove-HyperVImageArtifact {
    <#
    .SYNOPSIS
        Entfernt ein veroeffentlichtes Hyper-V-Image nur ohne aktive Build-Referenz.
    .DESCRIPTION
        Der Registry-Eintrag und die immutable VHDX werden als Einheit entfernt.
        Aktive Windows- oder SQL-Builds muessen vorher aufgeraeumt werden, damit
        kein Workflow auf ein geloeschtes Image verweist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArtifactId,
        [string]$StateRoot
    )

    if ($ArtifactId -notmatch '^hyperv-[a-z0-9-]+-[a-f0-9]{64}$') { throw 'HYPERV_ARTIFACT_ID_INVALID' }
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }

    return Invoke-LabArtifactStoreLock -StateRoot $StateRoot -ScriptBlock {
        $artifact = Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot -SkipIntegrityCheck
        if (-not $artifact) { throw 'HYPERV_ARTIFACT_NOT_FOUND' }

        $references = @()
        foreach ($build in @(Get-HyperVImageBuildPlans -StateRoot $StateRoot)) {
            if ([string]$build.artifact.artifactId -eq $ArtifactId) { $references += "Windows-Build $($build.buildId)" }
        }
        foreach ($build in @(Get-HyperVSqlImageBuildPlans -StateRoot $StateRoot)) {
            if ([string]$build.artifact.artifactId -eq $ArtifactId -or [string]$build.parentArtifact.artifactId -eq $ArtifactId) {
                $references += "SQL-Build $($build.buildId)"
            }
        }
        foreach ($run in @(Get-LabActiveRuns -StateRoot $StateRoot)) {
            if ([string]$run.metadata.imageArtifactId -eq $ArtifactId) {
                $references += "Lab-Run $($run.runId)"
            }
        }
        if ($references.Count -gt 0) {
            throw "HYPERV_ARTIFACT_IN_USE: $($references -join ', '). Bereinigen Sie zuerst den zugehörigen Build oder Lab-Run."
        }

        $resolvedTarget = (Resolve-Path -LiteralPath (Split-Path -Parent ([string]$artifact.Path)) -ErrorAction Stop).Path
        $mutationRoot = Resolve-LabHyperVMutationRoot -ExistingResourcePath (Join-Path $resolvedTarget 'parent.vhdx') `
            -ResourceClass Image -StateRoot $StateRoot
        if (-not $mutationRoot.AllowsExistingLifecycle -or (Split-Path -Leaf $resolvedTarget) -ne $ArtifactId) {
            throw 'HYPERV_ARTIFACT_DELETE_OUTSIDE_REGISTRY'
        }
        $vhdxPath = Join-Path $resolvedTarget 'parent.vhdx'
        if (Test-Path -LiteralPath $vhdxPath -PathType Leaf) { (Get-Item -LiteralPath $vhdxPath -Force).IsReadOnly = $false }
        Remove-Item -LiteralPath $resolvedTarget -Recurse -Force -ErrorAction Stop
        return [PSCustomObject]@{ ArtifactId = $ArtifactId; Status = 'REMOVED' }
    }
}

function Rename-HyperVImageArtifact {
    <#
    .SYNOPSIS
        Ändert ausschließlich den Anzeigenamen eines Registry-Images.
    .DESCRIPTION
        Die inhaltsadressierte Artifact-ID, der verifizierte Hash und die
        schreibgeschützte Parent-VHDX bleiben unverändert. Nur die frei
        wählbare UI-Metadatenbeschriftung wird unter derselben Store-Sperre
        wie Import und Löschen aktualisiert.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArtifactId,
        [Parameter(Mandatory)][ValidateLength(1, 80)][string]$DisplayName,
        [string]$StateRoot
    )

    if ($ArtifactId -notmatch '^hyperv-[a-z0-9-]+-[a-f0-9]{64}$') { throw 'HYPERV_ARTIFACT_ID_INVALID' }
    $DisplayName = $DisplayName.Trim()
    if ([string]::IsNullOrWhiteSpace($DisplayName)) { throw 'HYPERV_ARTIFACT_DISPLAY_NAME_REQUIRED' }
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }

    return Invoke-LabArtifactStoreLock -StateRoot $StateRoot -ScriptBlock {
        $artifact = Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot -SkipIntegrityCheck
        if (-not $artifact) { throw 'HYPERV_ARTIFACT_NOT_FOUND' }
        $metadataPath = Join-Path (Split-Path -Parent ([string]$artifact.Path)) 'metadata.json'
        $mutationRoot = Resolve-LabHyperVMutationRoot -ExistingResourcePath $metadataPath -ResourceClass Image -StateRoot $StateRoot
        if (-not $mutationRoot.AllowsExistingLifecycle) { throw 'HYPERV_ARTIFACT_METADATA_MUTATION_NOT_ALLOWED' }
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw 'HYPERV_ARTIFACT_METADATA_NOT_FOUND' }
        $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
        $metadata | Add-Member -NotePropertyName displayName -NotePropertyValue $DisplayName -Force
        $metadata | Add-Member -NotePropertyName displayNameUpdatedAt -NotePropertyValue (Get-LabTimestamp) -Force
        Write-LabArtifactJsonAtomic -Path $metadataPath -InputObject $metadata
        return Get-HyperVImageArtifact -ArtifactId $ArtifactId -StateRoot $StateRoot -SkipIntegrityCheck
    }
}

function Resolve-HyperVImageArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OperatingSystemId,
        [Parameter(Mandatory)][string]$OperatingSystemVersion,
        [Parameter(Mandatory)][string]$Edition,
        [string]$InstallationType = 'core',
        [string]$Language = 'en-US',
        [string]$Architecture = 'x64',
        [string]$SqlVersion,
        [string]$SqlEdition,
        [string[]]$SqlFeatures = @(),
        [ValidateRange(0, 3650)][int]$MinimumEvaluationDaysRemaining = 30,
        [string]$StateRoot
    )

    $accepted = @()
    $rejected = @()
    foreach ($artifact in @(Get-HyperVImageArtifact -StateRoot $StateRoot)) {
        $reasons = @()
        if ($artifact.artifactState -eq 'LIFECYCLE_TEST_ONLY') { $reasons += 'test-only' }
        foreach ($field in @('id', 'version', 'edition', 'installationType', 'language', 'architecture')) {
            $expected = switch ($field) {
                id { $OperatingSystemId }; version { $OperatingSystemVersion }; edition { $Edition }
                installationType { $InstallationType }; language { $Language }; architecture { $Architecture }
            }
            if (-not ([string]$artifact.operatingSystem.$field).Equals([string]$expected, [System.StringComparison]::OrdinalIgnoreCase)) {
                $reasons += "os-$field"
            }
        }
        $evaluationEligibility = Test-HyperVImageArtifactEvaluationEligibility -Artifact $artifact `
            -MinimumEvaluationDaysRemaining $MinimumEvaluationDaysRemaining
        if (-not $evaluationEligibility.Eligible) { $reasons += $evaluationEligibility.Reason }
        if ($SqlVersion) {
            if ($artifact.artifactState -ne 'SQL_PREPARED_SEALED') { $reasons += 'sql-not-prepared' }
            if ([string]$artifact.sql.version -ne $SqlVersion -or [string]$artifact.sql.edition -ne $SqlEdition) { $reasons += 'sql-version-edition' }
            $actualFeatures = @($artifact.sql.features | Sort-Object -Unique)
            if (($actualFeatures -join '|') -ne (@($SqlFeatures | Sort-Object -Unique) -join '|')) { $reasons += 'sql-features' }
        }
        if ($reasons.Count -gt 0) {
            $rejected += [PSCustomObject]@{ ArtifactId = $artifact.artifactId; Reasons = @($reasons | Sort-Object -Unique) }
        }
        else { $accepted += $artifact }
    }

    $selected = @($accepted | Sort-Object `
        @{ Expression = { if ($_.artifactState -eq 'SQL_PREPARED_SEALED') { 2 } else { 1 } }; Descending = $true }, `
        @{ Expression = { [datetime]$_.registeredAt }; Descending = $true }, artifactId | Select-Object -First 1)[0]
    return [PSCustomObject]@{
        Status = if ($selected) { 'ARTIFACT_SELECTED' } else { 'BASELINE_NOT_COMPATIBLE' }
        Selected = $selected
        Rejected = @($rejected)
    }
}

function Test-HyperVImageArtifactEvaluationEligibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Artifact,
        [ValidateRange(0, 3650)][int]$MinimumEvaluationDaysRemaining = 30
    )

    if (-not ([string]$Artifact.license.type).Equals('evaluation', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [PSCustomObject]@{ Eligible=$true; Reason=$null }
    }
    $expiryText = [string]$Artifact.license.evaluationExpiresAt
    if (-not $expiryText) {
        return [PSCustomObject]@{ Eligible=$false; Reason='evaluation-expiry-unknown' }
    }
    [datetime]$expiresAt = [datetime]::MinValue
    if (-not [datetime]::TryParse($expiryText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$expiresAt)) {
        return [PSCustomObject]@{ Eligible=$false; Reason='evaluation-expiry-invalid' }
    }
    if (($expiresAt.ToUniversalTime() - [datetime]::UtcNow).TotalDays -le $MinimumEvaluationDaysRemaining) {
        return [PSCustomObject]@{ Eligible=$false; Reason='evaluation-expiring' }
    }
    return [PSCustomObject]@{ Eligible=$true; Reason=$null }
}

function Get-HyperVManifestFallbackArtifactRejectionReasons {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SqlVersion,
        [ValidateRange(0, 3650)][int]$MinimumEvaluationDaysRemaining = 30
    )

    $reasons = @()
    if ([string]$Artifact.artifactState -ne 'SQL_PREPARED_SEALED') { $reasons += 'artifact-not-sql-prepared-sealed' }
    if (-not [bool]$Artifact.generalized) { $reasons += 'artifact-not-generalized' }
    if (-not [bool]$Artifact.sqlPrepared) { $reasons += 'artifact-sql-not-prepared' }
    if ([string]$Artifact.operatingSystem.id -notmatch '^windows-server') { $reasons += 'operating-system-not-windows-server' }
    if ([string]$Artifact.operatingSystem.edition -notmatch '(?i)standard') { $reasons += 'operating-system-not-standard' }
    if (-not ([string]$Artifact.operatingSystem.installationType).Equals('desktop-experience', [System.StringComparison]::OrdinalIgnoreCase)) { $reasons += 'installation-type-not-desktop-experience' }
    if (-not ([string]$Artifact.license.type).Equals('evaluation', [System.StringComparison]::OrdinalIgnoreCase)) { $reasons += 'license-not-evaluation' }
    if ([string]::IsNullOrWhiteSpace([string]$Artifact.sql.version)) { $reasons += 'sql-version-missing' }
    elseif (-not ([string]$Artifact.sql.version).Equals($SqlVersion, [System.StringComparison]::OrdinalIgnoreCase)) { $reasons += 'sql-version-mismatch' }
    $evaluationEligibility = Test-HyperVImageArtifactEvaluationEligibility -Artifact $Artifact `
        -MinimumEvaluationDaysRemaining $MinimumEvaluationDaysRemaining
    if (-not $evaluationEligibility.Eligible) { $reasons += $evaluationEligibility.Reason }
    return @($reasons | Sort-Object -Unique)
}

function Get-HyperVManifestFallbackArtifactSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SqlVersion,
        [ValidateRange(0, 3650)][int]$MinimumEvaluationDaysRemaining = 30,
        [string]$StateRoot
    )

    $candidates = @()
    $reasons = @()
    foreach ($artifact in @(Get-HyperVImageArtifact -StateRoot $StateRoot)) {
        $artifactReasons = @(Get-HyperVManifestFallbackArtifactRejectionReasons -Artifact $artifact `
            -SqlVersion $SqlVersion -MinimumEvaluationDaysRemaining $MinimumEvaluationDaysRemaining)
        if ($artifactReasons.Count -gt 0) {
            $reasons += $artifactReasons
            continue
        }
        $versionMatch = [regex]::Match([string]$artifact.operatingSystem.version, '\d{4}')
        $candidates += [PSCustomObject]@{
            Artifact = $artifact
            VersionRank = if ($versionMatch.Success) { [int]$versionMatch.Value } else { -1 }
        }
    }

    $selected = @($candidates | Sort-Object `
        @{ Expression = { $_.VersionRank }; Descending = $true }, `
        @{ Expression = { [datetime]$_.Artifact.registeredAt }; Descending = $true }, `
        @{ Expression = { [string]$_.Artifact.artifactId }; Descending = $false } |
        Select-Object -First 1 | ForEach-Object { $_.Artifact })[0]
    return [PSCustomObject]@{
        Selected = $selected
        Reasons = if ($reasons.Count -gt 0) { @($reasons | Sort-Object -Unique) } else { @('no-published-artifact') }
    }
}

function Resolve-HyperVManifestFallbackArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SqlVersion,
        [ValidateRange(0, 3650)][int]$MinimumEvaluationDaysRemaining = 30,
        [string]$StateRoot
    )

    return (Get-HyperVManifestFallbackArtifactSelection -SqlVersion $SqlVersion `
        -MinimumEvaluationDaysRemaining $MinimumEvaluationDaysRemaining -StateRoot $StateRoot).Selected
}

function Add-HyperVImageManifestLockEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)]$Artifact
    )

    if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) { throw 'ARTIFACT_LOCK_INVALID' }
    $lockPath = Join-Path $RunDirectory 'manifest.lock.json'
    $lock = if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        Get-Content -LiteralPath $lockPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    } else { [PSCustomObject]@{ formatVersion = '1'; artifacts = @() } }
    $entry = [PSCustomObject]@{
        artifactId = $Artifact.artifactId; artifactType = 'hyperv-image'; artifactState = $Artifact.artifactState
        sha256 = $Artifact.sha256; integrityOrigin = $Artifact.integrityOrigin; contractVersion = $Artifact.contractVersion
        compatibility = [PSCustomObject]@{ operatingSystem = $Artifact.operatingSystem; sql = $Artifact.sql }
    }
    if (-not @($lock.artifacts | Where-Object { $_.artifactId -eq $entry.artifactId })) {
        $lock.artifacts = @($lock.artifacts + $entry)
        Write-LabArtifactJsonAtomic -Path $lockPath -InputObject $lock
    }
    return $lockPath
}

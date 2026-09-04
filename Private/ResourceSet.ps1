<#
.SYNOPSIS
    Gemeinsamer Plan- und Importkern fuer katalogisierte Offline-Ressourcen.
.DESCRIPTION
    Loest Sample-Artefakte und Windows-/Hyper-V-External-Runtime-Medien ohne
    Provider- oder SQL-Mutation auf. Lokale Bestandsimporte werden nur aus
    exakt abgeleiteten Pfaden und nach SHA-256-Pruefung zugelassen.
#>

function Get-LabResourceSetDefaultId {
    [CmdletBinding()]
    param()

    $ids = [Collections.Generic.List[string]]::new()
    foreach ($sample in @(Get-LabExecutableSampleVariant |
        Where-Object ArtifactType -in @('backup', 'archive-backup', 'sql-script', 'script-bundle', 'bacpac') |
        Sort-Object SampleId, Variant)) {
        $ids.Add("sample:$($sample.SampleId):$($sample.Variant)")
    }
    foreach ($software in @((Get-LabSoftwareCatalog).software | Sort-Object id)) {
        foreach ($variant in @($software.variants | Where-Object {
            [string]$_.status -eq 'SUPPORTED' -and
            [string]$_.operatingSystem -eq 'windows' -and
            @($_.providers) -contains 'hyperv'
        } | Sort-Object id)) {
            $ids.Add("software:$($software.id):$($variant.id)")
        }
    }
    return @($ids)
}

function Get-LabResourceSetDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ResourceId)

    $parts = @($ResourceId -split ':')
    if ($parts.Count -ne 3 -or @($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw "RESOURCE_SET_ID_INVALID: '$ResourceId'. Erwartet wird sample:<id>:<variant> oder software:<id>:<variant>."
    }

    if ($parts[0] -eq 'sample') {
        $sample = @(Get-LabExecutableSampleVariant | Where-Object {
            [string]$_.SampleId -eq $parts[1] -and [string]$_.Variant -eq $parts[2]
        })
        if ($sample.Count -ne 1) {
            throw "RESOURCE_SET_SAMPLE_NOT_FOUND: $ResourceId"
        }
        if ([string]$sample[0].ArtifactType -notin @('backup', 'archive-backup', 'sql-script', 'script-bundle', 'bacpac')) {
            throw "RESOURCE_SET_SAMPLE_NOT_SUPPORTED: $ResourceId"
        }
        $catalogSample = Get-LabSampleDatabase -Id $parts[1]
        $catalogVariant = @($catalogSample.versions.PSObject.Properties |
            Where-Object Name -eq $parts[2] | Select-Object -First 1)
        if ($catalogVariant.Count -ne 1) { throw "RESOURCE_SET_SAMPLE_NOT_FOUND: $ResourceId" }
        $sample[0] | Add-Member -NotePropertyName HandlerContractVersion `
            -NotePropertyValue ([string]$catalogVariant[0].Value.handlerContractVersion) -Force
        return [PSCustomObject]@{
            ResourceId = $ResourceId
            Kind = 'sample'
            Sample = $sample[0]
            SoftwarePlan = $null
        }
    }

    if ($parts[0] -eq 'software') {
        $software = Get-LabSoftwareCatalogItem -Id $parts[1]
        $variant = if ($software) {
            @($software.variants | Where-Object { [string]$_.id -eq $parts[2] }) | Select-Object -First 1
        }
        else { $null }
        if (-not $variant -or [string]$software.kind -ne 'sqlExternalRuntime' -or
            [string]$variant.status -ne 'SUPPORTED' -or [string]$variant.operatingSystem -ne 'windows' -or
            @($variant.providers) -notcontains 'hyperv') {
            throw "RESOURCE_SET_SOFTWARE_NOT_SUPPORTED: $ResourceId"
        }

        $major = @($variant.sqlMajorVersions | ForEach-Object { [int]$_ } | Sort-Object -Unique)
        if ($major.Count -ne 1) { throw "RESOURCE_SET_SOFTWARE_SQL_VERSION_AMBIGUOUS: $ResourceId" }
        $sqlVersion = @($script:VersionCatalog.versions | Where-Object { [int]$_.major -eq $major[0] } | Select-Object -First 1)
        if ($sqlVersion.Count -ne 1) { throw "RESOURCE_SET_SOFTWARE_SQL_VERSION_UNKNOWN: $ResourceId" }
        $request = [PSCustomObject]@{
            Id = [string]$software.id
            Version = [string]$variant.runtimeVersion
            Variant = [string]$variant.id
            Scope = 'sqlExternalRuntime'
            InstallMethod = 'catalog'
            Optional = $false
            Packages = @()
            RequestSource = 'resource-set'
        }
        $plan = Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion ([string]$sqlVersion[0].id) `
            -Provider hyperv -OperatingSystem windows
        if ([string]$plan.Status -ne 'RESOLVED') {
            throw "RESOURCE_SET_SOFTWARE_PLAN_BLOCKED: $ResourceId / $($plan.ReasonCode)"
        }
        return [PSCustomObject]@{
            ResourceId = $ResourceId
            Kind = 'software'
            Sample = $null
            SoftwarePlan = $plan
        }
    }

    throw "RESOURCE_SET_KIND_INVALID: $($parts[0])"
}

function Get-LabResourceSetRoots {
    [CmdletBinding()]
    param(
        [string]$MediaRoot,
        [string]$TestDataRoot,
        [string]$StateRoot,
        [string]$SourceMediaRoot
    )

    if ([string]::IsNullOrWhiteSpace($MediaRoot)) { $MediaRoot = Get-LabMediaRootDefault }
    if ([string]::IsNullOrWhiteSpace($MediaRoot)) {
        throw 'RESOURCE_SET_MEDIA_ROOT_REQUIRED: -MediaRoot angeben oder den Media Root konfigurieren.'
    }
    $media = [IO.Path]::GetFullPath($MediaRoot).TrimEnd('\', '/')
    if ($media -eq [IO.Path]::GetPathRoot($media).TrimEnd('\', '/')) {
        throw 'RESOURCE_SET_MEDIA_ROOT_TOO_BROAD'
    }
    $mediaSafety = Test-PathSafe -Path $media -RepositoryRoot $script:ModuleRoot
    if (-not $mediaSafety.Valid) { throw "RESOURCE_SET_MEDIA_ROOT_UNSAFE: $($mediaSafety.Reason)" }
    if ([string]::IsNullOrWhiteSpace($TestDataRoot)) { $TestDataRoot = Get-LabTestDataRootDefault }
    if ([string]::IsNullOrWhiteSpace($TestDataRoot)) { $TestDataRoot = Join-Path $media 'Testdaten' }
    $testData = [IO.Path]::GetFullPath($TestDataRoot).TrimEnd('\', '/')
    if ($testData -eq [IO.Path]::GetPathRoot($testData).TrimEnd('\', '/')) {
        throw 'RESOURCE_SET_TEST_DATA_ROOT_TOO_BROAD'
    }
    $testDataSafety = Test-PathSafe -Path $testData -RepositoryRoot $script:ModuleRoot
    if (-not $testDataSafety.Valid) { throw "RESOURCE_SET_TEST_DATA_ROOT_UNSAFE: $($testDataSafety.Reason)" }
    if ([string]::IsNullOrWhiteSpace($StateRoot)) { $StateRoot = Get-LabStateRoot }
    $state = [IO.Path]::GetFullPath($StateRoot).TrimEnd('\', '/')
    $stateSafety = Test-PathSafe -Path $state -RepositoryRoot $script:ModuleRoot
    if (-not $stateSafety.Valid) { throw "RESOURCE_SET_STATE_ROOT_UNSAFE: $($stateSafety.Reason)" }
    $source = if ([string]::IsNullOrWhiteSpace($SourceMediaRoot)) { $null } else {
        $candidate = [IO.Path]::GetFullPath($SourceMediaRoot).TrimEnd('\', '/')
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
            throw "RESOURCE_SET_SOURCE_MEDIA_ROOT_NOT_FOUND: $candidate"
        }
        $candidate
    }
    return [PSCustomObject]@{ MediaRoot=$media; TestDataRoot=$testData; StateRoot=$state; SourceMediaRoot=$source }
}

function Get-LabSampleResourceReadOnlyStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Sample,
        [Parameter(Mandatory)][string]$TestDataRoot,
        [Parameter(Mandatory)][string]$StateRoot
    )

    $knownSha = if ($Sample.ExpectedSha256) { ([string]$Sample.ExpectedSha256).ToLowerInvariant() } else { $null }
    $trustStatus = if ($knownSha) { 'catalog-verified' } else { 'TRUST_REQUIRED' }
    $canonicalSource = Get-LabCanonicalArtifactSource -Source ([string]$Sample.Source)
    $trustPath = Join-Path $StateRoot 'trust/sample-artifacts.json'
    if (-not $knownSha -and (Test-Path -LiteralPath $trustPath -PathType Leaf)) {
        try {
            $trust = Get-Content -LiteralPath $trustPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
            $record = @($trust.records | Where-Object {
                [string]$_.source -eq $canonicalSource -and [string]$_.sampleId -eq [string]$Sample.SampleId -and
                [string]$_.sampleVariant -eq [string]$Sample.Variant
            } | Sort-Object trustedAt -Descending | Select-Object -First 1)
            if ($record.Count -eq 1 -and [string]$record[0].sha256 -match '^[a-fA-F0-9]{64}$') {
                $knownSha = ([string]$record[0].sha256).ToLowerInvariant()
                $trustStatus = [string]$record[0].integrityOrigin
            }
        }
        catch { $trustStatus = 'TRUST_STORE_INVALID' }
    }

    $cacheStatus = 'MISSING'
    if ($knownSha) {
        $cacheFile = Join-Path $TestDataRoot "_verified/sha256/$knownSha/artifact.bak"
        $cacheMetadata = Join-Path $TestDataRoot "_verified/sha256/$knownSha/metadata.json"
        if ((Test-Path -LiteralPath $cacheFile -PathType Leaf) -and (Test-Path -LiteralPath $cacheMetadata -PathType Leaf)) {
            $cacheStatus = if ((Get-FileHash -LiteralPath $cacheFile -Algorithm SHA256).Hash.ToLowerInvariant() -eq $knownSha) { 'READY' } else { 'DRIFT' }
        }
    }

    $category = ConvertTo-LabArtifactLibrarySegment -Value ([string]$Sample.Category) -Fallback 'Unkategorisiert'
    $sampleId = ConvertTo-LabArtifactLibrarySegment -Value ([string]$Sample.SampleId) -Fallback 'Direkte-Downloads'
    $variant = ConvertTo-LabArtifactLibrarySegment -Value ([string]$Sample.Variant) -Fallback 'Standard'
    $libraryDirectory = Join-Path $TestDataRoot "Sammlungen/$category/$sampleId/$variant"
    $libraryStatus = 'MISSING'
    $metadataPath = Join-Path $libraryDirectory 'artifact.json'
    if ($knownSha -and (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
            $file = Join-Path $libraryDirectory ([string]$metadata.file)
            if ([string]$metadata.sha256 -eq $knownSha -and [string]$metadata.source -eq $canonicalSource -and
                (Test-Path -LiteralPath $file -PathType Leaf)) {
                $libraryStatus = if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -eq $knownSha) { 'READY' } else { 'DRIFT' }
            }
            else { $libraryStatus = 'DRIFT' }
        }
        catch { $libraryStatus = 'DRIFT' }
    }

    return [PSCustomObject]@{
        Status = if ($cacheStatus -eq 'READY' -and $libraryStatus -eq 'READY') { 'READY' } elseif ($cacheStatus -eq 'DRIFT' -or $libraryStatus -eq 'DRIFT') { 'DRIFT' } else { 'MISSING' }
        TrustStatus = $trustStatus
        CacheStatus = $cacheStatus
        LibraryStatus = $libraryStatus
        KnownSha256 = $knownSha
        LibraryDirectory = $libraryDirectory
    }
}

function Get-LabSampleResourceImportCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Sample, [string]$SourceMediaRoot)

    if ([string]::IsNullOrWhiteSpace($SourceMediaRoot)) { return $null }
    $category = ConvertTo-LabArtifactLibrarySegment -Value ([string]$Sample.Category) -Fallback 'Unkategorisiert'
    $sampleId = ConvertTo-LabArtifactLibrarySegment -Value ([string]$Sample.SampleId) -Fallback 'Direkte-Downloads'
    $variant = ConvertTo-LabArtifactLibrarySegment -Value ([string]$Sample.Variant) -Fallback 'Standard'
    $directory = Join-Path $SourceMediaRoot "Testdaten/Sammlungen/$category/$sampleId/$variant"
    $metadataPath = Join-Path $directory 'artifact.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return $null }
    try {
        $safeMetadata = Test-LabPathWithinRoot -Root $SourceMediaRoot -Path $metadataPath
        if (-not $safeMetadata.Valid) { throw "RESOURCE_SET_SOURCE_SAMPLE_PATH_UNSAFE: $($safeMetadata.Reason)" }
        $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
        $fileName = [string]$metadata.file
        if ([IO.Path]::GetFileName($fileName) -ne $fileName -or [string]::IsNullOrWhiteSpace($fileName)) {
            throw 'RESOURCE_SET_SOURCE_SAMPLE_FILENAME_INVALID'
        }
        $path = Join-Path $directory $fileName
        $metadataMatches = [string]$metadata.sampleId -eq [string]$Sample.SampleId -and
            [string]$metadata.sampleVariant -eq [string]$Sample.Variant -and
            [string]$metadata.source -eq (Get-LabCanonicalArtifactSource -Source ([string]$Sample.Source)) -and
            [string]$metadata.artifactType -eq [string]$Sample.ArtifactType -and
            [string]$metadata.sha256 -match '^[a-fA-F0-9]{64}$' -and
            (Test-Path -LiteralPath $path -PathType Leaf) -and
            -not ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
        if (-not $metadataMatches) { throw 'RESOURCE_SET_SOURCE_SAMPLE_METADATA_MISMATCH' }
        $safeSource = Test-LabPathWithinRoot -Root $SourceMediaRoot -Path $path
        if (-not $safeSource.Valid) { throw "RESOURCE_SET_SOURCE_SAMPLE_PATH_UNSAFE: $($safeSource.Reason)" }
        if ($Sample.ExpectedSha256 -and [string]$metadata.sha256 -ne [string]$Sample.ExpectedSha256) {
            throw 'RESOURCE_SET_SOURCE_SAMPLE_CATALOG_HASH_MISMATCH'
        }
        return [PSCustomObject]@{ Status='AVAILABLE'; Path=$path; Sha256=([string]$metadata.sha256).ToLowerInvariant(); MetadataPath=$metadataPath }
    }
    catch {
        return [PSCustomObject]@{ Status='INVALID'; Path=$null; Sha256=$null; Reason=$_.Exception.Message; MetadataPath=$metadataPath }
    }
}

function Get-LabSoftwareResourceReadOnlyStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SoftwarePlan,
        [Parameter(Mandatory)][string]$MediaRoot,
        [string]$SourceMediaRoot
    )

    $variant = Get-LabExternalRuntimeWindowsCatalogVariant -SoftwarePlan $SoftwarePlan
    $artifacts = @($variant.artifacts | Where-Object { [string]$_.sourceType -ne 'generated' } | ForEach-Object {
        $fileName = Get-LabExternalRuntimeWindowsArtifactFileName -Artifact $_
        $sha = ([string]$_.sha256).ToLowerInvariant()
        $target = Join-Path $MediaRoot "ExternalLanguages/Windows/$sha/$fileName"
        $targetStatus = if (Test-Path -LiteralPath $target -PathType Leaf) {
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -eq $sha) { 'READY' } else { 'DRIFT' }
        } else { 'MISSING' }
        $source = if ($SourceMediaRoot) { Join-Path $SourceMediaRoot "ExternalLanguages/Windows/$sha/$fileName" } else { $null }
        $sourceStatus = if ($source -and (Test-Path -LiteralPath $source -PathType Leaf)) { 'AVAILABLE' } else { 'MISSING' }
        [PSCustomObject]@{ Id=[string]$_.id; Sha256=$sha; TargetPath=$target; TargetStatus=$targetStatus; SourcePath=$source; SourceStatus=$sourceStatus }
    })
    return [PSCustomObject]@{
        Status = if (@($artifacts | Where-Object TargetStatus -eq 'DRIFT').Count -gt 0) { 'DRIFT' }
            elseif (@($artifacts | Where-Object TargetStatus -ne 'READY').Count -eq 0) { 'READY' }
            elseif (@($artifacts | Where-Object TargetStatus -eq 'READY').Count -gt 0) { 'PARTIAL' }
            else { 'MISSING' }
        ArtifactCount = $artifacts.Count
        ReadyCount = @($artifacts | Where-Object TargetStatus -eq 'READY').Count
        ImportAvailableCount = @($artifacts | Where-Object { $_.TargetStatus -ne 'READY' -and $_.SourceStatus -eq 'AVAILABLE' }).Count
        Artifacts = $artifacts
    }
}

function Import-LabExternalRuntimeWindowsMedia {
    <# Importiert nur kataloggebundene Windows-External-Runtime-Dateien. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SoftwarePlans,
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$SourceMediaRoot
    )

    $imported = [Collections.Generic.List[object]]::new()
    Invoke-LabArtifactStoreLock -StateRoot $MediaRoot -ScriptBlock {
        foreach ($plan in @($SoftwarePlans)) {
            if ([string]$plan.Status -ne 'RESOLVED' -or [string]$plan.Provider -ne 'hyperv' -or
                [string]$plan.OperatingSystem -ne 'windows') {
                throw "EXTERNAL_RUNTIME_WINDOWS_IMPORT_PLAN_INVALID: $($plan.SoftwareId)"
            }
            $variant = Get-LabExternalRuntimeWindowsCatalogVariant -SoftwarePlan $plan
            foreach ($artifact in @($variant.artifacts | Where-Object { [string]$_.sourceType -ne 'generated' })) {
                $fileName = Get-LabExternalRuntimeWindowsArtifactFileName -Artifact $artifact
                $sha = ([string]$artifact.sha256).ToLowerInvariant()
                $sourcePath = Join-Path $SourceMediaRoot "ExternalLanguages/Windows/$sha/$fileName"
                $targetPath = Join-Path $MediaRoot "ExternalLanguages/Windows/$sha/$fileName"
                if (Test-Path -LiteralPath $targetPath -PathType Leaf) { continue }
                if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { continue }
                $safeSource = Test-LabPathWithinRoot -Root $SourceMediaRoot -Path $sourcePath
                $safeTarget = Test-LabPathWithinRoot -Root $MediaRoot -Path $targetPath
                if (-not $safeSource.Valid -or -not $safeTarget.Valid) {
                    throw "EXTERNAL_RUNTIME_WINDOWS_IMPORT_PATH_UNSAFE: $($artifact.id)"
                }
                $sourceItem = Get-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
                if ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "EXTERNAL_RUNTIME_WINDOWS_IMPORT_REPARSE_POINT: $($artifact.id)"
                }
                if ((Get-FileHash -LiteralPath $sourceItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) {
                    throw "EXTERNAL_RUNTIME_WINDOWS_IMPORT_HASH_MISMATCH: $($artifact.id)"
                }
                $directory = Split-Path -Parent $targetPath
                New-Item -Path $directory -ItemType Directory -Force | Out-Null
                $temporaryPath = Join-Path $directory ('.partial-' + [guid]::NewGuid().ToString('N'))
                try {
                    Copy-Item -LiteralPath $sourceItem.FullName -Destination $temporaryPath -ErrorAction Stop
                    if ((Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) {
                        throw "EXTERNAL_RUNTIME_WINDOWS_IMPORT_COPY_HASH_MISMATCH: $($artifact.id)"
                    }
                    [IO.File]::Move($temporaryPath, $targetPath, $false)
                    $imported.Add([PSCustomObject]@{ Id=[string]$artifact.id; Path=$targetPath; Sha256=$sha })
                }
                finally {
                    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force }
                }
            }
        }
    } | Out-Null
    return @($imported)
}

function Import-LabArtifact {
    <# Importiert eine explizit gebundene lokale Sample-Datei in Cache und Bibliothek. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Source,
        [ValidateSet('backup', 'archive-backup', 'sql-script', 'script-bundle', 'bacpac')][string]$ArtifactType,
        [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
        [string]$SampleId,
        [string]$SampleVariant,
        [string]$Category,
        [string]$HandlerContractVersion = '1',
        [int]$Compatibility,
        [array]$ExpectedOutputs = @(),
        [switch]$TrustUnknownArtifact,
        [string]$StateRoot,
        [string]$TestDataRoot
    )

    $item = Get-Item -LiteralPath $SourcePath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'ARTIFACT_IMPORT_SOURCE_INVALID'
    }
    $canonicalSource = Get-LabCanonicalArtifactSource -Source $Source
    $observed = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = if ($ExpectedSha256) { $ExpectedSha256.ToLowerInvariant() } else { $null }
    $integrityOrigin = if ($expected) { 'catalog-verified' } else { $null }
    if ($expected -and $observed -ne $expected) {
        throw "ARTIFACT_IMPORT_HASH_MISMATCH: Erwartet $expected, beobachtet $observed."
    }
    if (-not $expected) {
        $trust = Get-LabArtifactTrustRecord -Source $canonicalSource -SampleId $SampleId -SampleVariant $SampleVariant -StateRoot $StateRoot
        if ($trust) {
            $expected = ([string]$trust.sha256).ToLowerInvariant()
            $integrityOrigin = [string]$trust.integrityOrigin
            if ($observed -ne $expected) { throw 'ARTIFACT_IMPORT_TRUST_HASH_MISMATCH' }
        }
        elseif (-not $TrustUnknownArtifact) {
            return [PSCustomObject]@{ Status='TRUST_REQUIRED'; Message='Der lokale Import besitzt keine katalogisierte oder bereits vertraute SHA-256.'; Source=$canonicalSource }
        }
        else {
            $trust = Register-LabArtifactTrustRecord -Source $canonicalSource -Sha256 $observed -SampleId $SampleId `
                -SampleVariant $SampleVariant -ArtifactType $ArtifactType -HandlerContractVersion $HandlerContractVersion -StateRoot $StateRoot
            $expected = $observed
            $integrityOrigin = [string]$trust.integrityOrigin
        }
    }

    $paths = Initialize-LabArtifactStore -StateRoot $StateRoot -TestDataRoot $TestDataRoot
    $cacheDirectory = Join-Path $paths.CacheRoot $expected
    $cachePath = Join-Path $cacheDirectory 'artifact.bak'
    Invoke-LabArtifactStoreLock -StateRoot $StateRoot -ScriptBlock {
        $existing = Get-LabArtifactCacheEntry -Sha256 $expected -StateRoot $StateRoot -TestDataRoot $TestDataRoot
        if (-not $existing) {
            if (Test-Path -LiteralPath $cacheDirectory) { throw 'ARTIFACT_IMPORT_CACHE_TARGET_INCOMPLETE' }
            $temporaryDirectory = Join-Path $paths.CacheRoot ('.partial-' + [guid]::NewGuid().ToString('N'))
            try {
                New-Item -Path $temporaryDirectory -ItemType Directory -ErrorAction Stop | Out-Null
                $temporaryPath = Join-Path $temporaryDirectory 'artifact.bak'
                Copy-Item -LiteralPath $item.FullName -Destination $temporaryPath -ErrorAction Stop
                if ((Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
                    throw 'ARTIFACT_IMPORT_COPY_HASH_MISMATCH'
                }
                Write-LabArtifactJsonAtomic -Path (Join-Path $temporaryDirectory 'metadata.json') -InputObject ([PSCustomObject]@{
                    formatVersion='1'; source=$canonicalSource; sha256=$expected; integrityOrigin=$integrityOrigin
                    artifactType=$ArtifactType; sampleId=$SampleId; sampleVariant=$SampleVariant
                    handlerContractVersion=$HandlerContractVersion; acquiredAt=Get-LabTimestamp
                })
                [IO.Directory]::Move($temporaryDirectory, $cacheDirectory)
            }
            finally {
                if (Test-Path -LiteralPath $temporaryDirectory) { Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force }
            }
        }
    } | Out-Null
    $libraryPath = Publish-LabArtifactLibraryEntry -Paths $paths -CachePath $cachePath -Sha256 $expected `
        -Source $canonicalSource -Category $Category -SampleId $SampleId -SampleVariant $SampleVariant `
        -ArtifactType $ArtifactType -IntegrityOrigin $integrityOrigin
    return [PSCustomObject]@{
        Status='ARTIFACT_READY'; Message='Lokales Artifact nach SHA-256-Pruefung importiert.'; Source=$canonicalSource
        Path=$libraryPath; Sha256=$expected; IntegrityOrigin=$integrityOrigin; ArtifactType=$ArtifactType
        SampleId=$SampleId; SampleVariant=$SampleVariant; HandlerContractVersion=$HandlerContractVersion
        Compatibility=$Compatibility; ExpectedOutputs=@($ExpectedOutputs); CacheStatus='IMPORTED'
    }
}

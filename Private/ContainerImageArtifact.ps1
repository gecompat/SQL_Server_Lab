<#
.SYNOPSIS
    Inhaltsadressierter Build- und Registryvertrag fuer External-Runtime-OCI-Images.
.DESCRIPTION
    Erzeugt ausschließlich aus dem versionierten Repository-Rezept und bereits
    aufgeloesten Softwareplaenen einen deterministischen Image-Key. Freie
    Commands, Manifest-URLs oder ungepruefte Buildargumente werden nicht
    akzeptiert. Docker und Podman erhalten getrennte lokale Buildreceipts.
#>

function Get-LabExternalRuntimeContainerRecipeRoot {
    [CmdletBinding()]
    param()

    return Join-Path $script:ModuleRoot 'Images/ExternalLanguages/Linux'
}

function Get-LabLowerFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-LabExternalRuntimeContainerRecipe {
    [CmdletBinding()]
    param()

    $recipeRoot = Get-LabExternalRuntimeContainerRecipeRoot
    $recipePath = Join-Path $recipeRoot 'recipe.json'
    if (-not (Test-Path -LiteralPath $recipePath -PathType Leaf)) {
        throw "EXTERNAL_RUNTIME_RECIPE_NOT_FOUND: $recipePath"
    }

    $recipe = Get-Content -LiteralPath $recipePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    if (-not $recipe.contract -or
        [string]$recipe.contract.name -ne 'SqlServerLab.ExternalRuntimeContainerRecipe' -or
        [string]$recipe.contract.version -ne '1.0' -or
        [string]$recipe.recipeVersion -notmatch '^[1-9][0-9]*$') {
        throw 'EXTERNAL_RUNTIME_RECIPE_CONTRACT_INVALID'
    }
    if ([string]$recipe.architecture -ne 'x86_64' -or [string]$recipe.operatingSystem -ne 'ubuntu-22.04') {
        throw 'EXTERNAL_RUNTIME_RECIPE_PLATFORM_INVALID'
    }
    if ([string]$recipe.baseImage.reference -notmatch '^mcr\.microsoft\.com/mssql/server@sha256:([a-f0-9]{64})$' -or
        [string]$recipe.baseImage.sha256 -ne $Matches[1]) {
        throw 'EXTERNAL_RUNTIME_BASE_IMAGE_NOT_DIGEST_BOUND'
    }

    $artifacts = @($recipe.extensibility) + @($recipe.runtimeLibraries | ForEach-Object { $_.artifact }) + @(
        $recipe.runtimes.PSObject.Properties | ForEach-Object {
            if ($_.Value.runtimeImage) { $_.Value.runtimeImage }
            @($_.Value.artifacts)
        }
    )
    foreach ($artifact in $artifacts) {
        $uri = $null
        if (-not [System.Uri]::TryCreate([string]$artifact.source, [System.UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -ne 'https' -or $uri.UserInfo -or
            [string]$artifact.sha256 -notmatch '^[a-f0-9]{64}$' -or
            [string]::IsNullOrWhiteSpace([string]$artifact.version) -or
            [string]::IsNullOrWhiteSpace([string]$artifact.integrityOrigin) -or
            [string]::IsNullOrWhiteSpace([string]$artifact.license)) {
            throw "EXTERNAL_RUNTIME_RECIPE_ARTIFACT_INVALID: $($artifact.id)"
        }
    }
    foreach ($library in @($recipe.runtimeLibraries)) {
        if ([string]$library.id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]+$' -or
            @($library.languages).Count -eq 0 -or
            @($library.languages | Where-Object { [string]$_ -notin @('Python','R','Java') }).Count -gt 0 -or
            -not $library.artifact) {
            throw "EXTERNAL_RUNTIME_RECIPE_LIBRARY_INVALID: $($library.id)"
        }
    }
    foreach ($runtimeProperty in $recipe.runtimes.PSObject.Properties) {
        foreach ($artifact in @($runtimeProperty.Value.generatedArtifacts | Where-Object { $_ })) {
            if ([string]$artifact.id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]+$' -or
                [string]$artifact.source -notmatch '^repository://[A-Za-z0-9][A-Za-z0-9._/-]+$' -or
                [string]$artifact.sourcePath -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]+$' -or
                [string]$artifact.sourcePath -match '(^|/)\.\.(/|$)' -or
                [string]$artifact.version -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$' -or
                [string]$artifact.sha256 -notmatch '^[a-f0-9]{64}$' -or
                [string]::IsNullOrWhiteSpace([string]$artifact.integrityOrigin) -or
                [string]::IsNullOrWhiteSpace([string]$artifact.license)) {
                throw "EXTERNAL_RUNTIME_RECIPE_GENERATED_ARTIFACT_INVALID: $($artifact.id)"
            }
        }
    }

    $allContextFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($relativePath in @($recipe.contextFiles) + @(
        $recipe.runtimes.PSObject.Properties | ForEach-Object { @($_.Value.contextFiles) }
    )) {
        $relative = [string]$relativePath
        if ($relative -notmatch '^(\.dockerignore|[A-Za-z0-9][A-Za-z0-9._/-]+)$' -or $relative.Contains('..') -or
            -not $allContextFiles.Add($relative)) {
            if ($allContextFiles.Contains($relative)) { continue }
            throw "EXTERNAL_RUNTIME_RECIPE_CONTEXT_PATH_INVALID: $relative"
        }
        $fullPath = [IO.Path]::GetFullPath((Join-Path $recipeRoot $relative))
        if (-not $fullPath.StartsWith(([IO.Path]::GetFullPath($recipeRoot) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "EXTERNAL_RUNTIME_RECIPE_CONTEXT_FILE_INVALID: $relative"
        }
    }
    foreach ($runtimeProperty in $recipe.runtimes.PSObject.Properties) {
        foreach ($artifact in @($runtimeProperty.Value.generatedArtifacts | Where-Object { $_ })) {
            $sourcePath = [string]$artifact.sourcePath
            if (-not $allContextFiles.Contains($sourcePath) -or
                -not ([string]$artifact.source).EndsWith("/$sourcePath", [StringComparison]::Ordinal)) {
                throw "EXTERNAL_RUNTIME_RECIPE_GENERATED_ARTIFACT_SOURCE_INVALID: $($artifact.id)"
            }
        }
    }

    foreach ($runtimeProperty in $recipe.runtimes.PSObject.Properties) {
        $runtime = $runtimeProperty.Value
        if ([int]$runtime.buildOrder -lt 1 -or [string]$runtime.buildToken -notmatch '^[a-z][a-z0-9-]*$') {
            throw "EXTERNAL_RUNTIME_RECIPE_BUILD_STAGE_INVALID: $($runtimeProperty.Name)"
        }
        if ($runtime.runtimeImage -and
            ([string]$runtime.runtimeImage.reference -notmatch '^docker\.io/[a-z0-9./_-]+@sha256:([a-f0-9]{64})$' -or
             [string]$runtime.runtimeImage.sha256 -ne $Matches[1])) {
            throw "EXTERNAL_RUNTIME_RECIPE_RUNTIME_IMAGE_INVALID: $($runtimeProperty.Name)"
        }
        $lockPath = Join-Path $recipeRoot ([string]$runtime.lockFile)
        if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
            throw "EXTERNAL_RUNTIME_RECIPE_LOCK_NOT_FOUND: $($runtime.lockFile)"
        }
        $lockRecords = @(Get-Content -LiteralPath $lockPath -Encoding utf8 | Where-Object {
            $_ -and -not $_.StartsWith('#')
        } | ForEach-Object {
            $parts = $_.Split('|')
            if ($parts.Count -ne 5 -or [string]$parts[0] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
                [string]$parts[2] -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$' -or
                [string]$parts[3] -notmatch '^[a-f0-9]{64}$') {
                throw "EXTERNAL_RUNTIME_PACKAGE_LOCK_INVALID: $($runtimeProperty.Name)"
            }
            $sourceUri = [Uri]$parts[4]
            if ([IO.Path]::GetFileName($sourceUri.AbsolutePath) -cne [string]$parts[2]) {
                throw "EXTERNAL_RUNTIME_PACKAGE_LOCK_FILENAME_MISMATCH: $($runtimeProperty.Name)"
            }
            [PSCustomObject]@{ id=$parts[0]; version=$parts[1]; filename=$parts[2]; sha256=$parts[3]; source=$parts[4] }
        })
        $runtimeArtifacts = @($runtime.artifacts)
        if ($lockRecords.Count -ne $runtimeArtifacts.Count) {
            throw "EXTERNAL_RUNTIME_PACKAGE_LOCK_RECIPE_MISMATCH: $($runtimeProperty.Name)"
        }
        foreach ($record in $lockRecords) {
            $match = @($runtimeArtifacts | Where-Object {
                [string]$_.id -eq $record.id -and [string]$_.version -eq $record.version -and
                [string]$_.sha256 -eq $record.sha256 -and
                [string]$_.source -eq $record.source
            })
            if ($match.Count -ne 1) {
                throw "EXTERNAL_RUNTIME_PACKAGE_LOCK_RECIPE_MISMATCH: $($runtimeProperty.Name) / $($record.id)"
            }
        }
    }

    $recipe | Add-Member -NotePropertyName RecipeRoot -NotePropertyValue $recipeRoot -Force
    $recipe | Add-Member -NotePropertyName RecipePath -NotePropertyValue $recipePath -Force
    return $recipe
}

function Get-LabExternalRuntimeCatalogVariant {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VariantId)

    $matches = @(Get-LabSoftwareCatalog | ForEach-Object { $_.software } | ForEach-Object { @($_.variants) } |
        Where-Object { [string]$_.id -eq $VariantId })
    if ($matches.Count -ne 1) { throw "EXTERNAL_RUNTIME_VARIANT_NOT_UNIQUE: $VariantId" }
    return $matches[0]
}

function New-LabExternalRuntimeContainerImagePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][string]$SqlVersion,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SoftwarePlans,
        [switch]$AllowPreview
    )

    if ($SqlVersion -ne '2022') { throw "EXTERNAL_RUNTIME_CONTAINER_SQL_VERSION_UNSUPPORTED: $SqlVersion" }
    if (@($SoftwarePlans).Count -eq 0) { throw 'EXTERNAL_RUNTIME_CONTAINER_PLAN_EMPTY' }

    $recipe = Get-LabExternalRuntimeContainerRecipe
    $variantIds = [Collections.Generic.List[string]]::new()
    $languages = [Collections.Generic.List[string]]::new()
    $softwarePlanKeys = [Collections.Generic.List[string]]::new()
    $catalogArtifacts = [Collections.Generic.List[object]]::new()
    foreach ($softwarePlan in @($SoftwarePlans)) {
        $isResolved = [string]$softwarePlan.Status -eq 'RESOLVED'
        $isPreviewCharacterization = $AllowPreview -and
            [string]$softwarePlan.Status -eq 'DECLARED_UNSUPPORTED' -and
            [string]$softwarePlan.ReasonCode -eq 'VARIANT_PREVIEW'
        if (-not $isResolved -and -not $isPreviewCharacterization) {
            throw "EXTERNAL_RUNTIME_CONTAINER_SOFTWARE_PLAN_REJECTED: $($softwarePlan.SoftwareId) / $($softwarePlan.Status) / $($softwarePlan.ReasonCode)"
        }
        if ([string]$softwarePlan.Provider -ne $Provider -or [string]$softwarePlan.SqlVersion -ne $SqlVersion -or
            [string]$softwarePlan.OperatingSystem -ne 'linux' -or [string]$softwarePlan.InstallationMethod -ne 'derived-image') {
            throw "EXTERNAL_RUNTIME_CONTAINER_SOFTWARE_PLAN_SCOPE_MISMATCH: $($softwarePlan.SoftwareId)"
        }

        $variant = Get-LabExternalRuntimeCatalogVariant -VariantId ([string]$softwarePlan.VariantId)
        $language = [string]$variant.language
        $runtimeProperty = $recipe.runtimes.PSObject.Properties[$language]
        if (-not $runtimeProperty -or [string]$runtimeProperty.Value.runtimeVersion -ne [string]$variant.runtimeVersion) {
            throw "EXTERNAL_RUNTIME_CONTAINER_RECIPE_RUNTIME_MISSING: $language $($variant.runtimeVersion)"
        }
        $variantIds.Add([string]$variant.id)
        $languages.Add($language)
        if ([string]$softwarePlan.PlanKey -match '^[a-f0-9]{64}$') {
            $softwarePlanKeys.Add([string]$softwarePlan.PlanKey)
        }
        foreach ($artifact in @($variant.artifacts)) { $catalogArtifacts.Add($artifact) }
    }

    $distinctLanguages = @($languages | Sort-Object -Unique)
    if ($distinctLanguages.Count -ne $languages.Count) { throw 'EXTERNAL_RUNTIME_CONTAINER_DUPLICATE_LANGUAGE' }
    $requiredArtifacts = @($recipe.baseImage, $recipe.extensibility) + @($recipe.runtimeLibraries | Where-Object {
        @($_.languages | Where-Object { [string]$_ -in $distinctLanguages }).Count -gt 0
    } | ForEach-Object { $_.artifact }) + @($distinctLanguages | ForEach-Object {
        $runtime = $recipe.runtimes.PSObject.Properties[$_].Value
        if ($runtime.runtimeImage) { $runtime.runtimeImage }
        @($runtime.artifacts)
        @($runtime.generatedArtifacts | Where-Object { $_ })
    })
    foreach ($required in $requiredArtifacts) {
        $catalogMatch = @($catalogArtifacts | Where-Object {
            [string]$_.id -eq [string]$required.id -and
            [string]$_.version -eq [string]$required.version -and
            [string]$_.sha256 -eq [string]$required.sha256
        })
        if ($catalogMatch.Count -lt 1) {
            throw "EXTERNAL_RUNTIME_CONTAINER_CATALOG_RECIPE_MISMATCH: $($required.id)"
        }
    }

    $contextFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($relative in @($recipe.contextFiles)) { $null = $contextFiles.Add([string]$relative) }
    foreach ($language in $distinctLanguages) {
        foreach ($relative in @($recipe.runtimes.PSObject.Properties[$language].Value.contextFiles)) {
            $null = $contextFiles.Add([string]$relative)
        }
    }
    $contextEvidence = @($contextFiles | Sort-Object | ForEach-Object {
        [ordered]@{ path = $_; sha256 = Get-LabLowerFileSha256 -Path (Join-Path $recipe.RecipeRoot $_) }
    })
    $runtimeBuilds = @($distinctLanguages | ForEach-Object {
        $runtime = $recipe.runtimes.PSObject.Properties[$_].Value
        [PSCustomObject]@{ Language=$_; BuildOrder=[int]$runtime.buildOrder; BuildToken=[string]$runtime.buildToken }
    } | Sort-Object BuildOrder, Language)
    if (@($runtimeBuilds.BuildOrder | Sort-Object -Unique).Count -ne $runtimeBuilds.Count) {
        throw 'EXTERNAL_RUNTIME_CONTAINER_BUILD_ORDER_AMBIGUOUS'
    }
    $buildTokens = @($runtimeBuilds | ForEach-Object { $_.BuildToken })
    $buildStage = "runtime-$($buildTokens -join '-')"
    $keyInput = [ordered]@{
        contract = 'SqlServerLab.ExternalRuntimeContainerImageKey/1.0'
        recipeVersion = [string]$recipe.recipeVersion
        sqlVersion = $SqlVersion
        baseImage = [string]$recipe.baseImage.reference
        variants = @($variantIds | Sort-Object)
        languages = $distinctLanguages
        buildTokens = $buildTokens
        context = $contextEvidence
    }
    $keyJson = $keyInput | ConvertTo-Json -Depth 30 -Compress
    $imageKey = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($keyJson))
    ).ToLowerInvariant()
    $image = "sql-server-lab/external-runtime:$($imageKey.Substring(0, 24))"

    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name='SqlServerLab.ExternalRuntimeContainerImagePlan'; Version='1.0' }
        Provider = $Provider
        SqlVersion = $SqlVersion
        ImageKey = $imageKey
        Image = $image
        BaseImage = [string]$recipe.baseImage.reference
        BaseImageDigest = [string]$recipe.baseImage.sha256
        RecipeVersion = [string]$recipe.recipeVersion
        VariantIds = @($variantIds | Sort-Object)
        SoftwarePlanKeys = @($softwarePlanKeys | Sort-Object -Unique)
        Languages = $distinctLanguages
        BuildTokens = $buildTokens
        BuildStage = $buildStage
        ContextEvidence = $contextEvidence
        RecipeRoot = [string]$recipe.RecipeRoot
        Containerfile = Join-Path $recipe.RecipeRoot 'Containerfile'
        LaunchMode = [string]$recipe.launchContract.mode
        RequiredCgroupVersion = [string]$recipe.launchContract.requiredCgroupVersion
        RequiredLinuxCapabilities = @($recipe.launchContract.requiredLinuxCapabilities | ForEach-Object { [string]$_ })
        RequiredSecurityOptions = @($recipe.launchContract.requiredSecurityOptions | ForEach-Object { [string]$_ })
        NamespaceIsolation = [bool]$recipe.launchContract.namespaceIsolation
        OutboundAccess = [bool]$recipe.launchContract.outboundAccess
        EvidenceStatus = if ($AllowPreview) { 'PREVIEW_CHARACTERIZATION' } else { 'SUPPORTED' }
    }
}

function Test-LabExternalRuntimeContainerHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)]$ImagePlan
    )

    if ([string]$ImagePlan.LaunchMode -ne 'sql2022-namespace-v1' -or
        @($ImagePlan.RequiredLinuxCapabilities) -join ',' -ne 'CHOWN,DAC_OVERRIDE,KILL,SETGID,SETUID,SYS_ADMIN,MKNOD,SETPCAP,NET_ADMIN,NET_RAW,SYS_PTRACE' -or
        @($ImagePlan.RequiredSecurityOptions) -join ',' -ne 'apparmor=unconfined,seccomp=unconfined' -or
        $ImagePlan.NamespaceIsolation -ne $true -or $ImagePlan.OutboundAccess -ne $false) {
        throw 'EXTERNAL_RUNTIME_CONTAINER_LAUNCH_CONTRACT_INVALID'
    }
    if (-not (Get-Command $Provider -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{ Status='RUNTIME_UNAVAILABLE'; Provider=$Provider; CgroupVersion=$null; Rootless=$null; Reason="Provider '$Provider' ist nicht installiert." }
    }

    try {
        if ($Provider -eq 'docker') {
            $raw = & docker info --format '{{json .}}' 2>&1
        }
        else {
            $raw = & podman info --format json 2>&1
        }
        if ($LASTEXITCODE -ne 0) { throw (@($raw) -join ' ') }
        $info = (@($raw) -join "`n") | ConvertFrom-Json -Depth 50
    }
    catch {
        return [PSCustomObject]@{ Status='RUNTIME_UNAVAILABLE'; Provider=$Provider; CgroupVersion=$null; Rootless=$null; Reason=$_.Exception.Message }
    }

    if ($Provider -eq 'docker') {
        $operatingSystem = [string]$info.OSType
        $cgroupVersion = [string]$info.CgroupVersion
        $rootless = @($info.SecurityOptions | Where-Object { [string]$_ -match '(?i)rootless' }).Count -gt 0
    }
    else {
        $operatingSystem = [string]$info.host.os
        $cgroupVersion = [string]$info.host.cgroupVersion
        if (-not $cgroupVersion) { $cgroupVersion = [string]$info.host.cgroupsVersion }
        $rootless = [bool]$info.host.security.rootless
    }
    $normalizedCgroup = ($cgroupVersion -replace '[^0-9]', '')
    if ($operatingSystem -ne 'linux') {
        return [PSCustomObject]@{ Status='DECLARED_UNSUPPORTED'; Provider=$Provider; CgroupVersion=$normalizedCgroup; Rootless=$rootless; Reason='External Runtimes benötigen einen Linux-Containerhost.' }
    }
    if ($normalizedCgroup -ne [string]$ImagePlan.RequiredCgroupVersion) {
        return [PSCustomObject]@{
            Status='DECLARED_UNSUPPORTED'; Provider=$Provider; CgroupVersion=$normalizedCgroup; Rootless=$rootless
            Reason="SQL Server 2022 launchpadd benötigt für den isolierten Namespace-Modus cgroup v$($ImagePlan.RequiredCgroupVersion); erkannt wurde cgroup v$normalizedCgroup."
        }
    }
    if ($rootless) {
        return [PSCustomObject]@{
            Status='DECLARED_UNSUPPORTED'; Provider=$Provider; CgroupVersion=$normalizedCgroup; Rootless=$true
            Reason='Der SQL-Server-2022-Namespace-Modus benötigt einen rootful Provider für den schreibbaren cgroup-v1-Bind.'
        }
    }
    return [PSCustomObject]@{
        Status='READY'; Provider=$Provider; CgroupVersion=$normalizedCgroup; Rootless=$rootless
        Reason=$null; RequiredLinuxCapabilities=@($ImagePlan.RequiredLinuxCapabilities)
        RequiredSecurityOptions=@($ImagePlan.RequiredSecurityOptions)
    }
}

function Get-LabExternalRuntimeContainerImageStorePaths {
    [CmdletBinding()]
    param([string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $null = Initialize-LabStateRoot -StateRoot $StateRoot
    return [PSCustomObject]@{
        StateRoot = $StateRoot
        RegistryRoot = Join-Path $StateRoot 'artifacts/container/external-runtime-images'
    }
}

function Get-LabExternalRuntimeContainerImageReceiptPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ImageKey,
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [string]$StateRoot
    )

    $paths = Get-LabExternalRuntimeContainerImageStorePaths -StateRoot $StateRoot
    return Join-Path (Join-Path (Join-Path $paths.RegistryRoot $ImageKey) $Provider) 'receipt.json'
}

function Get-LabExternalRuntimeContainerImageReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ImageKey,
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [string]$StateRoot
    )

    $path = Get-LabExternalRuntimeContainerImageReceiptPath -ImageKey $ImageKey -Provider $Provider -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $receipt = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 50
    if (-not $receipt.contract -or [string]$receipt.contract.name -ne 'SqlServerLab.ExternalRuntimeContainerImageReceipt' -or
        [string]$receipt.contract.version -ne '1.0' -or [string]$receipt.imageKey -ne $ImageKey -or
        [string]$receipt.provider -ne $Provider) {
        throw "EXTERNAL_RUNTIME_CONTAINER_IMAGE_RECEIPT_INVALID: $ImageKey / $Provider"
    }
    return $receipt
}

function Get-LabExternalRuntimeLocalImageEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9./_-]+:[a-z0-9][a-z0-9._-]+$')][string]$Image
    )

    $raw = & $Provider image inspect $Image 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    $inspect = @((@($raw) -join "`n") | ConvertFrom-Json -Depth 50)[0]
    return [PSCustomObject]@{
        ImageId = [string]$inspect.Id
        User = [string]$inspect.Config.User
        ImageKey = [string]$inspect.Config.Labels.'sql-server-lab.external-runtime.image-key'
        Languages = [string]$inspect.Config.Labels.'sql-server-lab.external-runtime.languages'
        LaunchMode = [string]$inspect.Config.Labels.'sql-server-lab.external-runtime.launch-mode'
        RequiredCapabilities = [string]$inspect.Config.Labels.'sql-server-lab.external-runtime.required-capabilities'
        RequiredSecurityOptions = [string]$inspect.Config.Labels.'sql-server-lab.external-runtime.required-security-options'
        NamespaceIsolation = [string]$inspect.Config.Labels.'sql-server-lab.external-runtime.namespace-isolation'
        OutboundAccess = [string]$inspect.Config.Labels.'sql-server-lab.external-runtime.outbound-access'
    }
}

function Test-LabExternalRuntimeJavaImagePostcondition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][string]$Image
    )

    $command = @(
        'run', '--rm', '--network', 'none', '--user', 'mssql',
        '--entrypoint', '/bin/bash', $Image, '-lc',
        'set -e; test ! -e /opt/sql-server-lab/java/jre/bin/javac; test ! -d /opt/sql-server-lab/java/jre/jmods; test -x /opt/sql-server-lab/java/jre/lib/jspawnhelper; /opt/sql-server-lab/java/jre/bin/java -version'
    )
    $output = @(& $Provider @command 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "EXTERNAL_RUNTIME_JAVA_IMAGE_POSTCONDITION_FAILED: $(@($output) -join ' ')"
    }
    $runtimeLine = @($output | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^openjdk version "11\.[0-9.]+' } | Select-Object -First 1)[0]
    if (-not $runtimeLine -or $runtimeLine -notmatch '^openjdk version "(?<version>11\.[0-9.]+)') {
        throw "EXTERNAL_RUNTIME_JAVA_IMAGE_VERSION_MISSING: $(@($output) -join ' ')"
    }
    return [PSCustomObject]@{
        Id='java-image-runtime'; Status='PASS'; RuntimeVersion=[string]$Matches.version
        CompilerPresent=$false; NetworkMode='none'; ContainerUser='mssql'
    }
}

function Invoke-LabExternalRuntimeContainerImageBuildCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ImagePlan,
        [string]$StateRoot
    )

    if (-not $ImagePlan.Contract -or [string]$ImagePlan.Contract.Name -ne 'SqlServerLab.ExternalRuntimeContainerImagePlan' -or
        [string]$ImagePlan.Contract.Version -ne '1.0' -or [string]$ImagePlan.ImageKey -notmatch '^[a-f0-9]{64}$') {
        throw 'EXTERNAL_RUNTIME_CONTAINER_IMAGE_PLAN_INVALID'
    }
    $provider = [string]$ImagePlan.Provider
    if ($provider -notin @('docker', 'podman')) { throw 'EXTERNAL_RUNTIME_CONTAINER_PROVIDER_INVALID' }

    $existingReceipt = Get-LabExternalRuntimeContainerImageReceipt -ImageKey $ImagePlan.ImageKey -Provider $provider -StateRoot $StateRoot
    if ($existingReceipt) {
        $existingImage = Get-LabExternalRuntimeLocalImageEvidence -Provider $provider -Image ([string]$existingReceipt.image)
        if ($existingImage -and [string]$existingImage.ImageId -eq [string]$existingReceipt.localImageId -and
            [string]$existingImage.ImageKey -eq [string]$ImagePlan.ImageKey) {
            return [PSCustomObject]@{
                Contract=[PSCustomObject]@{ Name='SqlServerLab.ExternalRuntimeContainerImageArtifact'; Version='1.0' }
                Provider=$provider; Image=[string]$existingReceipt.image; ImageKey=[string]$ImagePlan.ImageKey
                SoftwarePlanKeys=@($existingReceipt.softwarePlanKeys)
                LocalImageId=[string]$existingReceipt.localImageId; LaunchMode=[string]$ImagePlan.LaunchMode
                RequiredLinuxCapabilities=@($ImagePlan.RequiredLinuxCapabilities); RequiredSecurityOptions=@($ImagePlan.RequiredSecurityOptions); Reused=$true; Receipt=$existingReceipt
            }
        }
    }

    $hostStatus = Test-LabExternalRuntimeContainerHost -Provider $provider -ImagePlan $ImagePlan
    if ([string]$hostStatus.Status -ne 'READY') {
        throw "EXTERNAL_RUNTIME_CONTAINER_HOST_REJECTED: $($hostStatus.Status) - $($hostStatus.Reason)"
    }

    $temporaryTag = "sql-server-lab/external-runtime-build:$($ImagePlan.ImageKey.Substring(0, 16))-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $buildArguments = @(
        'build',
        '--file', [string]$ImagePlan.Containerfile,
        '--tag', $temporaryTag,
        '--build-arg', "BASE_IMAGE=$($ImagePlan.BaseImage)",
        '--build-arg', "R_RUNTIME_IMAGE=$([string](Get-LabExternalRuntimeContainerRecipe).runtimes.R.runtimeImage.reference)",
        '--build-arg', "EXTERNAL_RUNTIME_STAGE=$($ImagePlan.BuildStage)",
        '--build-arg', "EXTERNAL_RUNTIMES=$(@($ImagePlan.BuildTokens) -join ',')",
        '--build-arg', "CONTENT_ID=$($ImagePlan.ImageKey)",
        [string]$ImagePlan.RecipeRoot
    )
    $built = $false
    try {
        $output = & $provider @buildArguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            $tail = @($output | Select-Object -Last 30) -join ' '
            throw "EXTERNAL_RUNTIME_CONTAINER_IMAGE_BUILD_FAILED: $tail"
        }
        $built = $true
        $evidence = Get-LabExternalRuntimeLocalImageEvidence -Provider $provider -Image $temporaryTag
        if (-not $evidence -or [string]$evidence.User -ne 'root' -or
            [string]$evidence.ImageKey -ne [string]$ImagePlan.ImageKey -or
            [string]$evidence.Languages -ne (@($ImagePlan.BuildTokens) -join ',') -or
            [string]$evidence.LaunchMode -ne [string]$ImagePlan.LaunchMode -or
            [string]$evidence.RequiredCapabilities -ne (@($ImagePlan.RequiredLinuxCapabilities) -join ',') -or
            [string]$evidence.RequiredSecurityOptions -ne (@($ImagePlan.RequiredSecurityOptions) -join ',') -or
            [string]$evidence.NamespaceIsolation -ne 'true' -or [string]$evidence.OutboundAccess -ne 'false') {
            throw 'EXTERNAL_RUNTIME_CONTAINER_IMAGE_POSTCONDITION_FAILED'
        }
        $imagePostconditions = @()
        if (@($ImagePlan.Languages) -contains 'Java') {
            $imagePostconditions = @(Test-LabExternalRuntimeJavaImagePostcondition -Provider $provider -Image $temporaryTag)
        }
        & $provider tag $temporaryTag ([string]$ImagePlan.Image) 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'EXTERNAL_RUNTIME_CONTAINER_IMAGE_TAG_FAILED' }

        $receipt = [PSCustomObject]@{
            contract = [PSCustomObject]@{ name='SqlServerLab.ExternalRuntimeContainerImageReceipt'; version='1.0' }
            imageKey = [string]$ImagePlan.ImageKey
            provider = $provider
            image = [string]$ImagePlan.Image
            localImageId = [string]$evidence.ImageId
            baseImageDigest = [string]$ImagePlan.BaseImageDigest
            recipeVersion = [string]$ImagePlan.RecipeVersion
            variantIds = @($ImagePlan.VariantIds)
            softwarePlanKeys = @($ImagePlan.SoftwarePlanKeys)
            languages = @($ImagePlan.Languages)
            buildStage = [string]$ImagePlan.BuildStage
            launchMode = [string]$ImagePlan.LaunchMode
            requiredCgroupVersion = [string]$ImagePlan.RequiredCgroupVersion
            requiredLinuxCapabilities = @($ImagePlan.RequiredLinuxCapabilities)
            requiredSecurityOptions = @($ImagePlan.RequiredSecurityOptions)
            namespaceIsolation = $true
            outboundAccess = $false
            contextEvidence = @($ImagePlan.ContextEvidence)
            imagePostconditions = @($imagePostconditions)
            status = 'IMAGE_READY'
            retention = 'reusable-explicit-removal'
            builtAt = Get-LabTimestamp
        }
        $receiptPath = Get-LabExternalRuntimeContainerImageReceiptPath -ImageKey $ImagePlan.ImageKey -Provider $provider -StateRoot $StateRoot
        Write-LabArtifactJsonAtomic -Path $receiptPath -InputObject $receipt
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{ Name='SqlServerLab.ExternalRuntimeContainerImageArtifact'; Version='1.0' }
            Provider=$provider; Image=[string]$ImagePlan.Image; ImageKey=[string]$ImagePlan.ImageKey
            SoftwarePlanKeys=@($ImagePlan.SoftwarePlanKeys)
            LocalImageId=[string]$evidence.ImageId; LaunchMode=[string]$ImagePlan.LaunchMode
            RequiredLinuxCapabilities=@($ImagePlan.RequiredLinuxCapabilities); RequiredSecurityOptions=@($ImagePlan.RequiredSecurityOptions); Reused=$false; Receipt=$receipt
        }
    }
    finally {
        if ($built -or (Get-LabExternalRuntimeLocalImageEvidence -Provider $provider -Image $temporaryTag)) {
            & $provider image rm $temporaryTag 1>$null 2>$null
        }
    }
}

function Invoke-LabExternalRuntimeContainerImageBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ImagePlan,
        [string]$StateRoot
    )

    if (-not $ImagePlan.Contract -or [string]$ImagePlan.Contract.Name -ne 'SqlServerLab.ExternalRuntimeContainerImagePlan' -or
        [string]$ImagePlan.Contract.Version -ne '1.0' -or [string]$ImagePlan.ImageKey -notmatch '^[a-f0-9]{64}$') {
        throw 'EXTERNAL_RUNTIME_CONTAINER_IMAGE_PLAN_INVALID'
    }
    if ([string]$ImagePlan.Provider -notin @('docker', 'podman')) {
        throw 'EXTERNAL_RUNTIME_CONTAINER_PROVIDER_INVALID'
    }

    return Invoke-LabArtifactStoreLock -StateRoot $StateRoot -ScriptBlock {
        Invoke-LabExternalRuntimeContainerImageBuildCore -ImagePlan $ImagePlan -StateRoot $StateRoot
    }
}

<#
.SYNOPSIS
    Kataloggebundene Derived Images fuer allgemeine SQL-Werkzeuge.
.DESCRIPTION
    Dieser Pfad ist vom External-Runtime-Image strikt getrennt: Tools wie
    SqlPackage benötigen weder Launchpad noch dessen privilegierten
    Namespace-Vertrag.
#>

function Get-LabContainerToolRecipeRoot {
    [CmdletBinding()]
    param()

    return Join-Path $script:ModuleRoot 'Images/Tools/Linux'
}

function Get-LabContainerToolRecipe {
    [CmdletBinding()]
    param()

    $recipeRoot = Get-LabContainerToolRecipeRoot
    $recipePath = Join-Path $recipeRoot 'recipe.json'
    if (-not (Test-Path -LiteralPath $recipePath -PathType Leaf)) {
        throw "CONTAINER_TOOL_RECIPE_NOT_FOUND: $recipePath"
    }
    $recipe = Get-Content -LiteralPath $recipePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    if (-not $recipe.contract -or [string]$recipe.contract.name -ne 'SqlServerLab.ContainerToolRecipe' -or
        [string]$recipe.contract.version -ne '1.0' -or [string]$recipe.recipeVersion -notmatch '^[1-9][0-9]*$' -or
        [string]$recipe.operatingSystem -ne 'ubuntu-22.04' -or [string]$recipe.architecture -ne 'x86_64') {
        throw 'CONTAINER_TOOL_RECIPE_CONTRACT_INVALID'
    }
    foreach ($image in @($recipe.baseImage, $recipe.extractorImage)) {
        if (-not $image -or [string]$image.reference -notmatch '^[a-z0-9./_-]+@sha256:([a-f0-9]{64})$' -or
            [string]$image.sha256 -ne $Matches[1]) {
            throw 'CONTAINER_TOOL_RECIPE_IMAGE_NOT_DIGEST_BOUND'
        }
    }
    $sqlPackage = $recipe.tools.sqlpackage
    if (-not $sqlPackage -or [string]$sqlPackage.runtimeVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$') {
        throw 'CONTAINER_TOOL_RECIPE_SQLPACKAGE_INVALID'
    }
    foreach ($artifact in @($sqlPackage.archive, $sqlPackage.runtimeLibrary)) {
        $uri = $null
        if (-not $artifact -or -not [Uri]::TryCreate([string]$artifact.source, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -ne 'https' -or $uri.UserInfo -or [string]$artifact.version -eq '' -or
            [string]$artifact.sha256 -notmatch '^[a-f0-9]{64}$') {
            throw 'CONTAINER_TOOL_RECIPE_ARTIFACT_INVALID'
        }
    }
    foreach ($relative in @($sqlPackage.contextFiles)) {
        if ([string]$relative -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]+$' -or [string]$relative -match '(^|/)\.\.(/|$)' -or
            -not (Test-Path -LiteralPath (Join-Path $recipeRoot $relative) -PathType Leaf)) {
            throw "CONTAINER_TOOL_RECIPE_CONTEXT_INVALID: $relative"
        }
    }
    $recipe | Add-Member -NotePropertyName RecipeRoot -NotePropertyValue $recipeRoot -Force
    return $recipe
}

function New-LabContainerToolImagePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][ValidateSet('2022')][string]$SqlVersion,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SoftwarePlans
    )

    if (@($SoftwarePlans).Count -ne 1) { throw 'CONTAINER_TOOL_PLAN_REQUIRES_EXACTLY_ONE_TOOL' }
    $softwarePlan = @($SoftwarePlans)[0]
    if ([string]$softwarePlan.Status -ne 'RESOLVED' -or [string]$softwarePlan.Kind -ne 'generalSoftware' -or
        [string]$softwarePlan.SoftwareId -ne 'sqlpackage' -or [string]$softwarePlan.Provider -ne $Provider -or
        [string]$softwarePlan.SqlVersion -ne $SqlVersion -or [string]$softwarePlan.OperatingSystem -ne 'linux' -or
        [string]$softwarePlan.InstallationMethod -ne 'derived-image' -or [string]$softwarePlan.PlanKey -notmatch '^[a-f0-9]{64}$') {
        throw 'CONTAINER_TOOL_SOFTWARE_PLAN_SCOPE_INVALID'
    }
    $recipe = Get-LabContainerToolRecipe
    if ([string]$softwarePlan.RuntimeVersion -ne [string]$recipe.tools.sqlpackage.runtimeVersion) {
        throw 'CONTAINER_TOOL_PLAN_RECIPE_VERSION_MISMATCH'
    }
    foreach ($requiredArtifact in @($recipe.tools.sqlpackage.archive, $recipe.tools.sqlpackage.runtimeLibrary)) {
        $match = @($softwarePlan.ArtifactRefs | Where-Object {
            [string]$_.Id -eq [string]$requiredArtifact.id -and [string]$_.Version -eq [string]$requiredArtifact.version -and
            [string]$_.Sha256 -eq [string]$requiredArtifact.sha256
        })
        if ($match.Count -ne 1) { throw "CONTAINER_TOOL_CATALOG_RECIPE_MISMATCH: $($requiredArtifact.id)" }
    }
    $contextEvidence = @($recipe.tools.sqlpackage.contextFiles | Sort-Object | ForEach-Object {
        [ordered]@{ path=[string]$_; sha256=Get-LabLowerFileSha256 -Path (Join-Path $recipe.RecipeRoot $_) }
    })
    $keyInput = [ordered]@{
        contract = 'SqlServerLab.ContainerToolImageKey/1.0'
        recipeVersion = [string]$recipe.recipeVersion
        sqlVersion = $SqlVersion
        baseImage = [string]$recipe.baseImage.reference
        extractorImage = [string]$recipe.extractorImage.reference
        softwarePlanKey = [string]$softwarePlan.PlanKey
        context = $contextEvidence
    }
    $keyJson = $keyInput | ConvertTo-Json -Depth 20 -Compress
    $imageKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($keyJson))).ToLowerInvariant()
    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name='SqlServerLab.ContainerToolImagePlan'; Version='1.0' }
        Provider = $Provider; SqlVersion = $SqlVersion; ImageKey = $imageKey
        Image = "sql-server-lab/container-tool:$($imageKey.Substring(0,24))"
        BaseImage = [string]$recipe.baseImage.reference; BaseImageDigest = [string]$recipe.baseImage.sha256
        ExtractorImage = [string]$recipe.extractorImage.reference; ExtractorImageDigest = [string]$recipe.extractorImage.sha256
        RecipeVersion = [string]$recipe.recipeVersion; RecipeRoot = [string]$recipe.RecipeRoot
        Containerfile = Join-Path $recipe.RecipeRoot 'Containerfile'; SoftwarePlanKeys = @([string]$softwarePlan.PlanKey)
        ToolIds = @('sqlpackage'); RuntimeVersion = [string]$recipe.tools.sqlpackage.runtimeVersion
        SqlPackageArchiveUrl = [string]$recipe.tools.sqlpackage.archive.source
        SqlPackageArchiveSha256 = [string]$recipe.tools.sqlpackage.archive.sha256
        LibunwindDebUrl = [string]$recipe.tools.sqlpackage.runtimeLibrary.source
        LibunwindDebSha256 = [string]$recipe.tools.sqlpackage.runtimeLibrary.sha256
        LibunwindDebVersion = [string]$recipe.tools.sqlpackage.runtimeLibrary.version
        ContextEvidence = $contextEvidence
    }
}

function Get-LabContainerToolImageReceiptPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ImageKey,
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    return Join-Path (Join-Path (Join-Path (Join-Path $StateRoot 'artifacts/container/tool-images') $ImageKey) $Provider) 'receipt.json'
}

function Get-LabContainerToolLocalImageEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][string]$Image
    )

    $runtimeInvocation = Get-LabHostToolInvocation -Name $Provider
    $raw = & $runtimeInvocation image inspect $Image 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    $inspect = @((@($raw) -join "`n") | ConvertFrom-Json -Depth 30)[0]
    return [PSCustomObject]@{
        ImageId = [string]$inspect.Id; User = [string]$inspect.Config.User
        ImageKey = [string]$inspect.Config.Labels.'sql-server-lab.container-tool.image-key'
        ToolIds = [string]$inspect.Config.Labels.'sql-server-lab.container-tool.ids'
    }
}

function Invoke-LabContainerToolImageBuild {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ImagePlan, [string]$StateRoot)

    if (-not $ImagePlan.Contract -or [string]$ImagePlan.Contract.Name -ne 'SqlServerLab.ContainerToolImagePlan' -or
        [string]$ImagePlan.Contract.Version -ne '1.0' -or [string]$ImagePlan.ImageKey -notmatch '^[a-f0-9]{64}$') {
        throw 'CONTAINER_TOOL_IMAGE_PLAN_INVALID'
    }
    $provider = [string]$ImagePlan.Provider
    $runtimeInvocation = Get-LabHostToolInvocation -Name $provider
    return Invoke-LabArtifactStoreLock -StateRoot $StateRoot -ScriptBlock {
        $receiptPath = Get-LabContainerToolImageReceiptPath -ImageKey $ImagePlan.ImageKey -Provider $provider -StateRoot $StateRoot
        $receipt = if (Test-Path -LiteralPath $receiptPath) { Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30 } else { $null }
        if ($receipt -and [string]$receipt.imageKey -eq [string]$ImagePlan.ImageKey) {
            $existing = Get-LabContainerToolLocalImageEvidence -Provider $provider -Image ([string]$receipt.image)
            if ($existing -and [string]$existing.ImageId -eq [string]$receipt.localImageId -and [string]$existing.ImageKey -eq [string]$ImagePlan.ImageKey) {
                return [PSCustomObject]@{ Contract=[PSCustomObject]@{ Name='SqlServerLab.ContainerToolImageArtifact'; Version='1.0' }; Provider=$provider; Image=[string]$receipt.image; ImageKey=[string]$ImagePlan.ImageKey; SoftwarePlanKeys=@($receipt.softwarePlanKeys); LocalImageId=[string]$existing.ImageId; Reused=$true; Receipt=$receipt }
            }
        }
        $temporaryTag = "sql-server-lab/container-tool-build:$($ImagePlan.ImageKey.Substring(0,16))-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $buildArguments = @('build','--file',[string]$ImagePlan.Containerfile,'--tag',$temporaryTag,
                '--build-arg',"BASE_IMAGE=$($ImagePlan.BaseImage)",'--build-arg',"EXTRACTOR_IMAGE=$($ImagePlan.ExtractorImage)",
                '--build-arg',"SQLPACKAGE_ARCHIVE_URL=$($ImagePlan.SqlPackageArchiveUrl)",'--build-arg',"SQLPACKAGE_ARCHIVE_SHA256=$($ImagePlan.SqlPackageArchiveSha256)",
                '--build-arg',"SQLPACKAGE_VERSION=$($ImagePlan.RuntimeVersion)",'--build-arg',"LIBUNWIND_DEB_URL=$($ImagePlan.LibunwindDebUrl)",
                '--build-arg',"LIBUNWIND_DEB_SHA256=$($ImagePlan.LibunwindDebSha256)",'--build-arg',"LIBUNWIND_DEB_VERSION=$($ImagePlan.LibunwindDebVersion)",
                '--build-arg',"CONTENT_ID=$($ImagePlan.ImageKey)",[string]$ImagePlan.RecipeRoot)
            $output = & $runtimeInvocation @buildArguments 2>&1
            if ($LASTEXITCODE -ne 0) { throw "CONTAINER_TOOL_IMAGE_BUILD_FAILED: $(@($output | Select-Object -Last 30) -join ' ')" }
            $evidence = Get-LabContainerToolLocalImageEvidence -Provider $provider -Image $temporaryTag
            if (-not $evidence -or [string]$evidence.ImageKey -ne [string]$ImagePlan.ImageKey -or [string]$evidence.ToolIds -ne 'sqlpackage') {
                throw 'CONTAINER_TOOL_IMAGE_POSTCONDITION_FAILED'
            }
            $probe = & $runtimeInvocation run --rm --network none --entrypoint /opt/sql-server-lab/tools/sqlpackage/sqlpackage $temporaryTag /Version 2>&1
            if ($LASTEXITCODE -ne 0 -or (@($probe) -join "`n") -notmatch [regex]::Escape([string]$ImagePlan.RuntimeVersion)) {
                throw 'CONTAINER_TOOL_IMAGE_SQLPACKAGE_PROBE_FAILED'
            }
            & $runtimeInvocation tag $temporaryTag ([string]$ImagePlan.Image) 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'CONTAINER_TOOL_IMAGE_TAG_FAILED' }
            $receipt = [PSCustomObject]@{ contract=[PSCustomObject]@{ name='SqlServerLab.ContainerToolImageReceipt'; version='1.0' }; imageKey=[string]$ImagePlan.ImageKey; provider=$provider; image=[string]$ImagePlan.Image; localImageId=[string]$evidence.ImageId; baseImageDigest=[string]$ImagePlan.BaseImageDigest; recipeVersion=[string]$ImagePlan.RecipeVersion; softwarePlanKeys=@($ImagePlan.SoftwarePlanKeys); toolIds=@($ImagePlan.ToolIds); runtimeVersion=[string]$ImagePlan.RuntimeVersion; contextEvidence=@($ImagePlan.ContextEvidence); status='IMAGE_READY'; retention='reusable-explicit-removal'; builtAt=Get-LabTimestamp }
            Write-LabArtifactJsonAtomic -Path $receiptPath -InputObject $receipt
            return [PSCustomObject]@{ Contract=[PSCustomObject]@{ Name='SqlServerLab.ContainerToolImageArtifact'; Version='1.0' }; Provider=$provider; Image=[string]$ImagePlan.Image; ImageKey=[string]$ImagePlan.ImageKey; SoftwarePlanKeys=@($ImagePlan.SoftwarePlanKeys); LocalImageId=[string]$evidence.ImageId; Reused=$false; Receipt=$receipt }
        }
        finally {
            if (Get-LabContainerToolLocalImageEvidence -Provider $provider -Image $temporaryTag) { & $runtimeInvocation image rm $temporaryTag 1>$null 2>$null }
        }
    }
}

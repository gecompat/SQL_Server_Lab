<#
.SYNOPSIS
    Katalog- und Planungsvertrag fuer SQL-bezogene External Runtimes.
.DESCRIPTION
    Loest External-Runtime-Anforderungen deterministisch und ohne Mutation
    gegen SQL-Version, Betriebssystem, Provider und deklarierte Capabilities
    auf. Nur vollstaendig belegte SUPPORTED-Varianten koennen RESOLVED werden.
#>

function Get-LabSoftwareCatalog {
    [CmdletBinding()]
    param()

    if ($script:SoftwareCatalog) {
        return $script:SoftwareCatalog
    }

    $catalogPath = Join-Path $script:CatalogsPath 'software.json'
    if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        throw "SOFTWARE_CATALOG_NOT_FOUND: $catalogPath"
    }

    $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 50
    if (-not $catalog.contract -or
        [string]$catalog.contract.name -ne 'SqlServerLab.SoftwareCatalog' -or
        [string]$catalog.contract.version -ne '1.0') {
        throw 'SOFTWARE_CATALOG_CONTRACT_INVALID'
    }

    $softwareIds = @($catalog.software | ForEach-Object { [string]$_.id })
    if (@($softwareIds | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
        throw 'SOFTWARE_CATALOG_DUPLICATE_SOFTWARE_ID'
    }
    $variantIds = @($catalog.software | ForEach-Object { @($_.variants) } | ForEach-Object { [string]$_.id })
    if (@($variantIds | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
        throw 'SOFTWARE_CATALOG_DUPLICATE_VARIANT_ID'
    }

    $script:SoftwareCatalog = $catalog
    return $script:SoftwareCatalog
}

function Get-LabSoftwareCatalogItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)

    $catalog = Get-LabSoftwareCatalog
    return $catalog.software |
        Where-Object { [string]$_.id -eq $Id } |
        Select-Object -First 1
}

function ConvertTo-LabExternalRuntimeSoftwareId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Language)

    switch ($Language) {
        'Python' { return 'sql-python' }
        'R' { return 'sql-r' }
        'Java' { return 'sql-java' }
        default { throw "EXTERNAL_RUNTIME_LANGUAGE_UNKNOWN: $Language" }
    }
}

function ConvertTo-LabExternalRuntimeRequests {
    <#
    .SYNOPSIS
        Normalisiert explizite software[]- und bestehende externalScripts-Anforderungen.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Software,
        $ExternalScripts
    )

    $requests = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Software | Where-Object { $_ -and [string]$_.id -in @('sql-python', 'sql-r', 'sql-java') })) {
        $requests.Add([PSCustomObject]@{
            Id = [string]$item.id
            Version = [string]$item.version
            Variant = [string]$item.variant
            Scope = if ($item.scope) { [string]$item.scope } else { 'sqlExternalRuntime' }
            InstallMethod = if ($item.installMethod) { [string]$item.installMethod } else { 'catalog' }
            Optional = if ($null -ne $item.optional) { [bool]$item.optional } else { $false }
            Packages = @($item.packages | Where-Object { $_ } | ForEach-Object {
                [PSCustomObject]@{
                    Name = [string]$_.name
                    Version = [string]$_.version
                    Scope = if ($_.scope) { [string]$_.scope } else { 'instance' }
                }
            })
            RequestSource = if ($item.requestSource) { [string]$item.requestSource } else { 'software' }
        })
    }

    if ($ExternalScripts -and $ExternalScripts.enabled -ne $false) {
        $legacyInstallMethod = switch ([string]$ExternalScripts.installMethod) {
            'custom-image' { 'custom-image' }
            'pre-built' { 'pre-built' }
            default { 'legacy-post-start' }
        }
        foreach ($language in @($ExternalScripts.languages | Where-Object { $_ })) {
            $softwareId = ConvertTo-LabExternalRuntimeSoftwareId -Language ([string]$language.name)
            if (@($requests | Where-Object Id -eq $softwareId).Count -gt 0) {
                throw "EXTERNAL_RUNTIME_REQUEST_DUPLICATE: $softwareId"
            }
            $requests.Add([PSCustomObject]@{
                Id = $softwareId
                Version = $null
                Variant = $null
                Scope = 'sqlExternalRuntime'
                InstallMethod = $legacyInstallMethod
                Optional = $false
                Packages = @($language.packages | Where-Object { $_ } | ForEach-Object {
                    [PSCustomObject]@{
                        Name = [string]$_.name
                        Version = [string]$_.version
                        Scope = if ($_.scope) { [string]$_.scope } else { 'instance' }
                    }
                })
                RequestSource = 'externalScripts-legacy'
            })
        }
    }

    $duplicateIds = @($requests | Group-Object Id | Where-Object Count -gt 1)
    if ($duplicateIds.Count -gt 0) {
        throw "EXTERNAL_RUNTIME_REQUEST_DUPLICATE: $($duplicateIds[0].Name)"
    }
    return @($requests)
}

function New-LabUnsupportedSoftwarePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][string]$SqlVersion,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$OperatingSystem,
        [Parameter(Mandatory)][string]$ReasonCode,
        [Parameter(Mandatory)][string]$Reason,
        $Variant,
        [ValidateSet('DECLARED_UNSUPPORTED', 'NON_REPRODUCIBLE')]
        [string]$Status = 'DECLARED_UNSUPPORTED'
    )

    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.SoftwarePlan'; Version = '1.0'; EvidenceBoundary = 'catalog-and-provider-metadata' }
        SoftwareId = [string]$Request.Id
        Kind = 'sqlExternalRuntime'
        Language = if ($Variant) { [string]$Variant.language } else { $null }
        RequestedVersion = [string]$Request.Version
        SqlVersion = $SqlVersion
        Provider = $Provider
        OperatingSystem = $OperatingSystem
        Architecture = 'x86_64'
        Status = $Status
        ReasonCode = $ReasonCode
        Reason = $Reason
        VariantId = if ($Variant) { [string]$Variant.id } else { $null }
        VariantStatus = if ($Variant) { [string]$Variant.status } else { $null }
        RuntimeVersion = if ($Variant) { [string]$Variant.runtimeVersion } else { $null }
        InstallationMethod = if ($Variant) { [string]$Variant.installMethod } else { [string]$Request.InstallMethod }
        RecipeVersion = if ($Variant) { [string]$Variant.recipeVersion } else { $null }
        RequiredCapabilities = if ($Variant) { @($Variant.requiresCapabilities | ForEach-Object { [string]$_ }) } else { @() }
        ArtifactRefs = if ($Variant) { @($Variant.artifacts | ForEach-Object {
            [PSCustomObject]@{
                Id = [string]$_.id
                Version = [string]$_.version
                Sha256 = [string]$_.sha256
                IntegrityOrigin = [string]$_.integrityOrigin
            }
        }) } else { @() }
        PackageLocks = @()
        Restart = if ($Variant) { $Variant.restart } else { $null }
        Validation = if ($Variant) { $Variant.validation } else { $null }
        RequestSource = [string]$Request.RequestSource
    }
}

function Resolve-LabExternalRuntimePlan {
    <#
    .SYNOPSIS
        Loest genau eine External-Runtime-Anforderung ohne Mutation auf.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SoftwareItem,
        [Parameter(Mandatory)][string]$SqlVersion,
        [Parameter(Mandatory)][ValidateSet('docker', 'podman', 'hyperv')][string]$Provider,
        [Parameter(Mandatory)][ValidateSet('linux', 'windows')][string]$OperatingSystem,
        [ValidateSet('x86_64')][string]$Architecture = 'x86_64'
    )

    $definition = Get-LabSoftwareCatalogItem -Id ([string]$SoftwareItem.Id)
    if (-not $definition) {
        return New-LabUnsupportedSoftwarePlan -Request $SoftwareItem -SqlVersion $SqlVersion -Provider $Provider `
            -OperatingSystem $OperatingSystem -ReasonCode 'SOFTWARE_NOT_CATALOGUED' `
            -Reason "Software '$($SoftwareItem.Id)' ist nicht im Softwarekatalog enthalten."
    }

    $sqlDefinition = Get-SqlServerVersion -VersionId $SqlVersion
    if (-not $sqlDefinition) {
        return New-LabUnsupportedSoftwarePlan -Request $SoftwareItem -SqlVersion $SqlVersion -Provider $Provider `
            -OperatingSystem $OperatingSystem -ReasonCode 'SQL_VERSION_UNKNOWN' `
            -Reason "SQL-Version '$SqlVersion' ist nicht katalogisiert."
    }

    $candidates = @($definition.variants | Where-Object {
        @($_.sqlMajorVersions) -contains [int]$sqlDefinition.major -and
        [string]$_.operatingSystem -eq $OperatingSystem -and
        @($_.providers) -contains $Provider -and
        [string]$_.architecture -eq $Architecture
    })
    if ($SoftwareItem.Variant) {
        $candidates = @($candidates | Where-Object { [string]$_.id -eq [string]$SoftwareItem.Variant })
    }
    if ($SoftwareItem.Version) {
        $candidates = @($candidates | Where-Object { [string]$_.runtimeVersion -eq [string]$SoftwareItem.Version })
    }

    if ($candidates.Count -eq 0) {
        return New-LabUnsupportedSoftwarePlan -Request $SoftwareItem -SqlVersion $SqlVersion -Provider $Provider `
            -OperatingSystem $OperatingSystem -ReasonCode 'RUNTIME_COMBINATION_NOT_CATALOGUED' `
            -Reason "Keine Variante fuer '$($SoftwareItem.Id)', SQL $SqlVersion, $Provider/$OperatingSystem und $Architecture katalogisiert."
    }
    if ($candidates.Count -gt 1) {
        throw "SOFTWARE_PLAN_AMBIGUOUS: $($SoftwareItem.Id) / $SqlVersion / $Provider / $OperatingSystem"
    }

    $variant = $candidates[0]
    if ([string]$SoftwareItem.InstallMethod -eq 'legacy-post-start') {
        return New-LabUnsupportedSoftwarePlan -Request $SoftwareItem -SqlVersion $SqlVersion -Provider $Provider `
            -OperatingSystem $OperatingSystem -Variant $variant -Status 'NON_REPRODUCIBLE' `
            -ReasonCode 'LEGACY_POST_START_MUTATION' `
            -Reason 'Der bestehende post-start-Installer mutiert einen laufenden Container und ist kein reproduzierbarer Standardpfad.'
    }
    if ([string]$SoftwareItem.InstallMethod -in @('custom-image', 'pre-built')) {
        return New-LabUnsupportedSoftwarePlan -Request $SoftwareItem -SqlVersion $SqlVersion -Provider $Provider `
            -OperatingSystem $OperatingSystem -Variant $variant -ReasonCode 'IMAGE_BINDING_NOT_IMPLEMENTED' `
            -Reason "Installationsmethode '$($SoftwareItem.InstallMethod)' ist noch nicht an die verifizierte Imageauswahl gebunden."
    }

    $lockedPackages = @($variant.packageLocks)
    $resolvedLocks = [System.Collections.Generic.List[object]]::new()
    foreach ($requestedPackage in @($SoftwareItem.Packages | Where-Object { $_ })) {
        $lock = $lockedPackages | Where-Object {
            [string]$_.name -ieq [string]$requestedPackage.Name -and
            (-not $requestedPackage.Version -or [string]$_.version -eq [string]$requestedPackage.Version)
        } | Select-Object -First 1
        if (-not $lock) {
            return New-LabUnsupportedSoftwarePlan -Request $SoftwareItem -SqlVersion $SqlVersion -Provider $Provider `
                -OperatingSystem $OperatingSystem -Variant $variant -ReasonCode 'PACKAGE_NOT_LOCKED' `
                -Reason "Paket '$($requestedPackage.Name)' ist fuer Variante '$($variant.id)' nicht mit Version und SHA-256 gebunden."
        }
        $resolvedLocks.Add([PSCustomObject]@{
            Name = [string]$lock.name
            Version = [string]$lock.version
            Sha256 = ([string]$lock.sha256).ToLowerInvariant()
            Scope = [string]$requestedPackage.Scope
        })
    }

    if ([string]$variant.status -ne 'SUPPORTED') {
        return New-LabUnsupportedSoftwarePlan -Request $SoftwareItem -SqlVersion $SqlVersion -Provider $Provider `
            -OperatingSystem $OperatingSystem -Variant $variant -ReasonCode "VARIANT_$([string]$variant.status)" `
            -Reason ([string]$variant.reason)
    }

    $providerDefinition = $script:RegisteredProviders[$Provider].Definition
    $declaredCapabilities = @($providerDefinition.capabilities | ForEach-Object { [string]$_ })
    $missingCapabilities = @($variant.requiresCapabilities | Where-Object { $declaredCapabilities -notcontains [string]$_ })
    if ($missingCapabilities.Count -gt 0) {
        return New-LabUnsupportedSoftwarePlan -Request $SoftwareItem -SqlVersion $SqlVersion -Provider $Provider `
            -OperatingSystem $OperatingSystem -Variant $variant -ReasonCode 'PROVIDER_CAPABILITY_MISSING' `
            -Reason "Provider '$Provider' deklariert nicht: $($missingCapabilities -join ', ')."
    }

    $invalidArtifacts = @($variant.artifacts | Where-Object {
        -not $_.version -or [string]$_.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or -not $_.integrityOrigin
    })
    if (@($variant.artifacts).Count -eq 0 -or $invalidArtifacts.Count -gt 0) {
        return New-LabUnsupportedSoftwarePlan -Request $SoftwareItem -SqlVersion $SqlVersion -Provider $Provider `
            -OperatingSystem $OperatingSystem -Variant $variant -ReasonCode 'ARTIFACT_INTEGRITY_INCOMPLETE' `
            -Reason "Variante '$($variant.id)' besitzt keine vollstaendige Version-/SHA-256-/Herkunftsbindung."
    }

    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.SoftwarePlan'; Version = '1.0'; EvidenceBoundary = 'catalog-and-provider-metadata' }
        SoftwareId = [string]$definition.id
        Kind = [string]$definition.kind
        Language = [string]$variant.language
        RequestedVersion = [string]$SoftwareItem.Version
        SqlVersion = $SqlVersion
        Provider = $Provider
        OperatingSystem = $OperatingSystem
        Architecture = $Architecture
        Status = 'RESOLVED'
        ReasonCode = $null
        Reason = $null
        VariantId = [string]$variant.id
        VariantStatus = [string]$variant.status
        RuntimeVersion = [string]$variant.runtimeVersion
        InstallationMethod = [string]$variant.installMethod
        RecipeVersion = [string]$variant.recipeVersion
        RequiredCapabilities = @($variant.requiresCapabilities | ForEach-Object { [string]$_ })
        ArtifactRefs = @($variant.artifacts | ForEach-Object {
            [PSCustomObject]@{
                Id = [string]$_.id
                Version = [string]$_.version
                Sha256 = ([string]$_.sha256).ToLowerInvariant()
                IntegrityOrigin = [string]$_.integrityOrigin
            }
        })
        PackageLocks = @($resolvedLocks)
        Restart = $variant.restart
        Validation = $variant.validation
        RequestSource = [string]$SoftwareItem.RequestSource
    }
}

function Resolve-LabExternalRuntimePlansForInstance {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Instance)

    $hasNormalizedLegacyRequest = @($Instance.software | Where-Object { [string]$_.requestSource -eq 'externalScripts-legacy' }).Count -gt 0
    $externalScripts = if ($Instance.serverConfig -and -not $hasNormalizedLegacyRequest) { $Instance.serverConfig.externalScripts } else { $null }
    $requests = @(ConvertTo-LabExternalRuntimeRequests -Software @($Instance.software) -ExternalScripts $externalScripts)
    return @($requests | ForEach-Object {
        Resolve-LabExternalRuntimePlan -SoftwareItem $_ -SqlVersion ([string]$Instance.version) `
            -Provider ([string]$Instance.provider) -OperatingSystem ([string]$Instance.os)
    })
}

function New-LabSoftwareInstallationReceipt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Postconditions
    )

    if ([string]$Plan.Status -ne 'RESOLVED') {
        throw "SOFTWARE_RECEIPT_REQUIRES_RESOLVED_PLAN: $($Plan.SoftwareId) / $($Plan.Status)"
    }
    if (@($Postconditions).Count -eq 0) {
        throw "SOFTWARE_RECEIPT_POSTCONDITION_REQUIRED: $($Plan.SoftwareId)"
    }
    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.SoftwareInstallationReceipt'; Version = '1.0' }
        SoftwareId = [string]$Plan.SoftwareId
        VariantId = [string]$Plan.VariantId
        RuntimeVersion = [string]$Plan.RuntimeVersion
        RecipeVersion = [string]$Plan.RecipeVersion
        Provider = [string]$Plan.Provider
        ArtifactRefs = @($Plan.ArtifactRefs)
        PackageLocks = @($Plan.PackageLocks)
        Status = 'EXTENSIONS_READY_RUN'
        Postconditions = @($Postconditions)
        CompletedAt = Get-LabTimestamp
    }
}

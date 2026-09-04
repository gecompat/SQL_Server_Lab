<#
.SYNOPSIS
    Lokale, geheimnisfreie Metadaten und DPAPI-geschuetzte Product Keys.
.DESCRIPTION
    Lizenzprofile liegen ausschliesslich im lokalen State Root. Oeffentliche
    Projektionen enthalten weder Product Keys noch Key-Fragmente. Ein Profil
    wird nur auf ausdrueckliche Auswahl an einen Build gebunden; ohne Profil
    bleibt der bestehende Evaluation-/Developer-/Express-Vertrag unveraendert.
#>

function Get-LabLicenseProfileRoot {
    [CmdletBinding()]
    param(
        [string]$StateRoot,
        [switch]$Ensure
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $root = Join-Path $StateRoot 'license-profiles'
    if (Test-Path -LiteralPath $root) {
        $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'LICENSE_PROFILE_ROOT_UNSAFE'
        }
    }
    elseif ($Ensure) {
        $null = Initialize-LabStateRoot -StateRoot $StateRoot
        $null = New-Item -Path $root -ItemType Directory -Force
    }
    return [IO.Path]::GetFullPath($root)
}

function Get-LabLicenseProfilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9.-]{2,63}$')][string]$Id,
        [string]$StateRoot
    )

    Join-Path (Get-LabLicenseProfileRoot -StateRoot $StateRoot) $Id
}

function ConvertTo-LabLicenseEdition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('SqlServer', 'Windows')][string]$Product,
        [Parameter(Mandatory)][string]$Edition
    )

    $token = ($Edition -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    if ($Product -eq 'SqlServer') {
        switch ($token) {
            'enterprise' { return 'Enterprise' }
            'enterprisecore' { return 'EnterpriseCore' }
            'standard' { return 'Standard' }
            'web' { return 'Web' }
            default { throw "LICENSE_PROFILE_SQL_EDITION_UNSUPPORTED: $Edition" }
        }
    }

    switch ($token) {
        'home' { return 'Home' }
        'pro' { return 'Pro' }
        'professional' { return 'Pro' }
        'proforworkstations' { return 'ProForWorkstations' }
        'enterprise' { return 'Enterprise' }
        'education' { return 'Education' }
        'iotenterprise' { return 'IoTEnterprise' }
        default { throw "LICENSE_PROFILE_WINDOWS_EDITION_UNSUPPORTED: $Edition" }
    }
}

function Test-LabProductKeyFormat {
    [CmdletBinding()]
    param([Parameter(Mandatory)][SecureString]$Key)

    $plain = $null
    try {
        $plain = ConvertFrom-LabSecureString -SecureString $Key
        return [bool]($plain -match '^(?:[A-Z0-9]{5}-){4}[A-Z0-9]{5}$')
    }
    finally { $plain = $null }
}

function Get-LabLicenseProfileMetadata {
    [CmdletBinding()]
    param(
        [ValidatePattern('^[a-z][a-z0-9.-]{2,63}$')][string]$Id,
        [string]$StateRoot
    )

    $root = Get-LabLicenseProfileRoot -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
    $directories = if ($Id) {
        $path = Join-Path $root $Id
        if (Test-Path -LiteralPath $path -PathType Container) { @(Get-Item -LiteralPath $path) } else { @() }
    }
    else {
        @(Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { $_.Name -match '^[a-z][a-z0-9.-]{2,63}$' })
    }

    foreach ($directory in $directories) {
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "LICENSE_PROFILE_PATH_UNSAFE: $($directory.Name)"
        }
        $metadataPath = Join-Path $directory.FullName 'metadata.json'
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { continue }
        $metadataItem = Get-Item -LiteralPath $metadataPath -Force -ErrorAction Stop
        if ($metadataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "LICENSE_PROFILE_METADATA_PATH_UNSAFE: $($directory.Name)"
        }
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
        }
        catch { throw "LICENSE_PROFILE_METADATA_INVALID: $($directory.Name)" }
        if ([string]$metadata.contractVersion -ne 'SqlServerLab.LicenseProfile/1.0' -or
            [string]$metadata.id -ne [string]$directory.Name -or
            [string]$metadata.product -notin @('SqlServer', 'Windows') -or
            [string]::IsNullOrWhiteSpace([string]$metadata.version) -or
            [string]::IsNullOrWhiteSpace([string]$metadata.edition) -or
            [string]::IsNullOrWhiteSpace([string]$metadata.channel)) {
            throw "LICENSE_PROFILE_METADATA_INVALID: $($directory.Name)"
        }
        $metadata
    }
}

function Get-LabLicenseProfileSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9.-]{2,63}$')][string]$Id,
        [string]$StateRoot
    )

    $profilePath = Get-LabLicenseProfilePath -Id $Id -StateRoot $StateRoot
    $profileItem = Get-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
    if ($profileItem -and (-not $profileItem.PSIsContainer -or ($profileItem.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw "LICENSE_PROFILE_PATH_UNSAFE: $Id"
    }
    $secretPath = Join-Path $profilePath 'secrets/product-key.secret'
    $secretItem = Get-Item -LiteralPath $secretPath -Force -ErrorAction SilentlyContinue
    if ($secretItem -and ($secretItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "LICENSE_PROFILE_SECRET_PATH_UNSAFE: $Id"
    }
    $secret = Get-LabSecret -Path $profilePath -Name 'product-key'
    if (-not $secret) { throw "LICENSE_PROFILE_SECRET_MISSING: $Id" }
    return $secret
}

function Resolve-LabLicenseProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9.-]{2,63}$')][string]$Id,
        [ValidateSet('SqlServer', 'Windows')][string]$Product,
        [string]$Version,
        [string]$Edition,
        [string]$StateRoot
    )

    $profile = @(Get-LabLicenseProfileMetadata -Id $Id -StateRoot $StateRoot)
    if ($profile.Count -ne 1) { throw "LICENSE_PROFILE_NOT_FOUND: $Id" }
    $profile = $profile[0]
    if ($Product -and [string]$profile.product -ne $Product) {
        throw "LICENSE_PROFILE_PRODUCT_MISMATCH: $Id"
    }
    if ($Version -and -not ([string]$profile.version).Equals($Version, [StringComparison]::OrdinalIgnoreCase)) {
        throw "LICENSE_PROFILE_VERSION_MISMATCH: $Id"
    }
    if ($Edition) {
        $expectedEdition = ConvertTo-LabLicenseEdition -Product ([string]$profile.product) -Edition $Edition
        if ([string]$profile.edition -ne $expectedEdition) { throw "LICENSE_PROFILE_EDITION_MISMATCH: $Id" }
    }
    $secret = Get-LabLicenseProfileSecret -Id $Id -StateRoot $StateRoot
    if (-not (Test-LabProductKeyFormat -Key $secret)) { throw "LICENSE_PROFILE_KEY_FORMAT_INVALID: $Id" }
    return $profile
}

function Resolve-LabSqlLicenseSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SqlVersion,
        [Parameter(Mandatory)][ValidateSet('Eval', 'Enterprise', 'EnterpriseCore', 'Standard', 'Web')][string]$MediaEdition,
        [ValidatePattern('^[a-z][a-z0-9.-]{2,63}$')][string]$LicenseProfileId,
        [string]$StateRoot
    )

    if ([string]::IsNullOrWhiteSpace($LicenseProfileId)) {
        switch ($MediaEdition) {
            'Eval' { $edition = 'Evaluation'; $type = 'evaluation' }
            'Enterprise' { $edition = 'EnterpriseDeveloper'; $type = 'developer' }
            'Standard' { $edition = 'StandardDeveloper'; $type = 'developer' }
            default { throw "HYPERV_SQL_LICENSE_PROFILE_REQUIRED: $MediaEdition" }
        }
        return [PSCustomObject]@{
            Edition = $edition; LicenseType = $type; ProfileId = $null; Channel = $null
            EvaluationStartsAt = if ($type -eq 'evaluation') { 'complete-image' } else { $null }
        }
    }

    if ($MediaEdition -eq 'Eval') { throw 'HYPERV_SQL_LICENSE_PROFILE_EVALUATION_MEDIA_UNSUPPORTED' }
    $expectedEdition = ConvertTo-LabLicenseEdition -Product SqlServer -Edition $MediaEdition
    $profile = Resolve-LabLicenseProfile -Id $LicenseProfileId -Product SqlServer -Version $SqlVersion `
        -Edition $expectedEdition -StateRoot $StateRoot
    return [PSCustomObject]@{
        Edition = $expectedEdition; LicenseType = 'licensed'; ProfileId = [string]$profile.id
        Channel = [string]$profile.channel; EvaluationStartsAt = $null
    }
}

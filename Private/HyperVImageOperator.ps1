<#
.SYNOPSIS
    Operatorfunktionen fuer den lokalen Hyper-V-Windows-Image-Build.
.DESCRIPTION
    Bindet den internen Image-Builder an die kanonische Media-Root-Struktur,
    verwaltet einzelne SHA-256-Sidecars und stellt sichere, resumierbare
    Operationen fuer Menue und Direkt-Aktion bereit.
#>

function Get-HyperVImageBuildPlans {
    [CmdletBinding()]
    param([string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $buildRoot = Join-Path $StateRoot 'image-builds/hyperv'
    if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $buildRoot -Directory -Force |
            Sort-Object Name |
            ForEach-Object {
                if ($_.Name -notmatch '^[a-f0-9-]{36}$') { return }
                Get-HyperVImageBuildPlan -BuildId $_.Name -StateRoot $StateRoot
            } |
            Where-Object { $null -ne $_ }
    )
}

function Resolve-HyperVWindowsInstallationMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)]
        [ValidateSet('windows-server-2022', 'windows-server-2025')]
        [string]$OperatingSystemId
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw 'HYPERV_MEDIA_ROOT_NOT_FOUND'
    }
    $version = $OperatingSystemId -replace '^windows-server-', ''
    $isoDirectory = Join-Path $resolvedRoot "WindowsServer/$version/Eval/ISO"
    if (-not (Test-Path -LiteralPath $isoDirectory -PathType Container)) {
        throw "HYPERV_WINDOWS_MEDIA_DIRECTORY_NOT_FOUND: $isoDirectory"
    }

    $isoFiles = @(
        Get-ChildItem -LiteralPath $isoDirectory -File -Force |
            Where-Object { $_.Extension -ieq '.iso' }
    )
    if ($isoFiles.Count -eq 0) {
        throw "HYPERV_WINDOWS_MEDIA_NOT_FOUND: $isoDirectory"
    }
    if ($isoFiles.Count -gt 1) {
        throw "HYPERV_WINDOWS_MEDIA_AMBIGUOUS: $($isoFiles.Name -join ', ')"
    }

    $iso = $isoFiles[0]
    $relativePath = [System.IO.Path]::GetRelativePath($resolvedRoot, $iso.FullName)
    if ($relativePath.StartsWith('..')) { throw 'HYPERV_WINDOWS_MEDIA_OUTSIDE_ROOT' }
    $portableRelative = $relativePath.Replace('\', '/')
    $hashPath = Join-Path (Join-Path $resolvedRoot 'Hashes') ($relativePath + '.sha256')
    $expectedSha256 = $null
    $hashStatus = 'MISSING'

    if (Test-Path -LiteralPath $hashPath -PathType Leaf) {
        $hashContent = (Get-Content -LiteralPath $hashPath -Raw -Encoding utf8).Trim()
        if ($hashContent -notmatch '^(?<sha>[A-Fa-f0-9]{64})\s{2}(?<relative>.+)$') {
            throw "HYPERV_WINDOWS_MEDIA_HASH_INVALID: $hashPath"
        }
        $sidecarRelative = $Matches['relative'].Replace('\', '/')
        $comparison = if ($IsWindows) {
            [System.StringComparison]::OrdinalIgnoreCase
        }
        else {
            [System.StringComparison]::Ordinal
        }
        if (-not $sidecarRelative.Equals($portableRelative, $comparison)) {
            throw "HYPERV_WINDOWS_MEDIA_HASH_PATH_MISMATCH: $hashPath"
        }
        $expectedSha256 = $Matches['sha'].ToLowerInvariant()
        $hashStatus = 'SIDECAR_READY'
    }

    return [PSCustomObject]@{
        MediaRoot        = $resolvedRoot
        OperatingSystemId = $OperatingSystemId
        IsoPath          = $iso.FullName
        RelativePath     = $portableRelative
        LengthBytes      = [long]$iso.Length
        HashPath         = $hashPath
        HashStatus       = $hashStatus
        ExpectedSha256   = $expectedSha256
    }
}

function New-HyperVWindowsMediaHashSidecar {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)]
        [ValidateSet('windows-server-2022', 'windows-server-2025')]
        [string]$OperatingSystemId
    )

    $media = Resolve-HyperVWindowsInstallationMedia `
        -MediaRoot $MediaRoot `
        -OperatingSystemId $OperatingSystemId
    if ($media.HashStatus -eq 'SIDECAR_READY') {
        return $media
    }

    $digest = (Get-FileHash -LiteralPath $media.IsoPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $hashDirectory = Split-Path -Parent $media.HashPath
    if ($PSCmdlet.ShouldProcess($media.HashPath, 'SHA-256-Sidecar fuer Windows-ISO schreiben')) {
        New-Item -Path $hashDirectory -ItemType Directory -Force | Out-Null
        $content = "$digest  $($media.RelativePath)"
        Set-Content -LiteralPath $media.HashPath -Value $content -Encoding utf8NoBOM
    }

    if ($WhatIfPreference) {
        return [PSCustomObject]@{
            MediaRoot        = $media.MediaRoot
            OperatingSystemId = $media.OperatingSystemId
            IsoPath          = $media.IsoPath
            RelativePath     = $media.RelativePath
            LengthBytes      = $media.LengthBytes
            HashPath         = $media.HashPath
            HashStatus       = 'WHAT_IF'
            ExpectedSha256   = $digest
        }
    }

    return Resolve-HyperVWindowsInstallationMedia `
        -MediaRoot $MediaRoot `
        -OperatingSystemId $OperatingSystemId
}

function Initialize-HyperVWindowsImageBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)]
        [ValidateSet('windows-server-2022', 'windows-server-2025')]
        [string]$OperatingSystemId,
        [Parameter(Mandatory)][string]$Edition,
        [Parameter(Mandatory)]
        [ValidateSet('core', 'desktop-experience')]
        [string]$InstallationType,
        [ValidateSet('licensed', 'evaluation')]
        [string]$LicenseType = 'evaluation',
        [ValidateRange(32GB, 1TB)][long]$OsDiskSizeBytes = 80GB,
        [ValidateRange(2GB, 1TB)][long]$MemoryStartupBytes = 4GB,
        [ValidateRange(1, 64)][int]$ProcessorCount = 4,
        [string]$Language = 'en-US',
        [string]$StateRoot
    )

    $media = Resolve-HyperVWindowsInstallationMedia `
        -MediaRoot $MediaRoot `
        -OperatingSystemId $OperatingSystemId
    if ($media.HashStatus -ne 'SIDECAR_READY' -or -not $media.ExpectedSha256) {
        throw "HYPERV_WINDOWS_MEDIA_HASH_REQUIRED: $($media.HashPath)"
    }

    $plan = New-HyperVWindowsImageBuildPlan `
        -IsoPath $media.IsoPath `
        -ExpectedSha256 $media.ExpectedSha256 `
        -OperatingSystemId $OperatingSystemId `
        -Edition $Edition `
        -InstallationType $InstallationType `
        -Language $Language `
        -LicenseType $LicenseType `
        -OsDiskSizeBytes $OsDiskSizeBytes `
        -StateRoot $StateRoot

    try {
        $builder = New-HyperVWindowsImageBuilder `
            -BuildId $plan.buildId `
            -MemoryStartupBytes $MemoryStartupBytes `
            -ProcessorCount $ProcessorCount `
            -StateRoot $StateRoot
        return Set-HyperVImageBuildManualAction `
            -BuildId $builder.buildId `
            -StateRoot $StateRoot
    }
    catch {
        try {
            $null = Set-HyperVImageBuildState `
                -BuildId $plan.buildId `
                -State FAILED `
                -Reason $_.Exception.Message `
                -StateRoot $StateRoot
        }
        catch { }
        throw
    }
}

function Confirm-HyperVWindowsImageInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [switch]$AcceptDetectedInstallationType,
        [string]$StateRoot
    )

    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
    if ($build.state -ne 'MANUAL_ACTION_REQUIRED') {
        throw 'HYPERV_IMAGE_BUILD_NOT_WAITING_FOR_INSTALLATION'
    }
    if (-not $build.builder -or -not $build.builder.vmName) {
        throw 'HYPERV_IMAGE_BUILD_VM_MISSING'
    }

    $receipt = Invoke-HyperVPowerShellDirect `
        -VMName ([string]$build.builder.vmName) `
        -ExpectedRunId $BuildId `
        -ExpectedScopeId ([string]$build.scopeId) `
        -Credential $Credential `
        -ArgumentList @([string]$build.buildId, [string]$build.scopeId) `
        -ScriptBlock {
            param($ExpectedBuildId, $ExpectedScopeId)
            $ErrorActionPreference = 'Stop'
            $currentVersion = Get-ItemProperty `
                -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
                -ErrorAction Stop
            [PSCustomObject]@{
                contractVersion = '1'
                buildId = $ExpectedBuildId
                scopeId = $ExpectedScopeId
                productName = [string]$currentVersion.ProductName
                editionId = [string]$currentVersion.EditionID
                installationType = [string]$currentVersion.InstallationType
                currentBuild = [string]$currentVersion.CurrentBuild
                displayVersion = [string]$currentVersion.DisplayVersion
                computerName = [string]$env:COMPUTERNAME
                observedAt = [datetime]::UtcNow.ToString('o')
            }
        }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or
        [string]$receipt.contractVersion -ne '1' -or
        [string]$receipt.buildId -ne [string]$build.buildId -or
        [string]$receipt.scopeId -ne [string]$build.scopeId -or
        -not [string]$receipt.productName -or
        -not [string]$receipt.editionId -or
        -not [string]$receipt.installationType -or
        -not [string]$receipt.currentBuild -or
        -not [string]$receipt.computerName -or
        -not [string]$receipt.observedAt) {
        throw 'HYPERV_IMAGE_INSTALLATION_RECEIPT_INVALID'
    }

    $expectedVersion = [string]$build.operatingSystem.id -replace '^windows-server-', ''
    if ([string]$receipt.productName -notmatch [regex]::Escape($expectedVersion)) {
        throw "HYPERV_IMAGE_INSTALLATION_VERSION_MISMATCH: erwartet $expectedVersion, erkannt $($receipt.productName)"
    }

    $expectedEditionPattern = switch -Regex ([string]$build.operatingSystem.edition) {
        '^standard-evaluation$'   { '^ServerStandardEval'; break }
        '^datacenter-evaluation$' { '^ServerDatacenterEval'; break }
        default { throw "HYPERV_IMAGE_INSTALLATION_EDITION_UNSUPPORTED: $($build.operatingSystem.edition)" }
    }
    if ([string]$receipt.editionId -notmatch $expectedEditionPattern) {
        throw "HYPERV_IMAGE_INSTALLATION_EDITION_MISMATCH: erwartet $($build.operatingSystem.edition), erkannt $($receipt.editionId)"
    }

    $detectedInstallationType = switch ([string]$receipt.installationType) {
        'Server Core' { 'core' }
        'Server'      { 'desktop-experience' }
        default { throw "HYPERV_IMAGE_INSTALLATION_TYPE_UNKNOWN: $($receipt.installationType)" }
    }
    $requestedInstallationType = [string]$build.operatingSystem.installationType
    $metadataAdjusted = $false
    if ($detectedInstallationType -ne $requestedInstallationType) {
        if (-not $AcceptDetectedInstallationType) {
            throw "HYPERV_IMAGE_INSTALLATION_TYPE_MISMATCH: erwartet $requestedInstallationType, erkannt $detectedInstallationType"
        }
        $build.operatingSystem.installationType = $detectedInstallationType
        $metadataAdjusted = $true
    }

    $evidence = [PSCustomObject]@{
        contractVersion = '1'
        verified = $true
        productName = [string]$receipt.productName
        editionId = [string]$receipt.editionId
        installationType = $detectedInstallationType
        requestedInstallationType = $requestedInstallationType
        metadataAdjusted = $metadataAdjusted
        currentBuild = [string]$receipt.currentBuild
        displayVersion = [string]$receipt.displayVersion
        computerName = [string]$receipt.computerName
        observedAt = [string]$receipt.observedAt
        acceptedAt = Get-LabTimestamp
    }
    $build | Add-Member -NotePropertyName installationEvidence -NotePropertyValue $evidence -Force
    Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
}

function Start-HyperVWindowsImageBuildVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [string]$StateRoot
    )

    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
    if ($build.state -notin @('BUILDER_READY', 'MANUAL_ACTION_REQUIRED')) {
        throw 'HYPERV_IMAGE_BUILD_VM_NOT_STARTABLE'
    }
    if (-not $build.builder -or -not $build.builder.vmName) {
        throw 'HYPERV_IMAGE_BUILD_VM_MISSING'
    }

    return Start-HyperVInstance `
        -VMName ([string]$build.builder.vmName) `
        -ExpectedRunId $BuildId `
        -ExpectedScopeId ([string]$build.scopeId)
}

function Remove-HyperVWindowsImageBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [string]$StateRoot
    )

    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
    $cleanup = Invoke-CleanupPlan `
        -RunDir $build.BuildDirectory `
        -ScopeId ([string]$build.scopeId)
    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    $build | Add-Member -NotePropertyName cleanupStatus -NotePropertyValue ([string]$cleanup.Status) -Force
    Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return [PSCustomObject]@{
        BuildId = $BuildId
        Status  = [string]$cleanup.Status
        Cleanup = $cleanup
        Build   = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    }
}

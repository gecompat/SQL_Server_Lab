<#
.SYNOPSIS
    Resumierbare Windows-Image-Builder-Grundlage fuer Hyper-V.
.DESCRIPTION
    Plant einen Build aus einem lokal verifizierten ISO und erzeugt einen
    isolierten Generation-2-Builder. OS-Installation und Generalisierung sind
    noch manuelle, explizit persistierte Schritte; dieser Slice veroeffentlicht
    daher noch kein OS_SEALED-Artifact.
#>

function Write-HyperVImageBuildState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildDirectory, [Parameter(Mandatory)]$State)
    $State.updatedAt = Get-LabTimestamp
    $serializable = $State | Select-Object * -ExcludeProperty BuildDirectory
    Write-LabArtifactJsonAtomic -Path (Join-Path $BuildDirectory 'build-state.json') -InputObject $serializable
}

function Get-HyperVImageBuildPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildId, [string]$StateRoot)
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    if ($BuildId -notmatch '^[a-f0-9-]{36}$') { throw 'HYPERV_IMAGE_BUILD_ID_INVALID' }
    $directory = Join-Path (Join-Path $StateRoot 'image-builds/hyperv') $BuildId
    $statePath = Join-Path $directory 'build-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $state | Add-Member -NotePropertyName BuildDirectory -NotePropertyValue $directory -Force
    return $state
}

function Set-HyperVImageBuildState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][ValidateSet('BUILDER_READY', 'MANUAL_ACTION_REQUIRED', 'RESUME_PENDING', 'FAILED')][string]$State,
        [Parameter(Mandatory)][string]$Reason,
        [string]$StateRoot
    )
    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
    $event = [PSCustomObject]@{ state = $State; timestamp = Get-LabTimestamp; reason = $Reason }
    $build.state = $State
    $build.stateHistory = @($build.stateHistory + $event)
    Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
}

function Test-WindowsInstallationIso {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($stream.Length -lt 32774) { return $false }
        $stream.Position = 32769
        $buffer = [byte[]]::new(5)
        $null = $stream.Read($buffer, 0, 5)
        return [System.Text.Encoding]::ASCII.GetString($buffer) -eq 'CD001'
    }
    finally { $stream.Dispose() }
}

function New-HyperVWindowsImageBuildPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
        [Parameter(Mandatory)][ValidateSet('windows-server-2022', 'windows-server-2025', 'synthetic-ci')][string]$OperatingSystemId,
        [Parameter(Mandatory)][string]$Edition,
        [ValidateSet('core', 'desktop-experience', 'synthetic')][string]$InstallationType = 'core',
        [string]$Language = 'en-US',
        [ValidateSet('licensed', 'evaluation', 'test-only')][string]$LicenseType,
        [ValidateRange(64MB, 1TB)][long]$OsDiskSizeBytes = 64GB,
        [string]$StateRoot
    )
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $resolvedIso = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).Path
    if ([System.IO.Path]::GetExtension($resolvedIso) -ne '.iso' -or -not (Test-WindowsInstallationIso -Path $resolvedIso)) {
        throw 'HYPERV_WINDOWS_MEDIA_INVALID'
    }
    $sha256 = (Get-FileHash -LiteralPath $resolvedIso -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha256 -ne $ExpectedSha256.ToLowerInvariant()) { throw 'HYPERV_WINDOWS_MEDIA_INTEGRITY_MISMATCH' }
    if ($OperatingSystemId -eq 'synthetic-ci' -and $LicenseType -ne 'test-only') { throw 'HYPERV_TEST_MEDIA_METADATA_INVALID' }
    if ($OperatingSystemId -ne 'synthetic-ci' -and $LicenseType -eq 'test-only') { throw 'HYPERV_TEST_MEDIA_METADATA_INVALID' }

    $buildId = New-LabGuid
    $buildRoot = Join-Path $StateRoot 'image-builds/hyperv'
    $buildDirectory = Join-Path $buildRoot $buildId
    New-Item -Path $buildDirectory -ItemType Directory -Force | Out-Null
    $scopeId = New-LabGuid
    $null = New-CleanupPlan -RunDir $buildDirectory -RunId $buildId -ScopeId $scopeId `
        -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-hyperv-builder'; provider = 'hyperv' })
    Write-LabArtifactJsonAtomic -Path (Join-Path $buildDirectory 'build-local.json') -InputObject ([PSCustomObject]@{
        isoPath = $resolvedIso
    })
    $timestamp = Get-LabTimestamp
    $state = [PSCustomObject]@{
        contractVersion = '1'; buildId = $buildId; scopeId = $scopeId; state = 'MEDIA_VERIFIED'
        stateHistory = @([PSCustomObject]@{ state = 'MEDIA_VERIFIED'; timestamp = $timestamp; reason = 'ISO SHA-256 und ISO-9660-Signatur verifiziert' })
        media = [PSCustomObject]@{ sha256 = $sha256; integrityOrigin = 'user-verified-local' }
        operatingSystem = [PSCustomObject]@{ id = $OperatingSystemId; edition = $Edition; installationType = $InstallationType; language = $Language; architecture = 'x64' }
        license = [PSCustomObject]@{ type = $LicenseType }
        resources = [PSCustomObject]@{ osDiskSizeBytes = $OsDiskSizeBytes }
        builder = $null; createdAt = $timestamp; updatedAt = $timestamp
    }
    Write-HyperVImageBuildState -BuildDirectory $buildDirectory -State $state
    return Get-HyperVImageBuildPlan -BuildId $buildId -StateRoot $StateRoot
}

function New-HyperVWindowsImageBuilder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [ValidateRange(512MB, 1TB)][long]$MemoryStartupBytes = 2GB,
        [ValidateRange(1, 64)][int]$ProcessorCount = 2,
        [string]$StateRoot
    )
    $availability = Test-HyperVAvailable
    if (-not $availability.Available) { throw "Hyper-V nicht verfuegbar: $($availability.Message)" }
    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build -or $build.state -ne 'MEDIA_VERIFIED') { throw 'HYPERV_IMAGE_BUILD_NOT_READY' }
    $local = Get-Content -LiteralPath (Join-Path $build.BuildDirectory 'build-local.json') -Raw | ConvertFrom-Json
    $resourceRoot = Join-Path (Join-Path $build.BuildDirectory 'resources') 'hyperv'
    $vmName = "sql-lab-image-builder-$($BuildId.Replace('-', '').Substring(0, 8))"
    $diskPath = Join-Path $resourceRoot "$vmName.vhdx"

    $null = Add-CleanupStep -RunDir $build.BuildDirectory -ResourceType vhdx -ResourceId $diskPath -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv-builder -Compensation 'Remove builder OS VHDX'
    $null = Add-CleanupStep -RunDir $build.BuildDirectory -ResourceType vm -ResourceId $vmName -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv-builder -Compensation 'Remove Hyper-V image builder'
    New-Item -Path $resourceRoot -ItemType Directory -Force | Out-Null
    $null = New-VHD -Path $diskPath -Dynamic -SizeBytes ([long]$build.resources.osDiskSizeBytes) -ErrorAction Stop
    # Use the host's default VM configuration root. The build directory can be
    # deeply nested and Hyper-V rejects long Smart Paging paths before the VM
    # can be tagged for deterministic cleanup.
    $vm = New-VM -Name $vmName -Generation 2 -MemoryStartupBytes $MemoryStartupBytes -VHDPath $diskPath -ErrorAction Stop
    # Mark the VM immediately so cleanup can identify it even when later setup fails.
    $notes = ConvertTo-HyperVLabNotes -RunId $BuildId -ScopeId $build.scopeId -InstanceId image-builder -ChildVhdxPath $diskPath
    $null = Set-VM -VM $vm -Notes $notes -ErrorAction Stop
    @($vm | Get-VMNetworkAdapter -ErrorAction Stop) | Remove-VMNetworkAdapter -ErrorAction Stop
    $null = Set-VMProcessor -VM $vm -Count $ProcessorCount -ErrorAction Stop
    $null = Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -ErrorAction Stop
    $dvd = Add-VMDvdDrive -VM $vm -Path ([string]$local.isoPath) -Passthru -ErrorAction Stop
    $null = Set-VMFirmware -VM $vm -FirstBootDevice $dvd -ErrorAction Stop

    $build.builder = [PSCustomObject]@{ vmName = $vmName; osDiskRelativePath = "resources/hyperv/$vmName.vhdx"; generation = 2; secureBoot = $true }
    Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Set-HyperVImageBuildState -BuildId $BuildId -State BUILDER_READY -Reason 'Generation-2-Builder mit verifiziertem Installationsmedium erstellt' -StateRoot $StateRoot
}

function Set-HyperVImageBuildManualAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildId, [string]$StateRoot)
    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build -or $build.state -ne 'BUILDER_READY') { throw 'HYPERV_IMAGE_BUILD_NOT_READY' }
    return Set-HyperVImageBuildState -BuildId $BuildId -State MANUAL_ACTION_REQUIRED `
        -Reason 'OS-Installation und Generalisierung muessen abgeschlossen und technisch verifiziert werden' -StateRoot $StateRoot
}

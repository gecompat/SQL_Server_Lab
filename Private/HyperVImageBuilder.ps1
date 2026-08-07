<#
.SYNOPSIS
    Resumierbare Windows-Image-Builder-Grundlage fuer Hyper-V.
.DESCRIPTION
    Plant einen Build aus einem lokal verifizierten ISO und erzeugt einen
    isolierten Generation-2-Builder. OS-Installation und Generalisierung sind
    noch manuelle, explizit persistierte Schritte. Die Fortsetzung akzeptiert
    buildgebundene Evidenz und veroeffentlicht erst nach Host-Postconditions ein
    immutable OS_SEALED- beziehungsweise test-only-Artifact.
#>

function Write-HyperVImageBuildState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildDirectory, [Parameter(Mandatory)]$State)
    $State.updatedAt = Get-LabTimestamp
    $serializable = $State | Select-Object * -ExcludeProperty BuildDirectory
    Write-LabArtifactJsonAtomic -Path (Join-Path $BuildDirectory 'build-state.json') -InputObject $serializable
}

function ConvertTo-HyperVImageDateTimeOffset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Value,
        [string]$ErrorId = 'HYPERV_IMAGE_TIMESTAMP_INVALID'
    )

    try {
        if ($Value -is [datetimeoffset]) {
            return [datetimeoffset]$Value
        }
        if ($Value -is [datetime]) {
            $dateTime = [datetime]$Value
            if ($dateTime.Kind -eq [DateTimeKind]::Unspecified) {
                $dateTime = [datetime]::SpecifyKind($dateTime, [DateTimeKind]::Utc)
            }
            return [datetimeoffset]::new($dateTime)
        }
        if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
            throw 'timestamp value is empty or has an unsupported type'
        }
        return [System.Xml.XmlConvert]::ToDateTimeOffset([string]$Value)
    }
    catch {
        throw $ErrorId
    }
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
        [Parameter(Mandatory)][ValidateSet('BUILDER_READY', 'MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED', 'RESUME_PENDING', 'OS_SEALED', 'TEST_ARTIFACT_PUBLISHED', 'FAILED', 'CLEANED_UP')][string]$State,
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
        [Parameter(Mandatory)][string]$OperatingSystemId,
        [Parameter(Mandatory)][string]$Edition,
        [ValidateSet('core', 'desktop-experience', 'synthetic')][string]$InstallationType = 'core',
        [string]$Language = 'en-US',
        [Parameter(Mandatory)][ValidateSet('licensed', 'evaluation', 'test-only')][string]$LicenseType,
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
        builder = $null; manualAction = $null; generalizationRequest = $null; generalizationEvidence = $null
        sealPostconditions = $null; artifact = $null; cleanupStatus = $null
        createdAt = $timestamp; updatedAt = $timestamp
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
    # Do not inherit Hyper-V's unbounded dynamic-memory default (commonly 1 TB).
    $null = Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -MinimumBytes 512MB `
        -StartupBytes $MemoryStartupBytes -MaximumBytes $MemoryStartupBytes -ErrorAction Stop
    # Mark the VM immediately so cleanup can identify it even when later setup fails.
    $notes = ConvertTo-HyperVLabNotes -RunId $BuildId -ScopeId $build.scopeId -InstanceId image-builder -ChildVhdxPath $diskPath
    $null = Set-VM -VM $vm -Notes $notes -AutomaticCheckpointsEnabled $false -ErrorAction Stop
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
    if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
    if ($build.state -eq 'MANUAL_ACTION_REQUIRED') { return $build }
    if ($build.state -ne 'BUILDER_READY') { throw 'HYPERV_IMAGE_BUILD_NOT_READY' }
    $manualAction = [PSCustomObject]@{
        stepId = 'install-and-generalize-windows'
        challenge = New-LabGuid
        requiredPostconditions = @('sysprep-generalize-succeeded', 'oobe-ready', 'vm-shutdown-observed')
        allowedNextActions = @('invoke-powershell-direct-sysprep', 'submit-generalization-evidence', 'cleanup')
        requestedAt = Get-LabTimestamp
    }
    $build | Add-Member -NotePropertyName manualAction -NotePropertyValue $manualAction -Force
    Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Set-HyperVImageBuildState -BuildId $BuildId -State MANUAL_ACTION_REQUIRED `
        -Reason 'OS-Installation und Generalisierung muessen abgeschlossen und technisch verifiziert werden' -StateRoot $StateRoot
}

function Submit-HyperVImageGeneralizationEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
        [string]$StateRoot
    )

    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
    if ($build.state -notin @('MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED', 'RESUME_PENDING')) {
        throw 'HYPERV_IMAGE_BUILD_NOT_WAITING_FOR_EVIDENCE'
    }
    if (-not $build.manualAction -or -not $build.manualAction.challenge) {
        throw 'HYPERV_IMAGE_BUILD_CHALLENGE_MISSING'
    }

    $resolvedEvidence = (Resolve-Path -LiteralPath $EvidencePath -ErrorAction Stop).Path
    if ((Get-Item -LiteralPath $resolvedEvidence -Force).Length -gt 64KB) {
        throw 'HYPERV_GENERALIZATION_EVIDENCE_TOO_LARGE'
    }
    $submittedSha256 = (Get-FileHash -LiteralPath $resolvedEvidence -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($submittedSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
        throw 'HYPERV_GENERALIZATION_EVIDENCE_INTEGRITY_MISMATCH'
    }
    try {
        $evidence = Get-Content -LiteralPath $resolvedEvidence -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    }
    catch { throw 'HYPERV_GENERALIZATION_EVIDENCE_INVALID_JSON' }

    $synthetic = [string]$build.operatingSystem.id -eq 'synthetic-ci'
    $expectedKind = if ($synthetic) { 'synthetic-ci-generalize' } else { 'windows-sysprep-generalize' }
    $allowedSources = if ($synthetic) { @('synthetic-test') } else { @('powershell-direct', 'offline-inspection') }
    if ([string]$evidence.contractVersion -ne '1' -or
        [string]$evidence.buildId -ne [string]$build.buildId -or
        [string]$evidence.scopeId -ne [string]$build.scopeId -or
        [string]$evidence.challenge -ne [string]$build.manualAction.challenge -or
        [string]$evidence.kind -ne $expectedKind -or
        [string]$evidence.source -notin $allowedSources -or
        $evidence.checks.sysprepGeneralizeSucceeded -ne $true -or
        $evidence.checks.oobeReady -ne $true -or
        $evidence.checks.shutdownObserved -ne $true) {
        throw 'HYPERV_GENERALIZATION_EVIDENCE_POSTCONDITION_FAILED'
    }
    $completedAt = ConvertTo-HyperVImageDateTimeOffset -Value $evidence.completedAt `
        -ErrorId 'HYPERV_GENERALIZATION_EVIDENCE_TIMESTAMP_INVALID'
    $requestedAt = ConvertTo-HyperVImageDateTimeOffset -Value $build.manualAction.requestedAt `
        -ErrorId 'HYPERV_GENERALIZATION_EVIDENCE_TIMESTAMP_INVALID'
    if ($completedAt.UtcDateTime -gt [datetime]::UtcNow.AddMinutes(5) -or
        $completedAt.UtcDateTime -lt $requestedAt.UtcDateTime.AddMinutes(-5)) {
        throw 'HYPERV_GENERALIZATION_EVIDENCE_TIMESTAMP_INVALID'
    }

    $evidenceDirectory = Join-Path $build.BuildDirectory 'evidence'
    New-Item -Path $evidenceDirectory -ItemType Directory -Force | Out-Null
    $sanitizedEvidence = [PSCustomObject]@{
        contractVersion = '1'; buildId = [string]$build.buildId; scopeId = [string]$build.scopeId
        challenge = [string]$build.manualAction.challenge; kind = $expectedKind; source = [string]$evidence.source
        completedAt = $completedAt.ToUniversalTime().ToString('o')
        checks = [PSCustomObject]@{
            sysprepGeneralizeSucceeded = $true; oobeReady = $true; shutdownObserved = $true
        }
    }
    $storedPath = Join-Path $evidenceDirectory 'generalization.json'
    Write-LabArtifactJsonAtomic -Path $storedPath -InputObject $sanitizedEvidence
    $storedSha256 = (Get-FileHash -LiteralPath $storedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $summary = [PSCustomObject]@{
        relativePath = 'evidence/generalization.json'; submittedSha256 = $submittedSha256
        storedSha256 = $storedSha256; kind = $expectedKind; source = [string]$evidence.source
        completedAt = $completedAt.ToUniversalTime().ToString('o'); acceptedAt = Get-LabTimestamp
    }
    $build | Add-Member -NotePropertyName generalizationEvidence -NotePropertyValue $summary -Force
    Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Set-HyperVImageBuildState -BuildId $BuildId -State RESUME_PENDING `
        -Reason 'Buildgebundene Generalisierungsevidenz akzeptiert; Host-Postconditions stehen aus' -StateRoot $StateRoot
}

function Submit-HyperVPowerShellDirectGeneralizationEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Build,
        [string]$StateRoot
    )

    if (-not $Build.generalizationRequest -or
        [string]$Build.generalizationRequest.challenge -ne [string]$Build.manualAction.challenge -or
        [string]$Build.generalizationRequest.sysprepExitCode -ne '0' -or
        [string]$Build.generalizationRequest.imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
        throw 'HYPERV_SYSPREP_REQUEST_NOT_RESUMABLE'
    }
    $completedAt = ConvertTo-HyperVImageDateTimeOffset -Value $Build.generalizationRequest.completedAt `
        -ErrorId 'HYPERV_GENERALIZATION_EVIDENCE_TIMESTAMP_INVALID'
    $evidenceDirectory = Join-Path $Build.BuildDirectory 'evidence'
    New-Item -Path $evidenceDirectory -ItemType Directory -Force | Out-Null
    $submissionPath = Join-Path $evidenceDirectory 'powershell-direct-submission.json'
    $submission = [PSCustomObject]@{
        contractVersion = '1'; buildId = [string]$Build.buildId; scopeId = [string]$Build.scopeId
        challenge = [string]$Build.manualAction.challenge; kind = 'windows-sysprep-generalize'
        source = 'powershell-direct'; completedAt = $completedAt.ToUniversalTime().ToString('o')
        checks = [PSCustomObject]@{
            sysprepGeneralizeSucceeded = $true; oobeReady = $true; shutdownObserved = $true
        }
    }
    Write-LabArtifactJsonAtomic -Path $submissionPath -InputObject $submission
    $submissionSha256 = (Get-FileHash -LiteralPath $submissionPath -Algorithm SHA256).Hash
    return Submit-HyperVImageGeneralizationEvidence -BuildId ([string]$Build.buildId) `
        -EvidencePath $submissionPath -ExpectedSha256 $submissionSha256 -StateRoot $StateRoot
}

function Repair-HyperVWindowsImageGeneralizationEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [string]$StateRoot
    )

    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
    if ($build.state -ne 'RESUME_PENDING' -or
        -not $build.generalizationEvidence -or
        [string]$build.generalizationEvidence.source -ne 'powershell-direct') {
        throw 'HYPERV_GENERALIZATION_EVIDENCE_NOT_REPAIRABLE'
    }
    return Submit-HyperVPowerShellDirectGeneralizationEvidence -Build $build -StateRoot $StateRoot
}

function Invoke-HyperVWindowsImageGeneralization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [PSCredential]$Credential,
        [ValidateRange(30, 1800)][int]$ShutdownTimeoutSeconds = 300,
        [string]$StateRoot
    )

    $availability = Test-HyperVAvailable
    if (-not $availability.Available) { throw "Hyper-V nicht verfuegbar: $($availability.Message)" }
    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
    if ([string]$build.operatingSystem.id -eq 'synthetic-ci') {
        throw 'HYPERV_SYSPREP_NOT_ALLOWED_FOR_TEST_MEDIA'
    }
    if (-not $build.PSObject.Properties['installationEvidence'] -or
        -not $build.installationEvidence -or
        $build.installationEvidence.verified -ne $true -or
        [string]$build.installationEvidence.installationType -ne [string]$build.operatingSystem.installationType) {
        throw 'HYPERV_IMAGE_INSTALLATION_NOT_VERIFIED'
    }
    if ($build.state -notin @('MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED')) {
        throw 'HYPERV_IMAGE_BUILD_NOT_READY_FOR_SYSPREP'
    }

    if ($build.state -eq 'MANUAL_ACTION_REQUIRED') {
        if (-not $Credential) { throw 'HYPERV_GUEST_CREDENTIAL_REQUIRED' }
        $vmName = [string]$build.builder.vmName
        $receipt = Invoke-HyperVPowerShellDirect -VMName $vmName -ExpectedRunId $BuildId `
            -ExpectedScopeId ([string]$build.scopeId) -Credential $Credential -ArgumentList @(
                [string]$build.buildId,
                [string]$build.scopeId,
                [string]$build.manualAction.challenge
            ) -ScriptBlock {
                param($ExpectedBuildId, $ExpectedScopeId, $ExpectedChallenge)
                $ErrorActionPreference = 'Stop'
                $sysprepPath = Join-Path $env:WINDIR 'System32\Sysprep\Sysprep.exe'
                if (-not (Test-Path -LiteralPath $sysprepPath -PathType Leaf)) {
                    throw 'SYSPREP_EXECUTABLE_NOT_FOUND'
                }
                $process = Start-Process -FilePath $sysprepPath `
                    -ArgumentList @('/generalize', '/oobe', '/mode:vm', '/quit', '/quiet') `
                    -Wait -PassThru -ErrorAction Stop
                if ($process.ExitCode -ne 0) { throw "SYSPREP_EXIT_CODE_$($process.ExitCode)" }
                $imageState = [string](Get-ItemProperty `
                    -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' `
                    -Name ImageState -ErrorAction Stop).ImageState
                if ($imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
                    throw "SYSPREP_IMAGE_STATE_INVALID_$imageState"
                }
                & (Join-Path $env:WINDIR 'System32\shutdown.exe') /s /t 30 /f /d p:4:1 /c 'SQL_Server_Lab image sealing'
                if ($LASTEXITCODE -ne 0) { throw "SYSPREP_SHUTDOWN_SCHEDULE_FAILED_$LASTEXITCODE" }
                [PSCustomObject]@{
                    contractVersion = '1'; buildId = $ExpectedBuildId; scopeId = $ExpectedScopeId
                    challenge = $ExpectedChallenge; imageState = $imageState; sysprepExitCode = $process.ExitCode
                    guestComputerName = $env:COMPUTERNAME; guestObservedAt = [datetime]::UtcNow.ToString('o')
                    shutdownDelaySeconds = 30
                }
            }
        $receipt = @($receipt)[-1]
        if (-not $receipt -or
            [string]$receipt.contractVersion -ne '1' -or
            [string]$receipt.buildId -ne [string]$build.buildId -or
            [string]$receipt.scopeId -ne [string]$build.scopeId -or
            [string]$receipt.challenge -ne [string]$build.manualAction.challenge -or
            [string]$receipt.sysprepExitCode -ne '0' -or
            [string]$receipt.imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' -or
            -not [string]$receipt.guestComputerName -or
            -not [string]$receipt.guestObservedAt) {
            throw 'HYPERV_SYSPREP_RECEIPT_INVALID'
        }
        $request = [PSCustomObject]@{
            contractVersion = '1'; challenge = [string]$receipt.challenge
            imageState = [string]$receipt.imageState; sysprepExitCode = [int]$receipt.sysprepExitCode
            guestComputerName = [string]$receipt.guestComputerName
            guestObservedAt = [string]$receipt.guestObservedAt; completedAt = Get-LabTimestamp
            shutdownDelaySeconds = [int]$receipt.shutdownDelaySeconds; status = 'SHUTDOWN_PENDING'
        }
        $build | Add-Member -NotePropertyName generalizationRequest -NotePropertyValue $request -Force
        Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
        $build = Set-HyperVImageBuildState -BuildId $BuildId -State REBOOT_REQUIRED `
            -Reason 'Sysprep-Generalize erfolgreich; geplanter Gast-Shutdown wird beobachtet' -StateRoot $StateRoot
    }

    if (-not $build.generalizationRequest -or
        [string]$build.generalizationRequest.challenge -ne [string]$build.manualAction.challenge -or
        [string]$build.generalizationRequest.sysprepExitCode -ne '0' -or
        [string]$build.generalizationRequest.imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
        throw 'HYPERV_SYSPREP_REQUEST_NOT_RESUMABLE'
    }

    $deadline = [datetime]::UtcNow.AddSeconds($ShutdownTimeoutSeconds)
    do {
        $managed = Get-HyperVManagedVM -VMName ([string]$build.builder.vmName) `
            -ExpectedRunId $BuildId -ExpectedScopeId ([string]$build.scopeId)
        if (-not $managed) { throw 'HYPERV_IMAGE_BUILD_VM_MISSING_DURING_SHUTDOWN' }
        if ([string]$managed.VM.State -eq 'Off') { break }
        Start-Sleep -Seconds 2
    } while ([datetime]::UtcNow -lt $deadline)
    if ([string]$managed.VM.State -ne 'Off') { throw 'HYPERV_IMAGE_BUILD_SHUTDOWN_TIMEOUT' }

    return Submit-HyperVPowerShellDirectGeneralizationEvidence -Build $build -StateRoot $StateRoot
}

function Publish-HyperVWindowsImageBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Nullable[datetime]]$EvaluationExpiresAt,
        [string]$StateRoot
    )

    $availability = Test-HyperVAvailable
    if (-not $availability.Available) { throw "Hyper-V nicht verfuegbar: $($availability.Message)" }
    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
    if ($build.state -in @('OS_SEALED', 'TEST_ARTIFACT_PUBLISHED')) {
        $existingArtifact = Get-HyperVImageArtifact -ArtifactId ([string]$build.artifact.artifactId) -StateRoot $StateRoot
        if (-not $existingArtifact) { throw 'HYPERV_IMAGE_BUILD_ARTIFACT_MISSING' }
        $existingCleanup = $null
        if ([string]$build.cleanupStatus -ne 'CLEANUP_SUCCEEDED') {
            $existingCleanup = Invoke-CleanupPlan -RunDir $build.BuildDirectory -ScopeId ([string]$build.scopeId)
            $build | Add-Member -NotePropertyName cleanupStatus -NotePropertyValue ([string]$existingCleanup.Status) -Force
            Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
        }
        return [PSCustomObject]@{ Status = [string]$build.state; Build = $build; Artifact = $existingArtifact; Cleanup = $existingCleanup }
    }
    if ($build.state -ne 'RESUME_PENDING' -or -not $build.generalizationEvidence) {
        throw 'HYPERV_IMAGE_BUILD_NOT_READY_TO_SEAL'
    }

    if ([string]$build.generalizationEvidence.relativePath -ne 'evidence/generalization.json') {
        throw 'HYPERV_GENERALIZATION_EVIDENCE_PATH_INVALID'
    }
    $evidencePath = Join-Path $build.BuildDirectory ([string]$build.generalizationEvidence.relativePath)
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$build.generalizationEvidence.storedSha256) {
        throw 'HYPERV_GENERALIZATION_EVIDENCE_INTEGRITY_MISMATCH'
    }
    $diskPath = Join-Path $build.BuildDirectory ([string]$build.builder.osDiskRelativePath)
    if (-not (Test-HyperVPathWithinRunDirectory -Path $diskPath -RunDirectory $build.BuildDirectory) -or
        -not (Test-Path -LiteralPath $diskPath -PathType Leaf)) {
        throw 'HYPERV_IMAGE_BUILD_DISK_SCOPE_INVALID'
    }
    if (-not (Test-HyperVVhdxSignature -Path $diskPath)) { throw 'HYPERV_ARTIFACT_NOT_VHDX' }
    $synthetic = [string]$build.operatingSystem.id -eq 'synthetic-ci'
    if (-not $synthetic -and [string]$build.license.type -eq 'evaluation' -and -not $EvaluationExpiresAt) {
        throw 'HYPERV_EVALUATION_EXPIRY_REQUIRED'
    }

    $managed = Get-HyperVManagedVM -VMName ([string]$build.builder.vmName) `
        -ExpectedRunId $BuildId -ExpectedScopeId ([string]$build.scopeId)
    if ($managed) {
        if ([string]$managed.VM.State -ne 'Off') { throw 'HYPERV_IMAGE_BUILD_VM_MUST_BE_OFF' }
        if (@(Get-VMSnapshot -VM $managed.VM -ErrorAction Stop).Count -gt 0) {
            throw 'HYPERV_IMAGE_BUILD_CHECKPOINTS_PRESENT'
        }
        if (-not ([System.IO.Path]::GetFullPath([string]$managed.Identity.childVhdxPath).Equals(
            [System.IO.Path]::GetFullPath($diskPath), [System.StringComparison]::OrdinalIgnoreCase))) {
            throw 'HYPERV_IMAGE_BUILD_DISK_IDENTITY_MISMATCH'
        }
        $postconditions = [PSCustomObject]@{
            identityValidated = $true; vmOff = $true; checkpointsAbsent = $true; validatedAt = Get-LabTimestamp
        }
        $build | Add-Member -NotePropertyName sealPostconditions -NotePropertyValue $postconditions -Force
        Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    }
    elseif (-not $build.sealPostconditions -or
        $build.sealPostconditions.identityValidated -ne $true -or
        $build.sealPostconditions.vmOff -ne $true -or
        $build.sealPostconditions.checkpointsAbsent -ne $true) {
        throw 'HYPERV_IMAGE_BUILD_VM_IDENTITY_NOT_VERIFIED'
    }

    (Get-Item -LiteralPath $diskPath -Force).IsReadOnly = $true
    $sha256 = (Get-FileHash -LiteralPath $diskPath -Algorithm SHA256).Hash
    $osVersion = if ($synthetic) { '1' } else { ([string]$build.operatingSystem.id -replace '^windows-(server-)?', '') }
    $importParameters = @{
        VhdxPath = $diskPath; ExpectedSha256 = $sha256
        ArtifactState = if ($synthetic) { 'LIFECYCLE_TEST_ONLY' } else { 'OS_SEALED' }
        OperatingSystemId = [string]$build.operatingSystem.id; OperatingSystemVersion = $osVersion
        Edition = [string]$build.operatingSystem.edition; InstallationType = [string]$build.operatingSystem.installationType
        Language = [string]$build.operatingSystem.language; LicenseType = [string]$build.license.type
        IntegrityOrigin = if ($synthetic) { 'synthetic-test' } else { 'generated-by-runtime' }
        EvaluationExpiresAt = $EvaluationExpiresAt; StateRoot = $StateRoot
    }
    if (-not $synthetic) { $importParameters.Generalized = $true }
    $artifact = Import-HyperVImageArtifact @importParameters
    if (-not $artifact -or
        [string]::IsNullOrWhiteSpace([string]$artifact.artifactId) -or
        [string]$artifact.sha256 -ne $sha256.ToLowerInvariant() -or
        [string]$artifact.artifactState -ne [string]$importParameters.ArtifactState) {
        throw 'HYPERV_IMAGE_ARTIFACT_PUBLICATION_FAILED'
    }
    # The immutable registry copy is complete and hash-verified before the
    # builder VM or its source VHDX can be removed.
    $managed = Get-HyperVManagedVM -VMName ([string]$build.builder.vmName) `
        -ExpectedRunId $BuildId -ExpectedScopeId ([string]$build.scopeId)
    if ($managed) {
        $null = Remove-HyperVInstance -VMName ([string]$build.builder.vmName) `
            -ExpectedScopeId ([string]$build.scopeId) -ExpectedRunDirectory $build.BuildDirectory `
            -PreserveVhdx -RequireOff
    }
    $artifactSummary = [PSCustomObject]@{
        artifactId = [string]$artifact.artifactId; artifactState = [string]$artifact.artifactState
        sha256 = [string]$artifact.sha256; publishedAt = Get-LabTimestamp
    }
    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    $build | Add-Member -NotePropertyName artifact -NotePropertyValue $artifactSummary -Force
    Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    $finalState = if ($synthetic) { 'TEST_ARTIFACT_PUBLISHED' } else { 'OS_SEALED' }
    $build = Set-HyperVImageBuildState -BuildId $BuildId -State $finalState `
        -Reason 'Immutable VHDX nach Evidenz- und Host-Postconditions in Registry veroeffentlicht' -StateRoot $StateRoot
    $cleanup = Invoke-CleanupPlan -RunDir $build.BuildDirectory -ScopeId ([string]$build.scopeId)
    $build | Add-Member -NotePropertyName cleanupStatus -NotePropertyValue ([string]$cleanup.Status) -Force
    Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return [PSCustomObject]@{ Status = $finalState; Build = $build; Artifact = $artifact; Cleanup = $cleanup }
}

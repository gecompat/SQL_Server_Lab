<#
.SYNOPSIS
    Resumierbare Windows-Image-Builder-Grundlage fuer Hyper-V.
.DESCRIPTION
    Plant einen Build aus einem lokal verifizierten ISO und erzeugt einen
    isolierten, versionsgerecht als Generation 1 oder 2 angelegten Builder.
    OS-Installation und Generalisierung sind
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

function Resolve-HyperVMutationStateRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateDirectory, [string]$StateRoot)
    $directory = [IO.Path]::GetFullPath($StateDirectory)
    $parent = Split-Path -Parent $directory
    if ((Split-Path -Leaf $parent) -in @('hyperv', 'hyperv-sql') -and
        (Split-Path -Leaf (Split-Path -Parent $parent)) -eq 'image-builds') {
        $derived = Split-Path -Parent (Split-Path -Parent $parent)
    }
    elseif ((Split-Path -Leaf $parent) -eq 'runs') { $derived = Split-Path -Parent $parent }
    else { throw 'HYPERV_MUTATION_STATE_LAYOUT_INVALID' }
    $root = Resolve-LabWindowsPoolRoot -StateRoot $derived
    if ($StateRoot -and $root -cne (Resolve-LabWindowsPoolRoot -StateRoot $StateRoot)) {
        throw 'HYPERV_BUILD_STATE_ROOT_MISMATCH'
    }
    if (-not (Test-LabPathWithinRoot -Root $root -Path $directory).Valid) { throw 'HYPERV_BUILD_STATE_PATH_INVALID' }
    return $root
}

function Get-HyperVBuildMutationContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildDirectory, [string]$StateRoot, [string]$ExpectedScopeId,
        [switch]$BeforeCreation)
    $root = Resolve-HyperVMutationStateRoot -StateDirectory $BuildDirectory -StateRoot $StateRoot
    $directory = [IO.Path]::GetFullPath($BuildDirectory)
    $kind = Split-Path -Leaf (Split-Path -Parent $directory)
    if ($kind -notin @('hyperv', 'hyperv-sql')) { throw 'HYPERV_BUILD_STATE_LAYOUT_INVALID' }
    $id = Split-Path -Leaf $directory
    if ($id -notmatch '^[a-f0-9-]{36}$') { throw 'HYPERV_IMAGE_BUILD_ID_INVALID' }
    # A build record can never replace run/pool membership in the selected root.
    if (Test-Path -LiteralPath (Join-Path $root "runs/$id/run-state.json")) { throw 'HYPERV_BUILD_RUN_AUTHORITY_CONFLICT' }
    foreach ($leaf in @('build-state.json', 'cleanup-plan.json', 'hyperv-resource-binding.local.json')) {
        $path = Join-Path $directory $leaf
        if (-not (Test-LabPathWithinRoot -Root $root -Path $path).Valid -or
            -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'HYPERV_BUILD_AUTHORITY_FILE_INVALID' }
    }
    $build = Read-LabWorkflowJson -Path (Join-Path $directory 'build-state.json')
    $plan = Read-LabWorkflowJson -Path (Join-Path $directory 'cleanup-plan.json')
    $rawBinding = Read-LabWorkflowJson -Path (Join-Path $directory 'hyperv-resource-binding.local.json')
    $binding = Read-LabHyperVResourceBinding -StateDirectory $directory -DataRoot ([string]$rawBinding.LabDataRoot)
    if ($build.buildId -cne $id -or -not $build.scopeId -or
        ($ExpectedScopeId -and $build.scopeId -cne $ExpectedScopeId) -or
        $binding.ResourceClass -cne 'Build' -or $binding.ResourceId -cne $id -or
        $plan.runId -cne $id -or $plan.scopeId -cne $build.scopeId) { throw 'HYPERV_BUILD_AUTHORITY_BINDING_INVALID' }
    if (-not $BeforeCreation -and ($build.builder.nativeBindingContract -cne 'SqlServerLab.HyperVBuildNative/1.0' -or
        -not $build.builder.vmId -or -not $build.builder.vmName -or -not $build.builder.instanceId)) {
        throw 'HYPERV_BUILD_NATIVE_BINDING_REQUIRED'
    }
    if (-not $BeforeCreation) {
        $nativeId = [guid]::Empty
        if (-not [guid]::TryParse([string]$build.builder.vmId, [ref]$nativeId) -or $nativeId -eq [guid]::Empty) { throw 'HYPERV_BUILD_NATIVE_BINDING_REQUIRED' }
        # Notes may have lost both the pool hint and the original run ID.
        # Independently recorded membership by native ID still takes precedence.
        $runsRoot=Join-Path $root 'runs'
        if (Test-Path -LiteralPath $runsRoot -PathType Container) {
            foreach ($entry in @(Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction Stop)) {
                $memberPath=Join-Path $entry.FullName 'run-state.json'
                if (-not (Test-LabPathWithinRoot -Root $root -Path $memberPath).Valid) { throw 'HYPERV_BUILD_POOL_MEMBERSHIP_UNKNOWN' }
                if (-not (Test-Path -LiteralPath $memberPath -PathType Leaf)) { continue }
                try { $memberRun=Read-LabWorkflowJson -Path $memberPath }
                catch { throw 'HYPERV_BUILD_POOL_MEMBERSHIP_UNKNOWN' }
                if ($memberRun.metadata.windowsPoolMember) {
                    try { $null=Assert-LabWindowsPoolMember -Run $memberRun }
                    catch { throw 'HYPERV_BUILD_POOL_MEMBERSHIP_UNKNOWN' }
                }
                $memberId=[guid]::Empty
                if ($memberRun.metadata.windowsPoolMember.vmId -and
                    [guid]::TryParse([string]$memberRun.metadata.windowsPoolMember.vmId,[ref]$memberId) -and $memberId -eq $nativeId) {
                    throw 'HYPERV_BUILD_POOL_AUTHORITY_CONFLICT'
                }
                $connectionPath=Join-Path $entry.FullName 'connection-info.json'
                if (-not (Test-LabPathWithinRoot -Root $root -Path $connectionPath).Valid) { throw 'HYPERV_BUILD_RUN_MEMBERSHIP_UNKNOWN' }
                if (Test-Path -LiteralPath $connectionPath -PathType Leaf) {
                    try { $connection=Read-LabWorkflowJson -Path $connectionPath }
                    catch { throw 'HYPERV_BUILD_RUN_MEMBERSHIP_UNKNOWN' }
                    foreach ($instance in @($connection.instances | Where-Object { $_.provider -ceq 'hyperv' })) {
                        $runVMId=[guid]::Empty
                        if ($instance.vmId -and [guid]::TryParse([string]$instance.vmId,[ref]$runVMId) -and $runVMId -eq $nativeId) {
                            throw 'HYPERV_BUILD_RUN_AUTHORITY_CONFLICT'
                        }
                    }
                }
            }
        }
    }
    return [pscustomobject]@{ StateRoot=$root; Directory=$directory; Build=$build; Plan=$plan; Binding=$binding; Kind=$kind }
}

function Set-HyperVBuildNativeBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildDirectory, [string]$StateRoot,
        [Parameter(Mandatory)]$VM, [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$ChildVhdxPath)
    try {
        $context = Get-HyperVBuildMutationContext -BuildDirectory $BuildDirectory -StateRoot $StateRoot -BeforeCreation
        $nativeId = [guid]::Parse([string]$VM.Id).ToString()
        if ($nativeId -eq [guid]::Empty.ToString() -or -not $VM.Name) { throw 'HYPERV_BUILD_NATIVE_ID_INVALID' }
        $null = Assert-LabHyperVBoundPath -Binding $context.Binding -Path $ChildVhdxPath -DataRoot $context.Binding.LabDataRoot
        $vmSteps = @($context.Plan.steps | Where-Object { $_.provider -ceq 'hyperv' -and $_.action -ceq 'remove' -and $_.resourceType -ceq 'vm' -and $_.resourceId -ceq [string]$VM.Name })
        $diskSteps = @($context.Plan.steps | Where-Object { $_.provider -ceq 'hyperv' -and $_.action -ceq 'remove' -and $_.resourceType -ceq 'vhdx' -and $_.resourceId -ceq $ChildVhdxPath })
        if ($vmSteps.Count -ne 1 -or $diskSteps.Count -ne 1 -or
            ($context.Build.builder.vmId -and [string]$context.Build.builder.vmId -cne $nativeId)) { throw 'HYPERV_BUILD_CREATION_INTENT_INVALID' }
        $context.Build.builder = [pscustomobject]@{ vmId=$nativeId; vmName=[string]$VM.Name; instanceId=$InstanceId;
            nativeBindingContract='SqlServerLab.HyperVBuildNative/1.0'; resourceRelativePath=[IO.Path]::GetRelativePath($context.Binding.HyperVResourceRoot, $ChildVhdxPath) }
        Write-HyperVImageBuildState -BuildDirectory $context.Directory -State $context.Build
        return $context.Build.builder
    }
    catch { throw 'HYPERV_BUILD_NATIVE_BINDING_PERSIST_FAILED_RECOVERY_REQUIRED' }
}

function Get-HyperVBuildBoundManagedVM {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $builder = $Context.Build.builder
    $expectedInstance = if ($Context.Kind -eq 'hyperv') { 'image-builder' } else { "sql-image-$($Context.Build.sql.version)" }
    if ($builder.instanceId -cne $expectedInstance) { throw 'HYPERV_BUILD_INSTANCE_BINDING_INVALID' }
    $disk = Join-Path $Context.Binding.HyperVResourceRoot ([string]$builder.resourceRelativePath)
    $null = Assert-LabHyperVBoundPath -Binding $Context.Binding -Path $disk -DataRoot $Context.Binding.LabDataRoot
    $vmSteps = @($Context.Plan.steps | Where-Object { $_.provider -ceq 'hyperv' -and $_.action -ceq 'remove' -and $_.resourceType -ceq 'vm' -and $_.resourceId -ceq $builder.vmName })
    $diskSteps = @($Context.Plan.steps | Where-Object { $_.provider -ceq 'hyperv' -and $_.action -ceq 'remove' -and $_.resourceType -ceq 'vhdx' -and $_.resourceId -ceq $disk })
    if ($vmSteps.Count -ne 1 -or $diskSteps.Count -ne 1) { throw 'HYPERV_BUILD_CLEANUP_INTENT_INVALID' }
    # A failed native read is never absence. Names only detect collisions; ID is authority.
    $all = @(Get-VM -ErrorAction Stop)
    $matches = @($all | Where-Object { [string]$_.Id -ceq [string]$builder.vmId })
    $names = @($all | Where-Object { [string]$_.Name -ceq [string]$builder.vmName })
    if ($matches.Count -eq 0 -and $names.Count -eq 0) { return $null }
    if ($matches.Count -ne 1 -or $names.Count -ne 1 -or [string]$names[0].Id -cne [string]$builder.vmId) { throw 'HYPERV_BUILD_NATIVE_IDENTITY_CHANGED' }
    $identity = ConvertFrom-HyperVLabNotes -Notes ([string]$matches[0].Notes)
    $managed = [pscustomobject]@{ VM=$matches[0]; Identity=$identity }
    if ($identity.windowsPoolMember) { Assert-LabWindowsPoolProviderMutation -Managed $managed -StateRoot $Context.StateRoot; throw 'HYPERV_BUILD_POOL_AUTHORITY_CONFLICT' }
    if ($identity.provider -cne 'hyperv' -or $identity.runId -cne $Context.Build.buildId -or
        $identity.scopeId -cne $Context.Build.scopeId -or $identity.instanceId -cne $builder.instanceId -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$identity.childVhdxPath), [IO.Path]::GetFullPath($disk), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'HYPERV_BUILD_NOTES_BINDING_INVALID'
    }
    $drives = @(Get-VMHardDiskDrive -VM $matches[0] -ErrorAction Stop)
    if ($drives.Count -ne 1 -or -not $drives[0].Path -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$drives[0].Path), [IO.Path]::GetFullPath($disk), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'HYPERV_BUILD_NATIVE_DISK_BINDING_INVALID'
    }
    return $managed
}

function Get-HyperVBuildCallerAuthority {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build, [string]$StateRoot, [switch]$AllowAbsent, [switch]$RequireOff)
    $context = Get-HyperVBuildMutationContext -BuildDirectory $Build.BuildDirectory -StateRoot $StateRoot -ExpectedScopeId $Build.scopeId
    if ($context.Build.buildId -cne $Build.buildId -or
        [string]$context.Build.builder.vmId -cne [string]$Build.builder.vmId -or
        [string]$context.Build.builder.vmName -cne [string]$Build.builder.vmName -or
        [string]$context.Build.builder.instanceId -cne [string]$Build.builder.instanceId -or
        [string]$context.Build.builder.resourceRelativePath -cne [string]$Build.builder.resourceRelativePath) { throw 'HYPERV_BUILD_CALLER_BINDING_CHANGED' }
    if ($context.Kind -ceq 'hyperv-sql' -and [string]$context.Build.sql.version -cne [string]$Build.sql.version) { throw 'HYPERV_BUILD_CALLER_BINDING_CHANGED' }
    $managed = Get-HyperVBuildBoundManagedVM -Context $context
    if (-not $managed -and -not $AllowAbsent) { throw 'HYPERV_BUILD_NATIVE_VM_REQUIRED' }
    if ($RequireOff -and $managed -and [string]$managed.VM.State -cne 'Off') { throw 'HYPERV_BUILD_VM_MUST_BE_OFF' }
    return [pscustomobject]@{ Context=$context; Managed=$managed }
}

function Assert-HyperVBuildGuestTransportAuthority {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build, [string]$StateRoot, [Parameter(Mandatory)][guid]$ExpectedVmId,
        [Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId, [string]$FallbackAddress)
    $authority=Get-HyperVBuildCallerAuthority -Build $Build -StateRoot $StateRoot
    if ($ExpectedVmId -eq [guid]::Empty -or [string]$authority.Managed.VM.Id -cne $ExpectedVmId.ToString() -or
        $VMName -cne [string]$authority.Managed.VM.Name -or $ExpectedRunId -cne [string]$authority.Context.Build.buildId -or
        $ExpectedScopeId -cne [string]$authority.Context.Build.scopeId -or [string]$authority.Managed.VM.State -cne 'Running') {
        throw 'HYPERV_BUILD_GUEST_TRANSPORT_BINDING_CHANGED'
    }
    if ($FallbackAddress) {
        $network=$authority.Context.Build.labNetwork
        if (-not $network -or -not $network.Name -or -not $network.Subnet -or
            (Get-LabNetworkGuestAddress -Network $network -Identity $ExpectedRunId) -cne $FallbackAddress) { throw 'HYPERV_BUILD_FALLBACK_ADDRESS_NOT_BOUND' }
        $switches=@(Get-VMSwitch -Name ([string]$network.Name) -ErrorAction Stop)
        if ($switches.Count -ne 1 -or -not $switches[0].Id) { throw 'HYPERV_BUILD_FALLBACK_NETWORK_NOT_BOUND' }
        $adapters=@(Get-VMNetworkAdapter -VM $authority.Managed.VM -ErrorAction Stop | Where-Object {
            [string]$_.SwitchId -ceq [string]$switches[0].Id -and [string]$_.SwitchName -ceq [string]$network.Name -and
            $FallbackAddress -cin @($_.IPAddresses)
        })
        if ($adapters.Count -ne 1) { throw 'HYPERV_BUILD_FALLBACK_NIC_NOT_BOUND' }
    }
}

function Assert-HyperVBuildOfflineDiskAuthority {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build, [string]$StateRoot, [Parameter(Mandatory)][string]$VhdxPath, [switch]$PlannedOutput)
    $authority = Get-HyperVBuildCallerAuthority -Build $Build -StateRoot $StateRoot -AllowAbsent -RequireOff
    $context = $authority.Context
    $expected = Join-Path $context.Binding.HyperVResourceRoot ([string]$context.Build.builder.resourceRelativePath)
    $null = Assert-LabHyperVBoundPath -Binding $context.Binding -Path $VhdxPath -DataRoot $context.Binding.LabDataRoot
    if ($PlannedOutput) {
        if (@($context.Plan.steps|Where-Object {$_.provider -ceq 'hyperv' -and $_.action -ceq 'remove' -and $_.resourceType -ceq 'vhdx' -and
            [string]::Equals([IO.Path]::GetFullPath([string]$_.resourceId),[IO.Path]::GetFullPath($VhdxPath),[StringComparison]::OrdinalIgnoreCase)}).Count -ne 1) { throw 'HYPERV_BUILD_OUTPUT_DISK_NOT_PLANNED' }
    }
    elseif (-not [string]::Equals([IO.Path]::GetFullPath($expected), [IO.Path]::GetFullPath($VhdxPath), [StringComparison]::OrdinalIgnoreCase)) { throw 'HYPERV_BUILD_OFFLINE_DISK_BINDING_INVALID' }
    $vhd = Get-VHD -Path $VhdxPath -ErrorAction Stop
    if (-not $vhd -or $vhd.Attached) { throw 'HYPERV_BUILD_OFFLINE_DISK_ATTACHED' }
    foreach ($vm in @(Get-VM -ErrorAction Stop)) {
        foreach ($drive in @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop)) {
            if ($drive.Path -and [string]::Equals([IO.Path]::GetFullPath($drive.Path), [IO.Path]::GetFullPath($VhdxPath), [StringComparison]::OrdinalIgnoreCase) -and
                ($PlannedOutput -or -not $authority.Managed -or [string]$vm.Id -cne [string]$authority.Managed.VM.Id -or [string]$vm.State -cne 'Off')) { throw 'HYPERV_BUILD_OFFLINE_DISK_FOREIGN_ATTACHMENT' }
        }
    }
    $dependency = Test-HyperVVhdxCleanupDependencyChain -Path $VhdxPath
    if (-not $dependency.Valid) { throw $dependency.Code }
}

function Invoke-HyperVBuildPowerShellDirect {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build, [string]$StateRoot,
        [Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId, [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock, [object[]]$ArgumentList=@(),
        [string]$FallbackAddress, [object]$Progress, [int]$TimeoutSeconds=86400)
    $authority = Get-HyperVBuildCallerAuthority -Build $Build -StateRoot $StateRoot
    if ($VMName -cne $authority.Context.Build.builder.vmName -or $ExpectedRunId -cne $authority.Context.Build.buildId -or
        $ExpectedScopeId -cne $authority.Context.Build.scopeId) { throw 'HYPERV_BUILD_GUEST_CALLER_BINDING_INVALID' }
    $arguments = @{} + $PSBoundParameters
    $null = $arguments.Remove('Build'); $null = $arguments.Remove('StateRoot')
    $arguments.ExpectedVmId = [guid]$authority.Managed.VM.Id
    $arguments.Build=$Build; $arguments.BuildStateRoot=$StateRoot
    Invoke-HyperVPowerShellDirect @arguments
}

function Assert-HyperVBuildProviderMutation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Managed, [Parameter(Mandatory)][string]$StateRoot)
    $directories = @('hyperv', 'hyperv-sql') | ForEach-Object { Join-Path $StateRoot "image-builds/$_/$($Managed.Identity.runId)" }
    $found = @($directories | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'build-state.json') -PathType Leaf })
    if ($found.Count -ne 1) { throw 'WINDOWS_POOL_PROVIDER_AUTHORITY_REQUIRED' }
    $context = Get-HyperVBuildMutationContext -BuildDirectory $found[0] -StateRoot $StateRoot -ExpectedScopeId $Managed.Identity.scopeId
    $fresh = Get-HyperVBuildBoundManagedVM -Context $context
    if (-not $fresh -or [string]$fresh.VM.Id -cne [string]$Managed.VM.Id) { throw 'HYPERV_BUILD_NATIVE_IDENTITY_CHANGED' }
}

function Test-HyperVSelectedBuildMutation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Managed, [string]$StateRoot)
    $root=Resolve-LabWindowsPoolRoot -StateRoot $StateRoot
    return @('hyperv','hyperv-sql' | ForEach-Object {
        Join-Path $root "image-builds/$_/$($Managed.Identity.runId)/build-state.json"
    } | Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}).Count -gt 0
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
        [ValidateSet('none', 'space')][string]$InitialMediaKey = 'space',
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

    $vmGeneration = if ($OperatingSystemId -in @('windows-server-2008', 'windows-server-2008-r2')) { 1 } else { 2 }
    # Current Hyper-V DBX updates reject the boot manager on the archived
    # Windows Server 2012 R2 evaluation ISO. Keep Generation 2, but bind this
    # exact legacy platform contract to Secure Boot off.
    $secureBoot = $vmGeneration -eq 2 -and $OperatingSystemId -ne 'windows-server-2012-r2'
    $guestControl = if ($OperatingSystemId -match '^windows-server-(2008|2012)(-r2)?$') {
        'legacy-wmi'
    } else { 'powershell-direct' }

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
        media = [PSCustomObject]@{
            sha256 = $sha256; integrityOrigin = 'user-verified-local'
            bootInteraction = [PSCustomObject]@{ initialMediaKey = $InitialMediaKey }
        }
        operatingSystem = [PSCustomObject]@{ id = $OperatingSystemId; edition = $Edition; installationType = $InstallationType; language = $Language; architecture = 'x64' }
        platform = [PSCustomObject]@{
            vmGeneration = $vmGeneration
            secureBoot = $secureBoot
            guestControl = $guestControl
        }
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
    $resourceBinding = Initialize-LabHyperVResourceBinding -ResourceId $BuildId -ResourceClass Build `
        -StateDirectory $build.BuildDirectory
    $resourceRoot = [string]$resourceBinding.HyperVResourceRoot
    $vmName = "sql-lab-image-builder-$($BuildId.Replace('-', '').Substring(0, 8))"
    $diskPath = Assert-LabHyperVBoundPath -Binding $resourceBinding -Path (Join-Path $resourceRoot "$vmName.vhdx")

    $null = Add-CleanupStep -RunDir $build.BuildDirectory -ResourceType vhdx -ResourceId $diskPath -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv-builder -Compensation 'Remove builder OS VHDX'
    $null = Add-CleanupStep -RunDir $build.BuildDirectory -ResourceType vm -ResourceId $vmName -Action remove -Provider hyperv -ProviderSubRunId provider-hyperv-builder -Compensation 'Remove Hyper-V image builder'
    New-Item -Path $resourceRoot -ItemType Directory -Force | Out-Null
    $null = Assert-LabHyperVBoundPath -Binding $resourceBinding -Path $diskPath
    $null = New-VHD -Path $diskPath -Dynamic -SizeBytes ([long]$build.resources.osDiskSizeBytes) -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $diskPath -PathType Leaf)) { throw 'HYPERV_IMAGE_BUILD_DISK_POSTCONDITION_FAILED' }
    $vmGeneration = if ($build.platform -and $build.platform.vmGeneration) {
        [int]$build.platform.vmGeneration
    } else { 2 }
    $secureBoot = if ($build.platform -and $null -ne $build.platform.secureBoot) {
        [bool]$build.platform.secureBoot
    } else { $vmGeneration -eq 2 }
    $vm = New-VM -Name $vmName -Generation $vmGeneration -MemoryStartupBytes $MemoryStartupBytes `
        -VHDPath $diskPath -Path $resourceRoot -ErrorAction Stop
    $nativeBinding = Set-HyperVBuildNativeBinding -BuildDirectory $build.BuildDirectory -StateRoot $StateRoot `
        -VM $vm -InstanceId image-builder -ChildVhdxPath $diskPath
    $null = Set-VM -VM $vm -SmartPagingFilePath $resourceRoot -SnapshotFileLocation $resourceRoot -ErrorAction Stop
    $null = Assert-HyperVVMResourceBinding -VMName $vmName -ResourceBinding $resourceBinding
    # Do not inherit Hyper-V's unbounded dynamic-memory default (commonly 1 TB).
    $memoryMinimumBytes = [long][Math]::Max([double]512MB, [double]$MemoryStartupBytes / 2)
    $memoryMaximumBytes = [long][Math]::Min([double]1TB, [double]$MemoryStartupBytes * 2)
    $null = Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -MinimumBytes $memoryMinimumBytes `
        -StartupBytes $MemoryStartupBytes -MaximumBytes $memoryMaximumBytes -ErrorAction Stop
    # Mark the VM immediately so cleanup can identify it even when later setup fails.
    $notes = ConvertTo-HyperVLabNotes -RunId $BuildId -ScopeId $build.scopeId -InstanceId image-builder -ChildVhdxPath $diskPath
    $null = Set-VM -VM $vm -Notes $notes -AutomaticCheckpointsEnabled $false -ErrorAction Stop
    @($vm | Get-VMNetworkAdapter -ErrorAction Stop) | Remove-VMNetworkAdapter -ErrorAction Stop
    $null = Set-VMProcessor -VM $vm -Count $ProcessorCount -ErrorAction Stop
    $dvd = Add-VMDvdDrive -VM $vm -Path ([string]$local.isoPath) -Passthru -ErrorAction Stop
    if ($vmGeneration -eq 2) {
        if ($secureBoot) {
            $null = Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -ErrorAction Stop
        }
        else {
            $null = Set-VMFirmware -VM $vm -EnableSecureBoot Off -ErrorAction Stop
        }
        $null = Set-VMFirmware -VM $vm -FirstBootDevice $dvd -ErrorAction Stop
    }
    else {
        $null = Set-VMBios -VM $vm -StartupOrder @(
            [Microsoft.HyperV.PowerShell.BootDevice]::CD,
            [Microsoft.HyperV.PowerShell.BootDevice]::IDE,
            [Microsoft.HyperV.PowerShell.BootDevice]::LegacyNetworkAdapter,
            [Microsoft.HyperV.PowerShell.BootDevice]::Floppy) -ErrorAction Stop
    }

    $build.builder = [PSCustomObject]@{ vmName = $vmName; vmId = $nativeBinding.vmId; instanceId = $nativeBinding.instanceId;
        nativeBindingContract = $nativeBinding.nativeBindingContract; osDiskRelativePath = "resources/hyperv/$vmName.vhdx";
        resourceRelativePath = "$vmName.vhdx"; generation = $vmGeneration; secureBoot = $secureBoot }
    Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Set-HyperVImageBuildState -BuildId $BuildId -State BUILDER_READY -Reason "Generation-$vmGeneration-Builder mit verifiziertem Installationsmedium erstellt" -StateRoot $StateRoot
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
    $allowedSources = if ($synthetic) { @('synthetic-test') } else { @('powershell-direct', 'offline-inspection', 'legacy-wmi') }
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
        $receipt = Invoke-HyperVBuildPowerShellDirect -Build $build -StateRoot $StateRoot -VMName $vmName -ExpectedRunId $BuildId `
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
                # Sysprep.exe can return exit code 0 while Windows still reports
                # IMAGE_STATE_UNDEPLOYABLE for a short transition. Wait for the
                # documented reseal state before creating the success receipt.
                $imageStatePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State'
                $imageStateDeadline = [datetime]::UtcNow.AddSeconds(180)
                do {
                    $imageState = [string](Get-ItemProperty -LiteralPath $imageStatePath `
                        -Name ImageState -ErrorAction Stop).ImageState
                    if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }
                    Start-Sleep -Seconds 2
                } while ([datetime]::UtcNow -lt $imageStateDeadline)
                if ($imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
                    $panther = Join-Path $env:WINDIR 'System32\Sysprep\Panther'
                    $errorLines = @()
                    $errorLog = Join-Path $panther 'setuperr.log'
                    if (Test-Path -LiteralPath $errorLog -PathType Leaf) {
                        $errorLines += @(Get-Content -LiteralPath $errorLog -Tail 20 -ErrorAction SilentlyContinue)
                    }
                    $actionLog = Join-Path $panther 'setupact.log'
                    if (Test-Path -LiteralPath $actionLog -PathType Leaf) {
                        $errorLines += @(Get-Content -LiteralPath $actionLog -Tail 120 -ErrorAction SilentlyContinue | `
                            Where-Object { $_ -match 'error|fail' } | Select-Object -Last 20)
                    }
                    $diagnostic = (@($errorLines | Where-Object { $_ } | Select-Object -Last 30) -join ' | ').Trim()
                    if ($diagnostic.Length -gt 3000) { $diagnostic = $diagnostic.Substring($diagnostic.Length - 3000) }
                    $suffix = if ($diagnostic) { ": $diagnostic" } else { '' }
                    throw "SYSPREP_IMAGE_STATE_INVALID_${imageState}$suffix"
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
        [switch]$RequireChildBootValidation,
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
    $buildAuthority = Get-HyperVBuildMutationContext -BuildDirectory $build.BuildDirectory -StateRoot $StateRoot -ExpectedScopeId $build.scopeId
    $null = Get-HyperVBuildBoundManagedVM -Context $buildAuthority

    if ([string]$build.generalizationEvidence.relativePath -ne 'evidence/generalization.json') {
        throw 'HYPERV_GENERALIZATION_EVIDENCE_PATH_INVALID'
    }
    $evidencePath = Join-Path $build.BuildDirectory ([string]$build.generalizationEvidence.relativePath)
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$build.generalizationEvidence.storedSha256) {
        throw 'HYPERV_GENERALIZATION_EVIDENCE_INTEGRITY_MISMATCH'
    }
    $diskPath = Resolve-LabHyperVBuilderDiskPath -Build $build
    if (-not (Test-HyperVPathWithinRunDirectory -Path $diskPath -RunDirectory $build.BuildDirectory) -or
        -not (Test-Path -LiteralPath $diskPath -PathType Leaf)) {
        throw 'HYPERV_IMAGE_BUILD_DISK_SCOPE_INVALID'
    }
    if (-not (Test-HyperVVhdxSignature -Path $diskPath)) { throw 'HYPERV_ARTIFACT_NOT_VHDX' }
    $synthetic = [string]$build.operatingSystem.id -eq 'synthetic-ci'
    if (-not $synthetic -and [string]$build.license.type -eq 'evaluation' -and -not $EvaluationExpiresAt) {
        throw 'HYPERV_EVALUATION_EXPIRY_REQUIRED'
    }

    $managed = Get-HyperVBuildBoundManagedVM -Context (Get-HyperVBuildMutationContext `
        -BuildDirectory $build.BuildDirectory -StateRoot $StateRoot -ExpectedScopeId $build.scopeId)
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

    Assert-HyperVBuildOfflineDiskAuthority -Build $build -StateRoot $StateRoot -VhdxPath $diskPath
    (Get-Item -LiteralPath $diskPath -Force).IsReadOnly = $true
    $sha256 = (Get-FileHash -LiteralPath $diskPath -Algorithm SHA256).Hash
    $osVersion = if ($synthetic) { '1' } else { ([string]$build.operatingSystem.id -replace '^windows-(server-)?', '') }
    $importParameters = @{
        VhdxPath = $diskPath; ExpectedSha256 = $sha256
        ArtifactState = if ($synthetic) { 'LIFECYCLE_TEST_ONLY' } else { 'OS_SEALED' }
        OperatingSystemId = [string]$build.operatingSystem.id; OperatingSystemVersion = $osVersion
        Edition = [string]$build.operatingSystem.edition; InstallationType = [string]$build.operatingSystem.installationType
        Language = [string]$build.operatingSystem.language; LicenseType = [string]$build.license.type
        VmGeneration = if ($build.platform -and $build.platform.vmGeneration) { [int]$build.platform.vmGeneration } else { 2 }
        SecureBoot = if ($build.platform -and $null -ne $build.platform.secureBoot) { [bool]$build.platform.secureBoot } else { $true }
        GuestControl = if ($build.platform -and $build.platform.guestControl) { [string]$build.platform.guestControl } else { 'powershell-direct' }
        IntegrityOrigin = if ($synthetic) { 'synthetic-test' } else { 'generated-by-runtime' }
        InitialMediaKey = [string]$build.media.bootInteraction.initialMediaKey
        EvaluationExpiresAt = $EvaluationExpiresAt; StateRoot = $StateRoot
    }
    if ($RequireChildBootValidation) { $importParameters.RequireChildBootValidation = $true }
    if (-not $synthetic) { $importParameters.Generalized = $true }
    Assert-HyperVBuildOfflineDiskAuthority -Build $build -StateRoot $StateRoot -VhdxPath $diskPath
    $artifact = Import-HyperVImageArtifact @importParameters
    if (-not $artifact -or
        [string]::IsNullOrWhiteSpace([string]$artifact.artifactId) -or
        [string]$artifact.sha256 -ne $sha256.ToLowerInvariant() -or
        [string]$artifact.artifactState -ne [string]$importParameters.ArtifactState) {
        throw 'HYPERV_IMAGE_ARTIFACT_PUBLICATION_FAILED'
    }
    # The immutable registry copy is complete and hash-verified before the
    # builder VM or its source VHDX can be removed.
    $managed = Get-HyperVBuildBoundManagedVM -Context (Get-HyperVBuildMutationContext `
        -BuildDirectory $build.BuildDirectory -StateRoot $StateRoot -ExpectedScopeId $build.scopeId)
    if ($managed) {
        $null = Remove-HyperVInstance -VMName ([string]$build.builder.vmName) `
            -ExpectedScopeId ([string]$build.scopeId) -ExpectedRunDirectory $build.BuildDirectory `
            -PreserveVhdx -RequireOff -StateRoot $StateRoot
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

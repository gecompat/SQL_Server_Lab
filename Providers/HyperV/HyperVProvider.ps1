<#
.SYNOPSIS
    Hyper-V-Lifecycle-Grundlage fuer SQL_Server_Lab.
.DESCRIPTION
    Implementiert Verfuegbarkeit, Generation-2-VM-Erstellung aus einer
    verifizierten read-only Parent-VHDX, Status, Start, Stop, PowerShell Direct,
    zusätzliche run-lokale VHDX und scopegebundenen Cleanup. SQL- und Gast-
    Provisionierung sind noch nicht Bestandteil dieses Vertical Slice.
#>

$script:HyperVLabNotesPrefix = 'SQL_SERVER_LAB:'

function Test-HyperVAvailable {
    [CmdletBinding()]
    param()

    if (-not $IsWindows) {
        return [PSCustomObject]@{
            Available = $false
            Version   = $null
            Message   = 'Hyper-V ist nur auf einem Windows-Host verfuegbar.'
        }
    }

    $requiredCommands = @(
        'Add-VMNetworkAdapter',
        'Add-VMHardDiskDrive',
        'Add-VMDvdDrive',
        'Convert-VHD',
        'Get-VM',
        'Get-VMHardDiskDrive',
        'Get-VMHost',
        'Get-VMNetworkAdapter',
        'Get-VMSwitch',
        'Get-NetAdapter',
        'Get-VMSnapshot',
        'Get-VHD',
        'New-VM',
        'New-VHD',
        'Remove-VMNetworkAdapter',
        'Set-VMFirmware',
        'Start-VM',
        'Stop-VM',
        'Remove-VM'
    )
    $missingCommands = @(
        $requiredCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
    )
    if ($missingCommands.Count -gt 0) {
        return [PSCustomObject]@{
            Available = $false
            Version   = $null
            Message   = "Hyper-V-Cmdlets fehlen: $($missingCommands -join ', ')"
        }
    }

    # Nicht pauschal ein administratives Token verlangen. Mitglieder der
    # lokalen Gruppe "Hyper-V-Administratoren" duerfen den Hyper-V-Dienst
    # verwalten, ohne lokale Administratoren zu sein. Der echte Get-VMHost-
    # Probe entscheidet deshalb capability-basiert. Einzelne Hostoperationen
    # wie das Offline-Mounten einer VHDX pruefen ihre zusaetzlichen Privilegien
    # weiterhin direkt am jeweiligen Ausfuehrungspunkt.
    try {
        $null = Get-VMHost -ErrorAction Stop
        $module = Get-Module Hyper-V -ListAvailable |
            Sort-Object Version -Descending |
            Select-Object -First 1
        return [PSCustomObject]@{
            Available = $true
            Version   = if ($module) { [string]$module.Version } else { 'available' }
            Message   = ''
        }
    }
    catch {
        return [PSCustomObject]@{
            Available = $false
            Version   = $null
            Message   = "Hyper-V-Host nicht erreichbar: $($_.Exception.Message)"
        }
    }
}

function ConvertTo-HyperVLabNotes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$ChildVhdxPath,
        [object[]]$AdditionalDrives = @()
    )

    $identity = [ordered]@{
        contractVersion = '0.3'
        provider        = 'hyperv'
        runId           = $RunId
        scopeId         = $ScopeId
        instanceId      = $InstanceId
        childVhdxPath   = [System.IO.Path]::GetFullPath($ChildVhdxPath)
        additionalVhdxPaths = @(
            $AdditionalDrives | ForEach-Object { [System.IO.Path]::GetFullPath([string]$_.Path) }
        )
        additionalDrives = @(
            $AdditionalDrives | ForEach-Object {
                [ordered]@{
                    id = [string]$_.Id
                    role = [string]$_.Role
                    sizeBytes = [long]$_.SizeBytes
                    vhdType = [string]$_.VhdType
                    path = [System.IO.Path]::GetFullPath([string]$_.Path)
                    diskIdentifier = [string]$_.DiskIdentifier
                    controllerNumber = [int]$_.ControllerNumber
                    controllerLocation = [int]$_.ControllerLocation
                    guestPath = if ($_.GuestPath) { [string]$_.GuestPath } else { $null }
                    driveLetter = if ($_.DriveLetter) { [string]$_.DriveLetter } else { $null }
                    fileSystem = [string]$_.FileSystem
                    allocationUnitKB = [int]$_.AllocationUnitKB
                    volumeLabel = [string]$_.VolumeLabel
                    maximumIops = [long]$_.MaximumIops
                    hostRoot = if ($_.HostRoot) { [string]$_.HostRoot } else { $null }
                    locationId = if ($_.LocationId) { [string]$_.LocationId } else { $null }
                    selector = if ($_.Selector) { [string]$_.Selector } else { $null }
                }
            }
        )
    }
    return $script:HyperVLabNotesPrefix + ($identity | ConvertTo-Json -Compress -Depth 10)
}

function Resolve-HyperVAdditionalDrivePlan {
    [CmdletBinding()]
    param(
        [object[]]$AdditionalDrives = @(),
        [Parameter(Mandatory)][string]$ResourceRoot,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$RunDirectory
    )

    # PowerShell bindet ein explizit uebergebenes $null bei object[] als einen
    # einzelnen Nullwert. Fuer den optionalen Drive-Vertrag bedeutet $null
    # jedoch dasselbe wie eine leere Liste. Echte Nullwerte innerhalb einer
    # nichtleeren Liste bleiben weiterhin ungueltig.
    if ($null -eq $AdditionalDrives) {
        $AdditionalDrives = @()
    }

    if (@($AdditionalDrives).Count -gt 16) {
        throw 'HYPERV_ADDITIONAL_DRIVE_LIMIT_EXCEEDED'
    }

    $seenIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $seenDriveLetters = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $plan = @()
    foreach ($drive in @($AdditionalDrives)) {
        $id = [string]$drive.id
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$') {
            throw "HYPERV_ADDITIONAL_DRIVE_ID_INVALID: $id"
        }
        if (-not $seenIds.Add($id)) {
            throw "HYPERV_ADDITIONAL_DRIVE_ID_DUPLICATE: $id"
        }

        $role = if ($drive.role) { [string]$drive.role } else { 'general' }
        if ($role -notin @('sqlData', 'sqlLog', 'tempdb', 'backup', 'general')) {
            throw "HYPERV_ADDITIONAL_DRIVE_ROLE_INVALID: $role"
        }
        $sizeBytes = [long]$drive.sizeBytes
        if ($sizeBytes -lt 32MB -or $sizeBytes -gt 64TB) {
            throw "HYPERV_ADDITIONAL_DRIVE_SIZE_INVALID: $id"
        }
        $vhdType = if ($drive.vhdType) { [string]$drive.vhdType } else { 'dynamic' }
        if ($vhdType -notin @('dynamic', 'fixed')) {
            throw "HYPERV_ADDITIONAL_DRIVE_TYPE_INVALID: $vhdType"
        }

        $guestPath = if ($drive.guestPath) { [string]$drive.guestPath } else { $null }
        $driveLetter = $null
        if ($guestPath) {
            if ($guestPath -notmatch '^[D-Zd-z]:\\(?:[^<>:"/|?*\r\n]+(?:\\[^<>:"/|?*\r\n]+)*)?$') {
                throw "HYPERV_ADDITIONAL_DRIVE_GUEST_PATH_INVALID: $id"
            }
            $driveLetter = $guestPath.Substring(0, 1).ToUpperInvariant()
            if (-not $seenDriveLetters.Add($driveLetter)) {
                throw "HYPERV_ADDITIONAL_DRIVE_LETTER_DUPLICATE: $driveLetter"
            }
            $guestPath = $driveLetter + $guestPath.Substring(1)
        }
        $allocationUnitKB = if ($drive.allocationUnitKB) { [int]$drive.allocationUnitKB } else { 64 }
        if ($allocationUnitKB -notin @(4, 8, 16, 32, 64)) {
            throw "HYPERV_ADDITIONAL_DRIVE_ALLOCATION_UNIT_INVALID: $id"
        }
        $fileSystem = if ($drive.fileSystem) { [string]$drive.fileSystem } else { 'NTFS' }
        if ($fileSystem -ne 'NTFS') {
            throw "HYPERV_ADDITIONAL_DRIVE_FILE_SYSTEM_INVALID: $id"
        }
        $volumeLabel = if ($drive.volumeLabel) {
            [string]$drive.volumeLabel
        }
        else {
            ('SQLLAB_' + ($id -replace '[^A-Za-z0-9_-]', '_')).ToUpperInvariant()
        }
        if ($volumeLabel -notmatch '^[A-Za-z0-9][A-Za-z0-9 _-]{0,31}$') {
            throw "HYPERV_ADDITIONAL_DRIVE_VOLUME_LABEL_INVALID: $id"
        }
        $maximumIops = if ($drive.maximumIops) { [long]$drive.maximumIops } else { 0 }
        if ($maximumIops -lt 0 -or $maximumIops -gt 1000000) { throw "HYPERV_ADDITIONAL_DRIVE_IOPS_INVALID: $id" }

        $safeId = $id -replace '_', '-'
        $hostRoot = if ($drive.hostRoot) { [IO.Path]::GetFullPath([string]$drive.hostRoot).TrimEnd('\', '/') } else { $null }
        $hostPath = if ($drive.hostPath) { [IO.Path]::GetFullPath([string]$drive.hostPath).TrimEnd('\', '/') } else { $null }
        if ([bool]$hostRoot -ne [bool]$hostPath) { throw "HYPERV_ADDITIONAL_DRIVE_HOST_BINDING_INCOMPLETE: $id" }
        if ($hostRoot) {
            $configuration = Get-LabStorageConfiguration -DataRoot $hostRoot
            $registered = @($configuration.LabDataLocations | Where-Object {
                [string]::Equals([IO.Path]::GetFullPath([string]$_.LabDataRoot).TrimEnd('\', '/'), $hostRoot, [StringComparison]::OrdinalIgnoreCase)
            })
            $boundary = Test-LabPathWithinRoot -Root $hostRoot -Path $hostPath
            $relativeHostPath = if ($boundary.Valid) { [IO.Path]::GetRelativePath($hostRoot, $hostPath) } else { '' }
            if ($registered.Count -ne 1 -or
                -not (Test-LabDataRootOwnership -DataRoot $hostRoot -ControllerId ([string]$configuration.ControllerId)) -or
                -not $boundary.Valid -or
                -not $drive.locationId -or [string]$drive.locationId -ne [string]$registered[0].LocationId -or
                -not $drive.selector -or [string]$drive.selector -notin @($registered[0].Selectors) -or
                $relativeHostPath -notmatch '^Labs[\\/][^\\/]+[\\/]Instances[\\/]hyperv[\\/][^\\/]+[\\/]Storage[\\/]([^\\/]+)$' -or
                [string]$Matches[1] -ne [string]$drive.selector) {
                throw "HYPERV_ADDITIONAL_DRIVE_HOST_BINDING_NOT_OWNED: $id"
            }
            $path = Join-Path $hostPath "$VMName-$safeId.vhdx"
        }
        else {
            $path = Join-Path $ResourceRoot "$VMName-$safeId.vhdx"
            if (-not (Test-HyperVPathWithinRunDirectory -Path $path -RunDirectory $RunDirectory)) {
                throw 'HYPERV_RESOURCE_SCOPE_VIOLATION'
            }
        }
        if (Test-Path -LiteralPath $path) {
            throw "Hyper-V-Zusatz-VHDX existiert bereits: $path"
        }
        $plan += [PSCustomObject]@{
            Id = $id
            Role = $role
            SizeBytes = $sizeBytes
            VhdType = $vhdType
            Path = [System.IO.Path]::GetFullPath($path)
            DiskIdentifier = $null
            ControllerNumber = 0
            # Generation-2-VMs verwenden fuer die OS-VHDX SCSI 0:0.
            # Zusatzdisks erhalten deshalb explizit stabile Slots 0:1..0:16.
            ControllerLocation = $plan.Count + 1
            GuestPath = $guestPath
            DriveLetter = $driveLetter
            FileSystem = 'NTFS'
            AllocationUnitKB = $allocationUnitKB
            VolumeLabel = $volumeLabel
            MaximumIops = $maximumIops
            HostRoot = $hostRoot
            LocationId = if ($drive.locationId) { [string]$drive.locationId } else { $null }
            Selector = if ($drive.selector) { [string]$drive.selector } else { $null }
        }
    }
    return @($plan)
}

function ConvertFrom-HyperVLabNotes {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Notes)

    if (-not $Notes -or -not $Notes.StartsWith($script:HyperVLabNotesPrefix, [System.StringComparison]::Ordinal)) {
        return $null
    }

    try {
        return $Notes.Substring($script:HyperVLabNotesPrefix.Length) |
            ConvertFrom-Json -Depth 10 -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Test-HyperVPathWithinRunDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunDirectory
    )

    $resourceRoot = [System.IO.Path]::GetFullPath(
        (Join-Path (Join-Path $RunDirectory 'resources') 'hyperv')
    ).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $candidate = [System.IO.Path]::GetFullPath($Path)
    $prefix = $resourceRoot + [System.IO.Path]::DirectorySeparatorChar

    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $current = Split-Path -Parent $candidate
    while ($current -and $current.StartsWith($resourceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                return $false
            }
        }
        if ($current.Equals($resourceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = Split-Path -Parent $current
    }

    return $true
}

function Get-HyperVManagedVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$ExpectedRunId,
        [string]$ExpectedScopeId
    )

    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        return $null
    }

    $identity = ConvertFrom-HyperVLabNotes -Notes ([string]$vm.Notes)
    if (-not $identity -or $identity.provider -ne 'hyperv') {
        throw "VM '$VMName' besitzt keine gueltige SQL_Server_Lab-Identitaet."
    }
    if ($ExpectedRunId -and $identity.runId -ne $ExpectedRunId) {
        throw "VM '$VMName' gehoert nicht zum erwarteten Run."
    }
    if ($ExpectedScopeId -and $identity.scopeId -ne $ExpectedScopeId) {
        throw "VM '$VMName' gehoert nicht zum erwarteten Scope."
    }

    return [PSCustomObject]@{
        VM       = $vm
        Identity = $identity
    }
}

function New-HyperVInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$ParentVhdxPath,
        [Parameter(Mandatory, ParameterSetName = 'Path')][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ParentSha256,
        [Parameter(Mandatory, ParameterSetName = 'Artifact')][string]$ImageArtifactId,
        [Parameter(ParameterSetName = 'Artifact')][string]$StateRoot,
        [Parameter(ParameterSetName = 'Artifact')][switch]$AllowLifecycleTestArtifact,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')][string]$InstanceId,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$')][string]$LabName,
        [ValidateRange(512MB, 1TB)][long]$MemoryStartupBytes = 2GB,
        [ValidateRange(1, 64)][int]$ProcessorCount = 2,
        [ValidateSet('on', 'off')][string]$AutoStart = 'off',
        [string]$SwitchName,
        [object[]]$AdditionalDrives = @()
    )

    $availability = Test-HyperVAvailable
    if (-not $availability.Available) {
        throw "Hyper-V nicht verfuegbar: $($availability.Message)"
    }

    $resolvedRunDirectory = [System.IO.Path]::GetFullPath($RunDirectory)
    $cleanupPlanPath = Join-Path $resolvedRunDirectory 'cleanup-plan.json'
    if (-not (Test-Path -LiteralPath $cleanupPlanPath -PathType Leaf)) {
        throw "Cleanup-Plan muss vor der ersten Hyper-V-Mutation existieren: $cleanupPlanPath"
    }
    $cleanupPlan = Get-Content -LiteralPath $cleanupPlanPath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 20
    if ($cleanupPlan.runId -ne $RunId -or $cleanupPlan.scopeId -ne $ScopeId) {
        throw 'Cleanup-Plan stimmt nicht mit RunId und ScopeId ueberein.'
    }

    if ($PSCmdlet.ParameterSetName -eq 'Artifact') {
        $imageArtifact = Get-HyperVImageArtifact -ArtifactId $ImageArtifactId -StateRoot $StateRoot
        if (-not $imageArtifact) { throw "HYPERV_ARTIFACT_NOT_FOUND: $ImageArtifactId" }
        if ($imageArtifact.artifactState -eq 'LIFECYCLE_TEST_ONLY' -and -not $AllowLifecycleTestArtifact) {
            throw 'HYPERV_TEST_ARTIFACT_NOT_ALLOWED'
        }
        if ($imageArtifact.artifactState -notin @('OS_SEALED', 'SQL_PREPARED_SEALED', 'LIFECYCLE_TEST_ONLY')) {
            throw 'BASELINE_NOT_COMPATIBLE'
        }
        $ParentVhdxPath = [string]$imageArtifact.Path
        $ParentSha256 = [string]$imageArtifact.sha256
        $null = Add-HyperVImageManifestLockEntry -RunDirectory $resolvedRunDirectory -Artifact $imageArtifact
    }

    $resolvedParent = (Resolve-Path -LiteralPath $ParentVhdxPath -ErrorAction Stop).Path
    if ([System.IO.Path]::GetExtension($resolvedParent) -ne '.vhdx') {
        throw 'Hyper-V-Parent muss eine VHDX-Datei sein.'
    }
    $parentItem = Get-Item -LiteralPath $resolvedParent -Force
    if (-not $parentItem.IsReadOnly) {
        throw 'Hyper-V-Parent muss read-only sein.'
    }
    $actualHash = (Get-FileHash -LiteralPath $resolvedParent -Algorithm SHA256).Hash
    if (-not $actualHash.Equals($ParentSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'PARENT_VHDX_INTEGRITY_MISMATCH'
    }

    if ($SwitchName -and -not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        throw "Hyper-V-Switch '$SwitchName' ist nicht vorhanden."
    }

    $runPrefix = $RunId.Replace('-', '').Substring(0, 8).ToLowerInvariant()
    $safeInstanceId = $InstanceId -replace '_', '-'
    # Der Projektname ist im Hyper-V-Manager sofort sichtbar; das Run-Präfix
    # hält gleichnamige Labs kollisionsfrei.
    $vmName = if ($LabName) { "$(($LabName.Trim()))-$runPrefix" } else { "sql-lab-$safeInstanceId-$runPrefix" }
    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        throw "Hyper-V-VM existiert bereits: $vmName"
    }

    $resourceRoot = Join-Path (Join-Path $resolvedRunDirectory 'resources') 'hyperv'
    $childVhdxPath = Join-Path $resourceRoot "$vmName.vhdx"
    if (-not (Test-HyperVPathWithinRunDirectory -Path $childVhdxPath -RunDirectory $resolvedRunDirectory)) {
        throw 'HYPERV_RESOURCE_SCOPE_VIOLATION'
    }
    if (Test-Path -LiteralPath $childVhdxPath) {
        throw "Hyper-V-Child-VHDX existiert bereits: $childVhdxPath"
    }
    $additionalDrivePlan = @(
        Resolve-HyperVAdditionalDrivePlan `
            -AdditionalDrives $AdditionalDrives `
            -ResourceRoot $resourceRoot `
            -VMName $vmName `
            -RunDirectory $resolvedRunDirectory
    )

    # Der Cleanup-Plan wird vor der ersten Provider-Mutation vervollstaendigt.
    # Die umgekehrte Ausfuehrung entfernt zuerst die VM und danach alle run-lokalen VHDX.
    $null = Add-CleanupStep `
        -RunDir $resolvedRunDirectory `
        -ResourceType 'vhdx' `
        -ResourceId $childVhdxPath `
        -Action 'remove' `
        -Provider 'hyperv' `
        -ProviderSubRunId 'provider-hyperv' `
        -Compensation "Remove Hyper-V child VHDX for $vmName"
    foreach ($drive in $additionalDrivePlan) {
        $null = Add-CleanupStep `
            -RunDir $resolvedRunDirectory `
            -ResourceType 'vhdx' `
            -ResourceId $drive.Path `
            -Action 'remove' `
            -Provider 'hyperv' `
            -ProviderSubRunId 'provider-hyperv' `
            -SafetyRoot ([string]$drive.HostRoot) `
            -Compensation "Remove Hyper-V $($drive.Role) VHDX $($drive.Id) for $vmName"
    }
    $null = Add-CleanupStep `
        -RunDir $resolvedRunDirectory `
        -ResourceType 'vm' `
        -ResourceId $vmName `
        -Action 'remove' `
        -Provider 'hyperv' `
        -ProviderSubRunId 'provider-hyperv' `
        -Compensation "Remove Hyper-V VM $vmName"

    $null = New-Item -ItemType Directory -Path $resourceRoot -Force
    $null = New-VHD -Path $childVhdxPath -ParentPath $resolvedParent -Differencing -ErrorAction Stop
    foreach ($drive in $additionalDrivePlan) {
        $driveDirectory = Split-Path -Parent ([string]$drive.Path)
        if (-not (Test-Path -LiteralPath $driveDirectory -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $driveDirectory -Force -ErrorAction Stop
        }
        $newVhdParameters = @{
            Path = $drive.Path
            SizeBytes = $drive.SizeBytes
            ErrorAction = 'Stop'
        }
        if ($drive.VhdType -eq 'fixed') {
            $newVhdParameters.Fixed = $true
        }
        else {
            $newVhdParameters.Dynamic = $true
        }
        $null = New-VHD @newVhdParameters
        $vhd = Get-VHD -Path $drive.Path -ErrorAction Stop
        $diskIdentifier = [string]$vhd.DiskIdentifier
        if ($diskIdentifier -notmatch '^[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$') {
            throw "HYPERV_ADDITIONAL_DRIVE_IDENTIFIER_INVALID: $($drive.Id)"
        }
        $drive.DiskIdentifier = $diskIdentifier.ToUpperInvariant()
    }

    $newVmParameters = @{
        Name               = $vmName
        Generation         = 2
        MemoryStartupBytes = $MemoryStartupBytes
        VHDPath            = $childVhdxPath
        Path               = $resourceRoot
        ErrorAction        = 'Stop'
    }
    if ($SwitchName) {
        $newVmParameters.SwitchName = $SwitchName
    }
    $vm = New-VM @newVmParameters
    # Hyper-V otherwise assigns a host-wide default maximum (commonly 1 TB).
    # Keep an actual dynamic range: half the chosen startup value (at least
    # 512 MB) through twice the startup value, capped at Hyper-V's 1-TB limit.
    $memoryMinimumBytes = [long][Math]::Max([double]512MB, [double]$MemoryStartupBytes / 2)
    $memoryMaximumBytes = [long][Math]::Min([double]1TB, [double]$MemoryStartupBytes * 2)
    $null = Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -MinimumBytes $memoryMinimumBytes `
        -StartupBytes $MemoryStartupBytes -MaximumBytes $memoryMaximumBytes -ErrorAction Stop
    $notes = ConvertTo-HyperVLabNotes `
        -RunId $RunId `
        -ScopeId $ScopeId `
        -InstanceId $InstanceId `
        -ChildVhdxPath $childVhdxPath `
        -AdditionalDrives $additionalDrivePlan
    $null = Set-VM -VM $vm -Notes $notes -AutomaticCheckpointsEnabled $false -ErrorAction Stop
    $automaticStartAction = if ($AutoStart -eq 'on') { 'Start' } else { 'Nothing' }
    $null = Set-VM -VM $vm -AutomaticStartAction $automaticStartAction -ErrorAction Stop
    if (-not $SwitchName) {
        # New-VM erzeugt hostabhaengig auch ohne SwitchName einen getrennten
        # Standardadapter. Dieser Slice besitzt noch keinen Netzwerkvertrag und
        # entfernt deshalb jeden impliziten Adapter deterministisch.
        @($vm | Get-VMNetworkAdapter -ErrorAction Stop) |
            Remove-VMNetworkAdapter -ErrorAction Stop
    }
    foreach ($drive in $additionalDrivePlan) {
        $attachedDrive = Add-VMHardDiskDrive `
            -VM $vm `
            -ControllerType SCSI `
            -ControllerNumber 0 `
            -ControllerLocation ([int]$drive.ControllerLocation) `
            -Path $drive.Path `
            -ErrorAction Stop
        if ([long]$drive.MaximumIops -gt 0) {
            $null = Set-VMHardDiskDrive -VMHardDiskDrive $attachedDrive `
                -MaximumIOPS ([long]$drive.MaximumIops) -ErrorAction Stop
        }
    }
    $null = Set-VMProcessor -VM $vm -Count $ProcessorCount -ErrorAction Stop
    $null = Set-VMFirmware `
        -VM $vm `
        -EnableSecureBoot On `
        -SecureBootTemplate MicrosoftWindows `
        -ErrorAction Stop
    return [PSCustomObject]@{
        Provider      = 'hyperv'
        VMId          = [string]$vm.Id
        VMName        = $vmName
        InstanceId    = $InstanceId
        RunId         = $RunId
        ScopeId       = $ScopeId
        ChildVhdxPath = $childVhdxPath
        AdditionalDrives = @($additionalDrivePlan)
        AutoStart     = $AutoStart
        State         = [string]$vm.State
        SqlReady      = $false
    }
}

function Get-HyperVInstanceStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$ExpectedRunId,
        [string]$ExpectedScopeId
    )

    $managed = Get-HyperVManagedVM `
        -VMName $VMName `
        -ExpectedRunId $ExpectedRunId `
        -ExpectedScopeId $ExpectedScopeId
    if (-not $managed) {
        return [PSCustomObject]@{
            Provider = 'hyperv'
            VMName   = $VMName
            Exists   = $false
            State    = 'Absent'
        }
    }

    return [PSCustomObject]@{
        Provider   = 'hyperv'
        VMName     = $VMName
        VMId       = [string]$managed.VM.Id
        Exists     = $true
        State      = [string]$managed.VM.State
        RunId      = [string]$managed.Identity.runId
        ScopeId    = [string]$managed.Identity.scopeId
        InstanceId = [string]$managed.Identity.instanceId
        AutoStart  = if ([string]$managed.VM.AutomaticStartAction -eq 'Start') { 'on' } else { 'off' }
        AdditionalVhdxPaths = @($managed.Identity.additionalVhdxPaths | ForEach-Object { [string]$_ })
        AdditionalDrives = @($managed.Identity.additionalDrives)
        GuestDrivesReady = [bool](
            @($managed.Identity.additionalDrives | Where-Object guestPath).Count -gt 0 -and
            @($managed.Identity.guestDriveInitialization).Count -eq
                @($managed.Identity.additionalDrives | Where-Object guestPath).Count
        )
        WindowsSpecialized = [bool](
            [string]$managed.Identity.windowsSpecialization.status -eq 'WINDOWS_SPECIALIZED'
        )
        LastSqlReadinessStatus = [string]$managed.Identity.sqlReadiness.status
        LastSqlReadinessAt = [string]$managed.Identity.sqlReadiness.observedAt
        # Ohne erneut bereitgestellte Credentials ist hier kein Live-SQL-Probe
        # moeglich. Der gespeicherte Receipt bleibt deshalb Historie, nicht
        # aktuelle Bereitschaft.
        SqlReady   = $false
    }
}

function Start-HyperVInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId
    )

    $managed = Get-HyperVManagedVM -VMName $VMName -ExpectedRunId $ExpectedRunId -ExpectedScopeId $ExpectedScopeId
    if (-not $managed) {
        throw "Hyper-V-VM nicht gefunden: $VMName"
    }
    if ([string]$managed.VM.State -ne 'Running') {
        $null = Start-VM -VM $managed.VM -ErrorAction Stop
    }
    return Get-HyperVInstanceStatus -VMName $VMName -ExpectedRunId $ExpectedRunId -ExpectedScopeId $ExpectedScopeId
}

function Stop-HyperVInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId
    )

    $managed = Get-HyperVManagedVM -VMName $VMName -ExpectedRunId $ExpectedRunId -ExpectedScopeId $ExpectedScopeId
    if (-not $managed) {
        throw "Hyper-V-VM nicht gefunden: $VMName"
    }
    if ([string]$managed.VM.State -ne 'Off') {
        $null = Stop-VM -VM $managed.VM -Force -ErrorAction Stop
    }
    return Get-HyperVInstanceStatus -VMName $VMName -ExpectedRunId $ExpectedRunId -ExpectedScopeId $ExpectedScopeId
}

function Initialize-HyperVLabWinRmClient {
    <#
    .SYNOPSIS
        Stellt ausschliesslich den lokalen WinRM-Client fuer das Lab bereit.
    .DESCRIPTION
        Der Host wird dabei nicht als Remote-Server konfiguriert: Es wird weder
        ein Listener erstellt noch eine Host-Firewallregel geoeffnet. Der
        laufende WinRM-Dienst stellt lediglich den WSMan-Clientkonfigurations-
        pfad fuer den kurzzeitigen, IP-genauen TrustedHost bereit.
    #>
    [CmdletBinding()]
    param()

    Import-Module Microsoft.WSMan.Management -ErrorAction Stop
    $service = Get-Service -Name WinRM -ErrorAction Stop
    if ($service.Status -ne 'Running') {
        try { Start-Service -Name WinRM -ErrorAction Stop }
        catch { throw "HYPERV_LAB_WINRM_CLIENT_START_FAILED: $($_.Exception.Message)" }
    }
    $trustedHostsPath = 'WSMan:\localhost\Client\TrustedHosts'
    if (-not (Test-Path -LiteralPath $trustedHostsPath)) {
        throw 'HYPERV_LAB_WINRM_CLIENT_CONFIGURATION_UNAVAILABLE'
    }
    return $trustedHostsPath
}

function Invoke-HyperVWinRmFallback {
    <#
    .SYNOPSIS
        Fuehrt einen Gastbefehl ueber das isolierte Hyper-V-Labnetz aus.
    .DESCRIPTION
        PowerShell Direct ist der bevorzugte Kanal. Bei einer noch nicht
        verfuegbaren Gastintegration kann ein durch die OOBE eingerichteter
        WinRM-Endpunkt im internen Labnetz verwendet werden. Der konkrete
        Zielhost wird nur fuer den einzelnen Aufruf temporär als TrustedHost
        eingetragen und der vorherige Wert danach wiederhergestellt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}$')][string]$Address,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    $trustedHostsPath = Initialize-HyperVLabWinRmClient
    $originalTrustedHosts = [string](Get-Item -Path $trustedHostsPath -ErrorAction Stop).Value
    $trustedHosts = @($originalTrustedHosts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $alreadyTrusted = $trustedHosts -contains '*' -or $trustedHosts -contains $Address
    $trustedHostsChanged = $false
    try {
        if (-not $alreadyTrusted) {
            try {
                Set-Item -Path $trustedHostsPath -Value (@($trustedHosts + $Address) -join ',') -Force -ErrorAction Stop
                $trustedHostsChanged = $true
            }
            catch {
                throw "HYPERV_LAB_WINRM_TRUSTED_HOST_REQUIRES_ELEVATION: $Address"
            }
        }
        return Invoke-Command -ComputerName $Address -Credential $Credential -Authentication Negotiate `
            -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    }
    finally {
        if ($trustedHostsChanged) {
            Set-Item -Path $trustedHostsPath -Value $originalTrustedHosts -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-HyperVPowerShellDirect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [ValidatePattern('^(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3})?$')][string]$FallbackAddress
    )

    $managed = Get-HyperVManagedVM -VMName $VMName -ExpectedRunId $ExpectedRunId -ExpectedScopeId $ExpectedScopeId
    if (-not $managed) {
        throw "Hyper-V-VM nicht gefunden: $VMName"
    }
    if ([string]$managed.VM.State -ne 'Running') {
        throw "PowerShell Direct erfordert eine laufende VM: $VMName"
    }

    $directError = $null
    foreach ($attempt in 1..10) {
        try {
            return Invoke-Command `
                -VMName $VMName `
                -Credential $Credential `
                -ScriptBlock $ScriptBlock `
                -ArgumentList $ArgumentList `
                -ErrorAction Stop
        }
        catch {
            if ([string]$_.CategoryInfo.Category -ne 'OpenError') { throw }
            $directError = $_
            if ($attempt -lt 10) { Start-Sleep -Seconds 3 }
        }
    }
    if (-not $FallbackAddress) { throw $directError }
    Write-LabInfo "PowerShell Direct fuer $VMName nach 10 Versuchen nicht verfuegbar; nutze WinRM im Labnetz ($FallbackAddress)."
    try {
        return Invoke-HyperVWinRmFallback -Address $FallbackAddress -Credential $Credential `
            -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    }
    catch {
        throw "HYPERV_LAB_GUEST_COMMAND_UNAVAILABLE: PowerShell Direct: $($directError.Exception.Message); WinRM: $($_.Exception.Message)"
    }
}

function Set-HyperVManagedVMIdentityProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ManagedVM,
        [Parameter(Mandatory)][string]$PropertyName,
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$ContractVersion
    )

    $ManagedVM.Identity | Add-Member `
        -NotePropertyName contractVersion `
        -NotePropertyValue $ContractVersion `
        -Force
    $ManagedVM.Identity | Add-Member `
        -NotePropertyName $PropertyName `
        -NotePropertyValue $Value `
        -Force
    $notes = $script:HyperVLabNotesPrefix + (
        $ManagedVM.Identity | ConvertTo-Json -Compress -Depth 10
    )
    $null = Set-VM -VM $ManagedVM.VM -Notes $notes -ErrorAction Stop
    return $notes
}

function Wait-HyperVPowerShellDirect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [string]$ExpectedComputerName,
        [ValidatePattern('^(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3})?$')][string]$FallbackAddress,
        [string]$GuestInitializationScript,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [ValidateRange(100, 60000)][int]$PollIntervalMilliseconds = 2000
    )

    $managed = Get-HyperVManagedVM `
        -VMName $VMName `
        -ExpectedRunId $ExpectedRunId `
        -ExpectedScopeId $ExpectedScopeId
    if (-not $managed) { throw "Hyper-V-VM nicht gefunden: $VMName" }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastError = ''
    $lastProgressSeconds = -30
    $guestInitializationComplete = [string]::IsNullOrWhiteSpace($GuestInitializationScript)
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (($stopwatch.Elapsed.TotalSeconds - $lastProgressSeconds) -ge 30) {
            $lastProgressSeconds = $stopwatch.Elapsed.TotalSeconds
            Write-LabInfo "PowerShell Direct: warte auf $VMName ($([int]$stopwatch.Elapsed.TotalSeconds)s/$TimeoutSeconds, letzter Status: $lastError)"
        }
        try {
            $probe = Invoke-HyperVPowerShellDirect `
                -VMName $VMName -ExpectedRunId $ExpectedRunId -ExpectedScopeId $ExpectedScopeId `
                -Credential $Credential -FallbackAddress $FallbackAddress -ScriptBlock {
                    [PSCustomObject]@{
                        computerName = [Environment]::MachineName
                        imageState = [string](Get-ItemPropertyValue `
                            -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' `
                            -Name ImageState `
                            -ErrorAction Stop)
                    }
                } `
                -ErrorAction Stop
            $probe = @($probe)[0]
            if (-not $guestInitializationComplete) {
                $null = Invoke-HyperVPowerShellDirect `
                    -VMName $VMName -ExpectedRunId $ExpectedRunId -ExpectedScopeId $ExpectedScopeId `
                    -Credential $Credential -FallbackAddress $FallbackAddress `
                    -ScriptBlock ([scriptblock]::Create($GuestInitializationScript)) `
                    -ErrorAction Stop
                $guestInitializationComplete = $true
                Write-LabInfo "PowerShell Direct: Gast-Initialisierung für $VMName ausgeführt."
            }
            if ((-not $ExpectedComputerName -or
                    [string]$probe.computerName -eq $ExpectedComputerName) -and
                [string]$probe.imageState -eq 'IMAGE_STATE_COMPLETE') {
                $stopwatch.Stop()
                return [PSCustomObject]@{
                    Ready = $true
                    ComputerName = [string]$probe.computerName
                    ImageState = [string]$probe.imageState
                    Duration = $stopwatch.Elapsed
                    Message = 'PowerShell Direct ist bereit.'
                }
            }
            $lastError = "ComputerName=$($probe.computerName), ImageState=$($probe.imageState)"
        }
        catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }

    $stopwatch.Stop()
    return [PSCustomObject]@{
        Ready = $false
        ComputerName = $null
        ImageState = $null
        Duration = $stopwatch.Elapsed
        Message = "PowerShell Direct Timeout: $lastError"
    }
}

function Set-HyperVWindowsGuestSpecialization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][ValidatePattern('^(?![0-9]+$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?$')][string]$ComputerName,
        [ValidatePattern('^(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3})?$')][string]$FallbackAddress,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )

    $targetComputerName = $ComputerName.ToUpperInvariant()
    $managed = Get-HyperVManagedVM `
        -VMName $VMName `
        -ExpectedRunId $ExpectedRunId `
        -ExpectedScopeId $ExpectedScopeId
    if (-not $managed) { throw "Hyper-V-VM nicht gefunden: $VMName" }
    if ([string]$managed.VM.State -ne 'Running') {
        throw "Windows-Specialization erfordert eine laufende VM: $VMName"
    }

    $observed = Invoke-HyperVPowerShellDirect `
        -VMName $VMName `
        -ExpectedRunId $ExpectedRunId `
        -ExpectedScopeId $ExpectedScopeId `
        -Credential $Credential `
        -FallbackAddress $FallbackAddress `
        -ScriptBlock {
            $pendingName = [string](Get-ItemPropertyValue `
                -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
                -Name ComputerName `
                -ErrorAction Stop)
            [PSCustomObject]@{
                computerName = [Environment]::MachineName
                pendingComputerName = $pendingName
                imageState = [string](Get-ItemPropertyValue `
                    -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' `
                    -Name ImageState `
                    -ErrorAction Stop)
            }
        }
    $observed = @($observed)[0]
    if ([string]$observed.imageState -ne 'IMAGE_STATE_COMPLETE') {
        throw "HYPERV_WINDOWS_SPECIALIZATION_IMAGE_STATE_NOT_COMPLETE: $($observed.imageState)"
    }
    if ([string]$observed.pendingComputerName -and
        [string]$observed.pendingComputerName -ne [string]$observed.computerName -and
        [string]$observed.pendingComputerName -ne $targetComputerName) {
        throw "HYPERV_WINDOWS_SPECIALIZATION_RENAME_CONFLICT: $($observed.pendingComputerName)"
    }

    $needsRestart = [string]$observed.computerName -ne $targetComputerName
    if ($needsRestart) {
        $intent = [PSCustomObject]@{
            status = 'RENAME_PLANNED'
            computerName = $targetComputerName
            previousComputerName = [string]$observed.computerName
            observedAt = [datetime]::UtcNow.ToString('o')
        }
        $null = Set-HyperVManagedVMIdentityProperty `
            -ManagedVM $managed `
            -PropertyName windowsSpecialization `
            -Value $intent `
            -ContractVersion '0.5'

        $null = Invoke-HyperVPowerShellDirect `
            -VMName $VMName `
            -ExpectedRunId $ExpectedRunId `
            -ExpectedScopeId $ExpectedScopeId `
            -Credential $Credential `
            -FallbackAddress $FallbackAddress `
            -ArgumentList @($targetComputerName) `
            -ScriptBlock {
                param($TargetComputerName)
                $null = Rename-Computer `
                    -NewName $TargetComputerName `
                    -Force `
                    -ErrorAction Stop
                return 'RENAME_APPLIED'
            }

        $intent.status = 'REBOOT_REQUIRED'
        $null = Set-HyperVManagedVMIdentityProperty `
            -ManagedVM $managed `
            -PropertyName windowsSpecialization `
            -Value $intent `
            -ContractVersion '0.5'

        $null = Invoke-HyperVPowerShellDirect `
            -VMName $VMName `
            -ExpectedRunId $ExpectedRunId `
            -ExpectedScopeId $ExpectedScopeId `
            -Credential $Credential `
            -FallbackAddress $FallbackAddress `
            -ScriptBlock {
                $shutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
                $null = Start-Process `
                    -FilePath $shutdown `
                    -ArgumentList '/r /t 0 /d p:4:1' `
                    -WindowStyle Hidden `
                    -PassThru
                return 'RESTART_REQUESTED'
            }

        $ready = Wait-HyperVPowerShellDirect `
            -VMName $VMName `
            -ExpectedRunId $ExpectedRunId `
            -ExpectedScopeId $ExpectedScopeId `
            -Credential $Credential `
            -ExpectedComputerName $targetComputerName `
            -FallbackAddress $FallbackAddress `
            -TimeoutSeconds $TimeoutSeconds
        if (-not $ready.Ready) {
            throw "HYPERV_WINDOWS_SPECIALIZATION_TIMEOUT: $($ready.Message)"
        }
    }

    $verified = Invoke-HyperVPowerShellDirect `
        -VMName $VMName `
        -ExpectedRunId $ExpectedRunId `
        -ExpectedScopeId $ExpectedScopeId `
        -Credential $Credential `
        -FallbackAddress $FallbackAddress `
        -ScriptBlock {
            [PSCustomObject]@{
                computerName = [Environment]::MachineName
                imageState = [string](Get-ItemPropertyValue `
                    -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' `
                    -Name ImageState `
                    -ErrorAction Stop)
                windowsVersion = [Environment]::OSVersion.Version.ToString()
            }
        }
    $verified = @($verified)[0]
    if ([string]$verified.computerName -ne $targetComputerName -or
        [string]$verified.imageState -ne 'IMAGE_STATE_COMPLETE') {
        throw 'HYPERV_WINDOWS_SPECIALIZATION_POSTCONDITION_FAILED'
    }

    $receipt = [PSCustomObject]@{
        status = 'WINDOWS_SPECIALIZED'
        computerName = $targetComputerName
        imageState = [string]$verified.imageState
        windowsVersion = [string]$verified.windowsVersion
        rebooted = [bool]$needsRestart
        observedAt = [datetime]::UtcNow.ToString('o')
    }
    $null = Set-HyperVManagedVMIdentityProperty `
        -ManagedVM $managed `
        -PropertyName windowsSpecialization `
        -Value $receipt `
        -ContractVersion '0.5'

    return [PSCustomObject]@{
        Provider = 'hyperv'
        VMName = $VMName
        RunId = $ExpectedRunId
        ScopeId = $ExpectedScopeId
        Status = 'WINDOWS_SPECIALIZED'
        ComputerName = $targetComputerName
        Rebooted = [bool]$needsRestart
    }
}

function Wait-HyperVGuestSqlReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [ValidatePattern('^(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3})?$')][string]$FallbackAddress,
        [ValidatePattern('^[A-Za-z][A-Za-z0-9_$-]{0,127}$')][string]$InstanceName = 'MSSQLSERVER',
        [ValidateRange(0, 99)][int]$ExpectedMajorVersion = 0,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [ValidateRange(100, 60000)][int]$PollIntervalMilliseconds = 2000
    )

    $managed = Get-HyperVManagedVM `
        -VMName $VMName `
        -ExpectedRunId $ExpectedRunId `
        -ExpectedScopeId $ExpectedScopeId
    if (-not $managed) { throw "Hyper-V-VM nicht gefunden: $VMName" }
    if ([string]$managed.VM.State -ne 'Running') {
        throw "SQL-Readiness erfordert eine laufende VM: $VMName"
    }
    if ([string]$managed.Identity.windowsSpecialization.status -ne 'WINDOWS_SPECIALIZED') {
        throw 'HYPERV_SQL_READINESS_REQUIRES_WINDOWS_SPECIALIZATION'
    }

    $receipt = Invoke-HyperVPowerShellDirect `
        -VMName $VMName `
        -ExpectedRunId $ExpectedRunId `
        -ExpectedScopeId $ExpectedScopeId `
        -Credential $Credential `
        -FallbackAddress $FallbackAddress `
        -ArgumentList @($InstanceName, $SaPassword, $ExpectedMajorVersion, $TimeoutSeconds, $PollIntervalMilliseconds) `
        -ScriptBlock {
            param($SqlInstanceName, $SqlSaPassword, $ExpectedMajor, $Timeout, $PollInterval)
            $ErrorActionPreference = 'Stop'
            Add-Type -AssemblyName System.Data
            $serviceName = if ($SqlInstanceName -eq 'MSSQLSERVER') {
                'MSSQLSERVER'
            }
            else { "MSSQL`$$SqlInstanceName" }
            $serverName = if ($SqlInstanceName -eq 'MSSQLSERVER') {
                'localhost'
            }
            else { "localhost\$SqlInstanceName" }

            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlSaPassword)
            $plainPassword = $null
            $builder = $null
            try {
                $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
                $builder['Data Source'] = $serverName
                $builder['Initial Catalog'] = 'master'
                $builder['User ID'] = 'sa'
                $builder['Password'] = $plainPassword
                $builder['Encrypt'] = $true
                $builder['TrustServerCertificate'] = $true
                $builder['Connect Timeout'] = [Math]::Min(15, [Math]::Max(1, [int]$Timeout))

                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $lastError = ''
                while ($stopwatch.Elapsed.TotalSeconds -lt [int]$Timeout) {
                    try {
                        $service = Get-Service -Name $serviceName -ErrorAction Stop
                        if ([string]$service.Status -ne 'Running') {
                            $lastError = "SQL service state: $($service.Status)"
                            Start-Sleep -Milliseconds ([int]$PollInterval)
                            continue
                        }

                        $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
                        $command = $null
                        $reader = $null
                        try {
                            $connection.Open()
                            $command = $connection.CreateCommand()
                            $command.CommandTimeout = [Math]::Min(30, [Math]::Max(1, [int]$Timeout))
                            $command.CommandText = @'
SET NOCOUNT ON;
SELECT
    CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS MajorVersion,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS ProductVersion,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS Edition,
    CAST(SERVERPROPERTY('MachineName') AS nvarchar(128)) AS MachineName,
    CAST(SERVERPROPERTY('ServiceName') AS nvarchar(128)) AS ServiceName,
    (SELECT COUNT(*) FROM sys.databases WHERE name IN ('master','tempdb','model','msdb') AND state_desc = 'ONLINE') AS OnlineSystemDatabases;
'@
                            $reader = $command.ExecuteReader()
                            if (-not $reader.Read()) { throw 'SQL readiness query returned no row.' }
                            $major = [int]$reader['MajorVersion']
                            $onlineSystemDatabases = [int]$reader['OnlineSystemDatabases']
                            if ([int]$ExpectedMajor -gt 0 -and $major -ne [int]$ExpectedMajor) {
                                throw "SQL major version mismatch: expected $ExpectedMajor, observed $major"
                            }
                            if ($onlineSystemDatabases -ne 4) {
                                throw "SQL system database readiness mismatch: $onlineSystemDatabases/4 online"
                            }
                            $stopwatch.Stop()
                            return [PSCustomObject]@{
                                status = 'SQL_READY_RUN'
                                instanceName = [string]$SqlInstanceName
                                serviceName = $serviceName
                                majorVersion = $major
                                productVersion = [string]$reader['ProductVersion']
                                edition = [string]$reader['Edition']
                                machineName = [string]$reader['MachineName']
                                sqlServiceName = [string]$reader['ServiceName']
                                onlineSystemDatabases = $onlineSystemDatabases
                                observedAt = [datetime]::UtcNow.ToString('o')
                            }
                        }
                        finally {
                            if ($reader) { $reader.Dispose() }
                            if ($command) { $command.Dispose() }
                            if ($connection) { $connection.Dispose() }
                        }
                    }
                    catch {
                        $lastError = $_.Exception.Message
                    }
                    Start-Sleep -Milliseconds ([int]$PollInterval)
                }
                throw "SQL readiness timeout: $lastError"
            }
            finally {
                if ($builder) { $builder.Clear() }
                $plainPassword = $null
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }

    $receipt = @($receipt)[0]
    if ([string]$receipt.status -ne 'SQL_READY_RUN' -or
        [string]$receipt.instanceName -ne $InstanceName -or
        [int]$receipt.onlineSystemDatabases -ne 4 -or
        ($ExpectedMajorVersion -gt 0 -and [int]$receipt.majorVersion -ne $ExpectedMajorVersion)) {
        throw 'HYPERV_SQL_READINESS_RECEIPT_INVALID'
    }
    $null = Set-HyperVManagedVMIdentityProperty `
        -ManagedVM $managed `
        -PropertyName sqlReadiness `
        -Value $receipt `
        -ContractVersion '0.6'

    return [PSCustomObject]@{
        Provider = 'hyperv'
        VMName = $VMName
        RunId = $ExpectedRunId
        ScopeId = $ExpectedScopeId
        Status = 'SQL_READY_RUN'
        Ready = $true
        InstanceName = [string]$receipt.instanceName
        MajorVersion = [int]$receipt.majorVersion
        ProductVersion = [string]$receipt.productVersion
        Edition = [string]$receipt.edition
        OnlineSystemDatabases = [int]$receipt.onlineSystemDatabases
        ObservedAt = [string]$receipt.observedAt
    }
}

function Initialize-HyperVWindowsGuestDrives {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId,
        [Parameter(Mandatory)][PSCredential]$Credential
    )

    $managed = Get-HyperVManagedVM `
        -VMName $VMName `
        -ExpectedRunId $ExpectedRunId `
        -ExpectedScopeId $ExpectedScopeId
    if (-not $managed) { throw "Hyper-V-VM nicht gefunden: $VMName" }

    $drivePlan = @($managed.Identity.additionalDrives | Where-Object guestPath)
    if ($drivePlan.Count -eq 0) { throw 'HYPERV_GUEST_DRIVE_PLAN_MISSING' }
    foreach ($drive in $drivePlan) {
        if ([string]$drive.diskIdentifier -notmatch '^[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$' -or
            [string]$drive.guestPath -notmatch '^[D-Zd-z]:\\') {
            throw "HYPERV_GUEST_DRIVE_PLAN_INVALID: $($drive.id)"
        }
    }

    $portablePlan = @(
        $drivePlan | ForEach-Object {
            [PSCustomObject]@{
                id = [string]$_.id
                diskIdentifier = [string]$_.diskIdentifier
                sizeBytes = [long]$_.sizeBytes
                controllerNumber = [int]$_.controllerNumber
                controllerLocation = [int]$_.controllerLocation
                guestPath = [string]$_.guestPath
                driveLetter = [string]$_.driveLetter
                fileSystem = [string]$_.fileSystem
                allocationUnitKB = [int]$_.allocationUnitKB
                volumeLabel = [string]$_.volumeLabel
            }
        }
    )
    # Windows PowerShell 5.1 liefert ein JSON-Top-Level-Array über Remoting
    # als einzelnes verschachteltes Object[] zurück. Ein benannter Envelope
    # hält die Elementgrenze provider- und PowerShell-versionsstabil.
    $planJson = [PSCustomObject]@{
        contractVersion = '1'
        drives = $portablePlan
    } | ConvertTo-Json -Compress -Depth 10
    $receipt = Invoke-HyperVPowerShellDirect `
        -VMName $VMName `
        -ExpectedRunId $ExpectedRunId `
        -ExpectedScopeId $ExpectedScopeId `
        -Credential $Credential `
        -ArgumentList @($planJson) `
        -ScriptBlock {
            param($DrivePlanJson)
            $ErrorActionPreference = 'Stop'
            # Der Gast bringt je nach Windows-Version noch Windows PowerShell
            # 5.1 mit; dessen ConvertFrom-Json kennt keinen -Depth-Parameter.
            # Der Plan ist bewusst flach und benötigt keine spezielle Tiefe.
            $plan = ($DrivePlanJson | ConvertFrom-Json)
            if ([string]$plan.contractVersion -ne '1') {
                throw 'GUEST_DRIVE_PLAN_CONTRACT_INVALID'
            }
            $specifications = @($plan.drives)

            function ConvertTo-NormalizedDiskIdentifier {
                param([string]$Value)
                return ($Value -replace '[^A-Fa-f0-9]', '').ToUpperInvariant()
            }

            $null = Update-HostStorageCache
            $allDisks = @(Get-Disk)
            $claimedDiskNumbers = [Collections.Generic.HashSet[int]]::new()
            $results = @()
            foreach ($specification in $specifications) {
                $expectedIdentifier = ConvertTo-NormalizedDiskIdentifier $specification.diskIdentifier
                $matches = @(
                    $allDisks | Where-Object {
                        (ConvertTo-NormalizedDiskIdentifier ([string]$_.UniqueId)) -eq $expectedIdentifier
                    }
                )
                $matchingMethod = 'disk-identifier'
                # Frische VHDX-Dateien besitzen vor der ersten GPT-
                # Initialisierung im Gast je nach Windows-/Hyper-V-Version
                # keinen zu Get-VHD passenden UniqueId-Wert. Die VHDX wurden
                # deshalb explizit auf SCSI 0:1..0:16 gebunden. In einer
                # Generation-2-VM belegt die OS-Disk 0:0; der initiale
                # Gast-DiskNumber entspricht dem festen ControllerLocation.
                if ($matches.Count -eq 0) {
                    $rawCandidates = @(
                        $allDisks | Where-Object {
                            [string]$_.PartitionStyle -eq 'RAW' -and
                            -not [bool]$_.IsBoot -and
                            -not [bool]$_.IsSystem -and
                            [int]$_.Number -eq [int]$specification.controllerLocation -and
                            [long]$_.Size -eq [long]$specification.sizeBytes -and
                            -not $claimedDiskNumbers.Contains([int]$_.Number)
                        }
                    )
                    if ($rawCandidates.Count -eq 1) {
                        $matches = $rawCandidates
                        $matchingMethod = 'scsi-location-raw-fallback'
                    }
                }
                if ($matches.Count -ne 1) {
                    throw "GUEST_DISK_IDENTIFIER_MATCH_COUNT_$($specification.id)_$($matches.Count)"
                }

                $disk = $matches[0]
                if (-not $claimedDiskNumbers.Add([int]$disk.Number)) {
                    throw "GUEST_DISK_ALREADY_CLAIMED_$($specification.id)_$($disk.Number)"
                }
                if ($disk.IsOffline) {
                    Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction Stop
                }
                if ($disk.IsReadOnly) {
                    Set-Disk -Number $disk.Number -IsReadOnly $false -ErrorAction Stop
                }
                $disk = Get-Disk -Number $disk.Number -ErrorAction Stop
                $driveLetter = [char]([string]$specification.driveLetter)
                $status = 'VERIFIED'

                if ([string]$disk.PartitionStyle -eq 'RAW') {
                    # Der Buchstabe eines Host-Data-Roots hat keinerlei
                    # Beziehung zum Gast. D: ist in Windows-VMs oft bereits
                    # das DVD-Laufwerk. Der Plan ist deshalb eine Präferenz:
                    # wenn sie belegt ist, verwenden wir einen freien,
                    # datenfreundlichen Buchstaben und quittieren ihn zurück.
                    if (Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue) {
                        $freeLetter = @('S','T','U','V','W','X','Y','Z','E','F','G','H','I','J','K','L','M','N','O','P','Q','R') |
                            Where-Object { -not (Get-Volume -DriveLetter ([char]$_) -ErrorAction SilentlyContinue) } |
                            Select-Object -First 1
                        if (-not $freeLetter) {
                            throw "GUEST_DRIVE_LETTER_NO_FREE_DATA_LETTER_$($specification.id)"
                        }
                        $driveLetter = [char][string]$freeLetter
                    }
                    $null = Initialize-Disk `
                        -Number $disk.Number `
                        -PartitionStyle GPT `
                        -ErrorAction Stop
                    $partition = New-Partition `
                        -DiskNumber $disk.Number `
                        -UseMaximumSize `
                        -DriveLetter $driveLetter `
                        -ErrorAction Stop
                    $volume = Format-Volume `
                        -Partition $partition `
                        -FileSystem NTFS `
                        -NewFileSystemLabel ([string]$specification.volumeLabel) `
                        -AllocationUnitSize ([int64]$specification.allocationUnitKB * 1KB) `
                        -Confirm:$false `
                        -Force `
                        -ErrorAction Stop
                    $status = 'INITIALIZED'
                }
                else {
                    $partitions = @(
                        Get-Partition -DiskNumber $disk.Number -ErrorAction Stop |
                            Where-Object DriveLetter -EQ $driveLetter
                    )
                    if ($partitions.Count -ne 1) {
                        throw "GUEST_DRIVE_PARTITION_NOT_IDEMPOTENT_$($specification.id)"
                    }
                    $volume = Get-Volume -Partition $partitions[0] -ErrorAction Stop
                }

                $expectedAllocationUnitSize = [int64]$specification.allocationUnitKB * 1KB
                if ([string]$volume.FileSystem -ne 'NTFS' -or
                    [int64]$volume.AllocationUnitSize -ne $expectedAllocationUnitSize -or
                    [string]$volume.FileSystemLabel -ne [string]$specification.volumeLabel) {
                    throw "GUEST_DRIVE_VOLUME_CONTRACT_MISMATCH_$($specification.id)"
                }
                $guestPath = ([string]$driveLetter) + ([string]$specification.guestPath).Substring(1)
                if (-not (Test-Path -LiteralPath $guestPath)) {
                    $null = New-Item `
                        -Path $guestPath `
                        -ItemType Directory `
                        -Force `
                        -ErrorAction Stop
                }

                $results += [PSCustomObject]@{
                    id = [string]$specification.id
                    diskIdentifier = [string]$specification.diskIdentifier
                    diskNumber = [int]$disk.Number
                    guestPath = $guestPath
                    driveLetter = [string]$driveLetter
                    fileSystem = [string]$volume.FileSystem
                    allocationUnitSize = [int64]$volume.AllocationUnitSize
                    volumeLabel = [string]$volume.FileSystemLabel
                    status = $status
                    matchingMethod = $matchingMethod
                    observedDiskUniqueId = [string]$disk.UniqueId
                    observedAt = [datetime]::UtcNow.ToString('o')
                }
            }
            return @($results)
        }

    $receipt = @($receipt)
    if ($receipt.Count -ne $portablePlan.Count) { throw 'HYPERV_GUEST_DRIVE_RECEIPT_COUNT_INVALID' }
    foreach ($expected in $portablePlan) {
        $actual = @($receipt | Where-Object id -EQ $expected.id)
        if ($actual.Count -ne 1 -or
            [string]$actual[0].diskIdentifier -ne [string]$expected.diskIdentifier -or
            [string]$actual[0].guestPath -notmatch '^[D-Z]:\\' -or
            ([string]$actual[0].guestPath).Substring(1) -ne ([string]$expected.guestPath).Substring(1) -or
            [string]$actual[0].fileSystem -ne 'NTFS' -or
            [string]$actual[0].status -notin @('INITIALIZED', 'VERIFIED')) {
            throw "HYPERV_GUEST_DRIVE_RECEIPT_INVALID: $($expected.id)"
        }
    }

    # Den tatsächlich gewählten Gastpfad in den VM-Notes festhalten. Dadurch
    # ist der zweite Aufruf idempotent und die Konsole/UI zeigt nicht länger
    # irreführend einen Host- oder Wunsch-Laufwerksbuchstaben.
    foreach ($actual in $receipt) {
        $plannedDrive = @($managed.Identity.additionalDrives | Where-Object id -EQ $actual.id)
        if ($plannedDrive.Count -eq 1) {
            $plannedDrive[0] | Add-Member -NotePropertyName guestPath -NotePropertyValue ([string]$actual.guestPath) -Force
            $plannedDrive[0] | Add-Member -NotePropertyName driveLetter -NotePropertyValue ([string]$actual.driveLetter) -Force
        }
    }

    $null = Set-HyperVManagedVMIdentityProperty `
        -ManagedVM $managed `
        -PropertyName guestDriveInitialization `
        -Value @($receipt) `
        -ContractVersion '0.4'

    return [PSCustomObject]@{
        Provider = 'hyperv'
        VMName = $VMName
        RunId = $ExpectedRunId
        ScopeId = $ExpectedScopeId
        Status = 'GUEST_DRIVES_READY'
        Drives = @($receipt)
    }
}

function Remove-HyperVInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedScopeId,
        [Parameter(Mandatory)][string]$ExpectedRunDirectory,
        [switch]$PreserveVhdx,
        [switch]$RequireOff
    )

    $managed = Get-HyperVManagedVM -VMName $VMName -ExpectedScopeId $ExpectedScopeId
    if (-not $managed) {
        return [PSCustomObject]@{ Removed = $false; AlreadyAbsent = $true; VMName = $VMName }
    }

    $childVhdxPath = [string]$managed.Identity.childVhdxPath
    if (-not (Test-HyperVPathWithinRunDirectory -Path $childVhdxPath -RunDirectory $ExpectedRunDirectory)) {
        throw 'HYPERV_RESOURCE_SCOPE_VIOLATION'
    }
    $additionalVhdxPaths = @($managed.Identity.additionalVhdxPaths | ForEach-Object { [string]$_ })
    $externalAdditionalVhdxPaths = @(
        $additionalVhdxPaths | Where-Object {
            -not (Test-HyperVPathWithinRunDirectory -Path $_ -RunDirectory $ExpectedRunDirectory)
        }
    )
    # Eine optionale Data-Root-VHDX gehört absichtlich nicht zum Run-Verzeichnis.
    # Beim regulären Cleanup wird sie mit -PreserveVhdx lediglich von der VM
    # getrennt und niemals entfernt. Ohne diesen expliziten Schutz darf keine
    # externe VHDX stillschweigend in den Löschumfang geraten.
    if ($externalAdditionalVhdxPaths.Count -gt 0 -and -not $PreserveVhdx) {
        throw 'HYPERV_EXTERNAL_VHDX_REQUIRES_PRESERVE'
    }
    $vhdxPaths = @($childVhdxPath) + @($additionalVhdxPaths)

    if ([string]$managed.VM.State -ne 'Off') {
        if ($RequireOff) { throw 'HYPERV_VM_MUST_BE_OFF' }
        $null = Stop-VM -VM $managed.VM -TurnOff -Force -ErrorAction Stop
    }
    $null = Remove-VM -VM $managed.VM -Force -ErrorAction Stop

    if (-not $PreserveVhdx) {
        foreach ($vhdxPath in @($childVhdxPath) + @($additionalVhdxPaths | Where-Object {
                    Test-HyperVPathWithinRunDirectory -Path $_ -RunDirectory $ExpectedRunDirectory
                })) {
            $null = Remove-HyperVVhdxForCleanup -Path $vhdxPath -ExpectedRunDirectory $ExpectedRunDirectory
        }
    }

    return [PSCustomObject]@{ Removed = $true; AlreadyAbsent = $false; VMName = $VMName }
}

function Remove-HyperVVhdxForCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedRunDirectory,
        [string]$SafetyRoot
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $runLocal = Test-HyperVPathWithinRunDirectory -Path $resolvedPath -RunDirectory $ExpectedRunDirectory
    if (-not $runLocal) {
        if (-not $SafetyRoot) { throw 'HYPERV_RESOURCE_SCOPE_VIOLATION' }
        $resolvedSafetyRoot = [IO.Path]::GetFullPath($SafetyRoot).TrimEnd('\', '/')
        $configuration = Get-LabStorageConfiguration -DataRoot $resolvedSafetyRoot
        $registered = @($configuration.LabDataLocations | Where-Object {
            [string]::Equals([IO.Path]::GetFullPath([string]$_.LabDataRoot).TrimEnd('\', '/'), $resolvedSafetyRoot, [StringComparison]::OrdinalIgnoreCase)
        })
        $boundary = Test-LabPathWithinRoot -Root $resolvedSafetyRoot -Path $resolvedPath
        $relative = if ($boundary.Valid) { [IO.Path]::GetRelativePath($resolvedSafetyRoot, $resolvedPath) } else { '' }
        $runStatePath = Join-Path $ExpectedRunDirectory 'run-state.json'
        $runPrefix = $null
        if (Test-Path -LiteralPath $runStatePath -PathType Leaf) {
            try {
                $runState = Get-Content -LiteralPath $runStatePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
                if ([string]$runState.runId -match '^[0-9a-fA-F-]{36}$') {
                    $runPrefix = ([string]$runState.runId).Replace('-', '').Substring(0, 8).ToLowerInvariant()
                }
            }
            catch { $runPrefix = $null }
        }
        if ($registered.Count -ne 1 -or
            -not (Test-LabDataRootOwnership -DataRoot $resolvedSafetyRoot -ControllerId ([string]$configuration.ControllerId)) -or
            -not $boundary.Valid -or
            $relative -notmatch '^Labs[\\/][^\\/]+[\\/]Instances[\\/]hyperv[\\/][^\\/]+[\\/]Storage[\\/][^\\/]+[\\/][^\\/]+\.vhdx$' -or
            -not $runPrefix -or (Split-Path -Leaf $resolvedPath) -notmatch "-$runPrefix-sfp-\d{2}\.vhdx$") {
            throw 'HYPERV_RESOURCE_SCOPE_VIOLATION'
        }
    }
    if ([System.IO.Path]::GetExtension($resolvedPath) -ne '.vhdx') {
        throw 'Nur scopegebundene run-lokale VHDX duerfen entfernt werden.'
    }
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        return [PSCustomObject]@{ Removed = $false; AlreadyAbsent = $true; Path = $resolvedPath }
    }

    $attached = @(
        Get-VM -ErrorAction SilentlyContinue |
            Get-VMHardDiskDrive -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Path -and [System.IO.Path]::GetFullPath([string]$_.Path).Equals(
                    $resolvedPath,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
    )
    if ($attached.Count -gt 0) {
        throw "Run-lokale VHDX ist noch an eine VM gebunden: $resolvedPath"
    }

    Remove-Item -LiteralPath $resolvedPath -Force
    return [PSCustomObject]@{ Removed = $true; AlreadyAbsent = $false; Path = $resolvedPath }
}

function Get-HyperVLabVMs {
    [CmdletBinding()]
    param(
        [string]$RunId,
        [string]$ScopeId
    )

    $results = @()
    foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue)) {
        $identity = ConvertFrom-HyperVLabNotes -Notes ([string]$vm.Notes)
        if (-not $identity -or $identity.provider -ne 'hyperv') {
            continue
        }
        if ($RunId -and $identity.runId -ne $RunId) {
            continue
        }
        if ($ScopeId -and $identity.scopeId -ne $ScopeId) {
            continue
        }
        $results += [PSCustomObject]@{
            Provider   = 'hyperv'
            VMName     = [string]$vm.Name
            VMId       = [string]$vm.Id
            State      = [string]$vm.State
            RunId      = [string]$identity.runId
            ScopeId    = [string]$identity.scopeId
            InstanceId = [string]$identity.instanceId
        }
    }
    return $results
}

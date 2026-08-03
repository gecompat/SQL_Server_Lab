<#
.SYNOPSIS
    Hyper-V-Lifecycle-Grundlage fuer SQL_Server_Lab.
.DESCRIPTION
    Implementiert Verfuegbarkeit, Generation-2-VM-Erstellung aus einer
    verifizierten read-only Parent-VHDX, Status, Start, Stop, PowerShell Direct
    und scopegebundenen Cleanup. SQL- und Gast-Provisionierung sind noch nicht
    Bestandteil dieses Vertical Slice.
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
        'Add-VMDvdDrive',
        'Get-VM',
        'Get-VMHost',
        'Get-VMNetworkAdapter',
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
        [Parameter(Mandatory)][string]$ChildVhdxPath
    )

    $identity = [ordered]@{
        contractVersion = '0.1'
        provider        = 'hyperv'
        runId           = $RunId
        scopeId         = $ScopeId
        instanceId      = $InstanceId
        childVhdxPath   = [System.IO.Path]::GetFullPath($ChildVhdxPath)
    }
    return $script:HyperVLabNotesPrefix + ($identity | ConvertTo-Json -Compress)
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
        [ValidateRange(512MB, 1TB)][long]$MemoryStartupBytes = 2GB,
        [ValidateRange(1, 64)][int]$ProcessorCount = 2,
        [string]$SwitchName
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
    $vmName = "sql-lab-$safeInstanceId-$runPrefix"
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

    # Der Cleanup-Plan wird vor der ersten Provider-Mutation vervollstaendigt.
    # Die umgekehrte Ausfuehrung entfernt zuerst die VM und danach die Child-VHDX.
    $null = Add-CleanupStep `
        -RunDir $resolvedRunDirectory `
        -ResourceType 'vhdx' `
        -ResourceId $childVhdxPath `
        -Action 'remove' `
        -Provider 'hyperv' `
        -ProviderSubRunId 'provider-hyperv' `
        -Compensation "Remove Hyper-V child VHDX for $vmName"
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
    if (-not $SwitchName) {
        # New-VM erzeugt hostabhaengig auch ohne SwitchName einen getrennten
        # Standardadapter. Dieser Slice besitzt noch keinen Netzwerkvertrag und
        # entfernt deshalb jeden impliziten Adapter deterministisch.
        @($vm | Get-VMNetworkAdapter -ErrorAction Stop) |
            Remove-VMNetworkAdapter -ErrorAction Stop
    }
    $null = Set-VMProcessor -VM $vm -Count $ProcessorCount -ErrorAction Stop
    $null = Set-VMFirmware `
        -VM $vm `
        -EnableSecureBoot On `
        -SecureBootTemplate MicrosoftWindows `
        -ErrorAction Stop
    $notes = ConvertTo-HyperVLabNotes `
        -RunId $RunId `
        -ScopeId $ScopeId `
        -InstanceId $InstanceId `
        -ChildVhdxPath $childVhdxPath
    $null = Set-VM -VM $vm -Notes $notes -ErrorAction Stop

    return [PSCustomObject]@{
        Provider      = 'hyperv'
        VMId          = [string]$vm.Id
        VMName        = $vmName
        InstanceId    = $InstanceId
        RunId         = $RunId
        ScopeId       = $ScopeId
        ChildVhdxPath = $childVhdxPath
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

function Invoke-HyperVPowerShellDirect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    $managed = Get-HyperVManagedVM -VMName $VMName -ExpectedRunId $ExpectedRunId -ExpectedScopeId $ExpectedScopeId
    if (-not $managed) {
        throw "Hyper-V-VM nicht gefunden: $VMName"
    }
    if ([string]$managed.VM.State -ne 'Running') {
        throw "PowerShell Direct erfordert eine laufende VM: $VMName"
    }

    return Invoke-Command `
        -VMName $VMName `
        -Credential $Credential `
        -ScriptBlock $ScriptBlock `
        -ArgumentList $ArgumentList `
        -ErrorAction Stop
}

function Remove-HyperVInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$ExpectedScopeId,
        [Parameter(Mandatory)][string]$ExpectedRunDirectory,
        [switch]$PreserveVhdx
    )

    $managed = Get-HyperVManagedVM -VMName $VMName -ExpectedScopeId $ExpectedScopeId
    if (-not $managed) {
        return [PSCustomObject]@{ Removed = $false; AlreadyAbsent = $true; VMName = $VMName }
    }

    $childVhdxPath = [string]$managed.Identity.childVhdxPath
    if (-not (Test-HyperVPathWithinRunDirectory -Path $childVhdxPath -RunDirectory $ExpectedRunDirectory)) {
        throw 'HYPERV_RESOURCE_SCOPE_VIOLATION'
    }

    if ([string]$managed.VM.State -ne 'Off') {
        $null = Stop-VM -VM $managed.VM -TurnOff -Force -ErrorAction Stop
    }
    $null = Remove-VM -VM $managed.VM -Force -ErrorAction Stop

    if (-not $PreserveVhdx) {
        $null = Remove-HyperVVhdxForCleanup -Path $childVhdxPath -ExpectedRunDirectory $ExpectedRunDirectory
    }

    return [PSCustomObject]@{ Removed = $true; AlreadyAbsent = $false; VMName = $VMName }
}

function Remove-HyperVVhdxForCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedRunDirectory
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-HyperVPathWithinRunDirectory -Path $resolvedPath -RunDirectory $ExpectedRunDirectory)) {
        throw 'HYPERV_RESOURCE_SCOPE_VIOLATION'
    }
    if ([System.IO.Path]::GetExtension($resolvedPath) -ne '.vhdx') {
        throw 'Nur scopegebundene Child-VHDX duerfen entfernt werden.'
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
        throw "Child-VHDX ist noch an eine VM gebunden: $resolvedPath"
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

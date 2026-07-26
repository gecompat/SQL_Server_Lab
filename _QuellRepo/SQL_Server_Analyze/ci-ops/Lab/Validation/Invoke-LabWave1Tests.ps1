[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-LabTest {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if (-not $Condition) {
        throw "LAB-001 Welle 1 test failed: $Message"
    }
}

function New-SyntheticCapability {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('WINDOWS', 'LINUX')]
        [string] $OperatingSystemFamily,

        [Parameter()]
        [switch] $HyperV,

        [Parameter()]
        [switch] $Docker,

        [Parameter()]
        [switch] $RemoteHost
    )

    return [pscustomobject] @{
        SchemaVersion = '1.0'
        DataClassification = 'SYNTHETIC_EXAMPLE'
        HostAdapter = if ($RemoteHost) {
            'RemoteHost'
        }
        elseif ($OperatingSystemFamily -eq 'WINDOWS') {
            'WindowsHyperV'
        }
        else {
            'LinuxNative'
        }
        OperatingSystemFamily = $OperatingSystemFamily
        Architecture = 'X86_64'
        LogicalProcessorCount = 16
        PhysicalMemoryMiB = 98304
        AvailableMemoryMiB = 81920
        StorageTargets = @(
            [pscustomobject] @{
                LogicalTargetId = 'SYNTHETIC_TARGET_01'
                Roles = @('EPHEMERAL_DATA')
                FreeStorageGiB = 2048
                IsSystemTarget = $false
                IsApprovedLabTarget = $true
            }
        )
        Capabilities = [pscustomobject] @{
            HyperV = [bool] $HyperV
            PowerShellDirect = [bool] $HyperV
            DockerEngine = [bool] $Docker
            PodmanEngine = $false
            ComposeProvider = [bool] $Docker
            CgroupResourceLimits = [bool] $Docker
            NetworkFaultInjection = [bool] $Docker
            RemoteHost = [bool] $RemoteHost
        }
        ResolvedHostClass = 'HC3_EXTENDED'
        SupportedExecutionModes = @(
            if ($OperatingSystemFamily -eq 'WINDOWS') {
                'WINDOWS_SINGLE_HOST'
            }
            else {
                'LINUX_NATIVE'
            }
        )
    }
}

$modulePath = Join-Path $RepositoryRoot (
    'Lab/Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1'
)
$module = $null
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'lab001-wave1-' + [Guid]::NewGuid().ToString('N')
)
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

try {
    $parseErrors = [Collections.Generic.List[object]]::new()
    foreach ($path in Get-ChildItem `
            -LiteralPath (Join-Path $RepositoryRoot 'Lab/Orchestration') `
            -File `
            -Recurse |
        Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') }) {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile(
            $path.FullName,
            [ref] $tokens,
            [ref] $errors
        ) | Out-Null
        foreach ($errorRecord in $errors) {
            $parseErrors.Add($errorRecord)
            Write-Output (
                'PowerShell parser finding: file={0}; line={1}; error={2}' -f
                    $path.Name,
                    $errorRecord.Extent.StartLineNumber,
                    $errorRecord.ErrorId
            )
        }
    }
    Assert-LabTest `
        -Condition ($parseErrors.Count -eq 0) `
        -Message 'PowerShell parser reported an error.'

    $module = Import-Module -Name $modulePath -Force -PassThru

    $runIds = @(
        & $module { New-LabRunId }
        & $module { New-LabRunId }
    )
    Assert-LabTest `
        -Condition ($runIds[0] -ne $runIds[1]) `
        -Message 'Run identifiers must be unique.'
    foreach ($runId in $runIds) {
        Assert-LabTest `
            -Condition ($runId -match '^LAB-[0-9]{8}T[0-9]{6}Z-[0-9A-F]{8}$') `
            -Message 'Run identifier format is invalid.'
    }

    $classCases = @(
        @{ Cpu = 7; Memory = 49152; Storage = 300; Expected = 'UNCLASSIFIED' }
        @{ Cpu = 8; Memory = 49152; Storage = 300; Expected = 'HC1_COMPACT' }
        @{ Cpu = 12; Memory = 61440; Storage = 750; Expected = 'HC2_STANDARD' }
        @{ Cpu = 16; Memory = 90112; Storage = 1536; Expected = 'HC3_EXTENDED' }
    )
    foreach ($case in $classCases) {
        $resolvedClass = & $module {
            param($InputCase)
            Resolve-LabHostClass `
                -LogicalProcessorCount $InputCase.Cpu `
                -PhysicalMemoryMiB $InputCase.Memory `
                -ApprovedFreeStorageGiB $InputCase.Storage
        } $case
        Assert-LabTest `
            -Condition ($resolvedClass -eq $case.Expected) `
            -Message "Host-class boundary $($case.Expected) failed."
    }

    $windowsCapability = New-SyntheticCapability `
        -OperatingSystemFamily WINDOWS `
        -HyperV
    $linuxCapability = New-SyntheticCapability `
        -OperatingSystemFamily LINUX `
        -Docker `
        -RemoteHost
    $distributedResolution = & $module {
        param($WindowsCapability, $LinuxCapability)
        Resolve-LabExecutionMode `
            -HostCapabilities @(
                [pscustomobject] @{
                    LogicalHostId = 'LOCAL_HOST'
                    IsRemote = $false
                    Capability = $WindowsCapability
                }
                [pscustomobject] @{
                    LogicalHostId = 'REMOTE_LINUX'
                    IsRemote = $true
                    Capability = $LinuxCapability
                }
            ) `
            -RequestedMode AUTO `
            -AllowedExecutionModes @(
                'WINDOWS_SINGLE_HOST'
                'LINUX_NATIVE'
                'DISTRIBUTED'
            ) `
            -ContainerEngine DOCKER
    } $windowsCapability $linuxCapability
    Assert-LabTest `
        -Condition (
            $distributedResolution.ResolvedExecutionMode -eq 'DISTRIBUTED'
        ) `
        -Message 'AUTO must prefer an explicitly available distributed mode.'

    $overlapResult = & $module {
        $left = ConvertTo-LabIpv4Range `
            -Cidr (((192, 0, 2, 0) -join '.') + '/24')
        $overlap = ConvertTo-LabIpv4Range `
            -Cidr (((192, 0, 2, 128) -join '.') + '/25')
        $separate = ConvertTo-LabIpv4Range `
            -Cidr (((198, 51, 100, 0) -join '.') + '/24')
        [pscustomobject] @{
            Overlap = Test-LabIpv4RangeOverlap -Left $left -Right $overlap
            Separate = Test-LabIpv4RangeOverlap -Left $left -Right $separate
            Empty = (ConvertTo-LabIpv4Range -Cidr '')
        }
    }
    Assert-LabTest `
        -Condition (
            $overlapResult.Overlap -and
            -not $overlapResult.Separate -and
            $null -eq $overlapResult.Empty
        ) `
        -Message 'Network-range collision detection is not deterministic.'

    $imageLockPath = Join-Path $testRoot 'image-lock.json'
    @"
{
  "SchemaVersion": "1.0",
  "DataClassification": "SYNTHETIC_EXAMPLE",
  "Images": [
    {
      "LogicalImageId": "SYNTHETIC_IMAGE_01",
      "Digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
      "Status": "LOCKED"
    }
  ],
  "Media": []
}
"@ | Set-Content -LiteralPath $imageLockPath -Encoding utf8
    $imageLockResult = & $module {
        param($Path)
        Test-LabImageLock `
            -Configuration ([pscustomobject] @{ ImageLockPath = $Path }) `
            -ResolvedExecutionMode LINUX_NATIVE
    } $imageLockPath
    Assert-LabTest `
        -Condition ($imageLockResult.CheckStatus -eq 'PASS') `
        -Message 'A complete synthetic image lock must pass.'

    $stateRoot = Join-Path $testRoot 'state'
    $cleanupRunId = & $module { New-LabRunId }
    $paths = & $module {
        param($RunId, $Root)
        Initialize-LabRunState -LabRunId $RunId -StateRoot $Root
    } $cleanupRunId $stateRoot
    $firstLock = & $module {
        param($LockPath)
        Enter-LabStateLock -LockPath $LockPath
    } $paths.LockPath
    $secondLockRejected = $false
    try {
        & $module {
            param($LockPath)
            $secondLock = Enter-LabStateLock -LockPath $LockPath
            $secondLock.Dispose()
        } $paths.LockPath
    }
    catch {
        $secondLockRejected = $true
    }
    finally {
        $firstLock.Dispose()
    }
    Assert-LabTest `
        -Condition $secondLockRejected `
        -Message 'A concurrent state lock must be rejected.'

    $ownedPath = Join-Path $paths.RunDirectory 'owned-resource.tmp'
    $unregisteredPath = Join-Path $paths.RunDirectory 'unregistered-resource.tmp'
    Set-Content -LiteralPath $ownedPath -Value 'synthetic' -Encoding utf8
    Set-Content -LiteralPath $unregisteredPath -Value 'synthetic' -Encoding utf8
    & $module {
        param($RunId, $Root, $OwnedPath)
        Register-LabResource `
            -LabRunId $RunId `
            -Provider LOCAL_FILESYSTEM `
            -ResourceType FILE `
            -ResourceId SYNTHETIC_RESOURCE_001 `
            -ExactLocator $OwnedPath `
            -StateRoot $Root
    } $cleanupRunId $stateRoot $ownedPath

    $whatIfResult = Invoke-LabCleanup `
        -LabRunId $cleanupRunId `
        -StateRoot $stateRoot `
        -WhatIf
    Assert-LabTest `
        -Condition (
            $whatIfResult.CleanupStatus -eq 'WHATIF' -and
            (Test-Path -LiteralPath $ownedPath -PathType Leaf)
        ) `
        -Message 'WhatIf must not remove a registered resource.'

    $cleanupResult = Invoke-LabCleanup `
        -LabRunId $cleanupRunId `
        -StateRoot $stateRoot `
        -Confirm:$false
    Assert-LabTest `
        -Condition (
            $cleanupResult.CleanupStatus -eq 'CLEANUP_COMPLETED' -and
            -not (Test-Path -LiteralPath $ownedPath) -and
            (Test-Path -LiteralPath $unregisteredPath -PathType Leaf)
        ) `
        -Message 'Cleanup must remove only the exact registered resource.'
    $secondCleanup = Invoke-LabCleanup `
        -LabRunId $cleanupRunId `
        -StateRoot $stateRoot `
        -Confirm:$false
    Assert-LabTest `
        -Condition (
            $secondCleanup.CleanupStatus -eq 'CLEANUP_COMPLETED' -and
            $secondCleanup.RemovedResourceCount -eq 0
        ) `
        -Message 'Repeated cleanup must be idempotent.'

    $wildcardRejected = $false
    try {
        & $module {
            param($RunId, $Root, $RunDirectory)
            Register-LabResource `
                -LabRunId $RunId `
                -Provider LOCAL_FILESYSTEM `
                -ResourceType FILE `
                -ResourceId SYNTHETIC_RESOURCE_002 `
                -ExactLocator (Join-Path $RunDirectory '*.tmp') `
                -StateRoot $Root
        } $cleanupRunId $stateRoot $paths.RunDirectory
    }
    catch {
        $wildcardRejected = $true
    }
    Assert-LabTest `
        -Condition $wildcardRejected `
        -Message 'Wildcard cleanup registration must be rejected.'

    $foreignRunId = & $module { New-LabRunId }
    $foreignPaths = & $module {
        param($RunId, $Root)
        Initialize-LabRunState -LabRunId $RunId -StateRoot $Root
    } $foreignRunId $stateRoot
    $foreignPath = Join-Path $foreignPaths.RunDirectory 'foreign.tmp'
    Set-Content -LiteralPath $foreignPath -Value 'synthetic' -Encoding utf8
    & $module {
        param($RunId, $RegistryPath, $ForeignPath)
        Write-LabJsonFile -Path $RegistryPath -InputObject ([ordered] @{
                SchemaVersion = '1.0'
                DataClassification = 'LOCAL_RUNTIME_STATE'
                LabRunId = $RunId
                Resources = @(
                    [ordered] @{
                        OwnerRunId = 'LAB-20000101T000000Z-00000000'
                        Provider = 'LOCAL_FILESYSTEM'
                        ResourceType = 'FILE'
                        ResourceId = 'FOREIGN_RESOURCE_001'
                        ExactLocator = $ForeignPath
                        RegisteredAtUtc = [DateTime]::UtcNow.ToString('o')
                    }
                )
            })
    } $foreignRunId $foreignPaths.RegistryPath $foreignPath
    $foreignRejected = $false
    try {
        Invoke-LabCleanup `
            -LabRunId $foreignRunId `
            -StateRoot $stateRoot `
            -Confirm:$false | Out-Null
    }
    catch {
        $foreignRejected = $true
    }
    Assert-LabTest `
        -Condition (
            $foreignRejected -and
            (Test-Path -LiteralPath $foreignPath -PathType Leaf)
        ) `
        -Message 'Cleanup must reject a foreign owner before deleting anything.'

    $logPath = Join-Path $paths.RunDirectory 'redaction-test.jsonl'
    & $module {
        param($Path)
        $sensitivePropertyName = 'Pass' + 'word'
        $properties = @{ Result = 'PASS' }
        $properties[$sensitivePropertyName] = 'synthetic-value-must-not-appear'
        Write-LabEvent `
            -LogPath $Path `
            -Level INFO `
            -EventCode SECRET_REDACTION_TEST `
            -Properties $properties
    } $logPath
    $logText = Get-Content -LiteralPath $logPath -Raw -Encoding utf8
    Assert-LabTest `
        -Condition (
            $logText -notmatch 'synthetic-value-must-not-appear' -and
            $logText -match '\[REDACTED\]'
        ) `
        -Message 'Sensitive logging properties must be redacted.'

    $preflightRunId = & $module { New-LabRunId }
    $faultTargetPath = Join-Path $testRoot 'bounded-fault-target'
    [IO.Directory]::CreateDirectory($faultTargetPath) | Out-Null
    $escapedTestRoot = $testRoot.Replace("'", "''")
    $escapedFaultTargetPath = $faultTargetPath.Replace("'", "''")
    $runtimeConfigPath = Join-Path $testRoot 'lab.config.psd1'
    @"
@{
    SchemaVersion = '1.0'
    DataClassification = 'LOCAL_RUNTIME_CONFIG'
    ExecutionMode = 'AUTO'
    AllowedExecutionModes = @('WINDOWS_SINGLE_HOST', 'LINUX_NATIVE')
    SqlVersionPriority = @(2025, 2022, 2019)
    ContainerEngine = 'DOCKER'
    ContainerImageLogicalIds = @{
        '2019' = 'SQLSERVER_2019'
        '2022' = 'SQLSERVER_2022'
        '2025' = 'SQLSERVER_2025'
    }
    AcceptSqlServerEula = `$false
    ResourceProfile = 'Compact'
    StorageRoleBindings = @{
        IMAGE_CACHE = 'SYNTHETIC_TARGET_01'
        ACTIVE_VM = 'SYNTHETIC_TARGET_01'
        EPHEMERAL_DATA = 'SYNTHETIC_TARGET_01'
        FAULT_TARGET = 'SYNTHETIC_FAULT_TARGET_01'
    }
    StorageTargets = @(
        @{
            LogicalTargetId = 'SYNTHETIC_TARGET_01'
            Path = '$escapedTestRoot'
            Roles = @('IMAGE_CACHE', 'ACTIVE_VM', 'EPHEMERAL_DATA')
            IsSystemTarget = `$false
            IsApprovedLabTarget = `$true
        }
        @{
            LogicalTargetId = 'SYNTHETIC_FAULT_TARGET_01'
            Path = '$escapedFaultTargetPath'
            Roles = @('FAULT_TARGET')
            IsSystemTarget = `$false
            IsApprovedLabTarget = `$true
            MaximumSizeGiB = 64
        }
    )
    NetworkPolicy = @{
        PrivateRangeReference = 'SYNTHETIC_RANGE_01'
        RejectRouteCollision = `$true
        AllowExternalLabDataNetwork = `$false
    }
    Retention = @{ MaximumCacheAgeDays = 1; MaximumArtifactAgeDays = 1 }
    Timeouts = @{
        PreflightSeconds = 120
        SetupSeconds = 1800
        ObserveSeconds = 300
        CleanupSeconds = 900
    }
    RemoteHosts = @()
    SecretPolicy = @{
        Provider = 'NONE'
        RequiredSecretNames = @()
        AllowInteractive = `$false
    }
}
"@ | Set-Content -LiteralPath $runtimeConfigPath -Encoding utf8

    $firstPreflight = Invoke-LabPreflight `
        -LabRunId $preflightRunId `
        -ConfigPath $runtimeConfigPath `
        -StateRoot $stateRoot
    $secondPreflight = Invoke-LabPreflight `
        -LabRunId $preflightRunId `
        -ConfigPath $runtimeConfigPath `
        -StateRoot $stateRoot
    $preflightState = Get-LabStatus `
        -LabRunId $preflightRunId `
        -StateRoot $stateRoot
    Assert-LabTest `
        -Condition (
            $firstPreflight.LabRunId -eq $preflightRunId -and
            $secondPreflight.LabRunId -eq $preflightRunId -and
            $preflightState.PreflightInvocationCount -eq 2 -and
            $preflightState.RegisteredResourceCount -eq 0
        ) `
        -Message 'Repeated Preflight must update the same state without resources.'

    $capabilityDocumentPath = Join-Path (
        Join-Path $stateRoot $preflightRunId
    ) 'host-capabilities.json'
    $capabilityDocument = Get-Content `
        -LiteralPath $capabilityDocumentPath `
        -Raw `
        -Encoding utf8 |
        ConvertFrom-Json -Depth 100
    $hostSchemaPath = Join-Path $RepositoryRoot (
        'Lab/Contracts/host-capability.schema.json'
    )
    foreach ($hostEntry in $capabilityDocument.Hosts) {
        $capabilityJson = $hostEntry.Capability | ConvertTo-Json -Depth 100
        Assert-LabTest `
            -Condition (
                Test-Json `
                    -Json $capabilityJson `
                    -SchemaFile $hostSchemaPath `
                    -ErrorAction Stop
            ) `
            -Message 'Runtime capability vector violates its JSON schema.'
    }
}
finally {
    Remove-Module -Name DiagnosticLab -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        [IO.Directory]::Delete($testRoot, $true)
    }
}

Write-Output 'LAB-001 Welle 1 PowerShell tests passed.'

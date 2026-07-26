function Invoke-LabPreflight {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string] $LabRunId = (New-LabRunId),

        [Parameter()]
        [ValidateSet('AUTO', 'WINDOWS_SINGLE_HOST', 'LINUX_NATIVE', 'DISTRIBUTED')]
        [string] $ExecutionMode,

        [Parameter()]
        [string] $ConfigPath,

        [Parameter()]
        [switch] $AllowRemoteExecution,

        [Parameter()]
        [string] $StateRoot = (Get-LabDefaultStateRoot)
    )

    Test-LabRunId -LabRunId $LabRunId -ThrowOnInvalid | Out-Null
    $configurationArguments = @{}
    if ($PSBoundParameters.ContainsKey('ConfigPath')) {
        $configurationArguments.ConfigPath = $ConfigPath
    }
    if ($PSBoundParameters.ContainsKey('ExecutionMode')) {
        $configurationArguments.ExecutionMode = $ExecutionMode
    }
    $configuration = Resolve-LabConfiguration @configurationArguments
    $paths = Initialize-LabRunState -LabRunId $LabRunId -StateRoot $StateRoot
    $stateLock = Enter-LabStateLock -LockPath $paths.LockPath

    try {
        Write-LabEvent `
            -LogPath $paths.LogPath `
            -Level INFO `
            -EventCode PREFLIGHT_STARTED `
            -Properties @{
                LabRunId = $LabRunId
                ConfigSource = $configuration.ConfigSource
            }

        $localCapability = if ($IsWindows) {
            Get-LabWindowsHyperVHostCapability -Configuration $configuration
        }
        elseif ($IsLinux) {
            Get-LabLinuxHostCapability -Configuration $configuration
        }
        else {
            throw 'LAB-001 supports only Windows and Linux x86-64 hosts.'
        }

        $hostEntries = [Collections.Generic.List[object]]::new()
        $hostEntries.Add([pscustomobject] @{
                LogicalHostId = 'LOCAL_HOST'
                IsRemote = $false
                Status = 'AVAILABLE'
                ReasonCode = ''
                Capability = $localCapability
            })

        $remoteResults = [Collections.Generic.List[object]]::new()
        foreach ($remoteConfiguration in $configuration.RemoteHosts) {
            $remoteResult = Get-LabRemoteHostCapability `
                -RemoteHostConfiguration $remoteConfiguration `
                -Configuration $configuration `
                -AllowRemoteExecution:$AllowRemoteExecution
            $remoteResults.Add($remoteResult)
            if ($remoteResult.Status -eq 'AVAILABLE') {
                $hostEntries.Add($remoteResult)
            }
        }

        $modeResolution = Resolve-LabExecutionMode `
            -HostCapabilities @($hostEntries) `
            -RequestedMode $configuration.ExecutionMode `
            -AllowedExecutionModes $configuration.AllowedExecutionModes `
            -ContainerEngine $configuration.ContainerEngine
        $secretAvailability = Test-LabSecretAvailability `
            -SecretPolicy $configuration.SecretPolicy
        $imageLockCheck = Test-LabImageLock `
            -Configuration $configuration `
            -ResolvedExecutionMode $modeResolution.ResolvedExecutionMode
        $networkCheck = Test-LabNetworkPolicy `
            -NetworkPolicy $configuration.NetworkPolicy
        $blockers = Get-LabPreflightBlockers `
            -Configuration $configuration `
            -HostCapabilities @($hostEntries) `
            -ModeResolution $modeResolution `
            -SecretAvailability $secretAvailability `
            -ImageLockCheck $imageLockCheck `
            -NetworkCheck $networkCheck
        $preflightStatus = if ($blockers.Count -eq 0) {
            'READY'
        }
        else {
            'NOT_EXECUTABLE'
        }

        $hostCapabilityDocument = [ordered] @{
            SchemaVersion = '1.0'
            DataClassification = 'LOCAL_RUNTIME_STATE'
            LabRunId = $LabRunId
            Hosts = @(
                $hostEntries |
                    ForEach-Object {
                        [ordered] @{
                            LogicalHostId = $_.LogicalHostId
                            IsRemote = $_.IsRemote
                            Capability = $_.Capability
                        }
                    }
            )
        }
        Write-LabJsonFile `
            -Path (Join-Path $paths.RunDirectory 'host-capabilities.json') `
            -InputObject $hostCapabilityDocument

        $summary = [ordered] @{
            SchemaVersion = '1.0'
            DataClassification = 'LOCAL_RUNTIME_STATE'
            LabRunId = $LabRunId
            PreflightStatus = $preflightStatus
            ConfigSource = $configuration.ConfigSource
            ConfigurationHash = $configuration.ConfigurationHash
            RequestedExecutionMode = $configuration.ExecutionMode
            ResolvedExecutionMode = $modeResolution.ResolvedExecutionMode
            SupportedExecutionModes = @($modeResolution.SupportedExecutionModes)
            LocalHostClass = $localCapability.ResolvedHostClass
            BlockerReasonCodes = @($blockers)
            SecretProvider = $secretAvailability.Provider
            MissingLogicalSecretNames = @(
                $secretAvailability.MissingLogicalSecretNames
            )
            ImageLockCheck = [ordered] @{
                CheckStatus = $imageLockCheck.CheckStatus
                ReasonCodes = @($imageLockCheck.ReasonCodes)
                Items = @($imageLockCheck.Items)
            }
            NetworkCheck = [ordered] @{
                CheckStatus = $networkCheck.CheckStatus
                ReasonCodes = @($networkCheck.ReasonCodes)
                CollisionCount = $networkCheck.CollisionCount
            }
            RemoteHostResults = @(
                $remoteResults |
                    ForEach-Object {
                        [ordered] @{
                            LogicalHostId = $_.LogicalHostId
                            Status = $_.Status
                            ReasonCode = $_.ReasonCode
                        }
                    }
            )
            CompletedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-LabJsonFile `
            -Path (Join-Path $paths.RunDirectory 'preflight-summary.json') `
            -InputObject $summary

        $currentState = Read-LabJsonFile -Path $paths.StatePath
        Set-LabRunState -StatePath $paths.StatePath -Changes @{
            LifecycleStatus = 'PREFLIGHT_COMPLETE'
            PreflightStatus = $preflightStatus
            RequestedExecutionMode = $configuration.ExecutionMode
            ResolvedExecutionMode = $modeResolution.ResolvedExecutionMode
            LocalHostClass = $localCapability.ResolvedHostClass
            ConfigurationHash = $configuration.ConfigurationHash
            PreflightInvocationCount = (
                [int] $currentState.PreflightInvocationCount + 1
            )
        }
        Write-LabEvent `
            -LogPath $paths.LogPath `
            -Level INFO `
            -EventCode PREFLIGHT_COMPLETED `
            -Properties @{
                LabRunId = $LabRunId
                PreflightStatus = $preflightStatus
                BlockerCount = $blockers.Count
            }

        return [pscustomobject] $summary
    }
    catch {
        try {
            Set-LabRunState -StatePath $paths.StatePath -Changes @{
                LifecycleStatus = 'PREFLIGHT_FAILED'
                PreflightStatus = 'ERROR'
            }
            Write-LabEvent `
                -LogPath $paths.LogPath `
                -Level ERROR `
                -EventCode PREFLIGHT_FAILED `
                -Properties @{ LabRunId = $LabRunId }
        }
        catch {
            # Preserve the original Preflight exception.
        }
        throw
    }
    finally {
        $stateLock.Dispose()
    }
}

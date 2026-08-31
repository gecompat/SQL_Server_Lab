<#
.SYNOPSIS
    Read-only Vertragskern fuer Lifecycle-Reconcile-Plaene.
.DESCRIPTION
    Der erste Vertragsstand liest bestehende Runs abwaertskompatibel und bildet
    daraus einen serialisierbaren Desired-, Actual-, Diff- und Action-Plan.
    Hyper-V-Netzbindungen werden semantisch und read-only verglichen. Der
    Vertrag fuehrt bewusst keine Lifecycle- oder Netzwerkaktion aus und gibt
    keine Secrets, Hostwerte oder Runtime-Identitaeten aus.
#>

function ConvertTo-LabReconcileNetworkIntent {
    [CmdletBinding()]
    param($Network)

    if (-not $Network -or [string]::IsNullOrWhiteSpace([string]$Network.Intent)) { return $null }
    $intent = [string]$Network.Intent
    $exposure = if ($Network.PSObject.Properties['Exposure'] -and $Network.Exposure) { [string]$Network.Exposure } else {
        switch ($intent) { 'isolated' { 'none' }; 'lan' { 'lan' }; default { 'host' } }
    }
    $binding = if ($Network.PSObject.Properties['Binding'] -and $Network.Binding) { [string]$Network.Binding } else {
        switch ($intent) {
            'isolated' { 'private-switch' }
            'hostOnly' { 'internal-switch' }
            'nat' { 'shared-internal-nat' }
            'lan' { 'external-switch' }
            default { 'unknown' }
        }
    }
    return [PSCustomObject]@{
        Intent = $intent
        Exposure = $exposure
        Binding = $binding
        PlanStatus = if ($Network.PSObject.Properties['PlanStatus'] -and $Network.PlanStatus) { [string]$Network.PlanStatus } else { 'RESOLVED' }
        CapabilityStatus = if ($Network.PSObject.Properties['CapabilityStatus'] -and $Network.CapabilityStatus) { [string]$Network.CapabilityStatus } else { 'SUPPORTED' }
        ReasonCode = if ($Network.PSObject.Properties['ReasonCode'] -and $Network.ReasonCode) { [string]$Network.ReasonCode } else { $null }
    }
}

function New-LabDesiredState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][ValidateSet('RUNNING', 'STOPPED')][string]$TargetState,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $persisted = Get-LabPersistedDesiredState -RunId ([string]$Run.runId) -StateRoot $StateRoot
    if ($persisted.Status -eq 'VALID') {
        $snapshot = $persisted.Snapshot
        return [PSCustomObject]@{
            Contract = [PSCustomObject]@{ Name = 'SqlServerLab.DesiredState'; Version = '1.0' }
            RunId = [string]$Run.runId
            TargetState = $TargetState
            Source = 'persisted-desired-state'
            IsValid = $true
            ValidationError = $null
            Instances = @($snapshot.Instances | ForEach-Object {
                [PSCustomObject]@{
                    Id = [string]$_.Id
                    Provider = [string]$_.Provider
                    TargetState = $TargetState
                    Network = ConvertTo-LabReconcileNetworkIntent -Network $(if ($_.Intents) { $_.Intents.Network } else { $null })
                }
            })
        }
    }
    if ($persisted.Status -eq 'INVALID') {
        return [PSCustomObject]@{
            Contract = [PSCustomObject]@{ Name = 'SqlServerLab.DesiredState'; Version = '1.0' }
            RunId = [string]$Run.runId
            TargetState = $TargetState
            Source = 'persisted-desired-state-invalid'
            IsValid = $false
            ValidationError = [string]$persisted.Reason
            Instances = @()
        }
    }
    $instances = @()
    $connectionPath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') ([string]$Run.runId)) 'connection-info.json'
    if (Test-Path -LiteralPath $connectionPath -PathType Leaf) {
        try {
            $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
            $instances = @($connection.instances | ForEach-Object {
                $networkIntent = if ($_.labNetwork -and $_.labNetwork.intent) { [string]$_.labNetwork.intent }
                    elseif ($Run.metadata -and $Run.metadata.networkIntent) { [string]$Run.metadata.networkIntent }
                    else { $null }
                [PSCustomObject]@{
                    Id = [string]$_.id
                    Provider = [string]$_.provider
                    TargetState = $TargetState
                    Network = ConvertTo-LabReconcileNetworkIntent -Network $(if ($networkIntent) { [PSCustomObject]@{ Intent=$networkIntent } } else { $null })
                }
            })
        }
        catch { }
    }

    if ($instances.Count -eq 0 -and $Run.PSObject.Properties['providerSubRuns']) {
        $instances = @($Run.providerSubRuns | ForEach-Object {
            $provider = [string]$_.provider
            @($_.instanceIds | ForEach-Object {
                [PSCustomObject]@{ Id = [string]$_; Provider = $provider; TargetState = $TargetState; Network = $null }
            })
        })
    }

    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.DesiredState'; Version = '1.0' }
        RunId = [string]$Run.runId
        TargetState = $TargetState
        Source = 'connection-info-or-provider-subruns'
        IsValid = $true
        ValidationError = $null
        Instances = $instances
    }
}

function Get-LabHyperVNetworkReconcileActual {
    <#
    .SYNOPSIS
        Liest die Hyper-V-Netzbindung und gibt nur semantische, hostneutrale Evidenz aus.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)]$DesiredInstance,
        [string]$StateRoot
    )

    $unavailable = {
        param([string[]]$ReasonCodes)
        [PSCustomObject]@{
            Contract = [PSCustomObject]@{ Name='SqlServerLab.HyperVNetworkActualState'; Version='1.0' }
            Status = 'UNAVAILABLE'
            AttachmentStatus = 'UNAVAILABLE'
            InfrastructureStatus = 'UNAVAILABLE'
            GuestAddressStatus = 'UNOBSERVED'
            ObservedBinding = 'unknown'
            ReasonCodes = @($ReasonCodes | Sort-Object -Unique)
        }
    }

    try {
        if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
        $connectionPath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') ([string]$Run.runId)) 'connection-info.json'
        if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) {
            return & $unavailable @('HYPERV_NETWORK_CONNECTION_INFO_MISSING')
        }
        $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        $connectionInstance = @($connection.instances | Where-Object {
            [string]$_.id -eq [string]$DesiredInstance.Id -and [string]$_.provider -eq 'hyperv'
        }) | Select-Object -First 1
        if (-not $connectionInstance) { return & $unavailable @('HYPERV_NETWORK_INSTANCE_BINDING_MISSING') }

        $workflow = Get-HyperVLabWorkflowRun -RunId ([string]$Run.runId) -StateRoot $StateRoot
        $vmName = [string]$workflow.Instance.vmName
        if ([string]::IsNullOrWhiteSpace($vmName)) { return & $unavailable @('HYPERV_NETWORK_VM_IDENTITY_MISSING') }

        $reasonCodes = [Collections.Generic.List[string]]::new()
        $connectedAdapters = @(Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop | Where-Object { $_.SwitchName })
        $attachmentStatus = 'MATCHED'
        $observedBinding = 'unknown'
        if ($connectedAdapters.Count -eq 0) {
            $attachmentStatus = 'DRIFT'
            $observedBinding = 'disconnected'
            $reasonCodes.Add('HYPERV_NETWORK_ADAPTER_MISSING')
        }
        elseif ($connectedAdapters.Count -gt 1) {
            $attachmentStatus = 'DRIFT'
            $observedBinding = 'multiple'
            $reasonCodes.Add('HYPERV_NETWORK_ADAPTER_COUNT_DRIFT')
        }
        else {
            $adapter = $connectedAdapters[0]
            $switch = Get-VMSwitch -Name ([string]$adapter.SwitchName) -ErrorAction Stop
            $observedBinding = switch ([string]$switch.SwitchType) {
                'Private' { 'private-switch' }
                'Internal' { if ([string]$DesiredInstance.Network.Intent -eq 'nat') { 'shared-internal-nat' } else { 'internal-switch' } }
                'External' { 'external-switch' }
                default { 'unknown' }
            }
            $expectedSwitchName = if ($connectionInstance.labNetwork) { [string]$connectionInstance.labNetwork.name } else { $null }
            if (($expectedSwitchName -and -not [string]::Equals([string]$adapter.SwitchName, $expectedSwitchName, [StringComparison]::OrdinalIgnoreCase)) -or
                $observedBinding -ne [string]$DesiredInstance.Network.Binding) {
                $attachmentStatus = 'DRIFT'
                $reasonCodes.Add('HYPERV_NETWORK_SWITCH_BINDING_DRIFT')
            }
        }

        $infrastructureStatus = 'NOT_APPLICABLE'
        if ([string]$DesiredInstance.Network.Intent -in @('hostOnly', 'nat')) {
            if (-not $connectionInstance.labNetwork) {
                $infrastructureStatus = 'DRIFT'
                $reasonCodes.Add('HYPERV_NETWORK_BOUND_PLAN_MISSING')
            }
            else {
                $boundPlan = Resolve-LabHyperVNetworkBoundPlan -Intent ([string]$DesiredInstance.Network.Intent) `
                    -SwitchName ([string]$connectionInstance.labNetwork.name) -Subnet ([string]$connectionInstance.labNetwork.subnet)
                if ([string]$boundPlan.Status -ne 'READY') {
                    $infrastructureStatus = 'DRIFT'
                    foreach ($blocker in @($boundPlan.Blockers)) { if ($blocker) { $reasonCodes.Add([string]$blocker) } }
                }
                elseif (@($boundPlan.Actions).Count -gt 0) {
                    $infrastructureStatus = 'DRIFT'
                    $reasonCodes.Add('HYPERV_NETWORK_INFRASTRUCTURE_DRIFT')
                }
                else { $infrastructureStatus = 'MATCHED' }
            }
        }

        $guestAddressStatus = 'NOT_APPLICABLE'
        if ($connectionInstance.labNetwork -and $connectionInstance.labNetwork.address) {
            $expectedAddress = [string]$connectionInstance.labNetwork.address
            $observedAddresses = @($connectedAdapters | ForEach-Object { @($_.IPAddresses) } | ForEach-Object {
                $parsedAddress = $null
                if ($_ -and [System.Net.IPAddress]::TryParse([string]$_, [ref]$parsedAddress) -and
                    $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    [string]$parsedAddress
                }
            })
            if ($observedAddresses -contains $expectedAddress) { $guestAddressStatus = 'MATCHED' }
            elseif ($observedAddresses.Count -eq 0) { $guestAddressStatus = 'UNOBSERVED' }
            else {
                $guestAddressStatus = 'DRIFT'
                $reasonCodes.Add('HYPERV_NETWORK_GUEST_ADDRESS_DRIFT')
            }
        }

        $status = if ($attachmentStatus -eq 'DRIFT' -or $infrastructureStatus -eq 'DRIFT' -or $guestAddressStatus -eq 'DRIFT') { 'DRIFT' } else { 'MATCHED' }
        return [PSCustomObject]@{
            Contract = [PSCustomObject]@{ Name='SqlServerLab.HyperVNetworkActualState'; Version='1.0' }
            Status = $status
            AttachmentStatus = $attachmentStatus
            InfrastructureStatus = $infrastructureStatus
            GuestAddressStatus = $guestAddressStatus
            ObservedBinding = $observedBinding
            ReasonCodes = @($reasonCodes | Sort-Object -Unique)
        }
    }
    catch {
        return & $unavailable @('HYPERV_NETWORK_ACTUAL_STATE_UNAVAILABLE')
    }
}

function Get-LabActualState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        $Desired,
        [string]$StateRoot
    )

    $runtime = Get-LabRunRuntimeStatus -Run $Run -StateRoot $StateRoot
    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.ActualState'; Version = '1.0' }
        RunId = [string]$Run.runId
        State = [string]$runtime.State
        Source = [string]$runtime.Source
        Instances = @($runtime.Instances | ForEach-Object {
            $runtimeInstance = $_
            $desiredInstance = if ($Desired) { @($Desired.Instances | Where-Object {
                [string]$_.Id -eq [string]$runtimeInstance.Id -and [string]$_.Provider -eq [string]$runtimeInstance.Provider
            }) | Select-Object -First 1 } else { $null }
            $networkPlanResolved = $desiredInstance -and $desiredInstance.Network -and
                (-not $desiredInstance.Network.PSObject.Properties['PlanStatus'] -or
                    [string]::IsNullOrWhiteSpace([string]$desiredInstance.Network.PlanStatus) -or
                    [string]$desiredInstance.Network.PlanStatus -eq 'RESOLVED')
            $networkCapabilitySupported = $desiredInstance -and $desiredInstance.Network -and
                [string]$desiredInstance.Network.CapabilityStatus -ne 'DECLARED_UNSUPPORTED'
            $network = if ([string]$runtimeInstance.Provider -eq 'hyperv' -and $networkPlanResolved -and $networkCapabilitySupported) {
                Get-LabHyperVNetworkReconcileActual -Run $Run -DesiredInstance $desiredInstance -StateRoot $StateRoot
            } else { $null }
            [PSCustomObject]@{ Id = [string]$runtimeInstance.Id; Provider = [string]$runtimeInstance.Provider; State = [string]$runtimeInstance.State; Network = $network }
        })
    }
}

function Compare-LabDesiredActualState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Desired,
        [Parameter(Mandatory)]$Actual
    )

    $diagnosticStates = @('UNKNOWN', 'UNAVAILABLE', 'MISSING', 'PARTIAL')
    if ($Desired.PSObject.Properties.Name -contains 'IsValid' -and -not [bool]$Desired.IsValid) {
        return [PSCustomObject]@{
            ChangeClass = 'unsupported'
            Reasons = @("Persisted desired state ist ungültig: $($Desired.ValidationError)")
            Actions = @()
            Warnings = @("Bitte Snapshot reparieren oder entfernen; fail-closed ohne Teilmutation bis zum Zielzustand.")
        }
    }
    if ($Actual.State -in $diagnosticStates) {
        return [PSCustomObject]@{
            ChangeClass = 'unsupported'
            Reasons = @("Actual State '$($Actual.State)' ist nicht vollstaendig steuerbar.")
            Actions = @()
            Warnings = @('Keine Teilmutation planen; zuerst Runtime oder Recovery diagnostizieren.')
            NetworkDiff = @()
        }
    }

    $networkDiff = @($Desired.Instances | Where-Object {
        $_.Network -and [string]$_.Provider -eq 'hyperv'
    } | ForEach-Object {
        $desiredInstance = $_
        $actualInstance = @($Actual.Instances | Where-Object {
            [string]$_.Id -eq [string]$desiredInstance.Id -and [string]$_.Provider -eq [string]$desiredInstance.Provider
        }) | Select-Object -First 1
        $desiredUnsupported = ($desiredInstance.Network.PSObject.Properties['PlanStatus'] -and
            -not [string]::IsNullOrWhiteSpace([string]$desiredInstance.Network.PlanStatus) -and
            [string]$desiredInstance.Network.PlanStatus -ne 'RESOLVED') -or
            [string]$desiredInstance.Network.CapabilityStatus -eq 'DECLARED_UNSUPPORTED'
        $actualNetwork = if ($actualInstance) { $actualInstance.Network } else { $null }
        $actualStatus = if ($desiredUnsupported) { 'DECLARED_UNSUPPORTED' }
            elseif ($actualNetwork) { [string]$actualNetwork.Status }
            else { 'UNAVAILABLE' }
        [PSCustomObject]@{
            Kind = 'network'
            InstanceId = [string]$desiredInstance.Id
            Provider = [string]$desiredInstance.Provider
            DesiredIntent = [string]$desiredInstance.Network.Intent
            DesiredBinding = [string]$desiredInstance.Network.Binding
            ActualStatus = $actualStatus
            ChangeClass = if ($actualStatus -eq 'MATCHED') { 'no-op' } else { 'unsupported' }
            ReasonCodes = if ($desiredUnsupported) {
                @($(if ($desiredInstance.Network.ReasonCode) { [string]$desiredInstance.Network.ReasonCode } else { 'NETWORK_INTENT_PROVIDER_UNSUPPORTED' }))
            }
            elseif ($actualNetwork) { @($actualNetwork.ReasonCodes) }
            else { @('HYPERV_NETWORK_ACTUAL_STATE_UNAVAILABLE') }
        }
    })
    $networkProblems = @($networkDiff | Where-Object { $_.ChangeClass -ne 'no-op' })
    if ($networkProblems.Count -gt 0) {
        return [PSCustomObject]@{
            ChangeClass = 'unsupported'
            Reasons = @($networkProblems | ForEach-Object {
                "Netzwerk-Istzustand fuer Instance '$($_.InstanceId)' ist '$($_.ActualStatus)'."
            })
            Actions = @()
            Warnings = @('Netzwerkdrift wird read-only ausgewiesen; der Lifecycle-Executor fuehrt keine Teilmutation aus.')
            NetworkDiff = $networkDiff
        }
    }

    if ($Actual.State -eq $Desired.TargetState) {
        return [PSCustomObject]@{
            ChangeClass = 'no-op'; Reasons = @('Desired State und Actual State stimmen ueberein.')
            Actions = @(); Warnings = @(); NetworkDiff = $networkDiff
        }
    }

    $operation = if ($Desired.TargetState -eq 'RUNNING') { 'Start' } else { 'Stop' }
    $providers = @($Desired.Instances | ForEach-Object Provider | Where-Object { $_ } | Sort-Object -Unique)
    return [PSCustomObject]@{
        ChangeClass = 'restart'
        Reasons = @("Actual State '$($Actual.State)' weicht vom Target '$($Desired.TargetState)' ab.")
        Actions = @($providers | ForEach-Object {
            [PSCustomObject]@{ Operation = $operation; Provider = [string]$_; TargetState = $Desired.TargetState }
        })
        Warnings = @('Die Aktionen sind nur ein Vorschlag; die Ausfuehrung erfolgt explizit ueber Invoke-SqlServerLabReconcileAction.')
        NetworkDiff = $networkDiff
    }
}

function New-LabReconcilePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('RUNNING', 'STOPPED')][string]$TargetState,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $desired = New-LabDesiredState -Run $run -TargetState $TargetState -StateRoot $StateRoot
    $actual = Get-LabActualState -Run $run -Desired $desired -StateRoot $StateRoot
    $comparison = Compare-LabDesiredActualState -Desired $desired -Actual $actual
    $migrationGuard = Get-LabHyperVResourceMigrationLifecycleGuard -RunId $RunId -StateRoot $StateRoot
    if (-not $migrationGuard.Allowed) {
        $comparison = [PSCustomObject]@{
            ChangeClass = 'unsupported'
            Reasons = @("Hyper-V-Ressourcenmigration blockiert Lifecycle-Reconcile: $([string]$migrationGuard.ReasonCode)")
            Actions = @()
            Warnings = @([string]$migrationGuard.Reason)
            NetworkDiff = @($comparison.NetworkDiff)
        }
    }

    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.ReconcilePlan'; Version = '1.0' }
        RunId = [string]$run.runId
        Desired = $desired
        Actual = $actual
        Diff = @([PSCustomObject]@{
            Kind = 'lifecycle'
            TargetState = $desired.TargetState; ActualState = $actual.State; ChangeClass = $comparison.ChangeClass; Reasons = $comparison.Reasons
        }) + @($comparison.NetworkDiff)
        Actions = $comparison.Actions
        HighestChangeClass = $comparison.ChangeClass
        IsNoOp = $comparison.ChangeClass -eq 'no-op'
        MutationAllowed = $false
        Warnings = $comparison.Warnings
        HyperVResourceMigration = $migrationGuard
    }
}

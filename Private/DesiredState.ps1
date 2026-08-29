<#
.SYNOPSIS
    Persistiert einen geheimnisfreien Sollzustand vor Provider-Mutationen.
#>
function Get-LabDeclaredIntentCapabilityStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ProviderCapability,
        [Parameter(Mandatory)][string]$RequiredCapability
    )

    $declared = @($ProviderCapability.Capabilities | ForEach-Object { [string]$_.SourceKey })
    if ($declared -contains $RequiredCapability) { return 'DECLARED_SUPPORTED' }
    return 'DECLARED_UNSUPPORTED'
}

function Get-LabDriveIntentRole {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DriveId)

    switch -Regex ($DriveId) {
        '(?i)temp' { return 'tempdb' }
        '(?i)backup' { return 'backup' }
        '(?i)log' { return 'sqlLog' }
        '(?i)data|mssql' { return 'sqlData' }
        default { return 'general' }
    }
}

function New-LabInstanceIntentSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)]$ProviderCapability
    )

    $provider = [string]$Instance.provider
    $driveCapability = if ($provider -eq 'hyperv') { 'run-local-additional-vhdx' } else { 'volume-mounts' }
    $drives = @($Instance.drives | Where-Object { $_ } | ForEach-Object {
        $binding = if ($_.hostPath) { 'host-mount' } elseif ($provider -eq 'hyperv') { 'additional-vhdx' } else { 'managed-volume' }
        [PSCustomObject]@{
            Id = [string]$_.id
            Role = Get-LabDriveIntentRole -DriveId ([string]$_.id)
            GuestPath = [string]$_.containerPath
            Binding = $binding
            AccessMode = if ($_.readOnly -eq $true) { 'readOnly' } else { 'readWrite' }
            SizeGB = if ($_.sizeLimitGB) { [double]$_.sizeLimitGB } else { $null }
            PerformanceClass = if ($_.type) { [string]$_.type } else { 'auto' }
            Persistence = if ($_.persistence) { [string]$_.persistence } elseif ($_.hostPath) { 'external-host-path' } else { 'run-scoped' }
            RequiredCapability = $driveCapability
            CapabilityStatus = Get-LabDeclaredIntentCapabilityStatus -ProviderCapability $ProviderCapability -RequiredCapability $driveCapability
        }
    })

    $networkIntent = if ($provider -eq 'hyperv' -and $Instance.hyperv -and $Instance.hyperv.switchName) {
        'lan'
    }
    elseif ($Instance.networkName) {
        'hostOnly'
    }
    else {
        'isolated'
    }
    $networkCapability = switch ($networkIntent) {
        'lan' { 'external-network-binding' }
        'hostOnly' { 'managed-lab-network' }
        default { 'isolated-network' }
    }
    $network = [PSCustomObject]@{
        Intent = $networkIntent
        Exposure = if ($networkIntent -eq 'hostOnly') { 'host' } else { 'none' }
        ManagedBinding = [bool]$Instance.networkName
        RequiredCapability = $networkCapability
        CapabilityStatus = Get-LabDeclaredIntentCapabilityStatus -ProviderCapability $ProviderCapability -RequiredCapability $networkCapability
    }

    $externalRuntimePlans = @(Resolve-LabExternalRuntimePlansForInstance -Instance $Instance)
    $generalSoftwareItems = @($Instance.software | Where-Object {
        $_ -and [string]$_.id -notin @('sql-python', 'sql-r', 'sql-java', 'sql-csharp')
    } | ForEach-Object {
        [PSCustomObject]@{
            Id = [string]$_.id
            Optional = if ($null -ne $_.optional) { [bool]$_.optional } else { $true }
            Scope = if ($_.scope) { [string]$_.scope } else { 'instance' }
            Status = 'DECLARED_UNSUPPORTED'
            ReasonCode = 'SOFTWARE_NOT_CATALOGUED'
        }
    })
    $externalRuntimeItems = @($externalRuntimePlans | ForEach-Object {
        [PSCustomObject]@{
            Id = [string]$_.SoftwareId
            PlanKey = [string]$_.PlanKey
            Optional = $false
            Scope = 'sqlExternalRuntime'
            Status = [string]$_.Status
            ReasonCode = [string]$_.ReasonCode
            VariantId = [string]$_.VariantId
            RuntimeVersion = [string]$_.RuntimeVersion
            InstallationMethod = [string]$_.InstallationMethod
            RequiredCapabilities = @($_.RequiredCapabilities)
            ArtifactRefs = @($_.ArtifactRefs)
            PackageLocks = @($_.PackageLocks)
            Restart = $_.Restart
            Validation = $_.Validation
        }
    })
    $softwareItems = @($generalSoftwareItems) + @($externalRuntimeItems)
    $planningCapabilityStatus = if ($softwareItems.Count -eq 0) {
        'NOT_REQUESTED'
    }
    else {
        Get-LabDeclaredIntentCapabilityStatus -ProviderCapability $ProviderCapability -RequiredCapability 'software-catalog-planning'
    }
    $software = [PSCustomObject]@{
        Items = $softwareItems
        RequiredCapability = if ($softwareItems.Count -gt 0) { 'software-catalog-planning' } else { $null }
        PlanningCapabilityStatus = $planningCapabilityStatus
        CapabilityStatus = if ($softwareItems.Count -eq 0) {
            'NOT_REQUESTED'
        }
        elseif ($planningCapabilityStatus -ne 'DECLARED_SUPPORTED' -or
            @($softwareItems | Where-Object Status -ne 'RESOLVED').Count -gt 0) {
            'DECLARED_UNSUPPORTED'
        }
        else {
            'DECLARED_SUPPORTED'
        }
    }

    $storage = if ($Instance.storageIntent) {
        $intent = $Instance.storageIntent
        [PSCustomObject]@{
            ContractVersion = [string]$intent.ContractVersion
            PlacementPolicy = [string]$intent.PlacementPolicy
            PhysicalIsolation = [string]$intent.PhysicalIsolation
            Roles = $intent.Roles
            TempDb = $intent.TempDb
            DatabaseFiles = @($intent.DatabaseFiles)
            RestoreRules = @($intent.RestoreRules)
            BindingStatus = 'LOCAL_BINDING_REQUIRED'
        }
    }
    else { $null }

    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.InstanceIntent'; Version = '1.0'; EvidenceBoundary = 'provider-metadata' }
        Drives = $drives
        Network = $network
        Software = $software
        Storage = $storage
    }
}

function New-LabDesiredStateSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ResolvedLab,
        [Parameter(Mandatory)][ValidateSet('manifest', 'adhoc')][string]$ProvisioningMode,
        [bool]$PersistentData
    )

    $providerCapabilities = @(Get-LabProviderCapabilityContract)
    $snapshot = [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.RunDesiredState'; Version = '1.0' }
        ProvisioningMode = $ProvisioningMode
        LabName = [string]$ResolvedLab.name
        PersistentData = $PersistentData
        Instances = @($ResolvedLab.instances | ForEach-Object {
            $instance = $_
            $providerCapability = $providerCapabilities | Where-Object { $_.Provider -eq [string]$instance.provider } | Select-Object -First 1
            if (-not $providerCapability) {
                $providerCapability = [PSCustomObject]@{ Capabilities = @() }
            }
            [PSCustomObject]@{
                Id = [string]$instance.id; Provider = [string]$instance.provider; Version = [string]$instance.version
                Profile = [string]$instance.profile; AutoStart = [string]$instance.autostart
                DatabaseNames = @($instance.databases | ForEach-Object { [string]$_.name })
                Intents = New-LabInstanceIntentSnapshot -Instance $instance -ProviderCapability $providerCapability
            }
        })
    }
    return $snapshot
}

function Get-LabPersistedDesiredState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [string]$StateRoot)
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if (-not $run.metadata -or -not $run.metadata.desiredState) {
        return [PSCustomObject]@{
            Status = 'ABSENT'
            Snapshot = $null
            Reason = $null
        }
    }

    $snapshot = $run.metadata.desiredState
    if (-not $snapshot.Contract -or [string]$snapshot.Contract.Name -ne 'SqlServerLab.RunDesiredState' -or [string]$snapshot.Contract.Version -ne '1.0') {
        return [PSCustomObject]@{
            Status = 'INVALID'
            Snapshot = $snapshot
            Reason = 'Run metadata desiredState-Contract fehlt oder hat keine gueltige Contract-Identitaet.'
        }
    }

    if (-not $snapshot.Instances -or @($snapshot.Instances).Count -eq 0) {
        return [PSCustomObject]@{
            Status = 'INVALID'
            Snapshot = $snapshot
            Reason = 'Run metadata desiredState-Inhalt enthaelt keine Instanzen.'
        }
    }

    $validationErrors = New-Object System.Collections.Generic.List[string]
    foreach ($instance in @($snapshot.Instances)) {
        if (-not $instance.Id) { $validationErrors.Add("Instance entry hat keine Id.") }
        if (-not $instance.Provider) { $validationErrors.Add("Instance '$($instance.Id)' hat keinen Provider.") }
        if ($instance.Intents -and
            (-not $instance.Intents.Contract -or
             [string]$instance.Intents.Contract.Name -ne 'SqlServerLab.InstanceIntent' -or
             [string]$instance.Intents.Contract.Version -ne '1.0')) {
            $validationErrors.Add("Instance '$($instance.Id)' hat keinen gueltigen InstanceIntent-Contract.")
        }
    }

    if ($validationErrors.Count -gt 0) {
        return [PSCustomObject]@{
            Status = 'INVALID'
            Snapshot = $snapshot
            Reason = ($validationErrors -join ' ')
        }
    }

    return [PSCustomObject]@{
        Status = 'VALID'
        Snapshot = $snapshot
        Reason = $null
    }
}

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

function New-LabHyperVResourceIntentSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Instance)

    if ([string]$Instance.provider -ne 'hyperv') { return $null }
    $settings = $Instance.hyperv
    $startupMB = if ($settings -and $settings.PSObject.Properties['memoryStartupMB']) {
        [int]$settings.memoryStartupMB
    }
    else { 4096 }
    $dynamicEnabled = if ($settings -and $settings.PSObject.Properties['dynamicMemoryEnabled']) {
        [bool]$settings.dynamicMemoryEnabled
    }
    else { $true }
    $minimumMB = if (-not $dynamicEnabled) {
        $startupMB
    }
    elseif ($settings -and $settings.PSObject.Properties['memoryMinimumMB']) {
        [int]$settings.memoryMinimumMB
    }
    else { [int][Math]::Max(512, [Math]::Floor([double]$startupMB / 2)) }
    $maximumMB = if (-not $dynamicEnabled) {
        $startupMB
    }
    elseif ($settings -and $settings.PSObject.Properties['memoryMaximumMB']) {
        [int]$settings.memoryMaximumMB
    }
    else { [int][Math]::Min(1048576, [long]$startupMB * 2) }

    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name='SqlServerLab.HyperVResourceIntent'; Version='1.0' }
        ProcessorCount = if ($settings -and $settings.PSObject.Properties['processorCount']) { [int]$settings.processorCount } else { 4 }
        DynamicMemoryEnabled = $dynamicEnabled
        MemoryMinimumMB = $minimumMB
        MemoryStartupMB = $startupMB
        MemoryMaximumMB = $maximumMB
        RequiredCapability = 'hyperv-resource-reconcile'
        CapabilityStatus = 'DECLARED_SUPPORTED'
    }
}

function New-LabSqlConfigurationIntentSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)]$ProviderCapability
    )

    if (-not $Instance.serverConfig) { return $null }
    $config = $Instance.serverConfig
    $configurationValues = [Collections.Generic.List[object]]::new()
    if ($config.memory) {
        if ($null -ne $config.memory.minMB) {
            $configurationValues.Add([PSCustomObject]@{ Name='min server memory (MB)'; Value=[int]$config.memory.minMB })
        }
        if ($null -ne $config.memory.maxMB) {
            $configurationValues.Add([PSCustomObject]@{ Name='max server memory (MB)'; Value=[int]$config.memory.maxMB })
        }
    }
    if ($null -ne $config.maxDop) {
        $configurationValues.Add([PSCustomObject]@{ Name='max degree of parallelism'; Value=[int]$config.maxDop })
    }
    if ($null -ne $config.costThreshold) {
        $configurationValues.Add([PSCustomObject]@{ Name='cost threshold for parallelism'; Value=[int]$config.costThreshold })
    }
    if ($config.spConfigure) {
        foreach ($property in @($config.spConfigure.PSObject.Properties | Sort-Object Name)) {
            $name = [string]$property.Name
            if ($name -notmatch '^[A-Za-z0-9 ()_-]+$') {
                throw "SQL_CONFIGURATION_INTENT_NAME_INVALID: $name"
            }
            $configurationValues.Add([PSCustomObject]@{ Name=$name; Value=[int]$property.Value })
        }
    }

    $deduplicated = [Collections.Generic.List[object]]::new()
    foreach ($group in @($configurationValues | Group-Object { ([string]$_.Name).ToLowerInvariant() } | Sort-Object Name)) {
        $values = @($group.Group | ForEach-Object { [long]$_.Value } | Sort-Object -Unique)
        if ($values.Count -ne 1) {
            throw "SQL_CONFIGURATION_INTENT_CONFLICT: $($group.Group[0].Name)"
        }
        $deduplicated.Add([PSCustomObject]@{ Name=[string]$group.Group[0].Name; Value=[long]$values[0] })
    }
    $requiredCapability = if ([string]$Instance.provider -eq 'hyperv') { 'hyperv-sql-configuration-reconcile' } else { 'sql-configuration-reconcile' }
    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name='SqlServerLab.SqlConfigurationIntent'; Version='1.0' }
        Configurations = @($deduplicated)
        TraceFlags = @($config.traceFlags | ForEach-Object { [int]$_ } | Sort-Object -Unique)
        RequiredCapability = $requiredCapability
        CapabilityStatus = Get-LabDeclaredIntentCapabilityStatus -ProviderCapability $ProviderCapability -RequiredCapability $requiredCapability
    }
}

function New-LabSqlEndpointIntentSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)]$ProviderCapability
    )

    if ([string]$Instance.provider -ne 'hyperv') { return $null }
    $settings = $Instance.hyperv
    $port = if ($settings -and $settings.PSObject.Properties['sqlPort']) { [int]$settings.sqlPort } else { 1433 }
    if ($port -lt 1 -or $port -gt 65535) { throw 'SQL_ENDPOINT_INTENT_PORT_INVALID' }
    $requiredCapability = 'hyperv-sql-port-reconcile'
    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name='SqlServerLab.SqlEndpointIntent'; Version='1.0' }
        Protocol = 'tcp'
        Port = $port
        RequiredCapability = $requiredCapability
        CapabilityStatus = Get-LabDeclaredIntentCapabilityStatus -ProviderCapability $ProviderCapability -RequiredCapability $requiredCapability
    }
}

function Get-LabTestDatabasePlanKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$RestoreDefinition)

    if (-not $RestoreDefinition.sampleId -or -not $RestoreDefinition.sampleVariant) {
        throw 'TEST_DATABASE_INTENT_SAMPLE_IDENTITY_MISSING'
    }
    $canonicalSource = Get-LabCanonicalArtifactSource -Source ([string]$RestoreDefinition.source)
    $canonical = [ordered]@{
        Contract = 'SqlServerLab.TestDatabasePlanKey/1.0'
        SampleId = [string]$RestoreDefinition.sampleId
        SampleVariant = [string]$RestoreDefinition.sampleVariant
        SourceSha256 = Get-LabSampleBaselineSha256Text -Text $canonicalSource
        ArtifactType = [string]$RestoreDefinition.artifactType
        HandlerContractVersion = [string]$RestoreDefinition.handlerContractVersion
        ExpectedSha256 = if ($RestoreDefinition.expectedSha256) { ([string]$RestoreDefinition.expectedSha256).ToLowerInvariant() } else { $null }
        ExpectedDatabaseNames = @($RestoreDefinition.expectedOutputs | Where-Object { [string]$_.kind -eq 'database' } | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
    }
    if ($canonical.ExpectedDatabaseNames.Count -eq 0) { throw 'TEST_DATABASE_INTENT_OUTPUTS_MISSING' }
    return Get-LabSampleBaselineSha256Text -Text ($canonical | ConvertTo-Json -Depth 20 -Compress)
}

function New-LabDatabaseIntentSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)]$ProviderCapability
    )

    $requiredCapability = if ([string]$Instance.provider -eq 'hyperv') { 'hyperv-test-database-reconcile' } else { 'test-database-reconcile' }
    $items = [Collections.Generic.List[object]]::new()
    foreach ($database in @($Instance.databases | Where-Object { $_ })) {
        if ($database.restore -and $database.restore.sampleId) {
            $outputs = @($database.restore.expectedOutputs | Where-Object { [string]$_.kind -eq 'database' } | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
            $planKey = Get-LabTestDatabasePlanKey -RestoreDefinition $database.restore
            $items.Add([PSCustomObject]@{
                Type = 'catalog-sample'
                Name = [string]$database.name
                SampleId = [string]$database.restore.sampleId
                SampleVariant = [string]$database.restore.sampleVariant
                PlanKey = $planKey
                DefinitionHash = $planKey
                ExpectedDatabaseNames = $outputs
                ReconcileSupported = [string]$Instance.provider -eq 'hyperv'
            })
        }
        else {
            $sourceHash = if ($database.restore -and $database.restore.source) {
                Get-LabSampleBaselineSha256Text -Text ([string]$database.restore.source)
            }
            else { $null }
            $definition = [ordered]@{
                Contract='SqlServerLab.DatabaseDefinitionHash/1.0';Type=if($database.restore){'direct-restore'}else{'create'}
                Name=[string]$database.name;Collation=[string]$database.collation;Files=$database.files;Options=$database.options
                RestoreSourceSha256=$sourceHash;RestoreType=if($database.restore){[string]$database.restore.type}else{$null}
                RestoreExpectedSha256=if($database.restore -and $database.restore.expectedSha256){[string]$database.restore.expectedSha256}else{$null}
                RestoreReplace=if($database.restore){[bool]$database.restore.replace}else{$null}
            }
            $items.Add([PSCustomObject]@{
                Type = if ($database.restore) { 'direct-restore' } else { 'create' }
                Name = [string]$database.name
                SampleId = $null
                SampleVariant = $null
                PlanKey = $null
                DefinitionHash = Get-LabSampleBaselineSha256Text -Text ($definition | ConvertTo-Json -Depth 30 -Compress)
                ExpectedDatabaseNames = @([string]$database.name)
                ReconcileSupported = $false
            })
        }
    }
    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name='SqlServerLab.DatabaseIntent'; Version='1.0' }
        Items = @($items | Sort-Object Type, Name, PlanKey)
        RequiredCapability = if (@($items | Where-Object Type -eq 'catalog-sample').Count -gt 0) { $requiredCapability } else { $null }
        CapabilityStatus = if (@($items | Where-Object Type -eq 'catalog-sample').Count -eq 0) {
            'NOT_REQUESTED'
        }
        else {
            Get-LabDeclaredIntentCapabilityStatus -ProviderCapability $ProviderCapability -RequiredCapability $requiredCapability
        }
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
            PersistentStorageId = if ($_.persistentStorageId) { [string]$_.persistentStorageId } else { $null }
            RequiredCapability = $driveCapability
            CapabilityStatus = Get-LabDeclaredIntentCapabilityStatus -ProviderCapability $ProviderCapability -RequiredCapability $driveCapability
        }
    })

    $networkPlan = Resolve-LabNetworkIntentPlan `
        -Provider $provider `
        -Network $Instance.network `
        -HasLegacyHyperVSwitch:([bool]($Instance.hyperv -and $Instance.hyperv.switchName))
    $networkCapabilityStatus = if ([string]$networkPlan.Status -ne 'RESOLVED') {
        'DECLARED_UNSUPPORTED'
    }
    else {
        Get-LabDeclaredIntentCapabilityStatus `
            -ProviderCapability $ProviderCapability `
            -RequiredCapability ([string]$networkPlan.RequiredCapability)
    }
    $network = [PSCustomObject]@{
        Intent = [string]$networkPlan.Intent
        Exposure = [string]$networkPlan.Exposure
        Binding = [string]$networkPlan.Binding
        ManagedBinding = [string]$networkPlan.Intent -ne 'isolated'
        RequiredCapability = [string]$networkPlan.RequiredCapability
        CapabilityStatus = $networkCapabilityStatus
        PlanStatus = [string]$networkPlan.Status
        ReasonCode = [string]$networkPlan.ReasonCode
    }

    $softwarePlans = @(Resolve-LabSoftwarePlansForInstance -Instance $Instance)
    $softwareItems = @($softwarePlans | ForEach-Object {
        [PSCustomObject]@{
            Id = [string]$_.SoftwareId
            PlanKey = [string]$_.PlanKey
            Optional = if ($_.PSObject.Properties['Optional']) { [bool]$_.Optional } else { [string]$_.Kind -ne 'sqlExternalRuntime' }
            Scope = if ([string]$_.Kind -eq 'sqlExternalRuntime') { 'sqlExternalRuntime' } else { 'instance' }
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
        Resources = New-LabHyperVResourceIntentSnapshot -Instance $Instance
        SqlEndpoint = New-LabSqlEndpointIntentSnapshot -Instance $Instance -ProviderCapability $ProviderCapability
        SqlConfiguration = New-LabSqlConfigurationIntentSnapshot -Instance $Instance -ProviderCapability $ProviderCapability
        Databases = New-LabDatabaseIntentSnapshot -Instance $Instance -ProviderCapability $ProviderCapability
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
        Ai = $ResolvedLab.ai
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

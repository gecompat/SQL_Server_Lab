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

function Test-LabSqlConfigurationIntentName {
    <#
    .SYNOPSIS
        Prueft die kanonische Schreibweise eines SQL-Systemkonfigurationsnamens.
    .DESCRIPTION
        Die Grammatik umfasst nur durch Leerzeichen getrennte ASCII-Woerter,
        Unterstriche oder Bindestriche innerhalb eines Worts sowie die von
        `sys.configurations` verwendeten Einheitssuffixe. Die abschliessende
        Zielbindung erfolgt vor einer Mutation gegen den exakten Namen in
        `sys.configurations`; diese Vorpruefung ist keine freie SQL-Eingabe.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    return $Name.Length -le 128 -and
        $Name -match '^[A-Za-z0-9](?:[A-Za-z0-9_-]| [A-Za-z0-9_-]+)*(?: \((?:B|KB|MB|ms|min|s|%)\))?$'
}

function Assert-LabSqlConfigurationIntentName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Test-LabSqlConfigurationIntentName -Name $Name)) {
        throw "SQL_CONFIGURATION_INTENT_NAME_INVALID: $Name"
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
    $processorCount = if ($settings -and $settings.PSObject.Properties['processorCount']) {
        [int]$settings.processorCount
    }
    else { 4 }

    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name='SqlServerLab.HyperVResourceIntent'; Version='1.0' }
        ProcessorCount = [long]$processorCount
        DynamicMemoryEnabled = $dynamicEnabled
        MemoryMinimumMB = [long]$minimumMB
        MemoryStartupMB = [long]$startupMB
        MemoryMaximumMB = [long]$maximumMB
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
            Assert-LabSqlConfigurationIntentName -Name $name
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
        CapabilityAssessment = New-LabInstanceCapabilityAssessment -Instance $Instance -ProviderCapability $ProviderCapability -Network $network -Drives $drives -Software $software
        Storage = $storage
        WindowsLocale = $Instance.windowsLocale
        WindowsActivation = $Instance.windowsActivation
    }
}

function New-LabDesiredStateSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ResolvedLab,
        [Parameter(Mandatory)][ValidateSet('manifest', 'adhoc')][string]$ProvisioningMode,
        [bool]$PersistentData,
        $PreviousSnapshot
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
            $intents = New-LabInstanceIntentSnapshot -Instance $instance -ProviderCapability $providerCapability
            # Ein Target-Rebuild migriert bestehende optionale Metadaten nicht.
            # Alle anderen Felder bleiben Bestandteil der bisherigen Driftpruefung.
            $previous = @($PreviousSnapshot.Instances | Where-Object {
                [string]$_.Id -ceq [string]$instance.id -and [string]$_.Provider -ceq [string]$instance.provider
            })
            if ($previous.Count -eq 1 -and $previous[0].Intents -and
                -not $previous[0].Intents.PSObject.Properties['CapabilityAssessment']) {
                $intents.PSObject.Properties.Remove('CapabilityAssessment')
            }
            [PSCustomObject]@{
                Id = [string]$instance.id; Provider = [string]$instance.provider; Version = [string]$instance.version
                Profile = [string]$instance.profile; AutoStart = [string]$instance.autostart
                DatabaseNames = @($instance.databases | ForEach-Object { [string]$_.name })
                Intents = $intents
            }
        })
    }
    return $snapshot
}

function Test-LabPersistedSqlEndpointIntent {
    [CmdletBinding()]
    param($SqlEndpoint, [string]$Provider)

    # Der Snapshot ist ein Persistenzvertrag, kein bequemes Eingabeformat:
    # unbekannte Felder und Coercion (z.B. true oder "1433") duerfen keinen
    # spaeteren Hyper-V-/Gastzugriff ausloesen.
    if ($null -eq $SqlEndpoint -or $SqlEndpoint -is [string] -or $SqlEndpoint -is [bool]) { return $false }
    $expectedFields = @('CapabilityStatus','Contract','Port','Protocol','RequiredCapability')
    if ((@($SqlEndpoint.PSObject.Properties.Name | Sort-Object) -join ',') -cne ($expectedFields -join ',')) { return $false }
    if (-not $SqlEndpoint.Contract -or $SqlEndpoint.Contract -is [string] -or $SqlEndpoint.Contract -is [bool] -or
        ((@($SqlEndpoint.Contract.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'Name,Version') -or
        [string]$SqlEndpoint.Contract.Name -cne 'SqlServerLab.SqlEndpointIntent' -or
        [string]$SqlEndpoint.Contract.Version -cne '1.0') { return $false }
    if ([string]$Provider -ine 'hyperv' -or [string]$SqlEndpoint.Protocol -cne 'tcp' -or
        [string]$SqlEndpoint.RequiredCapability -cne 'hyperv-sql-port-reconcile' -or
        [string]$SqlEndpoint.CapabilityStatus -cnotin @('DECLARED_SUPPORTED','DECLARED_UNSUPPORTED')) { return $false }

    $port = $SqlEndpoint.Port
    $integralTypes = @([byte],[sbyte],[int16],[uint16],[int],[uint32],[long],[uint64])
    if ($null -eq $port -or $integralTypes -notcontains $port.GetType()) { return $false }
    return ([decimal]$port -ge 1 -and [decimal]$port -le 65535)
}

function Test-LabPersistedSqlConfigurationIntent {
    [CmdletBinding()]
    param($SqlConfiguration, [string]$Provider)

    # Der Persistenzsnapshot ist kein Eingabeformat. Insbesondere duerfen
    # gespeicherte Strings, Bools oder Gleitkommawerte nicht spaeter in einen
    # SQL-/Hyper-V-Reconcile-Aufruf coercen.
    if ($null -eq $SqlConfiguration -or $SqlConfiguration -is [string] -or
        $SqlConfiguration -is [bool] -or $SqlConfiguration -is [array]) { return $false }
    $expectedFields = @('CapabilityStatus','Configurations','Contract','RequiredCapability','TraceFlags')
    if ((@($SqlConfiguration.PSObject.Properties.Name | Sort-Object) -join ',') -cne ($expectedFields -join ',')) { return $false }
    if ($null -eq $SqlConfiguration.Contract -or $SqlConfiguration.Contract -is [string] -or
        $SqlConfiguration.Contract -is [bool] -or $SqlConfiguration.Contract -is [array] -or
        ((@($SqlConfiguration.Contract.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'Name,Version') -or
        [string]$SqlConfiguration.Contract.Name -cne 'SqlServerLab.SqlConfigurationIntent' -or
        [string]$SqlConfiguration.Contract.Version -cne '1.0') { return $false }
    if ([string]$Provider -ine 'hyperv' -or
        [string]$SqlConfiguration.RequiredCapability -cne 'hyperv-sql-configuration-reconcile' -or
        [string]$SqlConfiguration.CapabilityStatus -cnotin @('DECLARED_SUPPORTED','DECLARED_UNSUPPORTED')) { return $false }
    if ($SqlConfiguration.Configurations -isnot [array] -or $SqlConfiguration.TraceFlags -isnot [array]) { return $false }

    $configurationNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($configuration in @($SqlConfiguration.Configurations)) {
        if ($null -eq $configuration -or $configuration -is [string] -or $configuration -is [bool] -or $configuration -is [array] -or
            ((@($configuration.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'Name,Value') -or
            $configuration.Name -isnot [string] -or -not (Test-LabSqlConfigurationIntentName -Name $configuration.Name) -or
            # New-LabSqlConfigurationIntentSnapshot normalizes every persisted
            # configuration value to Int64 after first accepting only Int32
            # manifest values.  The reconcile path carries that value as
            # SqlDbType.BigInt, so accepting another runtime type or a value
            # outside the originating Int32 range would create a coercion
            # boundary after state validation.
            $configuration.Value -isnot [long] -or $configuration.Value -lt [int]::MinValue -or $configuration.Value -gt [int]::MaxValue -or
            -not $configurationNames.Add($configuration.Name)) { return $false }
    }

    $traceFlags = [System.Collections.Generic.HashSet[long]]::new()
    foreach ($traceFlag in @($SqlConfiguration.TraceFlags)) {
        # Persisted JSON numbers normalize to Int64, while every subsequent
        # trace-flag consumer binds Int32.  Check the complete Int32 range
        # before the cast so malformed UInt64 values cannot throw during the
        # invalid-state path.
        if ($traceFlag -isnot [long] -or $traceFlag -lt 1 -or $traceFlag -gt [int]::MaxValue -or
            -not $traceFlags.Add($traceFlag)) { return $false }
    }
    return $true
}

function Test-LabPersistedHyperVResourceIntent {
    [CmdletBinding()]
    param($Resources, [string]$Provider)

    # Persisted desired state is a closed contract, not a permissive input
    # surface.  Every number has already passed manifest validation and JSON
    # deserialization normalizes it to Int64; accepting any other CLR type
    # here would reintroduce a coercion boundary before Hyper-V is read.
    if ($null -eq $Resources -or $Resources -is [string] -or $Resources -is [bool] -or
        $Resources -is [array]) { return $false }
    $expectedFields = @(
        'CapabilityStatus','Contract','DynamicMemoryEnabled','MemoryMaximumMB',
        'MemoryMinimumMB','MemoryStartupMB','ProcessorCount','RequiredCapability'
    )
    if ((@($Resources.PSObject.Properties.Name | Sort-Object) -join ',') -cne
        ($expectedFields -join ',')) { return $false }
    if ($null -eq $Resources.Contract -or $Resources.Contract -is [string] -or
        $Resources.Contract -is [bool] -or $Resources.Contract -is [array] -or
        ((@($Resources.Contract.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'Name,Version') -or
        [string]$Resources.Contract.Name -cne 'SqlServerLab.HyperVResourceIntent' -or
        [string]$Resources.Contract.Version -cne '1.0') { return $false }
    if ([string]$Provider -ine 'hyperv' -or
        [string]$Resources.RequiredCapability -cne 'hyperv-resource-reconcile' -or
        [string]$Resources.CapabilityStatus -cnotin @('DECLARED_SUPPORTED','DECLARED_UNSUPPORTED') -or
        $Resources.DynamicMemoryEnabled -isnot [bool]) { return $false }

    if ($Resources.ProcessorCount -isnot [long] -or
        $Resources.ProcessorCount -lt 1 -or $Resources.ProcessorCount -gt 64) { return $false }
    foreach ($memoryField in @('MemoryMinimumMB','MemoryStartupMB','MemoryMaximumMB')) {
        $memoryValue = $Resources.$memoryField
        if ($memoryValue -isnot [long] -or $memoryValue -lt 512 -or $memoryValue -gt 1048576) { return $false }
    }
    if ($Resources.MemoryMinimumMB -gt $Resources.MemoryStartupMB -or
        $Resources.MemoryStartupMB -gt $Resources.MemoryMaximumMB) { return $false }
    if (-not $Resources.DynamicMemoryEnabled -and
        ($Resources.MemoryMinimumMB -ne $Resources.MemoryStartupMB -or
         $Resources.MemoryStartupMB -ne $Resources.MemoryMaximumMB)) { return $false }
    return $true
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
            ReasonCodes = @()
        }
    }

    $snapshot = $run.metadata.desiredState
    if (-not $snapshot.Contract -or [string]$snapshot.Contract.Name -ne 'SqlServerLab.RunDesiredState' -or [string]$snapshot.Contract.Version -ne '1.0') {
        return [PSCustomObject]@{
            Status = 'INVALID'
            Snapshot = $snapshot
            Reason = 'DESIRED_STATE_CONTRACT_INVALID'
            ReasonCodes = @('DESIRED_STATE_CONTRACT_INVALID')
        }
    }

    if (-not $snapshot.Instances -or @($snapshot.Instances).Count -eq 0) {
        return [PSCustomObject]@{
            Status = 'INVALID'
            Snapshot = $snapshot
            Reason = 'DESIRED_STATE_INSTANCES_MISSING'
            ReasonCodes = @('DESIRED_STATE_INSTANCES_MISSING')
        }
    }

    $validationErrors = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($snapshot.ProvisioningMode -isnot [string] -or
        (-not (($snapshot.ProvisioningMode -ceq 'manifest') -or ($snapshot.ProvisioningMode -ceq 'adhoc')))) {
        [void]$validationErrors.Add('DESIRED_STATE_PROVISIONING_MODE_INVALID')
    }
    if ($snapshot.PersistentData -isnot [bool]) {
        [void]$validationErrors.Add('DESIRED_STATE_PERSISTENT_DATA_INVALID')
    }
    $instanceIdsByProvider = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]]::new([StringComparer]::OrdinalIgnoreCase)
    $supportedProviders = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$supportedProviders.Add('docker')
    [void]$supportedProviders.Add('podman')
    [void]$supportedProviders.Add('hyperv')
    foreach ($instance in @($snapshot.Instances)) {
        if ($instance.Intents -and $instance.Intents.PSObject.Properties['CapabilityAssessment'] -and
            -not (Test-LabInstanceCapabilityAssessment -Assessment $instance.Intents.CapabilityAssessment)) {
            [void]$validationErrors.Add('INSTANCE_CAPABILITY_ASSESSMENT_INVALID')
        }
        $idIsValid = $false
        $providerIsValid = $false
        $instanceId = $null
        $provider = $null
        if ($null -eq $instance.Id) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_ID_MISSING')
        }
        elseif ($instance.Id -isnot [string]) {
            # Persistierte JSON-Werte duerfen nicht durch String-Coercion zu
            # scheinbar gueltigen Manifest-IDs werden (z.B. $true oder $false).
            [void]$validationErrors.Add('DESIRED_INSTANCE_ID_INVALID')
        }
        else {
            $instanceId = $instance.Id
            if ($instanceId.Length -eq 0) {
                [void]$validationErrors.Add('DESIRED_INSTANCE_ID_MISSING')
            }
            elseif ($instanceId -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$') {
                [void]$validationErrors.Add('DESIRED_INSTANCE_ID_INVALID')
            }
            else {
                $idIsValid = $true
            }
        }
        $provider = [string]$instance.Provider
        if ($null -eq $instance.Provider -or $provider.Length -eq 0) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_PROVIDER_MISSING')
        }
        else {
            if (-not $supportedProviders.Contains($provider)) {
                [void]$validationErrors.Add('DESIRED_INSTANCE_PROVIDER_INVALID')
            }
            else {
                $providerIsValid = $true
            }
        }
        if ($instance.Intents -and $instance.Intents.PSObject.Properties['Network'] -and
            -not (Test-LabPersistedNetworkIntent -Network $instance.Intents.Network -Provider $provider)) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_NETWORK_INTENT_INVALID')
        }
        if ($instance.Intents -and $instance.Intents.PSObject.Properties['SqlEndpoint'] -and $null -ne $instance.Intents.SqlEndpoint -and
            -not (Test-LabPersistedSqlEndpointIntent -SqlEndpoint $instance.Intents.SqlEndpoint -Provider $provider)) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_SQL_ENDPOINT_INTENT_INVALID')
        }
        if ($instance.Intents -and $instance.Intents.PSObject.Properties['SqlConfiguration'] -and $null -ne $instance.Intents.SqlConfiguration -and
            -not (Test-LabPersistedSqlConfigurationIntent -SqlConfiguration $instance.Intents.SqlConfiguration -Provider $provider)) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_SQL_CONFIGURATION_INTENT_INVALID')
        }
        if ($instance.Intents -and $instance.Intents.PSObject.Properties['Resources'] -and $null -ne $instance.Intents.Resources -and
            -not (Test-LabPersistedHyperVResourceIntent -Resources $instance.Intents.Resources -Provider $provider)) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_HYPERV_RESOURCE_INTENT_INVALID')
        }
        if ($idIsValid -and $providerIsValid) {
            if (-not $instanceIdsByProvider.ContainsKey($provider)) {
                $instanceIdsByProvider[$provider] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            }
            if (-not $instanceIdsByProvider[$provider].Add($instanceId)) {
                [void]$validationErrors.Add('DESIRED_INSTANCE_IDENTITY_DUPLICATE')
            }
        }
        if ($instance.Intents -and
            (-not $instance.Intents.Contract -or
             [string]$instance.Intents.Contract.Name -ne 'SqlServerLab.InstanceIntent' -or
             [string]$instance.Intents.Contract.Version -ne '1.0')) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_INTENT_CONTRACT_INVALID')
        }
    }

    if ($validationErrors.Count -gt 0) {
        $reasonCodes = [string[]]@($validationErrors)
        [Array]::Sort($reasonCodes, [StringComparer]::Ordinal)
        return [PSCustomObject]@{
            Status = 'INVALID'
            Snapshot = $snapshot
            Reason = ($reasonCodes -join ',')
            ReasonCodes = @($reasonCodes)
        }
    }

    return [PSCustomObject]@{
        Status = 'VALID'
        Snapshot = $snapshot
        Reason = $null
        ReasonCodes = @()
    }
}

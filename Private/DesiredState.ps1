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

function New-LabContainerRuntimeIntentSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Instance)

    if ([string]$Instance.provider -notin @('docker','podman')) { return $null }
    # Generic container snapshots and capability assessment intentionally have
    # no SQL version.  They must not enter the collation catalog path or gain
    # a synthetic runtime intent.
    $version = [string]$Instance.version
    if ([string]::IsNullOrWhiteSpace($version)) { return $null }
    # Capability assessments can contain syntactically versioned generic or
    # deprecated inputs.  Without a currently supported catalog decision they
    # have not crossed the manifest/parser boundary and cannot form a runtime
    # intent.
    if (-not (Test-SqlServerVersionSupported -VersionId $version).Supported) { return $null }
    $profile = Get-LabResourceProfile -Name $(if ($Instance.profile) { [string]$Instance.profile } else { 'standard' })
    # Docker and Podman accept fractional CPU quotas.  Keep the numeric value
    # as a double through JSON instead of truncating it to an integer.
    $cpu = if ($Instance.runtimeResources -and $null -ne $Instance.runtimeResources.cpu) { [double]$Instance.runtimeResources.cpu } else { [double]$profile.maxCpus }
    if ([double]::IsNaN($cpu) -or [double]::IsInfinity($cpu) -or $cpu -lt 0.5 -or $cpu -gt 64 -or
        [Math]::Abs($cpu - [Math]::Round($cpu, 2, [MidpointRounding]::AwayFromZero)) -gt 0.000000001) {
        throw 'CONTAINER_RUNTIME_CPU_PRECISION_INVALID'
    }
    $memoryMB = if ($Instance.runtimeResources -and $null -ne $Instance.runtimeResources.memoryMB) { [long]$Instance.runtimeResources.memoryMB } else { [long]$profile.maxMemoryMB }
    # A versioned instance has passed the manifest/parser boundary.  Its
    # collation and catalog errors are contractual and must reach the caller.
    $collation = Resolve-LabSqlServerCollation -Name ([string]$Instance.collation) -SqlVersion $version
    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name='SqlServerLab.ContainerRuntimeIntent'; Version='1.0' }
        Cpu = $cpu
        MemoryMB = $memoryMB
        Collation = $collation
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
        # An omitted optional traceFlags property must remain an empty intent;
        # converting a null pipeline item to Int32 would persist an invalid 0.
        TraceFlags = @($config.traceFlags | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
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
        ContainerRuntime = New-LabContainerRuntimeIntentSnapshot -Instance $Instance
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
    param($SqlConfiguration, [string]$Provider, $ProviderCapability)

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
    $expectedRequiredCapability = if ([string]$Provider -ieq 'hyperv') {
        'hyperv-sql-configuration-reconcile'
    }
    elseif ([string]$Provider -iin @('docker','podman')) {
        'sql-configuration-reconcile'
    }
    else { return $false }
    if ([string]$SqlConfiguration.RequiredCapability -cne $expectedRequiredCapability -or
        [string]$SqlConfiguration.CapabilityStatus -cne (Get-LabDeclaredIntentCapabilityStatus `
            -ProviderCapability $ProviderCapability -RequiredCapability $expectedRequiredCapability)) { return $false }
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

function Test-LabPersistedContainerRuntimeIntent {
    [CmdletBinding()]
    param($ContainerRuntime, [string]$Provider, [string]$SqlVersion)

    if ($null -eq $ContainerRuntime -or $ContainerRuntime -is [string] -or $ContainerRuntime -is [bool] -or $ContainerRuntime -is [array]) { return $false }
    $expectedFields = @('Collation','Contract','Cpu','MemoryMB')
    if ((@($ContainerRuntime.PSObject.Properties.Name | Sort-Object) -join ',') -cne ($expectedFields -join ',')) { return $false }
    if (-not $ContainerRuntime.Contract -or $ContainerRuntime.Contract -is [string] -or $ContainerRuntime.Contract -is [bool] -or
        ((@($ContainerRuntime.Contract.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'Name,Version') -or
        [string]$ContainerRuntime.Contract.Name -cne 'SqlServerLab.ContainerRuntimeIntent' -or
        [string]$ContainerRuntime.Contract.Version -cne '1.0' -or
        [string]$Provider -cnotin @('docker','podman') -or
        (-not ($ContainerRuntime.Cpu -is [long] -or $ContainerRuntime.Cpu -is [double])) -or
        [double]::IsNaN([double]$ContainerRuntime.Cpu) -or [double]::IsInfinity([double]$ContainerRuntime.Cpu) -or
        [double]$ContainerRuntime.Cpu -lt 0.5 -or [double]$ContainerRuntime.Cpu -gt 64 -or
        [Math]::Abs(([double]$ContainerRuntime.Cpu) - [Math]::Round([double]$ContainerRuntime.Cpu, 2, [MidpointRounding]::AwayFromZero)) -gt 0.000000001 -or
        $ContainerRuntime.MemoryMB -isnot [long] -or $ContainerRuntime.MemoryMB -lt 512 -or $ContainerRuntime.MemoryMB -gt 1048576 -or
        $ContainerRuntime.Collation -isnot [string]) { return $false }
    try {
        # The invariant roundtrip rejects culture-dependent or coerced input
        # while preserving a valid fractional Docker/Podman quota exactly.
        $cpuValue = [double]$ContainerRuntime.Cpu
        $cpuText = $cpuValue.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
        $roundtripCpu = 0.0
        if (-not [double]::TryParse($cpuText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$roundtripCpu) -or $roundtripCpu -ne $cpuValue) { return $false }
        return [string](Resolve-LabSqlServerCollation -Name $ContainerRuntime.Collation -SqlVersion $SqlVersion) -ceq [string]$ContainerRuntime.Collation
    }
    catch { return $false }
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

function Test-LabPersistedDriveIntents {
    [CmdletBinding()]
    param($Drives, [string]$Provider, $ProviderCapability)

    # Drives are persisted provider metadata, not a second manifest input
    # surface.  Validate their closed JSON shape before a reconcile path can
    # derive a VHDX size or a mount binding from them.
    if ($null -eq $Drives) { return $true }
    if ($Drives -isnot [array]) { return $false }

    $providerName = ([string]$Provider).ToLowerInvariant()
    if ($providerName -notin @('docker','podman','hyperv')) { return $false }
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $expectedFields = @(
        'AccessMode','Binding','CapabilityStatus','GuestPath','Id','PerformanceClass',
        'Persistence','PersistentStorageId','RequiredCapability','Role','SizeGB'
    )
    $containerRuntimeDrives = @{
        'runtime-mssql' = '/var/opt/mssql'
        'runtime-mssql-external-languages' = '/var/opt/mssql-extensibility/externallanguages'
        'runtime-mssql-external-libraries' = '/var/opt/mssql-extensibility/externallibraries'
    }
    $containerPersistentDrives = @{
        'persistent-mssql' = '/var/opt/mssql'
        'persistent-mssql-external-languages' = '/var/opt/mssql-extensibility/externallanguages'
        'persistent-mssql-external-libraries' = '/var/opt/mssql-extensibility/externallibraries'
    }
    $containerReservedPersistence = @{
        'runtime-mssql' = @('run-scoped-runtime-volume')
        'runtime-mssql-external-languages' = @('run-scoped-runtime-volume')
        'runtime-mssql-external-libraries' = @('run-scoped-runtime-volume')
        'persistent-mssql' = @('data-root-runtime-volume','cataloged-runtime-volume')
        'persistent-mssql-external-languages' = @('data-root-runtime-volume','cataloged-runtime-volume')
        'persistent-mssql-external-libraries' = @('data-root-runtime-volume','cataloged-runtime-volume')
        'persistent-backups' = @('data-root-backup-bind')
    }
    foreach ($drive in @($Drives)) {
        if ($null -eq $drive -or $drive -is [string] -or $drive -is [bool] -or $drive -is [array] -or
            ((@($drive.PSObject.Properties.Name | Sort-Object) -join ',') -cne ($expectedFields -join ','))) { return $false }
        $isCanonicalContainerDrive = $providerName -in @('docker','podman') -and
            ($containerRuntimeDrives.ContainsKey([string]$drive.Id) -or $containerPersistentDrives.ContainsKey([string]$drive.Id))
        if ($drive.Id -isnot [string] -or
            (($drive.Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$') -and -not $isCanonicalContainerDrive) -or
            -not $ids.Add($drive.Id) -or
            $drive.Role -isnot [string] -or $drive.Role -cnotin @('sqlData','sqlLog','tempdb','backup','general') -or
            $drive.AccessMode -isnot [string] -or $drive.AccessMode -cnotin @('readOnly','readWrite') -or
            $drive.PerformanceClass -isnot [string] -or $drive.PerformanceClass -cnotin @('ssd','hdd','tmpfs','auto') -or
            $drive.Persistence -isnot [string] -or $drive.Persistence -cnotin @(
                'run-scoped','external-host-path','run-scoped-runtime-volume',
                'data-root-runtime-volume','data-root-backup-bind','cataloged-runtime-volume'
            ) -or
            $drive.CapabilityStatus -isnot [string] -or $drive.CapabilityStatus -cnotin @('DECLARED_SUPPORTED','DECLARED_UNSUPPORTED') -or
            $drive.GuestPath -isnot [string] -or [string]::IsNullOrWhiteSpace($drive.GuestPath)) { return $false }

        # CapabilityStatus is a projection of the declared provider contract,
        # not a caller-selectable enum.  A persisted "supported" value must
        # therefore never upgrade a drive whose declared capability is absent.
        if ($null -eq $ProviderCapability -or
            [string]$drive.CapabilityStatus -cne (Get-LabDeclaredIntentCapabilityStatus `
                -ProviderCapability $ProviderCapability `
                -RequiredCapability ([string]$drive.RequiredCapability))) { return $false }

        if ($null -ne $drive.PersistentStorageId -and
            ($drive.PersistentStorageId -isnot [string] -or -not [guid]::TryParse($drive.PersistentStorageId, [ref]([guid]::Empty)))) { return $false }
        if ($null -ne $drive.SizeGB -and
            ($drive.SizeGB -isnot [double] -or -not [double]::IsFinite($drive.SizeGB) -or
             $drive.SizeGB -lt 0.1 -or $drive.SizeGB -gt 65536)) { return $false }

        if ($providerName -eq 'hyperv') {
            if ($drive.Binding -cne 'additional-vhdx' -or
                $drive.RequiredCapability -cne 'run-local-additional-vhdx' -or
                $drive.PerformanceClass -ceq 'tmpfs' -or $null -eq $drive.SizeGB -or
                $drive.GuestPath -notmatch '^[D-Zd-z]:\\(?:[^<>:"/|?*\r\n]+(?:\\[^<>:"/|?*\r\n]+)*)?$' -or
                $drive.Persistence -cne 'run-scoped' -or $null -ne $drive.PersistentStorageId) { return $false }
        }
        else {
            if ($drive.Binding -cnotin @('host-mount','managed-volume') -or
                $drive.RequiredCapability -cne 'volume-mounts' -or
                $drive.GuestPath -notmatch '^/(?:[^/\x00\r\n]+(?:/[^/\x00\r\n]+)*)?$') { return $false }

            # These producer-owned IDs carry SQL system state or the bound
            # data-root backup lane.  They must not be downgraded into a
            # generic user drive by changing the entire persisted group to
            # run-scoped/null before a reconcile path reads it.
            $reservedPersistences = $containerReservedPersistence[[string]$drive.Id]
            if ($null -ne $reservedPersistences -and [string]$drive.Persistence -cnotin $reservedPersistences) { return $false }
            if ($drive.Binding -ceq 'host-mount') {
                if (($drive.Persistence -ceq 'external-host-path' -and $null -eq $drive.PersistentStorageId) -or
                    ($drive.Persistence -ceq 'data-root-backup-bind' -and $null -eq $drive.PersistentStorageId -and
                     $drive.Id -ceq 'persistent-backups' -and $drive.GuestPath -ceq '/var/opt/mssql/backup')) {
                    continue
                }
                return $false
            }

            if ($drive.Persistence -ceq 'run-scoped' -and $null -eq $drive.PersistentStorageId) { continue }
            if ($drive.Persistence -ceq 'run-scoped-runtime-volume' -and
                $null -ne $drive.PersistentStorageId -and
                $containerRuntimeDrives.ContainsKey([string]$drive.Id) -and
                $drive.GuestPath -ceq $containerRuntimeDrives[[string]$drive.Id]) { continue }
            if ($drive.Persistence -ceq 'data-root-runtime-volume' -and
                $containerPersistentDrives.ContainsKey([string]$drive.Id) -and
                $drive.GuestPath -ceq $containerPersistentDrives[[string]$drive.Id]) { continue }
            if ($drive.Persistence -ceq 'cataloged-runtime-volume' -and
                $null -ne $drive.PersistentStorageId -and
                $containerPersistentDrives.ContainsKey([string]$drive.Id) -and
                $drive.GuestPath -ceq $containerPersistentDrives[[string]$drive.Id]) { continue }
            return $false
        }
    }

    # The canonical container system volumes are not independent user drives.
    # PersistentLabData emits them as one of three exact groups: the system
    # volume alone, or the system volume together with both external-runtime
    # sidecars.  Keep that producer contract intact after persistence so a
    # caller cannot attach a sidecar to an arbitrary identity, split a group
    # across identities, or drop one member before reconcile reads it.
    if ($providerName -in @('docker','podman')) {
        $containerDriveGroups = @(
            [PSCustomObject]@{
                Persistence = 'run-scoped-runtime-volume'
                SystemId = 'runtime-mssql'
                SidecarIds = @('runtime-mssql-external-languages','runtime-mssql-external-libraries')
                RequiresStorageId = $true
            },
            [PSCustomObject]@{
                Persistence = 'data-root-runtime-volume'
                SystemId = 'persistent-mssql'
                SidecarIds = @('persistent-mssql-external-languages','persistent-mssql-external-libraries')
                RequiresStorageId = $false
            },
            [PSCustomObject]@{
                Persistence = 'cataloged-runtime-volume'
                SystemId = 'persistent-mssql'
                SidecarIds = @('persistent-mssql-external-languages','persistent-mssql-external-libraries')
                RequiresStorageId = $true
            }
        )
        foreach ($groupDefinition in $containerDriveGroups) {
            $group = @($Drives | Where-Object { $_.Persistence -ceq $groupDefinition.Persistence })
            if ($group.Count -eq 0) { continue }

            $groupIds = @($group | ForEach-Object { [string]$_.Id })
            $hasSidecar = @($groupIds | Where-Object { $_ -in $groupDefinition.SidecarIds }).Count -gt 0
            $expectedIds = @($groupDefinition.SystemId)
            if ($hasSidecar) { $expectedIds += @($groupDefinition.SidecarIds) }
            if ($groupIds.Count -ne $expectedIds.Count -or
                @($expectedIds | Where-Object { $_ -notin $groupIds }).Count -ne 0) { return $false }

            if ($groupDefinition.RequiresStorageId) {
                $storageIds = @($group | ForEach-Object { [string]$_.PersistentStorageId } | Sort-Object -Unique)
                if ($storageIds.Count -ne 1 -or [string]::IsNullOrWhiteSpace($storageIds[0])) { return $false }
            }
            elseif (@($group | Where-Object { $null -ne $_.PersistentStorageId }).Count -ne 0) {
                # Data-root runtime volumes deliberately have no catalog or
                # run-scoped identity; PersistentLabData only emits their
                # stable volume names and the backup bind separately.
                return $false
            }
        }
    }
    return $true
}

function Test-LabPersistedStorageIntent {
    [CmdletBinding()]
    param($Storage)

    # Der persistierte Snapshot verwendet absichtlich ein PascalCase-Envelope,
    # waehrend der portable Storage-Vertrag lower camel case verwendet.  Nur
    # eine vollstaendig geschlossene Envelope darf deshalb in einen neuen,
    # schema-validierten portablen Wert rehydriert werden.  Dies verhindert,
    # dass ein nachtraeglich eingefuegtes Feld oder eine abweichende Schreibweise
    # spaeter unbemerkt im Hyper-V-Storage-Reconcile verwendet wird.
    if ($null -eq $Storage -or $Storage -is [string] -or $Storage -is [bool] -or
        $Storage -is [array]) { return $false }
    $expectedFields = @(
        'BindingStatus','ContractVersion','DatabaseFiles','PhysicalIsolation','PlacementPolicy',
        'RestoreRules','Roles','TempDb'
    )
    if ((@($Storage.PSObject.Properties.Name | Sort-Object) -join ',') -cne
        ($expectedFields -join ',')) { return $false }
    if ($Storage.BindingStatus -isnot [string] -or $Storage.BindingStatus -cne 'LOCAL_BINDING_REQUIRED') { return $false }

    # Do not pass the persisted PascalCase object directly to a later consumer.
    # Assert-LabStorageIntent owns the complete portable schema and the semantic
    # selector/file-count rules after this explicit casing boundary.
    $portable = [PSCustomObject]@{
        contractVersion = $Storage.ContractVersion
        placementPolicy = $Storage.PlacementPolicy
        physicalIsolation = $Storage.PhysicalIsolation
        roles = $Storage.Roles
        tempDb = $Storage.TempDb
        databaseFiles = $Storage.DatabaseFiles
        restoreRules = $Storage.RestoreRules
    }
    try {
        $null = Assert-LabStorageIntent -StorageIntent $portable
        return $true
    }
    catch {
        return $false
    }
}

function Test-LabPersistedDatabaseIntent {
    [CmdletBinding()]
    param($Databases, [string]$Provider, $ProviderCapability)

    # Database intents are persisted provider metadata, not a permissive
    # restore/create request.  Keep the envelope closed before a reconcile
    # path reads a manifest, a VM, or a SQL endpoint from the run state.
    if ($null -eq $Databases -or $Databases -is [string] -or $Databases -is [bool] -or
        $Databases -is [array]) { return $false }
    $expectedFields = @('CapabilityStatus','Contract','Items','RequiredCapability')
    if ((@($Databases.PSObject.Properties.Name | Sort-Object) -join ',') -cne
        ($expectedFields -join ',')) { return $false }
    if ($null -eq $Databases.Contract -or $Databases.Contract -is [string] -or
        $Databases.Contract -is [bool] -or $Databases.Contract -is [array] -or
        ((@($Databases.Contract.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'Name,Version') -or
        [string]$Databases.Contract.Name -cne 'SqlServerLab.DatabaseIntent' -or
        [string]$Databases.Contract.Version -cne '1.0' -or
        $Databases.Items -isnot [array]) { return $false }

    $providerName = ([string]$Provider).ToLowerInvariant()
    if ($providerName -notin @('docker','podman','hyperv') -or $null -eq $ProviderCapability) { return $false }
    $itemFields = @('DefinitionHash','ExpectedDatabaseNames','Name','PlanKey','ReconcileSupported','SampleId','SampleVariant','Type')
    $itemKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $outputNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $catalogSampleCount = 0
    foreach ($item in @($Databases.Items)) {
        if ($null -eq $item -or $item -is [string] -or $item -is [bool] -or $item -is [array] -or
            ((@($item.PSObject.Properties.Name | Sort-Object) -join ',') -cne ($itemFields -join ',')) -or
            $item.Type -isnot [string] -or $item.Type -cnotin @('catalog-sample','direct-restore','create') -or
            $item.Name -isnot [string] -or $item.Name -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$' -or
            $item.DefinitionHash -isnot [string] -or $item.DefinitionHash -notmatch '^[a-f0-9]{64}$' -or
            $item.ExpectedDatabaseNames -isnot [array] -or $item.ReconcileSupported -isnot [bool]) { return $false }

        $expectedNames = @($item.ExpectedDatabaseNames)
        if ($expectedNames.Count -eq 0) { return $false }
        foreach ($name in $expectedNames) {
            if ($name -isnot [string] -or $name -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$' -or
                -not $outputNames.Add($name)) { return $false }
        }

        switch ([string]$item.Type) {
            'catalog-sample' {
                $catalogSampleCount++
                if ($item.SampleId -isnot [string] -or [string]::IsNullOrWhiteSpace($item.SampleId) -or
                    $item.SampleVariant -isnot [string] -or [string]::IsNullOrWhiteSpace($item.SampleVariant) -or
                    $item.PlanKey -isnot [string] -or $item.PlanKey -notmatch '^[a-f0-9]{64}$' -or
                    $item.DefinitionHash -cne $item.PlanKey -or
                    $item.ReconcileSupported -ne ($providerName -eq 'hyperv')) { return $false }
            }
            default {
                if ($null -ne $item.SampleId -or $null -ne $item.SampleVariant -or $null -ne $item.PlanKey -or
                    $item.ReconcileSupported -or $expectedNames.Count -ne 1 -or $expectedNames[0] -cne $item.Name) { return $false }
            }
        }
        $planKeyPart = if ($null -eq $item.PlanKey) { '' } else { [string]$item.PlanKey }
        $key = '{0}|{1}|{2}' -f $item.Type, $item.Name, $planKeyPart
        if (-not $itemKeys.Add($key)) { return $false }
    }

    if ($catalogSampleCount -eq 0) {
        return $null -eq $Databases.RequiredCapability -and [string]$Databases.CapabilityStatus -ceq 'NOT_REQUESTED'
    }
    $requiredCapability = if ($providerName -eq 'hyperv') { 'hyperv-test-database-reconcile' } else { 'test-database-reconcile' }
    return $Databases.RequiredCapability -is [string] -and
        [string]$Databases.RequiredCapability -ceq $requiredCapability -and
        $Databases.CapabilityStatus -is [string] -and
        [string]$Databases.CapabilityStatus -ceq (Get-LabDeclaredIntentCapabilityStatus `
            -ProviderCapability $ProviderCapability -RequiredCapability $requiredCapability)
}

function ConvertTo-LabPersistedSoftwareItemProjection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    return [ordered]@{
        Id = [string]$Plan.SoftwareId
        PlanKey = [string]$Plan.PlanKey
        Optional = if ($Plan.PSObject.Properties['Optional']) { [bool]$Plan.Optional } else { [string]$Plan.Kind -ne 'sqlExternalRuntime' }
        Scope = if ([string]$Plan.Kind -eq 'sqlExternalRuntime') { 'sqlExternalRuntime' } else { 'instance' }
        Status = [string]$Plan.Status
        ReasonCode = [string]$Plan.ReasonCode
        VariantId = [string]$Plan.VariantId
        RuntimeVersion = [string]$Plan.RuntimeVersion
        InstallationMethod = [string]$Plan.InstallationMethod
        RequiredCapabilities = @($Plan.RequiredCapabilities | ForEach-Object { [string]$_ })
        ArtifactRefs = @($Plan.ArtifactRefs | ForEach-Object {
            [ordered]@{ Id=[string]$_.Id; SourceType=[string]$_.SourceType; Version=[string]$_.Version; Sha256=[string]$_.Sha256; IntegrityOrigin=[string]$_.IntegrityOrigin }
        })
        PackageLocks = @($Plan.PackageLocks | ForEach-Object {
            [ordered]@{ Name=[string]$_.Name; Version=[string]$_.Version; Sha256=[string]$_.Sha256; Scope=[string]$_.Scope }
        })
        Restart = if ($null -eq $Plan.Restart) { $null } else { [ordered]@{ sqlServer=[bool]$Plan.Restart.sqlServer; launchpad=[bool]$Plan.Restart.launchpad; guest=[bool]$Plan.Restart.guest } }
        Validation = if ($null -eq $Plan.Validation) { $null } else { [ordered]@{ type=[string]$Plan.Validation.type; language=[string]$Plan.Validation.language; probeId=[string]$Plan.Validation.probeId; expectedRuntimeVersion=[string]$Plan.Validation.expectedRuntimeVersion } }
    }
}

function ConvertTo-LabValidatedPersistedSoftwareItemProjection {
    [CmdletBinding()]
    param($Item)

    if ($null -eq $Item -or $Item -is [string] -or $Item -is [bool] -or $Item -is [array]) { return $null }
    $fields = @('ArtifactRefs','Id','InstallationMethod','Optional','PackageLocks','PlanKey','ReasonCode','RequiredCapabilities','Restart','RuntimeVersion','Scope','Status','Validation','VariantId')
    if ((@($Item.PSObject.Properties.Name | Sort-Object) -join ',') -cne ($fields -join ',')) { return $null }
    if ($Item.Id -isnot [string] -or $Item.Id -notmatch '^[a-z][a-z0-9-]{2,63}$' -or
        $Item.PlanKey -isnot [string] -or ($Item.PlanKey.Length -gt 0 -and $Item.PlanKey -notmatch '^[a-f0-9]{64}$') -or
        $Item.Optional -isnot [bool] -or $Item.Scope -isnot [string] -or $Item.Scope -cnotin @('instance','sqlExternalRuntime') -or
        $Item.Status -isnot [string] -or $Item.Status -cnotin @('RESOLVED','DECLARED_UNSUPPORTED','NON_REPRODUCIBLE') -or
        $Item.ReasonCode -isnot [string] -or $Item.VariantId -isnot [string] -or $Item.RuntimeVersion -isnot [string] -or
        $Item.InstallationMethod -isnot [string] -or $Item.RequiredCapabilities -isnot [array] -or
        $Item.ArtifactRefs -isnot [array] -or $Item.PackageLocks -isnot [array]) { return $null }
    if (($null -ne $Item.Restart -and ($Item.Restart -is [string] -or $Item.Restart -is [bool] -or $Item.Restart -is [array])) -or
        ($null -ne $Item.Validation -and ($Item.Validation -is [string] -or $Item.Validation -is [bool] -or $Item.Validation -is [array]))) { return $null }
    foreach ($capability in @($Item.RequiredCapabilities)) {
        if ($capability -isnot [string] -or $capability -notmatch '^[a-z][a-z0-9-]{2,63}$') { return $null }
    }
    foreach ($artifact in @($Item.ArtifactRefs)) {
        if ($null -eq $artifact -or $artifact -is [string] -or $artifact -is [bool] -or $artifact -is [array] -or
            ((@($artifact.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'Id,IntegrityOrigin,Sha256,SourceType,Version') -or
            $artifact.Id -isnot [string] -or $artifact.SourceType -isnot [string] -or $artifact.Version -isnot [string] -or
            $artifact.Sha256 -isnot [string] -or $artifact.Sha256 -notmatch '^[a-f0-9]{64}$' -or $artifact.IntegrityOrigin -isnot [string]) { return $null }
    }
    foreach ($package in @($Item.PackageLocks)) {
        if ($null -eq $package -or $package -is [string] -or $package -is [bool] -or $package -is [array] -or
            ((@($package.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'Name,Scope,Sha256,Version') -or
            $package.Name -isnot [string] -or $package.Version -isnot [string] -or $package.Scope -isnot [string] -or
            $package.Sha256 -isnot [string] -or $package.Sha256 -notmatch '^[a-f0-9]{64}$') { return $null }
    }
    if ($null -ne $Item.Restart -and (((@($Item.Restart.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'guest,launchpad,sqlServer') -or
        $Item.Restart.sqlServer -isnot [bool] -or $Item.Restart.launchpad -isnot [bool] -or $Item.Restart.guest -isnot [bool])) { return $null }
    if ($null -ne $Item.Validation -and (((@($Item.Validation.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'expectedRuntimeVersion,language,probeId,type') -or
        $Item.Validation.type -isnot [string] -or $Item.Validation.language -isnot [string] -or $Item.Validation.probeId -isnot [string] -or
        $Item.Validation.expectedRuntimeVersion -isnot [string])) { return $null }
    return [ordered]@{
        Id=[string]$Item.Id; PlanKey=[string]$Item.PlanKey; Optional=[bool]$Item.Optional; Scope=[string]$Item.Scope; Status=[string]$Item.Status
        ReasonCode=[string]$Item.ReasonCode; VariantId=[string]$Item.VariantId; RuntimeVersion=[string]$Item.RuntimeVersion; InstallationMethod=[string]$Item.InstallationMethod
        RequiredCapabilities=@($Item.RequiredCapabilities | ForEach-Object {[string]$_})
        ArtifactRefs=@($Item.ArtifactRefs | ForEach-Object {[ordered]@{Id=[string]$_.Id;SourceType=[string]$_.SourceType;Version=[string]$_.Version;Sha256=[string]$_.Sha256;IntegrityOrigin=[string]$_.IntegrityOrigin}})
        PackageLocks=@($Item.PackageLocks | ForEach-Object {[ordered]@{Name=[string]$_.Name;Version=[string]$_.Version;Sha256=[string]$_.Sha256;Scope=[string]$_.Scope}})
        Restart=if($null -eq $Item.Restart){$null}else{[ordered]@{sqlServer=[bool]$Item.Restart.sqlServer;launchpad=[bool]$Item.Restart.launchpad;guest=[bool]$Item.Restart.guest}}
        Validation=if($null -eq $Item.Validation){$null}else{[ordered]@{type=[string]$Item.Validation.type;language=[string]$Item.Validation.language;probeId=[string]$Item.Validation.probeId;expectedRuntimeVersion=[string]$Item.Validation.expectedRuntimeVersion}}
    }
}

function Test-LabPersistedSoftwareIntent {
    <# Validates only the secret-free resolver projection; the catalog is the authority. #>
    [CmdletBinding()]
    param($Software, [Parameter(Mandatory)]$Instance, $ProviderCapability)

    if ($null -eq $Software -or $Software -is [string] -or $Software -is [bool] -or $Software -is [array]) { return $false }
    $fields = @('CapabilityStatus','Items','PlanningCapabilityStatus','RequiredCapability')
    if ((@($Software.PSObject.Properties.Name | Sort-Object) -join ',') -cne ($fields -join ',') -or
        $Software.Items -isnot [array] -or $Software.CapabilityStatus -isnot [string] -or
        $Software.PlanningCapabilityStatus -isnot [string] -or
        ($null -ne $Software.RequiredCapability -and $Software.RequiredCapability -isnot [string])) { return $false }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $expected = [Collections.Generic.List[object]]::new()
    foreach ($item in @($Software.Items)) {
        $actual = ConvertTo-LabValidatedPersistedSoftwareItemProjection -Item $item
        if ($null -eq $actual -or -not $seen.Add([string]$actual.Id)) { return $false }
        # Never use a persisted installer, URL, path or command.  Resolve only
        # an already closed catalog item against the persisted run identity.
        if (-not (Get-LabSoftwareCatalogItem -Id ([string]$actual.Id))) { return $false }
        $request = [PSCustomObject]@{
            Id=[string]$actual.Id; Version=[string]$actual.RuntimeVersion; Variant=[string]$actual.VariantId
            Scope=[string]$actual.Scope; InstallMethod=[string]$actual.InstallationMethod; Optional=[bool]$actual.Optional
            Packages=@($actual.PackageLocks | ForEach-Object {[PSCustomObject]@{Name=[string]$_.Name;Version=[string]$_.Version;Scope=[string]$_.Scope}})
            RequestSource='persisted-desired-state'
        }
        $operatingSystem = if ([string]$Instance.Provider -ceq 'hyperv') { 'windows' } else { 'linux' }
        try { $plan = Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion ([string]$Instance.Version -split '-',2)[0] -Provider ([string]$Instance.Provider) -OperatingSystem $operatingSystem }
        catch { return $false }
        $expectedItem = ConvertTo-LabPersistedSoftwareItemProjection -Plan $plan
        if ((ConvertTo-Json -InputObject $actual -Depth 20 -Compress) -cne (ConvertTo-Json -InputObject $expectedItem -Depth 20 -Compress)) { return $false }
        $expected.Add($expectedItem)
    }
    $planning = if ($expected.Count -eq 0) { 'NOT_REQUESTED' } else { Get-LabDeclaredIntentCapabilityStatus -ProviderCapability $ProviderCapability -RequiredCapability 'software-catalog-planning' }
    $requiredCapability = if ($expected.Count -eq 0) { $null } else { 'software-catalog-planning' }
    $capability = if ($expected.Count -eq 0) { 'NOT_REQUESTED' } elseif ($planning -ne 'DECLARED_SUPPORTED' -or @($expected | Where-Object Status -ne 'RESOLVED').Count -gt 0) { 'DECLARED_UNSUPPORTED' } else { 'DECLARED_SUPPORTED' }
    # Preserve a null required capability for an empty, catalog-derived intent.
    # Casting it to a string would turn a valid legacy-safe empty projection into
    # an invalid empty string after JSON round-tripping.
    return $Software.RequiredCapability -ceq $requiredCapability -and
        [string]$Software.PlanningCapabilityStatus -ceq $planning -and
        [string]$Software.CapabilityStatus -ceq $capability
}

function Resolve-LabValidatedPersistedSoftwarePlans {
    <#
    .SYNOPSIS
        Rehydrates only catalog-bound plans from a validated persisted projection.
    .DESCRIPTION
        This is deliberately not a manifest consumer.  The persisted item is
        reduced to catalog identity inputs before invoking the resolver, so a
        post-persistence manifest edit cannot select a package, artifact, plan
        key or derived image.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Software,
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)]$ProviderCapability
    )

    if (-not (Test-LabPersistedSoftwareIntent -Software $Software -Instance $Instance -ProviderCapability $ProviderCapability)) {
        throw 'DESIRED_INSTANCE_SOFTWARE_INTENT_INVALID'
    }
    $plans = [Collections.Generic.List[object]]::new()
    foreach ($item in @($Software.Items)) {
        $actual = ConvertTo-LabValidatedPersistedSoftwareItemProjection -Item $item
        $request = [PSCustomObject]@{
            Id=[string]$actual.Id; Version=[string]$actual.RuntimeVersion; Variant=[string]$actual.VariantId
            Scope=[string]$actual.Scope; InstallMethod=[string]$actual.InstallationMethod; Optional=[bool]$actual.Optional
            Packages=@($actual.PackageLocks | ForEach-Object {
                [PSCustomObject]@{Name=[string]$_.Name;Version=[string]$_.Version;Scope=[string]$_.Scope}
            })
            RequestSource='persisted-desired-state'
        }
        $operatingSystem = if ([string]$Instance.Provider -ceq 'hyperv') { 'windows' } else { 'linux' }
        $plan = Resolve-LabExternalRuntimePlan -SoftwareItem $request -SqlVersion ([string]$Instance.Version -split '-',2)[0] `
            -Provider ([string]$Instance.Provider) -OperatingSystem $operatingSystem
        if ((ConvertTo-Json -InputObject (ConvertTo-LabPersistedSoftwareItemProjection -Plan $plan) -Depth 20 -Compress) -cne
            (ConvertTo-Json -InputObject $actual -Depth 20 -Compress)) {
            throw 'DESIRED_INSTANCE_SOFTWARE_INTENT_INVALID'
        }
        $plans.Add($plan)
    }
    return @($plans)
}

function Test-LabPersistedAiIntent {
    <#
    .SYNOPSIS
        Validiert den optionalen, persistierten KI-Intent vor jeder
        Szenario-, Journal- oder SQL-Aufloesung.
    .DESCRIPTION
        Der Snapshot ist kein zweites Manifestformat.  Er enthaelt nur die
        vom lokalen Resolver erzeugte, geheimnisfreie Projektion.  Deshalb
        werden Modell- und Szenario-PlanKeys erneut aus lokalen Definitionen
        abgeleitet und alle Envelopes strikt geschlossen.
    #>
    [CmdletBinding()]
    param(
        $Ai,
        [Parameter(Mandatory)]$Instances
    )

    if ($null -eq $Ai) { return $true }
    if ($Ai -is [string] -or $Ai -is [bool] -or $Ai -is [array]) { return $false }
    $expectedFields = @('Contract','Models','PlanKey','Policies','Scenarios')
    if ((@($Ai.PSObject.Properties.Name | Sort-Object) -join ',') -cne ($expectedFields -join ',')) { return $false }
    if ($null -eq $Ai.Contract -or $Ai.Contract -is [string] -or $Ai.Contract -is [bool] -or $Ai.Contract -is [array] -or
        ((@($Ai.Contract.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'Name,Version') -or
        $Ai.Contract.Name -isnot [string] -or $Ai.Contract.Version -isnot [string] -or
        [string]$Ai.Contract.Name -cne 'SqlServerLab.AiIntent' -or [string]$Ai.Contract.Version -cne '1.0' -or
        $Ai.Models -isnot [array] -or $Ai.Models.Count -eq 0 -or
        $Ai.Scenarios -isnot [array] -or $Ai.Scenarios.Count -eq 0 -or
        $Ai.PlanKey -isnot [string] -or $Ai.PlanKey -notmatch '^[a-f0-9]{64}$') { return $false }

    $modelFields = @('CredentialRef','Dimension','EndpointRef','Id','PlanKey','Provider','Purpose','RetryCount','TimeoutSeconds','Variant')
    $modelIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $models = [Collections.Generic.List[object]]::new()
    foreach ($model in @($Ai.Models)) {
        if ($null -eq $model -or $model -is [string] -or $model -is [bool] -or $model -is [array] -or
            ((@($model.PSObject.Properties.Name | Sort-Object) -join ',') -cne ($modelFields -join ',')) -or
            $model.Id -isnot [string] -or $model.Id -notmatch '^[a-z][a-z0-9-]{2,63}$' -or -not $modelIds.Add($model.Id) -or
            $model.Purpose -isnot [string] -or $model.Purpose -cnotin @('embedding','generation') -or
            $model.Provider -isnot [string] -or $model.Provider -cnotin @('precomputed','stub','ollama','openai','azure-openai','onnx') -or
            $model.Variant -isnot [string] -or $model.Variant -notmatch '^[a-z0-9][a-z0-9._:-]{1,127}$' -or
            $model.TimeoutSeconds -isnot [long] -or $model.TimeoutSeconds -lt 1 -or $model.TimeoutSeconds -gt 600 -or
            $model.RetryCount -isnot [long] -or $model.RetryCount -lt 0 -or $model.RetryCount -gt 10 -or
            $model.PlanKey -isnot [string] -or $model.PlanKey -notmatch '^[a-f0-9]{64}$') { return $false }

        # EndpointRef is an opaque catalog identifier, never a URL or a path.
        # A credential may only be the already schema-bound environment-name
        # reference; a value, arbitrary environment name, or host data never
        # enters the persistable contract.
        if ($null -ne $model.EndpointRef -and ($model.EndpointRef -isnot [string] -or $model.EndpointRef -notmatch '^[a-z][a-z0-9-]{2,63}$') -or
            ($null -ne $model.CredentialRef -and ($model.CredentialRef -isnot [string] -or $model.CredentialRef -notmatch '^SQL_SERVER_LAB_SECRET_[A-Z0-9_]+$'))) { return $false }
        if (($model.Provider -in @('precomputed','onnx')) -and $null -ne $model.EndpointRef) { return $false }
        if (($model.Provider -in @('stub','ollama','openai','azure-openai')) -and $null -eq $model.EndpointRef) { return $false }
        if (($model.Provider -in @('openai','azure-openai')) -and $null -eq $model.CredentialRef) { return $false }
        if (($model.Provider -notin @('openai','azure-openai')) -and $null -ne $model.CredentialRef) { return $false }
        if ($model.Purpose -ceq 'embedding') {
            if ($model.Dimension -isnot [long] -or $model.Dimension -lt 1 -or $model.Dimension -gt 1998) { return $false }
        }
        elseif ($null -ne $model.Dimension) { return $false }

        $canonicalModel = [ordered]@{
            Id=[string]$model.Id; Purpose=[string]$model.Purpose; Provider=[string]$model.Provider; Variant=[string]$model.Variant
            EndpointRef=if($null -ne $model.EndpointRef){[string]$model.EndpointRef}else{$null}
            CredentialRef=if($null -ne $model.CredentialRef){[string]$model.CredentialRef}else{$null}
            Dimension=if($null -ne $model.Dimension){[long]$model.Dimension}else{$null}
            TimeoutSeconds=[long]$model.TimeoutSeconds; RetryCount=[long]$model.RetryCount
        }
        $expectedModelKey = Get-LabAiPlanKey -InputObject ([ordered]@{ Contract='SqlServerLab.AiModelPlan/1.0'; Model=$canonicalModel })
        if ([string]$model.PlanKey -cne $expectedModelKey) { return $false }
        $models.Add([PSCustomObject]($canonicalModel + [ordered]@{ PlanKey=$expectedModelKey }))
    }

    if ($null -eq $Ai.Policies -or $Ai.Policies -is [string] -or $Ai.Policies -is [bool] -or $Ai.Policies -is [array]) { return $false }
    $policyFields = @('AllowedTools','ContentLogging','DataClassification','Egress','Fallback')
    if ((@($Ai.Policies.PSObject.Properties.Name | Sort-Object) -join ',') -cne ($policyFields -join ',') -or
        $Ai.Policies.DataClassification -isnot [string] -or $Ai.Policies.DataClassification -cnotin @('synthetic-only','public-or-redistributable','internal-explicit') -or
        $Ai.Policies.Egress -isnot [string] -or $Ai.Policies.Egress -cnotin @('denied','explicit') -or
        $Ai.Policies.ContentLogging -isnot [string] -or $Ai.Policies.ContentLogging -cnotin @('disabled','metadata-only') -or
        $Ai.Policies.Fallback -isnot [string] -or $Ai.Policies.Fallback -cnotin @('disabled','explicit') -or
        $Ai.Policies.AllowedTools -isnot [array]) { return $false }
    # PlanKeys provide deterministic integrity only; they are not signatures.
    # Re-apply the manifest's egress invariant so a re-keyed persisted cloud
    # model cannot defer an explicitly denied egress decision to a later
    # endpoint or scenario path.
    if ([string]$Ai.Policies.Egress -cne 'explicit' -and
        @($models | Where-Object { [string]$_.Provider -cin @('openai','azure-openai') }).Count -gt 0) { return $false }
    $allowedTools = @($Ai.Policies.AllowedTools)
    $allowedToolIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($tool in $allowedTools) {
        if ($tool -isnot [string] -or $tool -notmatch '^[a-z][a-z0-9-]{2,63}$' -or -not $allowedToolIds.Add($tool)) { return $false }
    }
    if ((@($allowedTools) -join "`0") -cne (@($allowedTools | Sort-Object) -join "`0")) { return $false }

    $scenarioFields = @('Id','InstanceId','PlanKey','Version')
    $scenarioIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $scenarioTools = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $scenarios = [Collections.Generic.List[object]]::new()
    foreach ($reference in @($Ai.Scenarios)) {
        if ($null -eq $reference -or $reference -is [string] -or $reference -is [bool] -or $reference -is [array] -or
            ((@($reference.PSObject.Properties.Name | Sort-Object) -join ',') -cne ($scenarioFields -join ',')) -or
            $reference.Id -isnot [string] -or $reference.Id -notmatch '^[a-z][a-z0-9-]{2,63}$' -or
            $reference.Version -isnot [string] -or $reference.Version -notmatch '^[1-9][0-9]*\.[0-9]+$' -or
            $reference.InstanceId -isnot [string] -or $reference.InstanceId -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$' -or
            $reference.PlanKey -isnot [string] -or $reference.PlanKey -notmatch '^[a-f0-9]{64}$') { return $false }
        $scenarioIdentity = '{0}|{1}|{2}' -f $reference.Id,$reference.Version,$reference.InstanceId
        if (-not $scenarioIds.Add($scenarioIdentity)) { return $false }
        if (@($Instances | Where-Object { $_.Id -is [string] -and [string]$_.Id -ceq [string]$reference.InstanceId }).Count -ne 1) { return $false }
        try { $definition = Read-LabAiScenarioDefinition -ScenarioId $reference.Id -Version $reference.Version }
        catch { return $false }
        if ([string]$reference.PlanKey -cne [string]$definition.PlanKey) { return $false }
        foreach ($tool in @($definition.Scenario.tools)) { [void]$scenarioTools.Add([string]$tool) }
        foreach ($binding in $definition.Scenario.modelBindings.PSObject.Properties) {
            $bound = @($models | Where-Object { [string]$_.Id -ceq [string]$binding.Value })
            if ($bound.Count -ne 1 -or [string]$bound[0].Purpose -cne [string]$binding.Name) { return $false }
        }
        $scenarios.Add([PSCustomObject]@{ Id=[string]$reference.Id; Version=[string]$reference.Version; InstanceId=[string]$reference.InstanceId; PlanKey=[string]$definition.PlanKey })
    }
    foreach ($tool in @($allowedTools)) { if (-not $scenarioTools.Contains($tool)) { return $false } }

    $policies = [PSCustomObject]@{
        DataClassification=[string]$Ai.Policies.DataClassification; Egress=[string]$Ai.Policies.Egress
        AllowedTools=@($allowedTools); ContentLogging=[string]$Ai.Policies.ContentLogging; Fallback=[string]$Ai.Policies.Fallback
    }
    $portable = [ordered]@{ Contract='SqlServerLab.AiIntent/1.0'; Models=@($models); Policies=$policies; Scenarios=@($scenarios) }
    return [string]$Ai.PlanKey -ceq (Get-LabAiPlanKey -InputObject $portable)
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
    # This is static provider metadata from the registered provider contract;
    # it is deliberately not a runtime or host capability probe.
    $providerCapabilities = @(Get-LabProviderCapabilityContract)
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
        $providerCapability = $null
        if ($null -eq $instance.Provider -or $provider.Length -eq 0) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_PROVIDER_MISSING')
        }
        else {
            if (-not $supportedProviders.Contains($provider)) {
                [void]$validationErrors.Add('DESIRED_INSTANCE_PROVIDER_INVALID')
            }
            else {
                $providerIsValid = $true
                $providerCapability = @($providerCapabilities | Where-Object {
                    [string]$_.Provider -ieq $provider
                } | Select-Object -First 1)[0]
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
            -not (Test-LabPersistedSqlConfigurationIntent -SqlConfiguration $instance.Intents.SqlConfiguration -Provider $provider -ProviderCapability $providerCapability)) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_SQL_CONFIGURATION_INTENT_INVALID')
        }
        if ($instance.Intents -and $instance.Intents.PSObject.Properties['ContainerRuntime'] -and $null -ne $instance.Intents.ContainerRuntime -and
            -not (Test-LabPersistedContainerRuntimeIntent -ContainerRuntime $instance.Intents.ContainerRuntime -Provider $provider -SqlVersion ([string]$instance.Version))) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_CONTAINER_RUNTIME_INTENT_INVALID')
        }
        if ($instance.Intents -and $instance.Intents.PSObject.Properties['Resources'] -and $null -ne $instance.Intents.Resources -and
            -not (Test-LabPersistedHyperVResourceIntent -Resources $instance.Intents.Resources -Provider $provider)) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_HYPERV_RESOURCE_INTENT_INVALID')
        }
        if ($instance.Intents -and $instance.Intents.PSObject.Properties['Drives'] -and $null -ne $instance.Intents.Drives -and
            -not (Test-LabPersistedDriveIntents -Drives $instance.Intents.Drives -Provider $provider -ProviderCapability $providerCapability)) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_DRIVE_INTENT_INVALID')
        }
        if ($instance.Intents -and $instance.Intents.PSObject.Properties['Storage'] -and $null -ne $instance.Intents.Storage -and
            -not (Test-LabPersistedStorageIntent -Storage $instance.Intents.Storage)) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_STORAGE_INTENT_INVALID')
        }
        if ($instance.Intents -and $instance.Intents.PSObject.Properties['Databases'] -and $null -ne $instance.Intents.Databases -and
            -not (Test-LabPersistedDatabaseIntent -Databases $instance.Intents.Databases -Provider $provider -ProviderCapability $providerCapability)) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_DATABASE_INTENT_INVALID')
        }
        # Missing/null Software is retained for legacy snapshots.  A present
        # projection is re-derived only from the local catalog before any
        # container, Hyper-V, target, journal, or installer path can observe it.
        if ($instance.Intents -and $instance.Intents.PSObject.Properties['Software'] -and $null -ne $instance.Intents.Software -and
            -not (Test-LabPersistedSoftwareIntent -Software $instance.Intents.Software -Instance $instance -ProviderCapability $providerCapability)) {
            [void]$validationErrors.Add('DESIRED_INSTANCE_SOFTWARE_INTENT_INVALID')
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

    # Missing/null AI remains a valid legacy snapshot.  Any present value is
    # an exact, locally re-derived contract and may not defer validation to a
    # scenario planner, journal writer, endpoint resolver, or SQL call.
    if ($snapshot.PSObject.Properties['Ai'] -and $null -ne $snapshot.Ai -and
        -not (Test-LabPersistedAiIntent -Ai $snapshot.Ai -Instances @($snapshot.Instances))) {
        [void]$validationErrors.Add('DESIRED_STATE_AI_INTENT_INVALID')
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

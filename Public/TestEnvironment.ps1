function Get-LabTestEnvironmentExportDirectory {
    [CmdletBinding()]
    param([string]$OutputDirectory)

    if ($OutputDirectory) { return [IO.Path]::GetFullPath($OutputDirectory) }
    $dataRoot = Get-LabDataRootDefault
    if (-not $dataRoot) {
        throw 'TEST_ENVIRONMENT_DATA_ROOT_REQUIRED: Zuerst den Data Root im Hauptmenü konfigurieren.'
    }
    return (Join-Path $dataRoot 'Exports')
}

function ConvertTo-LabTestEnvironmentKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Platform,
        [Parameter(Mandatory)][string]$SqlVersion,
        [Parameter(Mandatory)][string]$Patch,
        [string]$Name
    )

    $candidate = if ($Name) { $Name } else { '{0}_{1}_{2}' -f $Platform, $SqlVersion, $Patch }
    $candidate = $candidate.ToUpperInvariant() -replace '[^A-Z0-9]+', '_'
    $candidate = $candidate.Trim('_')
    if (-not $candidate -or $candidate -notmatch '^[A-Z]') { $candidate = "ENV_$candidate" }
    return $candidate
}

function Get-LabTestEnvironmentRegistryPath {
    [CmdletBinding()]
    param([string]$OutputDirectory)

    return (Join-Path (Get-LabTestEnvironmentExportDirectory -OutputDirectory $OutputDirectory) 'TestUmgebung.registry.json')
}

function Get-LabTestEnvironmentRegistry {
    [CmdletBinding()]
    param([string]$OutputDirectory)

    $path = Get-LabTestEnvironmentRegistryPath -OutputDirectory $OutputDirectory
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [PSCustomObject]@{
            contractVersion = 'SqlServerLab.TestEnvironmentRegistry/1.0'
            updatedAt = Get-LabTimestamp
            environments = @()
        }
    }
    $registry = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    if ([string]$registry.contractVersion -ne 'SqlServerLab.TestEnvironmentRegistry/1.0') {
        throw 'TEST_ENVIRONMENT_REGISTRY_VERSION_UNSUPPORTED'
    }
    return $registry
}

function Get-LabAutomatedTestEnvironmentRunIds {
    [CmdletBinding()]
    param([string]$OutputDirectory)

    try {
        $registry = Get-LabTestEnvironmentRegistry -OutputDirectory $OutputDirectory
        return @($registry.environments | ForEach-Object { [string]$_.runId } | Where-Object { $_ } | Sort-Object -Unique)
    }
    catch { return @() }
}

function Test-LabAutomatedTestEnvironmentRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId, [string]$OutputDirectory)

    return [bool](@(Get-LabAutomatedTestEnvironmentRunIds -OutputDirectory $OutputDirectory) -contains $RunId)
}

function Get-LabTestEnvironmentLiveRuntimeStatus {
    <# Projiziert den gebundenen Providerzustand ohne State-Mutation. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        $Instance,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    try {
        $runtimeStatus = [string](Get-LabRunRuntimeStatus -Run $Run -StateRoot $StateRoot).State
        if ($runtimeStatus -ne 'RUNNING' -or -not $Instance) { return $runtimeStatus }

        $provider = ([string]$Instance.provider).ToLowerInvariant()
        if ($provider -notin @('docker', 'podman')) { return $runtimeStatus }
        $containerStatus = if ($provider -eq 'docker') {
            Get-DockerInstanceStatus -ContainerIdOrName ([string]$Instance.containerId)
        }
        else {
            Get-PodmanInstanceStatus -ContainerIdOrName ([string]$Instance.containerId)
        }
        if (-not $containerStatus.Exists) { return 'MISSING' }
        if (-not $containerStatus.Running) { return 'STOPPED' }
        if (-not $containerStatus.Healthy) { return 'UNHEALTHY' }
        return 'RUNNING'
    }
    catch { return 'UNAVAILABLE' }
}

function Get-LabAutomatedTestEnvironmentStatus {
    <# Liefert eine secretfreie, laufzeitnahe Statussicht für die interaktive Anzeige. #>
    [CmdletBinding()]
    param([string]$OutputDirectory, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $registry = Get-LabTestEnvironmentRegistry -OutputDirectory $OutputDirectory
    $entries = @(
        foreach ($registered in @($registry.environments | Sort-Object key)) {
            $statusCode = 'PROVISIONING_PENDING'
            $displayStatus = 'vorgemerkt, noch nicht erstellt'
            $runtimeState = $null
            $planState = $null
            if ([string]$registered.runId) {
                $runDirectory = Join-Path (Join-Path $StateRoot 'runs') ([string]$registered.runId)
                $runStatePath = Join-Path $runDirectory 'run-state.json'
                $connectionPath = Join-Path $runDirectory 'connection-info.json'
                if (-not (Test-Path -LiteralPath $runStatePath -PathType Leaf)) {
                    $statusCode = 'MISSING'
                    $displayStatus = 'Run-State fehlt'
                }
                else {
                    try {
                        $run = Get-Content -LiteralPath $runStatePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
                        $runtimeState = [string]$run.state
                        $connection = if (Test-Path -LiteralPath $connectionPath -PathType Leaf) {
                            Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
                        }
                        $instance = @($connection.instances | Where-Object { [string]$_.id -eq [string]$registered.instanceId } | Select-Object -First 1)[0]
                        $observedRuntimeState = Get-LabTestEnvironmentLiveRuntimeStatus -Run $run -Instance $instance -StateRoot $StateRoot
                        if ($observedRuntimeState -and $observedRuntimeState -ne 'UNKNOWN') { $runtimeState = $observedRuntimeState }
                        if ([string]$registered.platform -eq 'windows') {
                            $planState = if ($instance -and $instance.sqlDeploymentPlan) { [string]$instance.sqlDeploymentPlan.state } else { $null }
                            switch ($planState) {
                                'SQL_SLOT_READY' {
                                    if ($runtimeState -eq 'RUNNING') { $statusCode = 'READY'; $displayStatus = 'fertig' }
                                    else { $statusCode = $runtimeState; $displayStatus = "SQL fertig, VM $($runtimeState.ToLowerInvariant()) (startbar)" }
                                }
                                'CONFIGURATION_PENDING' { $statusCode = $planState; $displayStatus = 'SQL-Abschluss fortsetzbar' }
                                'INSTALL_RETRY_PENDING' { $statusCode = $planState; $displayStatus = 'SQL-Installation wiederholbar' }
                                'INSTALLING' { $statusCode = $planState; $displayStatus = 'SQL-Installation läuft' }
                                'PLANNED' { $statusCode = $planState; $displayStatus = 'SQL-Installation fortsetzbar' }
                                default {
                                    if ($instance -and $instance.windowsProvisioning -and [string]$instance.windowsProvisioning.state -eq 'COMPLETE') {
                                        $statusCode = 'WINDOWS_READY'; $displayStatus = 'Windows fertig, SQL noch offen'
                                    }
                                    else { $statusCode = 'OOBE_PENDING'; $displayStatus = 'Windows-OOBE noch offen' }
                                }
                            }
                        }
                        elseif ($instance -and $runtimeState -eq 'RUNNING') {
                            $statusCode = 'READY'; $displayStatus = 'fertig'
                        }
                        else {
                            $statusCode = if ($runtimeState) { $runtimeState } else { 'INCOMPLETE' }
                            $displayStatus = if ($runtimeState -eq 'STOPPED') { 'fertig, aber gestoppt (startbar)' } else { $statusCode.ToLowerInvariant() }
                        }
                    }
                    catch {
                        $statusCode = 'READ_FAILED'
                        $displayStatus = 'Status nicht lesbar'
                    }
                }
            }
            [PSCustomObject]@{
                Key = [string]$registered.key; Platform = [string]$registered.platform
                SqlVersion = [string]$registered.sqlVersion; Patch = [string]$registered.patch
                RunId = [string]$registered.runId; StatusCode = $statusCode
                DisplayStatus = $displayStatus; RuntimeState = $runtimeState; PlanState = $planState
            }
        }
    )
    $ready = @($entries | Where-Object StatusCode -eq 'READY').Count
    return [PSCustomObject]@{
        GroupStatus = if ($entries.Count -gt 0 -and $ready -eq $entries.Count) { 'READY' } elseif ($entries.Count -gt 0) { 'INCOMPLETE' } else { 'EMPTY' }
        Ready = $ready
        Total = $entries.Count
        Entries = $entries
    }
}

function Register-LabTestEnvironmentIntent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('linux','windows')][string]$Platform,
        [Parameter(Mandatory)][string]$SqlVersion,
        [Parameter(Mandatory)][string]$Patch,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$Name,
        [string]$OutputDirectory,
        [switch]$ReuseExisting
    )

    $registry = Get-LabTestEnvironmentRegistry -OutputDirectory $OutputDirectory
    $requestedKey = ConvertTo-LabTestEnvironmentKey -Platform $Platform -SqlVersion $SqlVersion -Patch $Patch -Name $Name
    $existingForKey = @($registry.environments | Where-Object { [string]$_.key -eq $requestedKey } | Select-Object -First 1)[0]
    if ($ReuseExisting -and $existingForKey) { return $existingForKey }
    $existingPending = @($registry.environments | Where-Object {
        [string]$_.key -eq $requestedKey -and -not [string]$_.runId -and [string]$_.registrationState -eq 'PROVISIONING_PENDING'
    } | Select-Object -First 1)[0]
    if ($existingPending) { return $existingPending }
    $key = $requestedKey
    $suffix = 2
    while (@($registry.environments | Where-Object { [string]$_.key -eq $key }).Count -gt 0) {
        $key = "${requestedKey}_$suffix"
        $suffix++
    }
    $registry.environments = @(@($registry.environments) + [PSCustomObject]@{
        key = $key
        platform = $Platform
        sqlVersion = $SqlVersion
        patch = $Patch.ToLowerInvariant()
        runId = $null
        instanceId = $InstanceId
        registrationState = 'PROVISIONING_PENDING'
        registeredAt = Get-LabTimestamp
    } | Sort-Object key)
    $registry.updatedAt = Get-LabTimestamp
    $path = Get-LabTestEnvironmentRegistryPath -OutputDirectory $OutputDirectory
    Write-LabArtifactJsonAtomic -Path $path -InputObject $registry
    Protect-LabTestEnvironmentSecretFile -Path $path
    return @($registry.environments | Where-Object key -eq $key)[0]
}

function Register-LabTestEnvironmentRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('linux','windows')][string]$Platform,
        [Parameter(Mandatory)][string]$SqlVersion,
        [Parameter(Mandatory)][string]$Patch,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$Name,
        [string]$OutputDirectory
    )

    $registry = Get-LabTestEnvironmentRegistry -OutputDirectory $OutputDirectory
    $requestedKey = ConvertTo-LabTestEnvironmentKey -Platform $Platform -SqlVersion $SqlVersion -Patch $Patch -Name $Name
    $pendingForKey = @($registry.environments | Where-Object {
        [string]$_.key -eq $requestedKey -and -not [string]$_.runId
    } | Select-Object -First 1)[0]
    $entries = @($registry.environments | Where-Object {
        [string]$_.runId -ne $RunId -and (-not $pendingForKey -or [string]$_.key -ne $requestedKey)
    })
    $key = $requestedKey
    $suffix = 2
    while (@($entries | Where-Object { [string]$_.key -eq $key }).Count -gt 0) {
        $key = "${requestedKey}_$suffix"
        $suffix++
    }
    $entries += [PSCustomObject]@{
        key = $key
        platform = $Platform
        sqlVersion = $SqlVersion
        patch = $Patch.ToLowerInvariant()
        runId = $RunId
        instanceId = $InstanceId
        registrationState = 'REGISTERED'
        registeredAt = Get-LabTimestamp
    }
    $registry.environments = @($entries | Sort-Object key)
    $registry.updatedAt = Get-LabTimestamp
    $path = Get-LabTestEnvironmentRegistryPath -OutputDirectory $OutputDirectory
    Write-LabArtifactJsonAtomic -Path $path -InputObject $registry
    return @($registry.environments | Where-Object runId -eq $RunId)[0]
}

function Get-LabAutomatedTestEnvironmentDisplayName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)

    $stem = (($Key.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-') -replace '-+', '-').Trim('-')
    if (-not $stem) { throw 'TEST_ENVIRONMENT_RUNTIME_NAME_REQUIRED' }
    $name = if ($stem.StartsWith('test-')) { $stem } else { "test-$stem" }
    if ($name.Length -gt 64) { $name = $name.Substring(0, 64).TrimEnd('-') }
    return $name
}

function Rename-LabAutomatedTestEnvironmentRuntime {
    <# Gleicht Run-Anzeigename und natives Runtime-Objekt mit dem Registry-Schlüssel ab. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$Key,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $displayName = Get-LabAutomatedTestEnvironmentDisplayName -Key $Key
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'LAB_CONNECTION_INFO_NOT_FOUND' }
    $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $instance = @($connection.instances | Where-Object { [string]$_.id -eq $InstanceId } | Select-Object -First 1)[0]
    if (-not $instance) { throw "TEST_ENVIRONMENT_RUNTIME_INSTANCE_NOT_FOUND: $InstanceId" }

    if ([string]$instance.provider -in @('docker','podman')) {
        return Rename-ContainerLabEnvironment -RunId $RunId -DisplayName $displayName -StateRoot $StateRoot
    }
    if ([string]$instance.provider -ne 'hyperv') {
        throw "TEST_ENVIRONMENT_RUNTIME_PROVIDER_UNSUPPORTED: $($instance.provider)"
    }

    $lab = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
    $desiredVmName = Get-HyperVLabRuntimeName -LabName $displayName -RunId $RunId
    $runtimeRenameRequired = [string]$lab.Instance.vmName -ne $desiredVmName
    $status = Get-HyperVInstanceStatus -VMName ([string]$lab.Instance.vmName) `
        -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    if (-not $status.Exists) { throw 'HYPERV_LAB_VM_NOT_FOUND' }
    if ($runtimeRenameRequired -and [string]$status.State -notin @('Off','Running')) {
        throw "TEST_ENVIRONMENT_RUNTIME_RENAME_STATE_UNSUPPORTED: $($status.State)"
    }

    $restartRequired = $runtimeRenameRequired -and [string]$status.State -eq 'Running'
    if ($restartRequired) {
        $null = Stop-HyperVInstance -VMName ([string]$lab.Instance.vmName) `
            -ExpectedRunId $lab.Run.runId -ExpectedScopeId $lab.Run.scopeId
    }

    $renameResult = $null
    $renameError = $null
    try {
        $renameResult = Rename-HyperVLabEnvironment -RunId $RunId -DisplayName $displayName -StateRoot $StateRoot
    }
    catch { $renameError = $_ }

    $restartError = $null
    if ($restartRequired) {
        try {
            $current = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot
            $null = Start-HyperVInstance -VMName ([string]$current.Instance.vmName) `
                -ExpectedRunId $current.Run.runId -ExpectedScopeId $current.Run.scopeId
        }
        catch { $restartError = $_ }
    }
    if ($renameError -and $restartError) {
        throw "TEST_ENVIRONMENT_RUNTIME_RENAME_AND_RESTART_FAILED: $($renameError.Exception.Message); $($restartError.Exception.Message)"
    }
    if ($renameError) { throw $renameError }
    if ($restartError) { throw $restartError }
    return $renameResult
}

function ConvertTo-LabDotEnvValue {
    [CmdletBinding()]
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '""' }
    return '"' + ($Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n')) + '"'
}

function Protect-LabTestEnvironmentSecretFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        if ($IsWindows) {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $icacls = Join-Path ([Environment]::GetFolderPath('System')) 'icacls.exe'
            if (-not (Test-Path -LiteralPath $icacls -PathType Leaf)) { throw 'icacls.exe nicht gefunden' }
            & $icacls $Path '/inheritance:r' '/grant:r' "$($identity.Name):(F)" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "icacls exit code $LASTEXITCODE" }
        }
        elseif (Get-Command chmod -ErrorAction SilentlyContinue) {
            & chmod 600 -- $Path
            if ($LASTEXITCODE -ne 0) { throw "chmod exit code $LASTEXITCODE" }
        }
    }
    catch { Write-LabWarning "Dateirechte konnten für '$Path' nicht eingeschränkt werden: $($_.Exception.Message)" }
}

function Get-LabTestEnvironmentResolvedEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Registry, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $resolved = @()
    foreach ($registered in @($Registry.environments)) {
        $runDirectory = Join-Path (Join-Path $StateRoot 'runs') ([string]$registered.runId)
        $runStatePath = Join-Path $runDirectory 'run-state.json'
        $connectionPath = Join-Path $runDirectory 'connection-info.json'
        $run = if (Test-Path -LiteralPath $runStatePath -PathType Leaf) {
            Get-Content -LiteralPath $runStatePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
        }
        $connection = if (Test-Path -LiteralPath $connectionPath -PathType Leaf) {
            Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
        }
        $instance = @($connection.instances | Where-Object { [string]$_.id -eq [string]$registered.instanceId }) | Select-Object -First 1
        $liveRuntimeStatus = if ($run -and $instance) {
            Get-LabTestEnvironmentLiveRuntimeStatus -Run $run -Instance $instance -StateRoot $StateRoot
        }
        $secret = if ($run) { Get-LabSecret -Path $runDirectory -Name 'sa-password' }
        if (-not $secret -and $run) { $secret = Get-LabSecret -Path $runDirectory -Name 'generated-sql-sa-password' }
        $password = $null
        if ($secret) {
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
            try { $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        $target = if ($instance) { ConvertFrom-LabConnectionStringTarget -ConnectionString ([string]$instance.connectionString) -Instance $instance }
        $hostName = if ($instance) { [string]$instance.host }
        if (-not $hostName -and $target -match '^(?<host>[^,:]+)') { $hostName = $Matches.host }
        $port = if ($instance -and [int]$instance.port -gt 0) { [int]$instance.port } elseif ($target -match '[,:](?<port>\d+)$') { [int]$Matches.port } else { 1433 }
        $runtimeStatus = if (-not [string]$registered.runId -and [string]$registered.registrationState -eq 'PROVISIONING_PENDING') {
            'PROVISIONING_PENDING'
        }
        elseif (-not $run) { 'MISSING' }
        elseif (-not $instance -or -not $hostName -or -not $password) { [string]$run.state }
        elseif ([string]$run.state -eq 'RUNNING' -and $liveRuntimeStatus -eq 'RUNNING') { 'READY' }
        elseif ([string]$run.state -eq 'RUNNING' -and $liveRuntimeStatus) { $liveRuntimeStatus }
        else { [string]$run.state }
        $resolvedVersion = if ($instance -and $instance.sqlDeploymentPlan -and $instance.sqlDeploymentPlan.installedSqlBuild) {
            [string]$instance.sqlDeploymentPlan.installedSqlBuild
        }
        elseif ($instance -and $instance.version) {
            [string]$instance.version
        }
        elseif ($instance -and $instance.sqlVersion) {
            [string]$instance.sqlVersion
        }
        elseif ($instance -and $instance.sqlDeploymentPlan -and $instance.sqlDeploymentPlan.SqlPatch) {
            '{0}-{1}' -f $registered.sqlVersion, $instance.sqlDeploymentPlan.SqlPatch
        }
        elseif ($instance -and $instance.sqlDeploymentPlan -and $instance.sqlDeploymentPlan.SqlVersion) {
            [string]$instance.sqlDeploymentPlan.SqlVersion
        }
        else { $null }
        $builder = $null
        if ($hostName -and $password) {
            $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
            $builder['Data Source'] = "$hostName,$port"
            $builder['Initial Catalog'] = 'master'
            $builder['User ID'] = 'sa'
            $builder['Password'] = $password
            $builder['Encrypt'] = $true
            $builder['TrustServerCertificate'] = $true
        }
        $resolved += [PSCustomObject]@{
            key = [string]$registered.key
            status = $runtimeStatus
            runtimeStatus = $runtimeStatus
            platform = [string]$registered.platform
            provider = if ($instance) { [string]$instance.provider } else { $null }
            sqlVersion = [string]$registered.sqlVersion
            patch = [string]$registered.patch
            resolvedVersion = $resolvedVersion
            runId = [string]$registered.runId
            instanceId = [string]$registered.instanceId
            host = $hostName
            port = $port
            database = 'master'
            username = 'sa'
            password = $password
            encrypt = $true
            trustServerCertificate = $true
            autoStart = 'on'
            connectionString = if ($builder) { $builder.ConnectionString } else { $null }
        }
    }
    $resolved = @($resolved | Sort-Object key)
    $groupReady = $resolved.Count -gt 0 -and @($resolved | Where-Object runtimeStatus -ne 'READY').Count -eq 0
    foreach ($entry in $resolved) {
        $entry.status = if ($groupReady) { 'READY' } else { 'GROUP_INCOMPLETE' }
    }
    return $resolved
}

function Sync-LabAutomatedTestEnvironmentConnectionCenter {
    <# Synchronisiert Testgruppe, Verbindungszentrale und optionalen CMS als eine Einheit. #>
    [CmdletBinding()]
    param([string]$StateRoot)

    try { $connectionCenter = Sync-SqlServerLabConnectionCenter -StateRoot $StateRoot -Quiet }
    catch { Write-LabWarning "Testumgebungs-Verbindungszentrale konnte nicht synchronisiert werden: $($_.Exception.Message)"; return $null }
    try {
        $cmsConfiguration = Get-LabConnectionCenterCmsConfiguration -StateRoot $StateRoot
        $cms = if ($cmsConfiguration) { Sync-SqlServerLabCms -StateRoot $StateRoot -Quiet } else { $null }
        if ($cms) { Write-LabInfo "Automatisierte Testumgebungen im CMS synchronisiert: $($cms.Entries) Endpunkt(e)." }
        return [PSCustomObject]@{ ConnectionCenter=$connectionCenter; Cms=$cms }
    }
    catch {
        Write-LabWarning "CMS-Synchronisation für automatisierte Testumgebungen fehlgeschlagen: $($_.Exception.Message)"
        return [PSCustomObject]@{ ConnectionCenter=$connectionCenter; Cms=$null }
    }
}

function Export-SqlServerLabTestEnvironment {
    <#
    .SYNOPSIS
        Exportiert automatisiert nutzbare SQL-Testzugänge nach Lab_Data.
    .DESCRIPTION
        Schreibt einen kanonischen JSON-Vertrag, das zugehörige JSON Schema, eine
        dotenv-Datei und eine menschen- sowie KI-lesbare Markdown-Beschreibung.
        Containerziele werden gegen ihre gespeicherte Providerbindung live
        geprüft; ein fehlender, gestoppter oder ungesunder Container sperrt die
        vollständige Gruppe.
        ENV und JSON enthalten Klartextkennwörter und werden nach Möglichkeit auf
        den aktuellen Benutzer beschränkt.
    .PARAMETER OutputDirectory
        Optionales Zielverzeichnis. Standard ist Lab_Data/Exports.
    .PARAMETER StateRoot
        Optionaler SQL_Server_Lab-State-Root, aus dem Runs und Secrets gelesen werden.
    .OUTPUTS
        Objekt mit den vier Exportpfaden sowie Anzahl aller und bereiter Einträge.
    #>
    [CmdletBinding()]
    param([string]$OutputDirectory, [string]$StateRoot)

    $directory = Get-LabTestEnvironmentExportDirectory -OutputDirectory $OutputDirectory
    $null = New-Item -ItemType Directory -Path $directory -Force
    $registry = Get-LabTestEnvironmentRegistry -OutputDirectory $directory
    $entries = @(Get-LabTestEnvironmentResolvedEntries -Registry $registry -StateRoot $StateRoot)
    $groupStatus = if ($entries.Count -eq 0) { 'EMPTY' } elseif (@($entries | Where-Object status -ne 'READY').Count -eq 0) { 'READY' } else { 'INCOMPLETE' }
    $schemaSourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Schemas/test-environment.schema.json'
    if (-not (Test-Path -LiteralPath $schemaSourcePath -PathType Leaf)) {
        throw "TEST_ENVIRONMENT_SCHEMA_MISSING: $schemaSourcePath"
    }
    $schemaPath = Join-Path $directory 'TestUmgebung.schema.json'
    Copy-Item -LiteralPath $schemaSourcePath -Destination $schemaPath -Force
    $promptSourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Documentation/User/LOCAL_SQL_TESTING_PROMPT.md'
    if (-not (Test-Path -LiteralPath $promptSourcePath -PathType Leaf)) {
        throw "TEST_ENVIRONMENT_PROMPT_MISSING: $promptSourcePath"
    }
    $promptPath = Join-Path $directory 'TestUmgebung.prompt.md'
    Copy-Item -LiteralPath $promptSourcePath -Destination $promptPath -Force
    $document = [PSCustomObject]@{
        '$schema' = './TestUmgebung.schema.json'
        contractVersion = 'SqlServerLab.TestEnvironment/1.0'
        generatedAt = Get-LabTimestamp
        groupStatus = $groupStatus
        selectionRule = 'nur groupStatus READY und Einträge mit status READY verwenden'
        containsPlainTextSecrets = $true
        environments = $entries
    }
    $jsonPath = Join-Path $directory 'TestUmgebung.json'
    Write-LabArtifactJsonAtomic -Path $jsonPath -InputObject $document

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# SqlServerLab.TestEnvironment/1.0 - enthält Klartextkennwörter')
    $lines.Add('SQL_SERVER_LAB_TEST_ENV_CONTRACT="SqlServerLab.TestEnvironment/1.0"')
    $lines.Add("SQL_SERVER_LAB_TEST_ENV_COUNT=$($entries.Count)")
    $lines.Add("SQL_SERVER_LAB_TEST_ENV_READY_COUNT=$(@($entries | Where-Object status -eq 'READY').Count)")
    $lines.Add("SQL_SERVER_LAB_TEST_ENV_GROUP_STATUS=$(ConvertTo-LabDotEnvValue $groupStatus)")
    $lines.Add('SQL_SERVER_LAB_TEST_ENV_KEYS=' + (ConvertTo-LabDotEnvValue (@($entries.key) -join ',')))
    $defaultEntry = @($entries | Where-Object status -eq 'READY' | Select-Object -First 1)[0]
    if ($defaultEntry) { $lines.Add("SQL_SERVER_LAB_DEFAULT_KEY=$(ConvertTo-LabDotEnvValue $defaultEntry.key)") }
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $entry = $entries[$index]
        $prefix = "SQL_SERVER_LAB_$($entry.key)"
        $values = [ordered]@{
            STATUS=$entry.status; RUNTIME_STATUS=$entry.runtimeStatus; PLATFORM=$entry.platform; PROVIDER=$entry.provider; SQL_VERSION=$entry.sqlVersion
            PATCH=$entry.patch; RESOLVED_VERSION=$entry.resolvedVersion; RUN_ID=$entry.runId; INSTANCE_ID=$entry.instanceId
            HOST=$entry.host; PORT=[string]$entry.port; DATABASE=$entry.database; USERNAME=$entry.username
            PASSWORD=$entry.password; ENCRYPT=([string]$entry.encrypt).ToLowerInvariant()
            TRUST_SERVER_CERTIFICATE=([string]$entry.trustServerCertificate).ToLowerInvariant(); AUTO_START=$entry.autoStart; CONNECTION_STRING=$entry.connectionString
        }
        foreach ($pair in $values.GetEnumerator()) { $lines.Add("${prefix}_$($pair.Key)=$(ConvertTo-LabDotEnvValue ([string]$pair.Value))") }
    }
    $envPath = Join-Path $directory 'TestUmgebung.env'
    [IO.File]::WriteAllLines($envPath, $lines, [Text.UTF8Encoding]::new($false))

    $markdown = @(
        '# SQL Server Lab – automatisierte Testumgebungen', '',
        '> `TestUmgebung.env` und `TestUmgebung.json` enthalten Klartextkennwörter. Nicht kopieren, committen oder weitergeben.', '',
        '## Maschinenvertrag', '',
        '- Kanonische Datei: `TestUmgebung.json` mit Vertrag `SqlServerLab.TestEnvironment/1.0`.',
        '- Validierung: `TestUmgebung.schema.json` nach JSON Schema Draft 2020-12; `TestUmgebung.json` verweist über `$schema` darauf.',
        '- Wiederverwendbarer Agenten-Prompt: `TestUmgebung.prompt.md`.',
        '- Portable Discovery: zuerst `SQL_SERVER_LAB_TEST_ENV_FILE`, sonst `SQL_SERVER_LAB_DATA_ROOT` plus `Exports/TestUmgebung.json`.',
        '- Die Gruppe ist nur bei `groupStatus = READY` verwendbar; andernfalls ist die gesamte Gruppe gesperrt.',
        '- Ein Eintrag wird über `platform`, `sqlVersion` und `patch` ausgewählt.',
        '- Ausschließlich Einträge mit `status = READY` dürfen für Tests verwendet werden; `runtimeStatus` zeigt den Einzelzustand.',
        '- `patch = latest` ist bei Linux gleitend; `patch = base` bezeichnet bei Windows die Basisinstallation ohne separates CU.',
        '- `resolvedVersion` dokumentiert die tatsächlich installierte SQL-Version.',
        '- Verbindung: `host`, `port`, `database`, `username`, `password`, `encrypt`, `trustServerCertificate`.',
        '- Dotenv-Schlüssel verwenden das Präfix `SQL_SERVER_LAB_<KEY>_...`.', '',
        '## Beispiel für KI und Tools', '',
        'Gesucht: Linux, SQL Server 2022, latest. Zuerst `groupStatus = READY` fordern; danach den Eintrag wählen, dessen `platform`, `sqlVersion`, `patch` und `status` genau passen.', '',
        '```powershell',
        '$contract = Get-Content .\TestUmgebung.json -Raw | ConvertFrom-Json',
        'if ($contract.groupStatus -ne ''READY'') { throw ''Testumgebungsgruppe ist nicht vollständig bereit.'' }',
        '$target = $contract.environments | Where-Object { $_.platform -eq ''linux'' -and $_.sqlVersion -eq ''2022'' -and $_.patch -eq ''latest'' -and $_.status -eq ''READY'' } | Select-Object -First 1',
        '$target.connectionString',
        '```', '',
        '## Aktuelle Einträge', ''
    )
    foreach ($entry in $entries) { $markdown += "- `$($entry.key)`: $($entry.platform), SQL $($entry.sqlVersion), $($entry.patch), $($entry.status), $($entry.host):$($entry.port)" }
    $mdPath = Join-Path $directory 'TestUmgebung.md'
    [IO.File]::WriteAllLines($mdPath, $markdown, [Text.UTF8Encoding]::new($false))
    $configuredUserDataRoot = [string][Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', 'User')
    $exportDataRoot = Split-Path -Parent $directory
    $persistDiscovery = $configuredUserDataRoot -and
        [string]::Equals([IO.Path]::GetFullPath($configuredUserDataRoot).TrimEnd('\','/'), [IO.Path]::GetFullPath($exportDataRoot).TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase)
    $null = Set-LabTestEnvironmentDiscoveryEnvironment -DataRoot $exportDataRoot -ProcessEnvironmentOnly:(-not $persistDiscovery)
    foreach ($secretPath in @($envPath, $jsonPath, (Get-LabTestEnvironmentRegistryPath -OutputDirectory $directory))) {
        Protect-LabTestEnvironmentSecretFile -Path $secretPath
    }
    return [PSCustomObject]@{ Directory=$directory; EnvPath=$envPath; JsonPath=$jsonPath; SchemaPath=$schemaPath; PromptPath=$promptPath; MarkdownPath=$mdPath; GroupStatus=$groupStatus; Entries=$entries.Count; Ready=@($entries | Where-Object status -eq 'READY').Count }
}

function Clear-SqlServerLabAutomatedTestEnvironment {
    <#
    .SYNOPSIS
        Entfernt die vollständige Gruppe automatisierter Testumgebungen.
    .DESCRIPTION
        Automatisierte Testumgebungen sind eine geschützte Lifecycle-Gruppe und
        können nicht einzeln über die normalen Start-, Stopp-, Verwaltungs-
        oder Löschaktionen verändert werden. Dieses Cmdlet entfernt alle
        registrierten Runs und anschließend deren TestUmgebung-Exportdateien.
    .PARAMETER Force
        Unterdrückt die zusätzliche Gruppenbestätigung. WhatIf und Confirm
        bleiben über SupportsShouldProcess verfügbar.
    .PARAMETER OutputDirectory
        Optionales Exportziel. Standard ist Lab_Data/Exports.
    .PARAMETER StateRoot
        Optionaler SQL_Server_Lab-State-Root.
    .OUTPUTS
        Zusammenfassung mit Status, entfernten und verbliebenen Runs.
    .EXAMPLE
        Clear-SqlServerLabAutomatedTestEnvironment
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([switch]$Force, [string]$OutputDirectory, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $directory = Get-LabTestEnvironmentExportDirectory -OutputDirectory $OutputDirectory
    $registry = Get-LabTestEnvironmentRegistry -OutputDirectory $directory
    $registered = @($registry.environments)
    if ($registered.Count -eq 0) {
        return [PSCustomObject]@{ Status='EMPTY'; Removed=0; Remaining=0; Errors=0 }
    }
    if (-not $PSCmdlet.ShouldProcess("$($registered.Count) automatisierte Testumgebung(en)", 'Gesamte Testumgebungsgruppe entfernen')) {
        return [PSCustomObject]@{ Status='CANCELLED'; Removed=0; Remaining=$registered.Count; Errors=0 }
    }
    if (-not $Force -and -not $PSCmdlet.ShouldContinue(
        'Alle automatisierten Testumgebungen werden gemeinsam und unwiderruflich entfernt. Fortfahren?',
        'Gesamte Testumgebungsgruppe löschen')) {
        return [PSCustomObject]@{ Status='CANCELLED'; Removed=0; Remaining=$registered.Count; Errors=0 }
    }

    $remaining = [Collections.Generic.List[object]]::new()
    $removed = 0
    $errors = 0
    $previousGroupOperation = $script:LabAutomatedTestEnvironmentGroupOperation
    $script:LabAutomatedTestEnvironmentGroupOperation = $true
    try {
        foreach ($entry in $registered) {
            $runId = [string]$entry.runId
            if (-not $runId) { $removed++; continue }
            $runStatePath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $runId) 'run-state.json'
            if (-not (Test-Path -LiteralPath $runStatePath -PathType Leaf)) { $removed++; continue }
            try {
                $result = Remove-SqlServerLab -RunId $runId -StateRoot $StateRoot -Force -Confirm:$false
                if ([string]$result.Status -eq 'REMOVED') { $removed++ }
                else { $remaining.Add($entry); $errors++ }
            }
            catch {
                Write-LabError "Testumgebung '$($entry.key)' konnte nicht entfernt werden: $($_.Exception.Message)"
                $remaining.Add($entry)
                $errors++
            }
        }
    }
    finally { $script:LabAutomatedTestEnvironmentGroupOperation = $previousGroupOperation }

    if ($remaining.Count -eq 0) {
        foreach ($fileName in @('TestUmgebung.env','TestUmgebung.json','TestUmgebung.schema.json','TestUmgebung.prompt.md','TestUmgebung.md','TestUmgebung.registry.json')) {
            $path = Join-Path $directory $fileName
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
        }
        $null = Sync-LabAutomatedTestEnvironmentConnectionCenter -StateRoot $StateRoot
        return [PSCustomObject]@{ Status='REMOVED'; Removed=$removed; Remaining=0; Errors=0 }
    }

    $registry.environments = @($remaining)
    $registry.updatedAt = Get-LabTimestamp
    $registryPath = Get-LabTestEnvironmentRegistryPath -OutputDirectory $directory
    Write-LabArtifactJsonAtomic -Path $registryPath -InputObject $registry
    Protect-LabTestEnvironmentSecretFile -Path $registryPath
    $null = Export-SqlServerLabTestEnvironment -OutputDirectory $directory -StateRoot $StateRoot
    $null = Sync-LabAutomatedTestEnvironmentConnectionCenter -StateRoot $StateRoot
    return [PSCustomObject]@{ Status='RECOVERY_REQUIRED'; Removed=$removed; Remaining=$remaining.Count; Errors=$errors }
}

function Repair-SqlServerLabAutomatedTestEnvironment {
    <#
    .SYNOPSIS
        Repariert Runtime-Namen sowie Ressourcen- und Readiness-Verträge der Testgruppe.
    .DESCRIPTION
        Gleicht registrierte Docker-/Podman-Mitglieder der geschützten Testgruppe
        auf 4 vCPU, 4096 MB Container-RAM, 3276 MB SQL-internes Speicherlimit,
        Autostart und den TLS-tauglichen Healthcheck ab. Zusätzlich erhalten
        alle Container und belegten Hyper-V-Slots einen aus ihrem Registry-
        Schlüssel abgeleiteten, sprechenden Runtime-Namen. Ports, Volumes,
        Run-IDs und Kennwörter bleiben erhalten. Jeder Container-Austausch
        besitzt einen eigenen Rollback; laufende Hyper-V-VMs werden nur für die
        Umbenennung gestoppt und garantiert wieder gestartet. Anschließend wird
        der Gruppenexport live erneuert.
    .PARAMETER Force
        Unterdrückt die zusätzliche Gruppenbestätigung. WhatIf und Confirm
        bleiben über SupportsShouldProcess verfügbar.
    .PARAMETER ReadinessTimeoutSeconds
        Maximale Wartezeit pro ausgetauschtem Linux-Container bis zur stabilen
        SQL-Bereitschaft.
    .PARAMETER OutputDirectory
        Optionales Exportziel. Standard ist Lab_Data/Exports.
    .PARAMETER StateRoot
        Optionaler SQL_Server_Lab-State-Root.
    .OUTPUTS
        Zusammenfassung mit Status, reparierten, umbenannten, unveränderten und
        fehlerhaften Mitgliedern sowie dem erneuerten Exportstatus.
    .EXAMPLE
        Repair-SqlServerLabAutomatedTestEnvironment -Force -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [switch]$Force,
        [ValidateRange(10, 600)][int]$ReadinessTimeoutSeconds = 180,
        [string]$OutputDirectory,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $directory = Get-LabTestEnvironmentExportDirectory -OutputDirectory $OutputDirectory
    $registry = Get-LabTestEnvironmentRegistry -OutputDirectory $directory
    $registeredEntries = @($registry.environments | Where-Object { [string]$_.runId })
    if ($registeredEntries.Count -eq 0) {
        return [PSCustomObject]@{ Status='EMPTY'; Repaired=0; Renamed=0; Unchanged=0; Errors=0; Export=$null }
    }
    if (-not $PSCmdlet.ShouldProcess("$($registeredEntries.Count) automatisierte Testumgebung(en)", 'Runtime-Namen, Ressourcen- und Readiness-Vertrag der geschützten Gruppe reparieren')) {
        return [PSCustomObject]@{ Status='CANCELLED'; Repaired=0; Renamed=0; Unchanged=0; Errors=0; Export=$null }
    }
    if (-not $Force -and -not $PSCmdlet.ShouldContinue(
        'Linux-Container werden bei Bedarf kontrolliert ersetzt; belegte Hyper-V-Slots können für die Umbenennung kurz neu gestartet werden. Fortfahren?',
        'Automatisierte Testumgebungsgruppe reparieren')) {
        return [PSCustomObject]@{ Status='CANCELLED'; Repaired=0; Renamed=0; Unchanged=0; Errors=0; Export=$null }
    }

    $repaired = 0
    $renamed = 0
    $unchanged = 0
    $errors = [Collections.Generic.List[object]]::new()
    $serverConfig = [PSCustomObject]@{
        memory = [PSCustomObject]@{ minMB = 0; maxMB = 3072 }
        maxDop = 4
        costThreshold = 50
        traceFlags = @()
        spConfigure = [PSCustomObject]@{ 'optimize for ad hoc workloads' = 1 }
    }
    $previousGroupOperation = $script:LabAutomatedTestEnvironmentGroupOperation
    $script:LabAutomatedTestEnvironmentGroupOperation = $true
    try {
        foreach ($entry in $registeredEntries) {
            $runId = [string]$entry.runId
            try {
                if ([string]$entry.platform -eq 'linux') {
                    $result = Update-SqlServerLabContainer -RunId $runId -Cpu 4 -MemoryMB 4096 -AutoStart on `
                        -RepairSqlRuntimeContract -ReadinessTimeoutSeconds $ReadinessTimeoutSeconds -StateRoot $StateRoot -Confirm:$false
                    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $runId
                    $connection = Get-Content -LiteralPath (Join-Path $runDirectory 'connection-info.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
                    $instance = @($connection.instances | Where-Object { [string]$_.provider -in @('docker','podman') })[0]
                    if (-not $instance) { throw 'TEST_ENVIRONMENT_REPAIR_CONTAINER_INSTANCE_MISSING' }
                    $saPassword = Get-LabSecret -Path $runDirectory -Name 'sa-password'
                    if (-not $saPassword) { throw 'TEST_ENVIRONMENT_REPAIR_SA_SECRET_MISSING' }
                    $null = Set-LabServerConfig -Config $serverConfig -HostName ([string]$instance.host) -Port ([int]$instance.port) `
                        -SaPassword $saPassword -Provider ([string]$instance.provider) -ContainerName ([string]$result.Container)
                    if ($result.Changed) { $repaired++ } else { $unchanged++ }
                }
                $nameResult = Rename-LabAutomatedTestEnvironmentRuntime -RunId $runId `
                    -InstanceId ([string]$entry.instanceId) -Key ([string]$entry.key) -StateRoot $StateRoot
                if ($nameResult.RuntimeRenamed -or $nameResult.VMRenamed) { $renamed++ }
            }
            catch {
                $errors.Add([PSCustomObject]@{ Key=[string]$entry.key; Message=$_.Exception.Message })
                Write-LabError "Testumgebung '$($entry.key)' konnte nicht repariert werden: $($_.Exception.Message)"
            }
        }
    }
    finally { $script:LabAutomatedTestEnvironmentGroupOperation = $previousGroupOperation }

    if (@($registeredEntries | Where-Object { [string]$_.platform -eq 'windows' }).Count -gt 0) {
        try {
            $windowsReady = Start-SqlServerLabAutomatedTestEnvironment -TimeoutSeconds $ReadinessTimeoutSeconds `
                -Force -OutputDirectory $directory -StateRoot $StateRoot -Confirm:$false
            if ([string]$windowsReady.Status -ne 'READY') {
                throw "TEST_ENVIRONMENT_RUNTIME_RENAME_READINESS_FAILED: $($windowsReady.Status)"
            }
        }
        catch {
            $errors.Add([PSCustomObject]@{ Key='WINDOWS_GROUP'; Message=$_.Exception.Message })
            Write-LabError "Windows-Testgruppe konnte nach der Namensreparatur nicht vollständig bereitgestellt werden: $($_.Exception.Message)"
        }
    }

    $export = Export-SqlServerLabTestEnvironment -OutputDirectory $directory -StateRoot $StateRoot
    $null = Sync-LabAutomatedTestEnvironmentConnectionCenter -StateRoot $StateRoot
    $status = if ($errors.Count -eq 0 -and [string]$export.GroupStatus -eq 'READY') { 'READY' } else { 'INCOMPLETE' }
    return [PSCustomObject]@{ Status=$status; Repaired=$repaired; Renamed=$renamed; Unchanged=$unchanged; Errors=$errors.Count; Details=@($errors); Export=$export }
}

function New-SqlServerLabAutomatedTestEnvironment {
    <#
    .SYNOPSIS
        Erstellt Linux-SQL-Testumgebungen mit getrennten Zufallskennwörtern.
    .DESCRIPTION
        Verarbeitet eine oder mehrere Spezifikationen, erstellt für jede eine
        eigene Docker- oder Podman-Umgebung und aktualisiert anschließend
        TestUmgebung.env, TestUmgebung.json, TestUmgebung.schema.json und
        TestUmgebung.md unter Lab_Data.
        Windows-Aufträge werden wegen möglicher OOBE-Schritte über Menüpunkt [e]
        geführt.
    .PARAMETER Specification
        Liste von Objekten mit Platform, SqlVersion, Patch sowie optional Name,
        Key, InstanceId und Provider.
    .PARAMETER Provider
        Containerprovider oder auto für die erste verfügbare Runtime.
    .PARAMETER OutputDirectory
        Optionales Exportziel. Standard ist Lab_Data/Exports.
    .PARAMETER StateRoot
        Optionaler SQL_Server_Lab-State-Root für die erzeugten Runs.
    .OUTPUTS
        Objekt mit den erzeugten Umgebungen und den Exportpfaden.
    .EXAMPLE
        New-SqlServerLabAutomatedTestEnvironment -Specification @(
            @{ Platform='linux'; SqlVersion='2022'; Patch='latest' }
        )
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Specification,
        [ValidateSet('auto','docker','podman')][string]$Provider = 'auto',
        [string]$OutputDirectory,
        [string]$StateRoot
    )

    foreach ($spec in $Specification) {
        if (([string]$spec.Platform).ToLowerInvariant() -ne 'linux') {
            throw 'TEST_ENVIRONMENT_WINDOWS_INTERACTIVE_MENU_REQUIRED'
        }
    }

    $requests = @()
    foreach ($spec in $Specification) {
        $platform = ([string]$spec.Platform).ToLowerInvariant()
        $version = [string]$spec.SqlVersion
        $patch = if ($spec.Patch) { ([string]$spec.Patch).ToLowerInvariant() } else { 'latest' }
        $instanceId = if ($spec.InstanceId) { [string]$spec.InstanceId } else { 'primary' }
        $intent = Register-LabTestEnvironmentIntent -Platform $platform -SqlVersion $version -Patch $patch `
            -InstanceId $instanceId -Name ([string]$spec.Key) -OutputDirectory $OutputDirectory
        $requests += [PSCustomObject]@{ Specification=$spec; Platform=$platform; Version=$version; Patch=$patch; InstanceId=$instanceId; Key=[string]$intent.key }
    }

    $results = @()
    $errors = @()
    foreach ($request in $requests) {
        $spec = $request.Specification
        $platform = $request.Platform
        $version = $request.Version
        $patch = $request.Patch
        $versionId = if ($patch -eq 'latest') { $version } else { "$version-$($patch.ToUpperInvariant())" }
        $selectedProvider = if ($spec.Provider) { ([string]$spec.Provider).ToLowerInvariant() } else { $Provider }
        if ($selectedProvider -eq 'auto') {
            $selectedProvider = @(Get-AvailableLabProviders | Where-Object { $_ -in @('docker','podman') }) | Select-Object -First 1
        }
        $name = Get-LabAutomatedTestEnvironmentDisplayName -Key $request.Key
        try {
            if ($selectedProvider -notin @('docker','podman')) { throw 'TEST_ENVIRONMENT_LINUX_PROVIDER_UNAVAILABLE' }
            $password = New-HyperVSqlUnattendedPassword
            $serverConfig = [PSCustomObject]@{
                memory = [PSCustomObject]@{ minMB = 0; maxMB = 3072 }
                maxDop = 4
                costThreshold = 50
                traceFlags = @()
                spConfigure = [PSCustomObject]@{ 'optimize for ad hoc workloads' = 1 }
            }
            $lab = New-SqlServerLab -Version $versionId -Provider $selectedProvider -Profile standard -LabName $name `
                -InstanceId $request.InstanceId -Cpu 4 -MemoryMB 4096 -ServerConfig $serverConfig `
                -SaPassword $password -NonInteractive -AutoStart on -StateRoot $StateRoot
            $null = Rename-LabAutomatedTestEnvironmentRuntime -RunId $lab.RunId -InstanceId $request.InstanceId `
                -Key $request.Key -StateRoot $StateRoot
            $null = Register-LabTestEnvironmentRun -RunId $lab.RunId -Platform linux -SqlVersion $version -Patch $patch `
                -InstanceId $request.InstanceId -Name $request.Key -OutputDirectory $OutputDirectory
            $results += $lab
        }
        catch {
            $errors += [PSCustomObject]@{ Key=$request.Key; Message=$_.Exception.Message }
            Write-LabError "Automatisierte Testumgebung '$($request.Key)' konnte nicht erstellt werden: $($_.Exception.Message)"
        }
    }
    $export = Export-SqlServerLabTestEnvironment -OutputDirectory $OutputDirectory -StateRoot $StateRoot
    $null = Sync-LabAutomatedTestEnvironmentConnectionCenter -StateRoot $StateRoot
    return [PSCustomObject]@{ Status=if ($errors.Count -eq 0 -and $export.GroupStatus -eq 'READY') { 'READY' } else { 'INCOMPLETE' }; Environments=$results; Errors=$errors; Export=$export }
}

<#
.SYNOPSIS
    State-Management fuer SQL_Server_Lab.
.DESCRIPTION
    Verwaltet lokalen Run-State, Transitionen, Fehlerhistorie und Scope-Marker.
    State liegt ausserhalb des Git-Checkouts.
#>

function Get-LabStateRoot {
    [CmdletBinding()]
    param(
        [string]$ExplicitPath
    )

    if ($ExplicitPath) {
        return $ExplicitPath
    }
    if ($env:SQL_SERVER_LAB_STATE) {
        return $env:SQL_SERVER_LAB_STATE
    }

    if ($IsWindows) {
        return Join-Path $env:LOCALAPPDATA 'SqlServerLab'
    }

    return Join-Path (Resolve-Path '~') '.sql-server-lab'
}

function Initialize-LabStateRoot {
    [CmdletBinding()]
    param(
        [string]$StateRoot
    )

    if (-not $StateRoot) {
        $StateRoot = Get-LabStateRoot
    }

    $directories = @(
        $StateRoot,
        (Join-Path $StateRoot 'runs'),
        (Join-Path $StateRoot 'scope-markers'),
        (Join-Path $StateRoot 'catalog')
    )

    foreach ($directory in $directories) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
    }

    $configPath = Join-Path $StateRoot 'config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        [PSCustomObject]@{
            version        = '0.1.0'
            createdAt      = Get-LabTimestamp
            defaultProfile = 'standard'
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding utf8
    }

    return $StateRoot
}

function New-LabRunState {
    [CmdletBinding()]
    param(
        [string]$StateRoot,
        [string]$ScopeId,
        [hashtable]$Metadata = @{},
        [array]$ProviderSubRuns = @()
    )

    if (-not $StateRoot) {
        $StateRoot = Get-LabStateRoot
    }

    $null = Initialize-LabStateRoot -StateRoot $StateRoot

    $runId = New-LabGuid
    if (-not $ScopeId) {
        $ScopeId = New-LabGuid
    }

    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $runId
    New-Item -Path $runDirectory -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $runDirectory 'log') -ItemType Directory -Force | Out-Null

    $timestamp = Get-LabTimestamp
    $normalizedProviderSubRuns = @()
    $knownProviders = @{}
    foreach ($providerSubRun in @($ProviderSubRuns)) {
        $provider = ([string]$providerSubRun.provider).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($provider)) {
            throw 'ProviderSubRun besitzt keinen Provider.'
        }
        if ($knownProviders.ContainsKey($provider)) {
            throw "ProviderSubRun fuer '$provider' wurde mehrfach angegeben."
        }
        $knownProviders[$provider] = $true

        $normalizedProviderSubRuns += [PSCustomObject]@{
            id            = if ($providerSubRun.id) { [string]$providerSubRun.id } else { "provider-$provider" }
            provider      = $provider
            instanceIds   = @($providerSubRun.instanceIds | Where-Object { $_ } | ForEach-Object { [string]$_ })
            state         = 'INITIALIZING'
            stateHistory  = @(
                [PSCustomObject]@{
                    state     = 'INITIALIZING'
                    timestamp = $timestamp
                    reason    = 'ProviderSubRun erstellt'
                }
            )
            createdAt     = $timestamp
            updatedAt     = $timestamp
            errors        = @()
        }
    }

    $state = [PSCustomObject]@{
        runId        = $runId
        scopeId      = $ScopeId
        state        = 'INITIALIZING'
        stateHistory = @(
            [PSCustomObject]@{
                state     = 'INITIALIZING'
                timestamp = $timestamp
                reason    = 'Run erstellt'
            }
        )
        createdAt    = $timestamp
        updatedAt    = $timestamp
        instances    = @()
        providerSubRuns = $normalizedProviderSubRuns
        metadata     = $Metadata
        errors       = @()
    }

    $statePath = Join-Path $runDirectory 'run-state.json'
    $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8

    $owner = if ($env:USERNAME) {
        $env:USERNAME
    }
    elseif ($env:USER) {
        $env:USER
    }
    else {
        'unknown'
    }

    $markerPath = Join-Path (Join-Path $StateRoot 'scope-markers') "$ScopeId.json"
    [PSCustomObject]@{
        scopeId   = $ScopeId
        runId     = $runId
        createdAt = $timestamp
        owner     = $owner
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $markerPath -Encoding utf8

    return [PSCustomObject]@{
        RunId     = $runId
        ScopeId   = $ScopeId
        State     = 'INITIALIZING'
        RunDir    = $runDirectory
        StateRoot = $StateRoot
    }
}

function Get-LabRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    if (-not $StateRoot) {
        $StateRoot = Get-LabStateRoot
    }

    $statePath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) 'run-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "Run-State nicht gefunden: $RunId"
    }

    return Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
}

function Get-LabProviderSubRuns {
    <#
    .SYNOPSIS
        Liest die providergebundenen Teil-Lifecycles eines Runs.
    .DESCRIPTION
        Aeltere Run-State-Dateien besitzen keine ProviderSubRuns. Sie bleiben
        lesbar und liefern dann ein leeres Array.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    $state = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if (-not $state.PSObject.Properties['providerSubRuns']) {
        return @()
    }

    return @($state.providerSubRuns)
}

function Get-LabStateTransitionMap {
    [CmdletBinding()]
    param()

    return @{
        INITIALIZING      = @('PROVISIONING', 'PROVISION_FAILED', 'CLEANUP_PENDING')
        PROVISIONING      = @('SQL_READY', 'PROVISION_FAILED', 'CLEANUP_PENDING')
        SQL_READY         = @('DATABASES_CREATED', 'PROVISION_FAILED', 'CLEANUP_PENDING')
        DATABASES_CREATED = @('POST_PROVISIONED', 'RUNNING', 'PROVISION_FAILED', 'CLEANUP_PENDING')
        POST_PROVISIONED  = @('RUNNING', 'PROVISION_FAILED', 'CLEANUP_PENDING')
        RUNNING           = @('STOPPED', 'CLEANUP_PENDING', 'REMOVED')
        STOPPED           = @('RUNNING', 'CLEANUP_PENDING', 'REMOVED')
        PROVISION_FAILED  = @('CLEANUP_PENDING')
        CLEANUP_PENDING   = @('CLEANUP_RUNNING')
        CLEANUP_RUNNING   = @('CLEANED_UP', 'RECOVERY_REQUIRED', 'REMOVED')
        CLEANED_UP        = @('RECOVERY_REQUIRED', 'REMOVED')
        RECOVERY_REQUIRED = @('CLEANUP_PENDING', 'REMOVED')
    }
}

function Set-LabProviderSubRunState {
    <#
    .SYNOPSIS
        Setzt den State eines providergebundenen Teil-Lifecycles.
    .DESCRIPTION
        Ein ProviderSubRun ist eine interne Gruppierung aller Instanzen eines
        Providers innerhalb desselben Run. Der globale Run-State bleibt fuer
        die Benutzeroberflaeche massgeblich; die Teilstates erlauben Status,
        Lifecycle und Recovery ohne eine zufaellig gewaehlte Container-Runtime.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('docker', 'podman', 'hyperv')][string]$Provider,
        [Parameter(Mandatory)]
        [ValidateSet(
            'INITIALIZING',
            'PROVISIONING',
            'SQL_READY',
            'DATABASES_CREATED',
            'POST_PROVISIONED',
            'RUNNING',
            'STOPPED',
            'PROVISION_FAILED',
            'CLEANUP_PENDING',
            'CLEANUP_RUNNING',
            'CLEANED_UP',
            'RECOVERY_REQUIRED',
            'REMOVED'
        )]
        [string]$NewState,
        [string]$Reason = '',
        [string]$StateRoot
    )

    if (-not $StateRoot) {
        $StateRoot = Get-LabStateRoot
    }

    $statePath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) 'run-state.json'
    $current = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    if (-not $current.PSObject.Properties['providerSubRuns']) {
        return
    }

    $providerSubRun = @(
        $current.providerSubRuns |
            Where-Object { ([string]$_.provider).Equals($Provider, [System.StringComparison]::OrdinalIgnoreCase) }
    ) | Select-Object -First 1
    if (-not $providerSubRun) {
        throw "ProviderSubRun fuer '$Provider' nicht gefunden."
    }

    if ($providerSubRun.state -eq $NewState) {
        return
    }

    $validTransitions = Get-LabStateTransitionMap
    $allowed = $validTransitions[$providerSubRun.state]
    if (-not $allowed -or $NewState -notin $allowed) {
        $allowedText = if ($allowed) { $allowed -join ', ' } else { '(keine)' }
        throw "Ungueltiger ProviderSubRun-State-Uebergang ($Provider): $($providerSubRun.state) -> $NewState. Erlaubt: $allowedText"
    }

    $timestamp = Get-LabTimestamp
    $providerSubRun.state = $NewState
    $providerSubRun.updatedAt = $timestamp
    $providerSubRun.stateHistory += [PSCustomObject]@{
        state     = $NewState
        timestamp = $timestamp
        reason    = $Reason
    }

    $current.updatedAt = $timestamp
    $current | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8
}

function Set-LabProviderSubRunsState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string[]]$Providers,
        [Parameter(Mandatory)][string]$NewState,
        [string]$Reason = '',
        [string]$StateRoot
    )

    foreach ($provider in @($Providers | Where-Object { $_ } | Sort-Object -Unique)) {
        Set-LabProviderSubRunState `
            -RunId $RunId `
            -Provider $provider `
            -NewState $NewState `
            -Reason $Reason `
            -StateRoot $StateRoot
    }
}

function Set-LabRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]
        [ValidateSet(
            'INITIALIZING',
            'PROVISIONING',
            'SQL_READY',
            'DATABASES_CREATED',
            'POST_PROVISIONED',
            'RUNNING',
            'STOPPED',
            'PROVISION_FAILED',
            'CLEANUP_PENDING',
            'CLEANUP_RUNNING',
            'CLEANED_UP',
            'RECOVERY_REQUIRED',
            'REMOVED'
        )]
        [string]$NewState,
        [string]$Reason = '',
        [string]$StateRoot
    )

    if (-not $StateRoot) {
        $StateRoot = Get-LabStateRoot
    }

    $statePath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) 'run-state.json'
    $current = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20

    $validTransitions = Get-LabStateTransitionMap

    if ($current.state -eq $NewState) {
        return
    }

    $allowed = $validTransitions[$current.state]
    if (-not $allowed -or $NewState -notin $allowed) {
        $allowedText = if ($allowed) { $allowed -join ', ' } else { '(keine)' }
        throw "Ungueltiger State-Uebergang: $($current.state) -> $NewState. Erlaubt: $allowedText"
    }

    $timestamp = Get-LabTimestamp
    $current.state = $NewState
    $current.updatedAt = $timestamp
    $current.stateHistory += [PSCustomObject]@{
        state     = $NewState
        timestamp = $timestamp
        reason    = $Reason
    }

    $current | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8
}

function Add-LabRunError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Message,
        [string]$Component = '',
        [string]$StateRoot
    )

    if (-not $StateRoot) {
        $StateRoot = Get-LabStateRoot
    }

    $statePath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) 'run-state.json'
    $current = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    $timestamp = Get-LabTimestamp

    $current.errors += [PSCustomObject]@{
        timestamp = $timestamp
        message   = $Message
        component = $Component
    }
    $current.updatedAt = $timestamp

    $current | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8
}

function Rename-LabRunDisplayName {
    <#
    .SYNOPSIS
        Ändert ausschließlich den Anzeigenamen eines vorhandenen Lab-Runs.
    .DESCRIPTION
        Die Operation verändert weder Container, virtuelle Maschinen, Ports,
        persistenten Speicher noch die Run- oder Scope-ID. Der Name ist reine
        Bedienmetadaten und wird mit einer nachvollziehbaren Historie im
        Run-State gespeichert.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$')][string]$DisplayName,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $statePath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') $RunId) 'run-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw "LAB_RUN_NOT_FOUND: $RunId" }
    $current = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    if ([string]$current.state -in @('REMOVED', 'CLEANED_UP')) { throw "LAB_RUN_NOT_RENAMEABLE: $RunId" }

    $DisplayName = $DisplayName.Trim()
    if ([string]::IsNullOrWhiteSpace($DisplayName)) { throw 'LAB_RUN_DISPLAY_NAME_REQUIRED' }
    $previousName = [string]$current.metadata.name
    if ($previousName -eq $DisplayName) {
        return [PSCustomObject]@{ RunId = $RunId; PreviousName = $previousName; Name = $DisplayName; Changed = $false }
    }

    if (-not $current.metadata) { $current | Add-Member -NotePropertyName metadata -NotePropertyValue ([PSCustomObject]@{}) -Force }
    $current.metadata | Add-Member -NotePropertyName name -NotePropertyValue $DisplayName -Force
    # ConvertFrom-Json liefert bei genau einem Eintrag ein PSCustomObject statt
    # eines Arrays. Eine explizite Liste verhindert daher op_Addition-Fehler
    # beim zweiten oder späteren Umbenennen.
    $history = [System.Collections.Generic.List[object]]::new()
    if ($current.metadata.PSObject.Properties['nameHistory']) {
        foreach ($entry in @($current.metadata.nameHistory)) { $history.Add($entry) }
    }
    $history.Add([PSCustomObject]@{ previousName = $previousName; name = $DisplayName; changedAt = Get-LabTimestamp })
    $current.metadata | Add-Member -NotePropertyName nameHistory -NotePropertyValue @($history.ToArray()) -Force
    $current.updatedAt = Get-LabTimestamp
    $current | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8
    return [PSCustomObject]@{ RunId = $RunId; PreviousName = $previousName; Name = $DisplayName; Changed = $true }
}

function Get-LabContainerRuntimeName {
    <#
    .SYNOPSIS
        Erzeugt einen Docker-/Podman-konformen, projektlesbaren Runtime-Namen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$')][string]$LabName,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')][string]$InstanceId,
        [Parameter(Mandatory)][string]$RunId
    )

    $stem = ($LabName.Trim() -replace '[^A-Za-z0-9_.-]+', '-').Trim([char[]]@('.', '-', '_')).ToLowerInvariant()
    if (-not $stem) { throw 'LAB_RUNTIME_NAME_REQUIRED' }
    $runPrefix = $RunId.Replace('-', '').Substring(0, 8).ToLowerInvariant()
    return "$stem-$InstanceId-$runPrefix"
}

function Rename-ContainerLabEnvironment {
    <#
    .SYNOPSIS
        Benennt Docker- oder Podman-Container eines Lab-Runs gemeinsam um.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$')][string]$DisplayName,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $connectionPath = Join-Path $runDirectory 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { throw 'LAB_CONNECTION_INFO_NOT_FOUND' }
    $originalConnectionJson = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8
    $connection = $originalConnectionJson | ConvertFrom-Json -Depth 20
    $DisplayName = $DisplayName.Trim()
    $renames = @()
    $planPath = Join-Path $runDirectory 'cleanup-plan.json'
    $originalPlanJson = $null

    try {
        foreach ($instance in @($connection.instances)) {
            $provider = [string]$instance.provider
            if ($provider -notin @('docker', 'podman')) { continue }
            $oldName = [string]$instance.containerName
            $newName = Get-LabContainerRuntimeName -LabName $DisplayName -InstanceId ([string]$instance.id) -RunId $RunId
            if ($oldName -eq $newName) { continue }
            $output = & $provider rename ([string]$instance.containerId) $newName 2>&1
            if ($LASTEXITCODE -ne 0) { throw "${provider}_CONTAINER_RENAME_FAILED: $(($output | Out-String).Trim())" }
            $instance | Add-Member -NotePropertyName containerName -NotePropertyValue $newName -Force
            $renames += [PSCustomObject]@{ Provider = $provider; OldName = $oldName; NewName = $newName; ContainerId = [string]$instance.containerId }
        }

        if (Test-Path -LiteralPath $planPath -PathType Leaf) {
            $originalPlanJson = Get-Content -LiteralPath $planPath -Raw -Encoding utf8
            $plan = $originalPlanJson | ConvertFrom-Json -Depth 20
            foreach ($rename in $renames) {
                foreach ($step in @($plan.steps | Where-Object { $_.resourceType -eq 'container' -and $_.provider -eq $rename.Provider -and $_.resourceId -eq $rename.OldName })) {
                    $step.resourceId = $rename.NewName
                    $step.compensation = "$($rename.Provider) rm -f $($rename.NewName)"
                }
            }
            Write-LabArtifactJsonAtomic -Path $planPath -InputObject $plan
        }
        Write-LabArtifactJsonAtomic -Path $connectionPath -InputObject $connection
        $renamed = Rename-LabRunDisplayName -RunId $RunId -DisplayName $DisplayName -StateRoot $StateRoot
    }
    catch {
        for ($index = @($renames).Count - 1; $index -ge 0; $index--) {
            $rename = @($renames)[$index]
            try { & $rename.Provider rename $rename.ContainerId $rename.OldName 1>$null 2>$null } catch { }
        }
        if ($originalPlanJson) { Set-Content -LiteralPath $planPath -Value $originalPlanJson -Encoding utf8 }
        Set-Content -LiteralPath $connectionPath -Value $originalConnectionJson -Encoding utf8
        throw
    }

    return [PSCustomObject]@{
        RunId = $renamed.RunId; PreviousName = $renamed.PreviousName; Name = $renamed.Name; Changed = $renamed.Changed
        RuntimeRenamed = @($renames).Count -gt 0; RuntimeObjects = @($renames)
    }
}

function Get-LabActiveRuns {
    [CmdletBinding()]
    param(
        [string]$StateRoot
    )

    if (-not $StateRoot) {
        $StateRoot = Get-LabStateRoot
    }

    $runsDirectory = Join-Path $StateRoot 'runs'
    if (-not (Test-Path -LiteralPath $runsDirectory -PathType Container)) {
        return @()
    }

    $runs = @()
    foreach ($directory in Get-ChildItem -LiteralPath $runsDirectory -Directory) {
        $statePath = Join-Path $directory.FullName 'run-state.json'
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            continue
        }

        try {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
            if ($state.state -notin @('REMOVED', 'CLEANED_UP')) {
                $runs += $state
            }
        }
        catch {
            Write-LabWarning "Run-State konnte nicht gelesen werden: $statePath - $($_.Exception.Message)"
        }
    }

    return $runs
}

function Get-LabRunRuntimeStatus {
    <#
    .SYNOPSIS
        Liest den aktuellen Zustand der Runtime, ohne den Workflow-State zu ändern.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $connectionPath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') ([string]$Run.runId)) 'connection-info.json'
    if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) {
        return [PSCustomObject]@{ State = 'UNKNOWN'; Source = 'connection-info fehlt'; Instances = @() }
    }

    try { $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 }
    catch { return [PSCustomObject]@{ State = 'UNAVAILABLE'; Source = 'connection-info ungültig'; Instances = @() } }

    $instances = @()
    foreach ($instance in @($connection.instances)) {
        try {
            $provider = [string]$instance.provider
            $status = switch ($provider) {
                'hyperv' {
                    # Resolve über die VM-Notes repariert bei Bedarf alte
                    # connection-info-Namen vor der Live-Abfrage.
                    $hyperVLab = Get-HyperVLabWorkflowRun -RunId ([string]$Run.runId) -StateRoot $StateRoot
                    Get-HyperVInstanceStatus -VMName ([string]$hyperVLab.Instance.vmName) -ExpectedRunId ([string]$Run.runId) -ExpectedScopeId ([string]$Run.scopeId)
                }
                'docker' { Get-DockerInstanceStatus -ContainerIdOrName ([string]$instance.containerId) }
                'podman' { Get-PodmanInstanceStatus -ContainerIdOrName ([string]$instance.containerId) }
                default { $null }
            }
            if (-not $status) { throw "Unbekannter Provider: $provider" }
            $liveState = if ($provider -eq 'hyperv') {
                if (-not $status.Exists) { 'MISSING' } elseif ([string]$status.State -eq 'Running') { 'RUNNING' } elseif ([string]$status.State -eq 'Off') { 'STOPPED' } else { ([string]$status.State).ToUpperInvariant() }
            }
            elseif (-not $status.Exists) { 'MISSING' }
            elseif ($status.Running) { 'RUNNING' }
            else { 'STOPPED' }
            $instances += [PSCustomObject]@{ Id = [string]$instance.id; Provider = $provider; State = $liveState }
        }
        catch {
            $instances += [PSCustomObject]@{ Id = [string]$instance.id; Provider = [string]$instance.provider; State = 'UNAVAILABLE' }
        }
    }

    $states = @($instances.State)
    $runningCount = @($states | Where-Object { $_ -eq 'RUNNING' }).Count
    $stoppedCount = @($states | Where-Object { $_ -eq 'STOPPED' }).Count
    $state = if ($states.Count -eq 0) { 'UNKNOWN' }
    elseif ($states -contains 'UNAVAILABLE') { 'UNAVAILABLE' }
    elseif ($states -contains 'MISSING') { 'MISSING' }
    elseif ($runningCount -eq $states.Count) { 'RUNNING' }
    elseif ($stoppedCount -eq $states.Count) { 'STOPPED' }
    else { 'PARTIAL' }
    return [PSCustomObject]@{ State = $state; Source = 'Runtime'; Instances = $instances }
}

function Sync-LabRunRuntimeState {
    <#
    .SYNOPSIS
        Gleicht den sichtbaren RUNNING-/STOPPED-Status mit der echten Runtime ab.
    .DESCRIPTION
        Der Workflow-State ist für Recovery und Audit nötig, darf jedoch nach
        einem manuellen Start/Stopp in Hyper-V, Docker oder Podman nicht die
        Benutzeraktionen blockieren. Nur eindeutige, vollständige Runtime-
        Zustände werden zurück in den State geschrieben; MISSING, PARTIAL und
        UNAVAILABLE bleiben absichtlich Diagnosezustände ohne Mutation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $runtime = Get-LabRunRuntimeStatus -Run $Run -StateRoot $StateRoot
    $targetState = [string]$runtime.State
    $currentState = [string]$Run.state
    $synchronized = $false

    if ($targetState -in @('RUNNING', 'STOPPED') -and $currentState -in @('RUNNING', 'STOPPED') -and $currentState -ne $targetState) {
        $null = Set-LabRunState -RunId ([string]$Run.runId) -NewState $targetState -Reason "Runtime-Abgleich: $targetState" -StateRoot $StateRoot
        foreach ($providerSubRun in @(Get-LabProviderSubRuns -RunId ([string]$Run.runId) -StateRoot $StateRoot)) {
            if ([string]$providerSubRun.state -in @('RUNNING', 'STOPPED') -and [string]$providerSubRun.state -ne $targetState) {
                Set-LabProviderSubRunState -RunId ([string]$Run.runId) -Provider ([string]$providerSubRun.provider) -NewState $targetState -Reason "Runtime-Abgleich: $targetState" -StateRoot $StateRoot
            }
        }
        $synchronized = $true
    }

    return [PSCustomObject]@{
        Run          = Get-LabRunState -RunId ([string]$Run.runId) -StateRoot $StateRoot
        Runtime      = $runtime
        Synchronized = $synchronized
    }
}

function Remove-LabRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    if (-not $StateRoot) {
        $StateRoot = Get-LabStateRoot
    }

    $state = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ($state.state -notin @('REMOVED', 'CLEANED_UP')) {
        throw "Run kann nur im Status REMOVED oder CLEANED_UP geloescht werden (aktuell: $($state.state))."
    }

    $runDirectory = Join-Path (Join-Path $StateRoot 'runs') $RunId
    $null = Remove-LabSecrets -Path $runDirectory

    $markerPath = Join-Path (Join-Path $StateRoot 'scope-markers') "$($state.scopeId).json"
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        Remove-Item -LiteralPath $markerPath -Force
    }

    if (Test-Path -LiteralPath $runDirectory -PathType Container) {
        Remove-Item -LiteralPath $runDirectory -Recurse -Force
    }
}

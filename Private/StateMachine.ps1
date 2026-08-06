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
        (Join-Path $StateRoot 'scope-markers')
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
    $history = if ($current.metadata.PSObject.Properties['nameHistory']) { @($current.metadata.nameHistory) } else { @() }
    $current.metadata | Add-Member -NotePropertyName nameHistory -NotePropertyValue @($history + [PSCustomObject]@{
        previousName = $previousName; name = $DisplayName; changedAt = Get-LabTimestamp
    }) -Force
    $current.updatedAt = Get-LabTimestamp
    $current | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $statePath -Encoding utf8
    return [PSCustomObject]@{ RunId = $RunId; PreviousName = $previousName; Name = $DisplayName; Changed = $true }
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

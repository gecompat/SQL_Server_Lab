<#
.SYNOPSIS
    State-Management fuer SQL_Server_Lab.
.DESCRIPTION
    Verwaltet Run-State, State-Transitions und lokale Persistenz.
    State-Verzeichnis liegt AUSSERHALB des Git-Checkouts.
#>

# =============================================================================
# State-Root ermitteln
# =============================================================================

function Get-LabStateRoot {
    <#
    .SYNOPSIS Ermittelt das State-Verzeichnis (Auto-Discovery).
    .OUTPUTS String-Pfad zum State-Root.
    #>
    [CmdletBinding()]
    param([string]$ExplicitPath)

    if ($ExplicitPath) { return $ExplicitPath }
    if ($env:SQL_SERVER_LAB_STATE) { return $env:SQL_SERVER_LAB_STATE }

    if ($IsWindows) {
        return Join-Path $env:LOCALAPPDATA 'SqlServerLab'
    }
    else {
        return Join-Path (Resolve-Path '~') '.sql-server-lab'
    }
}

function Initialize-LabStateRoot {
    <#
    .SYNOPSIS Erstellt das State-Verzeichnis falls nicht vorhanden.
    #>
    [CmdletBinding()]
    param([string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }

    $dirs = @(
        $StateRoot,
        (Join-Path $StateRoot 'runs'),
        (Join-Path $StateRoot 'scope-markers')
    )

    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
    }

    # config.json anlegen falls nicht vorhanden
    $configFile = Join-Path $StateRoot 'config.json'
    if (-not (Test-Path $configFile)) {
        @{
            version      = '0.1.0'
            createdAt    = Get-LabTimestamp
            defaultProfile = 'standard'
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $configFile -Encoding utf8
    }

    return $StateRoot
}

# =============================================================================
# Run-State CRUD
# =============================================================================

function New-LabRunState {
    <#
    .SYNOPSIS Erzeugt einen neuen Run-State (INITIALIZING).
    .OUTPUTS PSCustomObject mit RunId, ScopeId, State, Pfaden.
    #>
    [CmdletBinding()]
    param(
        [string]$StateRoot,
        [string]$ScopeId,
        [hashtable]$Metadata = @{}
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    Initialize-LabStateRoot -StateRoot $StateRoot | Out-Null

    $runId = New-LabGuid
    if (-not $ScopeId) { $ScopeId = New-LabGuid }

    $runDir = Join-Path $StateRoot 'runs' $runId
    New-Item -Path $runDir -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $runDir 'log') -ItemType Directory -Force | Out-Null

    $state = [PSCustomObject]@{
        runId       = $runId
        scopeId     = $ScopeId
        state       = 'INITIALIZING'
        stateHistory = @(
            @{ state = 'INITIALIZING'; timestamp = Get-LabTimestamp; reason = 'Run erstellt' }
        )
        createdAt   = Get-LabTimestamp
        updatedAt   = Get-LabTimestamp
        instances   = @()
        metadata    = $Metadata
        errors      = @()
    }

    $statePath = Join-Path $runDir 'run-state.json'
    $state | ConvertTo-Json -Depth 10 | Set-Content -Path $statePath -Encoding utf8

    # Scope-Marker registrieren
    $markerPath = Join-Path $StateRoot 'scope-markers' "$ScopeId.json"
    @{
        scopeId   = $ScopeId
        runId     = $runId
        createdAt = Get-LabTimestamp
        owner     = $env:USERNAME ?? $env:USER ?? 'unknown'
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $markerPath -Encoding utf8

    return [PSCustomObject]@{
        RunId    = $runId
        ScopeId  = $ScopeId
        State    = 'INITIALIZING'
        RunDir   = $runDir
        StateRoot = $StateRoot
    }
}

function Get-LabRunState {
    <#
    .SYNOPSIS Liest den aktuellen Run-State.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $statePath = Join-Path $StateRoot 'runs' $RunId 'run-state.json'

    if (-not (Test-Path $statePath)) {
        throw "Run-State nicht gefunden: $RunId"
    }

    Get-Content $statePath -Raw | ConvertFrom-Json -Depth 10
}

function Set-LabRunState {
    <#
    .SYNOPSIS Setzt den Run-State auf einen neuen Wert (mit Transition-Log).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]
        [ValidateSet(
            'INITIALIZING','PROVISIONING','SQL_READY','DATABASES_CREATED',
            'POST_PROVISIONED','RUNNING','STOPPED','REMOVED',
            'PROVISION_FAILED','CLEANUP_PENDING','CLEANUP_RUNNING','CLEANED_UP'
        )]
        [string]$NewState,
        [string]$Reason = '',
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $statePath = Join-Path $StateRoot 'runs' $RunId 'run-state.json'

    $current = Get-Content $statePath -Raw | ConvertFrom-Json -Depth 10

    # Transition-Validierung
    $validTransitions = @{
        'INITIALIZING'      = @('PROVISIONING', 'PROVISION_FAILED', 'CLEANUP_PENDING')
        'PROVISIONING'      = @('SQL_READY', 'PROVISION_FAILED', 'CLEANUP_PENDING')
        'SQL_READY'         = @('DATABASES_CREATED', 'PROVISION_FAILED', 'CLEANUP_PENDING')
        'DATABASES_CREATED' = @('POST_PROVISIONED', 'RUNNING', 'PROVISION_FAILED', 'CLEANUP_PENDING')
        'POST_PROVISIONED'  = @('RUNNING', 'PROVISION_FAILED', 'CLEANUP_PENDING')
        'RUNNING'           = @('STOPPED', 'CLEANUP_PENDING', 'REMOVED')
        'STOPPED'           = @('RUNNING', 'CLEANUP_PENDING', 'REMOVED')
        'PROVISION_FAILED'  = @('CLEANUP_PENDING')
        'CLEANUP_PENDING'   = @('CLEANUP_RUNNING')
        'CLEANUP_RUNNING'   = @('CLEANED_UP', 'REMOVED')
        'CLEANED_UP'        = @('REMOVED')
    }

    $allowed = $validTransitions[$current.state]
    if ($allowed -and $NewState -notin $allowed) {
        throw "Ungueltiger State-Uebergang: $($current.state) -> $NewState. Erlaubt: $($allowed -join ', ')"
    }

    $current.state = $NewState
    $current.updatedAt = Get-LabTimestamp
    $current.stateHistory += @{
        state     = $NewState
        timestamp = Get-LabTimestamp
        reason    = $Reason
    }

    $current | ConvertTo-Json -Depth 10 | Set-Content -Path $statePath -Encoding utf8
}

function Add-LabRunError {
    <#
    .SYNOPSIS Fuegt einen Fehler zum Run-State hinzu.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Message,
        [string]$Component = '',
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $statePath = Join-Path $StateRoot 'runs' $RunId 'run-state.json'
    $current = Get-Content $statePath -Raw | ConvertFrom-Json -Depth 10

    $current.errors += @{
        timestamp = Get-LabTimestamp
        message   = $Message
        component = $Component
    }
    $current.updatedAt = Get-LabTimestamp

    $current | ConvertTo-Json -Depth 10 | Set-Content -Path $statePath -Encoding utf8
}

# =============================================================================
# Run-Abfrage
# =============================================================================

function Get-LabActiveRuns {
    <#
    .SYNOPSIS Listet alle aktiven (nicht entfernten) Runs.
    #>
    [CmdletBinding()]
    param([string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $runsDir = Join-Path $StateRoot 'runs'

    if (-not (Test-Path $runsDir)) { return @() }

    $runs = @()
    Get-ChildItem -Path $runsDir -Directory | ForEach-Object {
        $stateFile = Join-Path $_.FullName 'run-state.json'
        if (Test-Path $stateFile) {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json -Depth 10
            if ($state.state -notin @('REMOVED', 'CLEANED_UP')) {
                $runs += $state
            }
        }
    }

    return $runs
}

function Remove-LabRunState {
    <#
    .SYNOPSIS Entfernt einen Run-State komplett (nach REMOVED/CLEANED_UP).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }

    $state = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    if ($state.state -notin @('REMOVED', 'CLEANED_UP')) {
        throw "Run kann nur im Status REMOVED oder CLEANED_UP geloescht werden (aktuell: $($state.state))"
    }

    # Secrets sicher loeschen
    $runDir = Join-Path $StateRoot 'runs' $RunId
    Remove-LabSecrets -Path $runDir

    # Scope-Marker entfernen
    $markerPath = Join-Path $StateRoot 'scope-markers' "$($state.scopeId).json"
    if (Test-Path $markerPath) { Remove-Item $markerPath -Force }

    # Run-Verzeichnis entfernen
    Remove-Item $runDir -Recurse -Force
}

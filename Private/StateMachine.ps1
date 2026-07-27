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
        [hashtable]$Metadata = @{}
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

    $validTransitions = @{
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
        CLEANED_UP        = @('REMOVED')
        RECOVERY_REQUIRED = @('CLEANUP_PENDING', 'REMOVED')
    }

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

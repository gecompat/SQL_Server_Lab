<#
.SYNOPSIS
    Erstellt und normalisiert den gemeinsamen Ergebnisvertrag mutierender Aktionen.
.DESCRIPTION
    Der Vertrag trennt eine tatsaechliche Mutation von No-op, Abbruch und Fehler.
    Nur ein geaenderter Endpunkt-, Runtime- oder Anzeigenamensstand darf danach
    die Verbindungszentrale und einen eingerichteten CMS synchronisieren.
#>

function New-LabActionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)]
        [ValidateSet('Changed', 'NoChange', 'Cancelled', 'Failed')]
        [string]$Status,
        [string[]]$RunIds = @(),
        [object[]]$Mutations = @(),
        [ValidateSet('None', 'RuntimeState', 'EndpointSet', 'DisplayMetadata')]
        [string]$ConnectionCenterImpact = 'None',
        [string]$ErrorCode
    )

    if ($Status -ne 'Changed') {
        $ConnectionCenterImpact = 'None'
        $Mutations = @()
    }

    [PSCustomObject]@{
        SchemaVersion = 'SqlServerLab.ActionResult/1.0'
        Status = $Status
        Action = $Action
        RunIds = @($RunIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        Mutations = @($Mutations)
        ConnectionCenterImpact = $ConnectionCenterImpact
        ErrorCode = if ([string]::IsNullOrWhiteSpace($ErrorCode)) { $null } else { $ErrorCode }
    }
}

function Get-LabActionConnectionCenterImpact {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Action)

    switch ($Action) {
        'New' { 'EndpointSet' }
        'AutomatedTestEnvironment' { 'EndpointSet' }
        'ClearAutomatedTestEnvironment' { 'EndpointSet' }
        'Start' { 'RuntimeState' }
        'Stop' { 'RuntimeState' }
        'Restart' { 'RuntimeState' }
        'Remove' { 'EndpointSet' }
        'Clear' { 'EndpointSet' }
        'Rename' { 'DisplayMetadata' }
        'UpdateContainer' { 'EndpointSet' }
        # Manage muss den Impact der konkret gewaehlten Unteraktion liefern.
        # Ein pauschaler Impact wuerde Ressourcen- und Diagnoseaktionen syncen.
        'Manage' { 'None' }
        default { 'None' }
    }
}

function ConvertTo-LabActionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [AllowNull()][object[]]$InputObject,
        [AllowNull()][string]$BeforeFingerprint,
        [AllowNull()][string]$AfterFingerprint,
        [string]$ErrorCode
    )

    $items = @($InputObject | Where-Object { $null -ne $_ })
    $existing = @($items | Where-Object { [string]$_.SchemaVersion -eq 'SqlServerLab.ActionResult/1.0' } | Select-Object -Last 1)
    if ($existing.Count -gt 0) { return $existing[0] }

    $runIds = @($items | ForEach-Object {
        if ($_.PSObject.Properties['RunIds']) { @($_.RunIds) }
        if ($_.PSObject.Properties['RunId']) { [string]$_.RunId }
    })
    $signals = @($items | ForEach-Object {
        foreach ($propertyName in @('Action', 'Status', 'Cleanup')) {
            if ($_.PSObject.Properties[$propertyName]) { [string]$_.$propertyName }
        }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $normalizedSignals = @($signals | ForEach-Object { $_.ToUpperInvariant() })

    $status = if ($ErrorCode -or @($normalizedSignals | Where-Object { $_ -match 'FAILED|RECOVERY_REQUIRED|WITH_ERRORS' }).Count -gt 0) {
        'Failed'
    }
    elseif (@($normalizedSignals | Where-Object { $_ -match 'CANCELLED|DECLINED|ABORTED' }).Count -gt 0) {
        'Cancelled'
    }
    elseif ($null -ne $BeforeFingerprint -and $null -ne $AfterFingerprint -and $BeforeFingerprint -ne $AfterFingerprint) {
        'Changed'
    }
    elseif (@($normalizedSignals | Where-Object { $_ -match 'STARTED|STOPPED|RUNNING|REMOVED|CREATED|SUCCEEDED|RENAMED|UPDATED' }).Count -gt 0 -and
        @($normalizedSignals | Where-Object { $_ -match 'SKIPPED|NOT_FOUND|ALREADY|NOT_REQUIRED' }).Count -eq 0) {
        'Changed'
    }
    else {
        'NoChange'
    }

    $impact = if ($status -eq 'Changed') { Get-LabActionConnectionCenterImpact -Action $Action } else { 'None' }
    $mutations = if ($status -eq 'Changed') {
        @([PSCustomObject]@{ Kind = $Action; Result = if ($signals.Count -gt 0) { $signals[-1] } else { 'CHANGED' } })
    }
    else { @() }

    return New-LabActionResult -Action $Action -Status $status -RunIds $runIds -Mutations $mutations `
        -ConnectionCenterImpact $impact -ErrorCode $ErrorCode
}

function Test-LabActionResultRequiresConnectionCenterSync {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ActionResult)

    return [string]$ActionResult.SchemaVersion -eq 'SqlServerLab.ActionResult/1.0' -and
        [string]$ActionResult.Status -eq 'Changed' -and
        [string]$ActionResult.ConnectionCenterImpact -ne 'None'
}

function Invoke-LabActionResultSynchronization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ActionResult,
        [Parameter(Mandatory)][scriptblock]$SynchronizationAction
    )

    if (-not (Test-LabActionResultRequiresConnectionCenterSync -ActionResult $ActionResult)) {
        return $false
    }
    & $SynchronizationAction
    return $true
}

<#
.SYNOPSIS
    Read-only Vertragskern fuer Lifecycle-Reconcile-Plaene.
.DESCRIPTION
    Der erste Vertragsstand liest bestehende Runs abwaertskompatibel und bildet
    daraus einen serialisierbaren Desired-, Actual-, Diff- und Action-Plan.
    Er fuehrt bewusst keine Lifecycle-Aktion aus und gibt keine Secrets,
    Hostwerte oder Runtime-Identitaeten aus.
#>

function New-LabDesiredState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][ValidateSet('RUNNING', 'STOPPED')][string]$TargetState,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $persisted = Get-LabPersistedDesiredState -RunId ([string]$Run.runId) -StateRoot $StateRoot
    if ($persisted.Status -eq 'VALID') {
        $snapshot = $persisted.Snapshot
        return [PSCustomObject]@{
            Contract = [PSCustomObject]@{ Name = 'SqlServerLab.DesiredState'; Version = '1.0' }
            RunId = [string]$Run.runId
            TargetState = $TargetState
            Source = 'persisted-desired-state'
            IsValid = $true
            ValidationError = $null
            Instances = @($snapshot.Instances | ForEach-Object { [PSCustomObject]@{ Id = [string]$_.Id; Provider = [string]$_.Provider; TargetState = $TargetState } })
        }
    }
    if ($persisted.Status -eq 'INVALID') {
        return [PSCustomObject]@{
            Contract = [PSCustomObject]@{ Name = 'SqlServerLab.DesiredState'; Version = '1.0' }
            RunId = [string]$Run.runId
            TargetState = $TargetState
            Source = 'persisted-desired-state-invalid'
            IsValid = $false
            ValidationError = [string]$persisted.Reason
            Instances = @()
        }
    }
    $instances = @()
    $connectionPath = Join-Path (Join-Path (Join-Path $StateRoot 'runs') ([string]$Run.runId)) 'connection-info.json'
    if (Test-Path -LiteralPath $connectionPath -PathType Leaf) {
        try {
            $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
            $instances = @($connection.instances | ForEach-Object {
                [PSCustomObject]@{ Id = [string]$_.id; Provider = [string]$_.provider; TargetState = $TargetState }
            })
        }
        catch { }
    }

    if ($instances.Count -eq 0 -and $Run.PSObject.Properties['providerSubRuns']) {
        $instances = @($Run.providerSubRuns | ForEach-Object {
            $provider = [string]$_.provider
            @($_.instanceIds | ForEach-Object {
                [PSCustomObject]@{ Id = [string]$_; Provider = $provider; TargetState = $TargetState }
            })
        })
    }

    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.DesiredState'; Version = '1.0' }
        RunId = [string]$Run.runId
        TargetState = $TargetState
        Source = 'connection-info-or-provider-subruns'
        IsValid = $true
        ValidationError = $null
        Instances = $instances
    }
}

function Get-LabActualState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Run,
        [string]$StateRoot
    )

    $runtime = Get-LabRunRuntimeStatus -Run $Run -StateRoot $StateRoot
    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.ActualState'; Version = '1.0' }
        RunId = [string]$Run.runId
        State = [string]$runtime.State
        Source = [string]$runtime.Source
        Instances = @($runtime.Instances | ForEach-Object {
            [PSCustomObject]@{ Id = [string]$_.Id; Provider = [string]$_.Provider; State = [string]$_.State }
        })
    }
}

function Compare-LabDesiredActualState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Desired,
        [Parameter(Mandatory)]$Actual
    )

    $diagnosticStates = @('UNKNOWN', 'UNAVAILABLE', 'MISSING', 'PARTIAL')
    if ($Desired.PSObject.Properties.Name -contains 'IsValid' -and -not [bool]$Desired.IsValid) {
        return [PSCustomObject]@{
            ChangeClass = 'unsupported'
            Reasons = @("Persisted desired state ist ungültig: $($Desired.ValidationError)")
            Actions = @()
            Warnings = @("Bitte Snapshot reparieren oder entfernen; fail-closed ohne Teilmutation bis zum Zielzustand.")
        }
    }
    if ($Actual.State -in $diagnosticStates) {
        return [PSCustomObject]@{
            ChangeClass = 'unsupported'
            Reasons = @("Actual State '$($Actual.State)' ist nicht vollstaendig steuerbar.")
            Actions = @()
            Warnings = @('Keine Teilmutation planen; zuerst Runtime oder Recovery diagnostizieren.')
        }
    }

    if ($Actual.State -eq $Desired.TargetState) {
        return [PSCustomObject]@{
            ChangeClass = 'no-op'; Reasons = @('Desired State und Actual State stimmen ueberein.')
            Actions = @(); Warnings = @()
        }
    }

    $operation = if ($Desired.TargetState -eq 'RUNNING') { 'Start' } else { 'Stop' }
    $providers = @($Desired.Instances | ForEach-Object Provider | Where-Object { $_ } | Sort-Object -Unique)
    return [PSCustomObject]@{
        ChangeClass = 'restart'
        Reasons = @("Actual State '$($Actual.State)' weicht vom Target '$($Desired.TargetState)' ab.")
        Actions = @($providers | ForEach-Object {
            [PSCustomObject]@{ Operation = $operation; Provider = [string]$_; TargetState = $Desired.TargetState }
        })
        Warnings = @('Die Aktionen sind nur ein Vorschlag; die Ausfuehrung erfolgt explizit ueber Invoke-SqlServerLabReconcileAction.')
    }
}

function New-LabReconcilePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('RUNNING', 'STOPPED')][string]$TargetState,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $desired = New-LabDesiredState -Run $run -TargetState $TargetState -StateRoot $StateRoot
    $actual = Get-LabActualState -Run $run -StateRoot $StateRoot
    $comparison = Compare-LabDesiredActualState -Desired $desired -Actual $actual
    $migrationGuard = Get-LabHyperVResourceMigrationLifecycleGuard -RunId $RunId -StateRoot $StateRoot
    if (-not $migrationGuard.Allowed) {
        $comparison = [PSCustomObject]@{
            ChangeClass = 'unsupported'
            Reasons = @("Hyper-V-Ressourcenmigration blockiert Lifecycle-Reconcile: $([string]$migrationGuard.ReasonCode)")
            Actions = @()
            Warnings = @([string]$migrationGuard.Reason)
        }
    }

    return [PSCustomObject]@{
        Contract = [PSCustomObject]@{ Name = 'SqlServerLab.ReconcilePlan'; Version = '1.0' }
        RunId = [string]$run.runId
        Desired = $desired
        Actual = $actual
        Diff = @([PSCustomObject]@{
            TargetState = $desired.TargetState; ActualState = $actual.State; ChangeClass = $comparison.ChangeClass; Reasons = $comparison.Reasons
        })
        Actions = $comparison.Actions
        HighestChangeClass = $comparison.ChangeClass
        IsNoOp = $comparison.ChangeClass -eq 'no-op'
        MutationAllowed = $false
        Warnings = $comparison.Warnings
        HyperVResourceMigration = $migrationGuard
    }
}

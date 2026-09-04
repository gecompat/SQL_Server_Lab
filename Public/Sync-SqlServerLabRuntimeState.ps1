function Sync-SqlServerLabRuntimeState {
    <#
    .SYNOPSIS
        Gleicht SQL_Server_Lab-Runs mit Docker, Podman und Hyper-V ab.
    .DESCRIPTION
        Liest den echten Runtimezustand aller oder eines ausgewählten Runs.
        Eindeutige Start-/Stopp-Abweichungen werden wie bisher synchronisiert.
        Fehlt eine gebundene VM oder ein gebundener Container, wird der Run
        fail-closed als RECOVERY_REQUIRED markiert. Runtime-Ressourcen, Storage
        und Run-Verzeichnisse werden weder gelöscht noch neu erstellt.

        PARTIAL, UNAVAILABLE und UNKNOWN bleiben reine Diagnosezustände, weil
        daraus keine sichere Mutation abgeleitet werden kann.
    .PARAMETER RunId
        Optionale Run-ID. Ohne Angabe werden alle aktiven Runs geprüft.
    .PARAMETER StateRoot
        Optionaler abweichender State Root.
    .OUTPUTS
        PSCustomObject je Run mit beobachtetem und gespeichertem Zustand.
    .EXAMPLE
        Sync-SqlServerLabRuntimeState
    .EXAMPLE
        Sync-SqlServerLabRuntimeState -RunId 01234567-89ab-cdef-0123-456789abcdef -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [string]$RunId,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $runs = if ($RunId) { @(Get-LabRunState -RunId $RunId -StateRoot $StateRoot) }
        else { @(Get-LabActiveRuns -StateRoot $StateRoot) }
    foreach ($run in $runs) {
        $runtime = Get-LabRunRuntimeStatus -Run $run -StateRoot $StateRoot
        $previousState = [string]$run.state
        $changed = $false
        $action = 'NO_CHANGE'
        if ([string]$runtime.State -in @('RUNNING','STOPPED')) {
            if ($PSCmdlet.ShouldProcess([string]$run.runId, "Run-State mit Runtimezustand $($runtime.State) abgleichen")) {
                $sync = Sync-LabRunRuntimeState -Run $run -StateRoot $StateRoot
                $run = $sync.Run
                $changed = [bool]$sync.Synchronized
                if ($changed) { $action = 'STATE_SYNCHRONIZED' }
            }
        }
        elseif ([string]$runtime.State -eq 'MISSING') {
            $action = if ($previousState -eq 'RECOVERY_REQUIRED') { 'ALREADY_RECOVERY_REQUIRED' } else { 'RECOVERY_REQUIRED' }
            if ($previousState -in @('RUNNING','STOPPED') -and
                $PSCmdlet.ShouldProcess([string]$run.runId, 'Fehlende Runtime als RECOVERY_REQUIRED markieren')) {
                foreach ($provider in @($runtime.Instances | Where-Object State -eq 'MISSING' |
                    ForEach-Object { [string]$_.Provider } | Sort-Object -Unique)) {
                    $subRun = @(Get-LabProviderSubRuns -RunId ([string]$run.runId) -StateRoot $StateRoot |
                        Where-Object { [string]$_.provider -eq $provider } | Select-Object -First 1)[0]
                    if ($subRun -and [string]$subRun.state -in @('RUNNING','STOPPED')) {
                        Set-LabProviderSubRunState -RunId ([string]$run.runId) -Provider $provider `
                            -NewState RECOVERY_REQUIRED -Reason 'Runtime-Abgleich: gebundene Ressource fehlt.' -StateRoot $StateRoot
                    }
                }
                $run = Get-LabRunState -RunId ([string]$run.runId) -StateRoot $StateRoot
                if ([string]$run.state -in @('RUNNING','STOPPED')) {
                    $null = Set-LabRunState -RunId ([string]$run.runId) -NewState RECOVERY_REQUIRED `
                        -Reason 'Runtime-Abgleich: mindestens eine gebundene VM oder ein Container fehlt.' -StateRoot $StateRoot
                }
                Add-LabRunError -RunId ([string]$run.runId) -Component 'runtime-sync' `
                    -Message 'Gebundene Runtime-Ressource fehlt; automatische Neuerstellung und Löschung wurden nicht ausgeführt.' -StateRoot $StateRoot
                $run = Get-LabRunState -RunId ([string]$run.runId) -StateRoot $StateRoot
                $changed = $true
            }
        }
        else { $action = 'DIAGNOSTIC_ONLY' }

        [PSCustomObject]@{
            ContractVersion = 'SqlServerLab.RuntimeStateSyncResult/1.0'
            RunId = [string]$run.runId
            PreviousState = $previousState
            RuntimeState = [string]$runtime.State
            State = [string]$run.state
            Action = $action
            Changed = $changed
            Instances = @($runtime.Instances)
        }
    }
}

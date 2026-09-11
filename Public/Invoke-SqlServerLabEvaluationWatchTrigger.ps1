<#
.SYNOPSIS
    Führt den Evaluation-Watch in einem begrenzten lokalen Zeitintervall aus.
.DESCRIPTION
    Ruft den vorhandenen Evaluation-Watch in diesem PowerShell-Prozess sofort
    und anschließend höchstens bis zur angegebenen Anzahl von Prüfungen auf.
    Der Trigger registriert keine Windows-Aufgabe, startet keine Runtime und
    führt keinen Netzwerk- oder Gastzugriff aus. Mit -RecordEvents nutzt er
    ausschließlich die vorhandene lokale, idempotente Ereignisdeduplizierung.
.PARAMETER IntervalSeconds
    Wartezeit zwischen zwei Prüfungen in Sekunden.
.PARAMETER MaximumChecks
    Harte Obergrenze für die Anzahl der Watch-Prüfungen.
.PARAMETER WarningDaysRemaining
    Restlaufzeit in Tagen, ab der eine Evaluation als Warnung erscheint.
.PARAMETER CriticalDaysRemaining
    Restlaufzeit in Tagen, ab der eine Evaluation kritisch erscheint.
.PARAMETER RecordEvents
    Erfasst neue fällige Ereignisse über den bestehenden lokalen Watch-State.
    Ohne diesen Schalter bleiben alle Prüfungen read-only.
.PARAMETER StateRoot
    Optionaler lokaler State-Root für den bestehenden Evaluation-Watch.
.OUTPUTS
    SqlServerLab.EvaluationWatchTrigger/1.0 ohne lokale Pfade, Secrets,
    Lizenzschlüssel, Runtime- oder Netzwerkdaten.
.EXAMPLE
    Invoke-SqlServerLabEvaluationWatchTrigger -IntervalSeconds 3600 -MaximumChecks 24 -RecordEvents
#>
function Invoke-SqlServerLabEvaluationWatchTrigger {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 86400)][int]$IntervalSeconds,
        [ValidateRange(1, 1440)][int]$MaximumChecks,
        [ValidateRange(1, 3650)][int]$WarningDaysRemaining = 30,
        [ValidateRange(0, 3650)][int]$CriticalDaysRemaining = 7,
        [switch]$RecordEvents,
        [string]$StateRoot
    )

    if ($CriticalDaysRemaining -gt $WarningDaysRemaining) {
        throw 'EVALUATION_WATCH_TRIGGER_CRITICAL_THRESHOLD_INVALID'
    }

    $startedAt = [datetime]::UtcNow
    $checks = [System.Collections.Generic.List[object]]::new()
    for ($checkNumber = 1; $checkNumber -le $MaximumChecks; $checkNumber++) {
        $watchParameters = @{
            WarningDaysRemaining = $WarningDaysRemaining
            CriticalDaysRemaining = $CriticalDaysRemaining
        }
        if ($StateRoot) { $watchParameters.StateRoot = $StateRoot }
        if ($RecordEvents) { $watchParameters.RecordEvents = $true }

        $watch = Get-SqlServerLabEvaluationWatch @watchParameters
        $checks.Add([PSCustomObject]@{
            CheckNumber = $checkNumber
            TriggeredAt = [datetime]::UtcNow.ToString('o')
            DueEventCount = [int]$watch.DueEventCount
            NewEventCount = [int]$watch.NewEventCount
            NewEvents = @($watch.NewEvents)
        })

        if ($checkNumber -lt $MaximumChecks) {
            Start-Sleep -Seconds $IntervalSeconds
        }
    }

    [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.EvaluationWatchTrigger/1.0'
        StartedAt = $startedAt.ToString('o')
        CompletedAt = [datetime]::UtcNow.ToString('o')
        IntervalSeconds = $IntervalSeconds
        MaximumChecks = $MaximumChecks
        CheckCount = $checks.Count
        WaitCount = [Math]::Max(0, $checks.Count - 1)
        RecordEvents = [bool]$RecordEvents
        TotalDueEventCount = [int](@($checks | Measure-Object -Property DueEventCount -Sum).Sum)
        TotalNewEventCount = [int](@($checks | Measure-Object -Property NewEventCount -Sum).Sum)
        Checks = @($checks)
    }
}

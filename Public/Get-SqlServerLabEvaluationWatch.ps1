<#
.SYNOPSIS
    Prüft registrierte Windows- und SQL-Server-Evaluationsfristen read-only.
.DESCRIPTION
    Liest die pfadfreie Hyper-V-Image-Inventur sowie registrierte, im
    Workflow-State als RUNNING geführte Hyper-V-Instanzen. Für solche Instanzen
    wird ausschließlich eine bereits persistierte Windows-Aktivierungsevidenz
    ausgewertet; es findet weder eine Runtime-Abfrage noch ein Gastzugriff
    statt. Für fällige Evaluationen erzeugt die Ausgabe stabile, sanitisierte
    Ereignisse. Mit -RecordEvents werden bislang unbekannte Ereignisse
    idempotent im lokalen State erfasst; Images, Lizenzen und Runs bleiben
    unverändert.
.PARAMETER WarningDaysRemaining
    Restlaufzeit in Tagen, ab der eine Evaluation als Warnung erscheint.
.PARAMETER CriticalDaysRemaining
    Restlaufzeit in Tagen, ab der eine Evaluation kritisch erscheint.
.PARAMETER RecordEvents
    Erfasst neue fällige Ereignisse im lokalen State. Ohne diesen Schalter
    bleibt der Aufruf vollständig read-only.
.PARAMETER StateRoot
    Optionaler lokaler State-Root.
.OUTPUTS
    SqlServerLab.EvaluationWatch/1.1 mit stabilen IDs, Artefakt- und
    Instanzfristen, Status und optional neu erfassten Ereignissen ohne lokale
    Pfade, Secrets oder Lizenzschlüssel.
.EXAMPLE
    Get-SqlServerLabEvaluationWatch

.EXAMPLE
    Get-SqlServerLabEvaluationWatch -RecordEvents
#>
function Get-SqlServerLabEvaluationWatch {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateRange(1, 3650)][int]$WarningDaysRemaining = 30,
        [ValidateRange(0, 3650)][int]$CriticalDaysRemaining = 7,
        [switch]$RecordEvents,
        [string]$StateRoot
    )

    if ($CriticalDaysRemaining -gt $WarningDaysRemaining) {
        throw 'EVALUATION_WATCH_CRITICAL_THRESHOLD_INVALID'
    }
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }

    $now = [datetime]::UtcNow
    $items = [System.Collections.Generic.List[object]]::new()
    $instanceItems = [System.Collections.Generic.List[object]]::new()
    $artifactsById = @{}
    foreach ($artifact in @(Get-SqlServerLabHyperVImageArtifact -MinimumEvaluationDaysRemaining $WarningDaysRemaining -StateRoot $StateRoot)) {
        $artifactsById[[string]$artifact.ArtifactId] = $artifact
        foreach ($component in @(
            [PSCustomObject]@{ Name = 'Windows'; Evaluation = $artifact.Evaluation },
            [PSCustomObject]@{ Name = 'SqlServer'; Evaluation = $artifact.Sql.Evaluation }
        )) {
            $evaluation = $component.Evaluation
            if ([string]$evaluation.LicenseType -ne 'evaluation') { continue }

            $expiresAt = [datetime]::MinValue
            $expiryText = [string]$evaluation.ExpiresAt
            $hasValidExpiry = -not [string]::IsNullOrWhiteSpace($expiryText) -and
                [datetime]::TryParse($expiryText, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$expiresAt)
            $daysRemaining = $null
            $status = if (-not $hasValidExpiry) {
                'UNKNOWN'
            }
            else {
                $expiresAt = $expiresAt.ToUniversalTime()
                $daysRemaining = [Math]::Max(0, [int][Math]::Ceiling(($expiresAt - $now).TotalDays))
                if ($expiresAt -le $now) { 'EXPIRED' }
                elseif ($daysRemaining -le $CriticalDaysRemaining) { 'CRITICAL' }
                elseif ($daysRemaining -le $WarningDaysRemaining) { 'WARNING' }
                else { 'OK' }
            }
            $refreshAction = switch ($status) {
                'EXPIRED' { 'MANUAL_REBUILD_REQUIRED'; break }
                'CRITICAL' { 'MANUAL_REBUILD_RECOMMENDED'; break }
                'WARNING' { 'MANUAL_REBUILD_RECOMMENDED'; break }
                'UNKNOWN' { 'EVALUATION_REVIEW_REQUIRED'; break }
                default { 'NO_ACTION' }
            }
            $eventId = $null
            if ($status -ne 'OK') {
                $fingerprint = "{0}|{1}|{2}|{3}" -f $artifact.ArtifactId, $component.Name, $status, $expiryText
                $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fingerprint))).ToLowerInvariant()
                $eventId = "evaluation-$hash"
            }
            $items.Add([PSCustomObject]@{
                ArtifactId = [string]$artifact.ArtifactId
                ArtifactState = [string]$artifact.ArtifactState
                Component = [string]$component.Name
                Status = $status
                EvaluationExpiresAt = if ($hasValidExpiry) { $expiresAt.ToString('o') } else { $null }
                DaysRemaining = $daysRemaining
                RefreshAction = $refreshAction
                RefreshStatus = if ($status -eq 'OK') { 'NOT_REQUIRED' } else { 'REFRESH_BLOCKED' }
                EventId = $eventId
            })
        }
    }

    # A RUNNING workflow state is a registered-state projection, not a live VM
    # assertion. The latter can repair stale connection metadata and would
    # violate the read-only contract of this command.
    foreach ($run in @(Get-LabActiveRuns -StateRoot $StateRoot | Where-Object {
        [string]$_.state -eq 'RUNNING' -and
        [string]$_.metadata.workflowKind -eq 'hyperv-lab' -and
        -not [string]::IsNullOrWhiteSpace([string]$_.metadata.imageArtifactId)
    })) {
        $artifactId = [string]$run.metadata.imageArtifactId
        $artifact = $artifactsById[$artifactId]
        if (-not $artifact) { continue }

        $runDirectory = Join-Path (Join-Path $StateRoot 'runs') ([string]$run.runId)
        $connectionPath = Join-Path $runDirectory 'connection-info.json'
        $connectionSafety = Test-LabPathWithinRoot -Root $StateRoot -Path $connectionPath
        if (-not $connectionSafety.Valid) { continue }
        if (-not (Test-Path -LiteralPath $connectionPath -PathType Leaf)) { continue }
        try { $connection = Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 }
        catch { continue }

        foreach ($instance in @($connection.instances | Where-Object { [string]$_.provider -eq 'hyperv' })) {
            $activation = $instance.windowsActivation
            $isEvaluation = [string]$artifact.Evaluation.LicenseType -eq 'evaluation' -or
                [string]$activation.state -in @('EVALUATION_ACTIVE', 'EVALUATION_EXPIRED') -or
                [string]$activation.edition -match '(?i)eval'
            if (-not $isEvaluation) { continue }

            $expiresAt = [datetime]::MinValue
            $expiryText = [string]$activation.evaluationExpiresAt
            $hasValidExpiry = -not [string]::IsNullOrWhiteSpace($expiryText) -and
                [datetime]::TryParse($expiryText, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind, [ref]$expiresAt)
            $daysRemaining = $null
            $status = if (-not $hasValidExpiry) {
                'UNKNOWN'
            }
            else {
                $expiresAt = $expiresAt.ToUniversalTime()
                $daysRemaining = [Math]::Max(0, [int][Math]::Ceiling(($expiresAt - $now).TotalDays))
                if ($expiresAt -le $now) { 'EXPIRED' }
                elseif ($daysRemaining -le $CriticalDaysRemaining) { 'CRITICAL' }
                elseif ($daysRemaining -le $WarningDaysRemaining) { 'WARNING' }
                else { 'OK' }
            }
            $refreshAction = switch ($status) {
                'EXPIRED' { 'MANUAL_REBUILD_REQUIRED'; break }
                'CRITICAL' { 'MANUAL_REBUILD_RECOMMENDED'; break }
                'WARNING' { 'MANUAL_REBUILD_RECOMMENDED'; break }
                'UNKNOWN' { 'EVALUATION_REVIEW_REQUIRED'; break }
                default { 'NO_ACTION' }
            }
            $eventId = $null
            if ($status -ne 'OK') {
                $fingerprint = "{0}|{1}|Windows|{2}|{3}" -f $run.runId, $instance.id, $status, $expiryText
                $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fingerprint))).ToLowerInvariant()
                $eventId = "evaluation-$hash"
            }
            $instanceItems.Add([PSCustomObject]@{
                RunId = [string]$run.runId
                InstanceId = [string]$instance.id
                ArtifactId = $artifactId
                Component = 'Windows'
                RegistrationState = 'RUNNING'
                DeadlineSource = if ($hasValidExpiry) { 'PERSISTED_WINDOWS_ACTIVATION' } else { 'PERSISTED_WINDOWS_ACTIVATION_MISSING_OR_INVALID' }
                Status = $status
                EvaluationExpiresAt = if ($hasValidExpiry) { $expiresAt.ToString('o') } else { $null }
                DaysRemaining = $daysRemaining
                RefreshAction = $refreshAction
                RefreshStatus = if ($status -eq 'OK') { 'NOT_REQUIRED' } else { 'REFRESH_BLOCKED' }
                EventId = $eventId
            })
        }
    }

    $orderedItems = @($items | Sort-Object Status, Component, ArtifactId)
    $orderedInstanceItems = @($instanceItems | Sort-Object Status, RunId, InstanceId, Component)
    $dueEvents = @($orderedItems + $orderedInstanceItems | Where-Object { $_.Status -ne 'OK' })
    $newEvents = @()
    if ($RecordEvents -and $dueEvents.Count -gt 0 -and $PSCmdlet.ShouldProcess('lokaler Evaluation-Watch-State', 'Neue Fälligkeitsereignisse erfassen')) {
        $eventStatePath = Join-Path $StateRoot 'evaluation-watch-events.json'
        $newEvents = @(Invoke-LabArtifactStoreLock -StateRoot $StateRoot -ScriptBlock {
            $existingEvents = @()
            if (Test-Path -LiteralPath $eventStatePath -PathType Leaf) {
                try {
                    $state = Get-Content -LiteralPath $eventStatePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10
                    if ([string]$state.Contract -eq 'SqlServerLab.EvaluationWatchEventState/1.0') {
                        $existingEvents = @($state.Events)
                    }
                }
                catch { throw 'EVALUATION_WATCH_EVENT_STATE_INVALID' }
            }
            $knownEventIds = @($existingEvents | ForEach-Object { [string]$_.EventId })
            $new = @($dueEvents | Where-Object { [string]$_.EventId -notin $knownEventIds })
            if ($new.Count -gt 0) {
                $eventRecords = @($existingEvents) + @($new | ForEach-Object {
                    [PSCustomObject]@{
                        EventId = [string]$_.EventId; ArtifactId = [string]$_.ArtifactId
                        Component = [string]$_.Component; Status = [string]$_.Status
                        RunId = [string]$_.RunId; InstanceId = [string]$_.InstanceId
                        EvaluationExpiresAt = [string]$_.EvaluationExpiresAt; RecordedAt = $now.ToString('o')
                    }
                })
                Write-LabArtifactJsonAtomic -Path $eventStatePath -InputObject ([PSCustomObject]@{
                    Contract = 'SqlServerLab.EvaluationWatchEventState/1.0'
                    Events = $eventRecords
                })
            }
            return $new
        })
    }

    [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.EvaluationWatch/1.1'
        GeneratedAt = $now.ToString('o')
        WarningDaysRemaining = $WarningDaysRemaining
        CriticalDaysRemaining = $CriticalDaysRemaining
        Items = $orderedItems
        InstanceItems = $orderedInstanceItems
        DueEventCount = $dueEvents.Count
        NewEventCount = $newEvents.Count
        NewEvents = @($newEvents | ForEach-Object { [PSCustomObject]@{
            EventId = [string]$_.EventId; ArtifactId = [string]$_.ArtifactId
            RunId = [string]$_.RunId; InstanceId = [string]$_.InstanceId
            Component = [string]$_.Component; Status = [string]$_.Status
        }})
    }
}

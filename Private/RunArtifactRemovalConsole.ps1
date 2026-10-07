# Geführte Einzelauswahl; Metadaten liefern keine Löschberechtigung.
function Get-LabRunArtifactRemovalConsoleCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot)
    $root = Assert-LabRunArtifactPath $StateRoot
    $candidates = @{}
    foreach ($area in @('runs', 'run-artifact-removals')) {
        $directory = Assert-LabRunArtifactPath (Join-Path $root $area)
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        $entries = @(Get-ChildItem -LiteralPath $directory -Directory -Force -ErrorAction Stop)
        if ($entries.Count -gt 8192) { throw 'RUN_ARTIFACT_INVENTORY_LIMIT' }
        foreach ($entry in $entries) {
            if ($entry.Name -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { continue }
            $fileName = if ($area -ceq 'runs') { 'run-state.json' } else { 'journal.json' }
            $path = Assert-LabRunArtifactPath (Join-Path $entry.FullName $fileName)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            if ($area -ceq 'runs') {
                if ((Get-Item -LiteralPath $path -ErrorAction Stop).Length -gt 16MB) { throw 'RUN_ARTIFACT_INVENTORY_LIMIT' }
                try { $state = Get-Content -LiteralPath $path -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -Depth 20 -ErrorAction Stop }
                catch { throw 'RUN_ARTIFACT_EVIDENCE_UNVERIFIABLE' }
                if ($state.runId -cne $entry.Name -or $state.state -cne 'REMOVED') { continue }
                $label = 'Entfernter Run'
                if ($state.metadata.name -is [string] -and -not [string]::IsNullOrWhiteSpace($state.metadata.name)) {
                    $label = ($state.metadata.name -replace '[\x00-\x1f\x7f]', ' ')
                    if ($label.Length -gt 120) { $label = $label.Substring(0, 120) }
                }
            }
            else { $label = 'Artefaktvorgang / Ergebnis prüfen' }
            $candidates[$entry.Name] = [pscustomobject]@{ RunId = $entry.Name; Label = $label }
        }
    }
    @($candidates.Values | Sort-Object RunId)
}

function Get-LabRunArtifactRemovalConsoleReason {
    param([string]$Code)
    switch -CaseSensitive ($Code) {
        'RUN_ARTIFACT_HYPERV_ABSENCE_UNVERIFIABLE' { 'Hyper-V: Die physische VHDX-Abwesenheit ist nicht sicher nachweisbar. Artefakte bleiben erhalten.' }
        'RUN_ARTIFACT_CLEANUP_INCOMPLETE' { 'Der reguläre Cleanup ist unvollständig. Zuerst den gebundenen Cleanup-/Recovery-Vorgang klären.' }
        'RUN_ARTIFACT_RESOURCE_PRESENT' { 'Gebundene Providerressourcen sind noch vorhanden. Dieser Dialog löscht keine Providerressourcen.' }
        'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE' { 'Die ursprüngliche Runtimebindung ist nicht verifizierbar. Keine nachträgliche Übernahme oder Löschung.' }
        { $_ -cin @('RUN_ARTIFACT_RETAINED_OR_PROTECTED', 'RUN_ARTIFACT_REFERENCED_OR_RETAINED', 'RUN_ARTIFACT_PROTECTED_GROUP') } { 'Retention, persistente Daten oder geschützte Referenzen verhindern die Entfernung.' }
        { $_ -cin @('RUN_ARTIFACT_CONTENT_CHANGED', 'RUN_ARTIFACT_PREVIEW_STALE', 'RUN_ARTIFACT_LOCATIONS_CHANGED') } { 'Die Bindung hat sich seit der Vorschau verändert. Erneut prüfen; keine automatische Wiederholung.' }
        'RUN_ARTIFACT_RECOVERY_REQUIRED' { 'Recovery-Evidence verhindert die Entfernung. Den ursprünglichen Vorgang klären; Evidence bleibt erhalten.' }
        'RUN_ARTIFACT_REGISTERED_STATE_REQUIRED' { 'Der State-Root ist nicht als Lab_Data/State registriert. Keine automatische Übernahme.' }
        default { 'Die erforderliche Evidence ist nicht vollständig verifizierbar. Artefakte erhalten und den gebundenen Vorgang prüfen.' }
    }
}

function Test-LabRunArtifactRemovalConsolePlan {
    param($Plan, [string]$RunId)
    if ($null -eq $Plan -or $Plan -is [array] -or $Plan.RunId -cne $RunId -or
        $Plan.Status -cnotin @('READY', 'RECOVERY_REQUIRED', 'REMOVED', 'BLOCKED') -or
        $Plan.CanApply -isnot [bool] -or $Plan.FileCount -isnot [int] -or $Plan.FileCount -lt 0) { return $false }
    if ($Plan.Status -cin @('READY', 'RECOVERY_REQUIRED')) {
        return $Plan.CanApply -and $Plan.PlanKey -is [string] -and $Plan.PlanKey -cmatch '^[a-f0-9]{64}$' -and $null -eq $Plan.ReasonCode
    }
    return -not $Plan.CanApply -and ($Plan.Status -cne 'BLOCKED' -or
        ($Plan.ReasonCode -is [string] -and $Plan.ReasonCode -cmatch '^RUN_ARTIFACT_[A-Z_]+$'))
}

function Invoke-LabRunArtifactRemovalInteractive {
    [CmdletBinding()]
    param()
    $runId = $null
    try {
        $dataRoot = Get-LabDataRootDefault
        if (-not $dataRoot) { throw 'RUN_ARTIFACT_REGISTERED_STATE_REQUIRED' }
        $stateRoot = Get-LabStateRoot
        $configuration = Get-LabStorageConfiguration -DataRoot $dataRoot
        if (-not @($configuration.LabDataLocations | Where-Object {
            [IO.Path]::GetFullPath((Join-Path $_.LabDataRoot 'State')) -eq [IO.Path]::GetFullPath($stateRoot)
        }).Count) { throw 'RUN_ARTIFACT_REGISTERED_STATE_REQUIRED' }
        while ($true) {
            $candidates = @(Get-LabRunArtifactRemovalConsoleCandidates -StateRoot $stateRoot)
            if (-not $candidates.Count) { Write-LabInfo 'Keine entfernten Runs oder Artefaktvorgänge im aktuellen registrierten State-Root.'; return }
            $items = @(foreach ($candidate in $candidates) {
                New-LabConsoleItem -Id $candidate.RunId -Label $candidate.Label -Value $candidate.RunId
            })
            $items += New-LabConsoleItem -Id back -Label 'Zurück' -Shortcut 0
            $selection = Invoke-LabConsoleMenu -ScreenId 'run-artifact-removal' -Title 'Artefakte eines entfernten Runs' `
                -Subtitle 'Genau ein Run · Auswahl liest nur Metadaten · keine globale Entfernung' -Items $items
            if ($selection.Status -ceq 'Refresh') { continue }
            if ($selection.Status -cne 'Selected' -or $selection.SelectedItem.Id -ceq 'back') { return }
            break
        }
        $selected = @($candidates | Where-Object RunId -CEQ $selection.SelectedItem.Id)
        if ($selected.Count -ne 1) { throw 'RUN_ARTIFACT_EVIDENCE_UNVERIFIABLE' }
        $runId = $selected[0].RunId
        $arguments = @{ RunId = $runId; StateRoot = $stateRoot; DataRoot = $dataRoot }
        while ($true) {
            $plan = Get-SqlServerLabRunArtifactRemovalPlan @arguments
            if (-not (Test-LabRunArtifactRemovalConsolePlan -Plan $plan -RunId $runId)) { throw 'RUN_ARTIFACT_EVIDENCE_UNVERIFIABLE' }
            Write-LabStatus -Label 'Run' -Value $runId
            Write-LabStatus -Label 'Artefaktstatus' -Value $plan.Status
            Write-LabStatus -Label 'Metadatendateien' -Value ([string]$plan.FileCount)
            Write-LabInfo 'Nur geprüfte Run-Metadaten und leere Runverzeichnisse werden endgültig entfernt. Ein Abschlussreceipt bleibt erhalten. Keine Providerressourcen oder Sicherungen werden gelöscht.'
            if ($plan.Status -ceq 'BLOCKED') {
                Write-LabWarning (Get-LabRunArtifactRemovalConsoleReason -Code $plan.ReasonCode)
                Write-LabStatus -Label 'Sperrgrund' -Value $plan.ReasonCode
            }
            if ($plan.Status -ceq 'REMOVED') { Write-LabInfo 'Die Artefaktentfernung ist bereits abgeschlossen.'; return }
            if ($plan.Status -ceq 'RECOVERY_REQUIRED') { Write-LabInfo 'Ein begonnener Artefaktvorgang wird ausschließlich vorwärts fortgesetzt. Bereits entfernte Metadaten werden nicht wiederhergestellt.' }
            $actions = @(
                New-LabConsoleItem -Id apply -Label $(if ($plan.Status -ceq 'RECOVERY_REQUIRED') { 'Artefaktentfernung fortsetzen' } else { 'Geprüfte Artefakte endgültig entfernen' }) `
                    -Value $(if ($plan.CanApply) { 'Endgültig · nur Run-Metadaten · Abschlussreceipt bleibt' } else { Get-LabRunArtifactRemovalConsoleReason -Code $plan.ReasonCode }) `
                    -Shortcut 1 -Disabled:(-not $plan.CanApply) -DisabledReason (Get-LabRunArtifactRemovalConsoleReason -Code $plan.ReasonCode)
                New-LabConsoleItem -Id refresh -Label 'Vorschau erneut prüfen' -Value 'read-only · frische Ressourcenprüfung' -Shortcut 2
                New-LabConsoleItem -Id back -Label 'Zurück ohne Entfernung' -Shortcut 0
            )
            $action = Invoke-LabConsoleMenu -ScreenId 'run-artifact-removal-review' -Title 'Artefaktentfernung prüfen' `
                -Subtitle "Run $runId · $($plan.Status) · $($plan.FileCount) Dateien · $($plan.ReasonCode)" -Items $actions
            if ($action.Status -ceq 'Refresh') { continue }
            if ($action.Status -cne 'Selected' -or $action.SelectedItem.Id -ceq 'back') { return }
            if ($action.SelectedItem.Id -ceq 'refresh') { continue }
            if ($action.SelectedItem.Id -cne 'apply' -or -not $plan.CanApply) { return }
            if (-not (Read-LabConfirm -Prompt "Run-Metadaten für $runId endgültig entfernen / fortsetzen?" -Default $false)) { return }
            $result = Invoke-SqlServerLabRunArtifactRemoval @arguments -ExpectedPlanKey $plan.PlanKey -Confirm:$false
            if ($null -eq $result -or $result -is [array] -or $result.RunId -cne $runId -or
                $result.Status -cnotin @('REMOVED', 'CANCELLED') -or $result.Changed -isnot [bool] -or
                ($result.Status -ceq 'CANCELLED' -and $result.Changed)) { throw 'RUN_ARTIFACT_EVIDENCE_UNVERIFIABLE' }
            Write-LabStatus -Label 'Artefaktentfernung' -Value $result.Status
            return New-LabActionResult -Action RunArtifactRemoval -RunIds @($runId) -Status $(
                if ($result.Status -ceq 'CANCELLED') { 'Cancelled' } elseif ($result.Changed) { 'Changed' } else { 'NoChange' }
            ) -ConnectionCenterImpact None
        }
    }
    catch {
        if (Test-LabConsoleInputCancellation -InputObject $_) { return }
        $code = if ($_.Exception.Message -cmatch '^RUN_ARTIFACT_[A-Z_]+$') { $_.Exception.Message } else { 'RUN_ARTIFACT_EVIDENCE_UNVERIFIABLE' }
        Write-LabWarning (Get-LabRunArtifactRemovalConsoleReason -Code $code)
        Write-LabStatus -Label 'Artefaktentfernung nicht bestätigt' -Value $code
        Write-LabInfo 'Kein automatischer Retry. Bei begonnenem Vorgang denselben Run erneut auswählen und die öffentliche Vorschau prüfen.'
        return New-LabActionResult -Action RunArtifactRemoval -Status Failed -RunIds @($runId) -ErrorCode $code
    }
}

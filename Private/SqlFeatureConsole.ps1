function Invoke-LabSqlFeatureInteractive {
    param([string]$RunId, [string]$InstanceId, [switch]$FullTextOnly)

    try {
        if (-not $RunId) {
            $runs = @(Get-LabActiveRuns | Where-Object state -CEQ RUNNING)
            if (-not $runs.Count) {
                Write-LabInfo 'Keine laufende SQL-Lab-Umgebung verfügbar.'
                $null = Wait-LabConsoleAcknowledgement
                return
            }
            $RunId = Select-LabRun -Runs $runs -Prompt 'Laufendes SQL-Lab auswählen' -DisableAutomatedTestEnvironments -DisableSystemServices
            if (-not $RunId) { return }
        }

        $targets = @(Get-LabResourceChangeTargets -RunId $RunId | Where-Object {
            $_.Provider -cin @('docker', 'podman', 'hyperv') -and (-not $InstanceId -or $_.InstanceId -ceq $InstanceId)
        })
        if (-not $targets.Count -or ($InstanceId -and $targets.Count -ne 1)) { throw 'SQL_FEATURE_RUNNING_INSTANCE_REQUIRED' }
        $target = $targets[0]
        if ($targets.Count -gt 1) {
            $targetChoice = Invoke-LabConsoleMenu -ScreenId 'sql-feature-target' -Title 'SQL-Instanz auswählen' -Items @(
                foreach ($item in $targets) {
                    New-LabConsoleItem -Id $item.InstanceId -Label $item.InstanceId -Value $item.Provider -Data $item
                }
                New-LabConsoleItem -Id 'back' -Label 'Zurück' -Shortcut 0
            )
            if ($targetChoice.Status -ne 'Selected' -or $targetChoice.SelectedItem.Id -eq 'back') { return }
            $target = $targetChoice.SelectedItem.Data
        }

        $choices = @(
            New-LabConsoleItem -Id 'fulltext-on' -Label 'Volltext nachinstallieren' -Data @{ Feature = 'FullText'; Enabled = $true }
            New-LabConsoleItem -Id 'fulltext-off' -Label 'Volltext deaktivieren (Komponente entfernen)' -Data @{ Feature = 'FullText'; Enabled = $false }
            if ($target.Provider -ceq 'hyperv' -and -not $FullTextOnly) {
                New-LabConsoleItem -Id 'filestream-on' -Label 'FILESTREAM aktivieren' -Data @{ Feature = 'FileStream'; Enabled = $true }
                New-LabConsoleItem -Id 'filestream-off' -Label 'FILESTREAM deaktivieren' -Data @{ Feature = 'FileStream'; Enabled = $false }
            }
            New-LabConsoleItem -Id 'back' -Label 'Zurück' -Shortcut 0
        )
        $choice = Invoke-LabConsoleMenu -ScreenId 'sql-feature-operation' -Title 'SQL-Funktion ändern' -Items $choices -Subtitle 'SQL Server wird bei einer Änderung neu gestartet.'
        if ($choice.Status -ne 'Selected' -or $choice.SelectedItem.Id -eq 'back') { return }

        $operation = $choice.SelectedItem.Data
        $prompt = '{0} für {1} bestätigen? SQL Server kann dabei neu starten.' -f $choice.SelectedItem.Label, $target.InstanceId
        if (-not (Read-LabConfirm -Prompt $prompt -Default $false)) { return }
        $result = Set-SqlServerLabFeature -RunId $RunId -InstanceId $target.InstanceId -Feature $operation.Feature -Enabled $operation.Enabled -Confirm:$false -ErrorAction Stop
        if ($result.Status -cne 'VERIFIED') { throw 'SQL_FEATURE_RESULT_UNCONFIRMED' }
        Write-LabSuccess ('{0} · {1}' -f $choice.SelectedItem.Label, $(if ($result.Changed) { 'Änderung bestätigt' } else { 'Zielzustand bereits aktiv' }))
    }
    catch {
        $code = if ($_.Exception.Message -cmatch '^SQL_FEATURE_[A-Z0-9_]{1,80}$') { $_.Exception.Message } else { 'SQL_FEATURE_UNAVAILABLE' }
        Write-LabError ('SQL-Funktion konnte nicht bestätigt werden ({0}).' -f $code)
    }
    $null = Wait-LabConsoleAcknowledgement
}

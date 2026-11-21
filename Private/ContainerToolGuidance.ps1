function Invoke-LabContainerToolCheckInteractive {
    $items = @(foreach ($target in Get-LabContainerSqlConsoleTargets) {
        New-LabConsoleItem -Id ($target.RunId + '/' + $target.InstanceId) -Label $target.Label -Data $target
    })
    if (-not $items.Count) {
        Write-LabInfo 'Keine registrierte laufende Docker- oder Podman-SQL-Instanz gefunden.'
        $null = Wait-LabConsoleAcknowledgement
        return
    }
    $selected = Select-LabConsoleDataItem -ScreenId 'container-tool-check' -Title 'Instanz für SqlPackage-Versionsprüfung' -Items $items
    if (-not $selected) { return }
    if (-not (Read-LabConfirm -Prompt 'SqlPackage /Version im gewählten laufenden Container prüfen?' -Default $false)) { return }
    try {
        $result = Test-SqlServerLabContainerTool -RunId $selected.RunId -InstanceId $selected.InstanceId -ErrorAction Stop
        if ($result.Status -cne 'PASS' -or $result.RunId -cne $selected.RunId -or $result.InstanceId -cne $selected.InstanceId -or
            $result.Provider -cne $selected.Provider -or
            $result.RuntimeVersion -cnotmatch '\A[0-9]+(?:\.[0-9]+){3}\z') { throw 'CONTAINER_TOOL_RESULT_INVALID' }
        Write-LabSuccess ('SqlPackage ist in der gewählten Instanz verfügbar · Version {0}' -f $result.RuntimeVersion)
    }
    catch { Write-LabWarning 'Keine Version bestätigt. Prüfe, ob SqlPackage für diese Instanz provisioniert wurde und der Container läuft.' }
    $null = Wait-LabConsoleAcknowledgement
}

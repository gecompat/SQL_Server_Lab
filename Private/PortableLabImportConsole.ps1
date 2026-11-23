function Show-LabPortableImportPlanInteractive {
    try {
        $targets = @(Get-LabContainerSqlConsoleTargets -IncludeStopped | Sort-Object RunId,Provider -Unique)
        if (-not $targets.Count) {
            Write-LabInfo 'Für den Plan ist ein registrierter Docker- oder Podman-Ziel-Run nötig.'
            $null = Wait-LabConsoleAcknowledgement
            return
        }
        $items = @(for ($index=0; $index -lt $targets.Count; $index++) {
            New-LabConsoleItem -Id "target-$index" -Label $targets[$index].Label -Data $targets[$index]
        })
        $target = Select-LabConsoleDataItem -ScreenId 'portable-import-plan-target' -Title 'Ziel-Run für Importplan wählen' -Items $items
        if (-not $target) { return }
        $inputResult = Read-LabConsoleTextInput -Prompt 'Absoluter lokaler Pfad zum JSON-Lab-Paket'
        if ($inputResult.Status -ne 'Confirmed') { return }
        $path = [string]$inputResult.Value
        if ($path.Length -gt 4096 -or -not [IO.Path]::IsPathFullyQualified($path) -or $path.StartsWith('\\') -or $path.StartsWith('//')) {
            throw 'PORTABLE_IMPORT_PATH_INVALID'
        }
        $full = [IO.Path]::GetFullPath($path)
        if ($IsWindows -and $full.Substring(2).Contains(':')) { throw 'PORTABLE_IMPORT_PATH_INVALID' }
        Assert-LabPortableContainerTransferPreflightNoReparsePath -Root ([IO.Path]::GetPathRoot($full)) -Path $full
        $file = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($file -isnot [IO.FileInfo] -or $file.Extension -ine '.json' -or $file.Length -le 0 -or $file.Length -gt 256KB) {
            throw 'PORTABLE_IMPORT_FILE_INVALID'
        }
        $plan = Get-SqlServerLabPortableLabImportPlan -PackagePath $full -TargetRunId $target.RunId -TargetProvider $target.Provider -ErrorAction Stop
        if ($plan.ExecutionImplemented -ne $false -or $plan.TargetRunId -ne $target.RunId -or $plan.TargetProvider -ne $target.Provider) {
            throw 'PORTABLE_IMPORT_PLAN_UNCONFIRMED'
        }
        Write-LabInfo ('Importplan: {0} · Ziel: {1} · Backups: {2}' -f $plan.Status, $target.Label, @($plan.BackupReferences).Count)
        if ($plan.Blockers.Count) { Write-LabInfo ('Befunde: {0}' -f ($plan.Blockers -join ', ')) }
        Write-LabInfo 'Der Plan beschreibt die Machbarkeit. Für eine tatsächliche Übertragung steht der separate Datenbanktransfer zur Verfügung.'
    }
    catch { Write-LabError 'Der Importplan konnte nicht gelesen werden. Prüfe die JSON-Paketdatei und den gebundenen Ziel-Run.' }
    $null = Wait-LabConsoleAcknowledgement
}

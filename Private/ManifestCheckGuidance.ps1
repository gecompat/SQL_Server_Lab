function Get-LabManifestCheckView {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.Length -gt 4096) { throw 'MANIFEST_CHECK_PATH_INVALID' }
    $manifestPath = Assert-LabDiagnosticPath -Path $Path
    $manifest = Read-LabDiagnosticJson -Path $manifestPath -MaximumBytes 1048576 -MaximumDepth 40
    $json = ConvertTo-Json -InputObject $manifest -Depth 40 -Compress
    $directory = Split-Path -Parent $manifestPath
    foreach ($instance in $manifest.instances) {
        $paths = @($instance.postProvision | Where-Object { $_ -is [string] -and $_ })
        foreach ($database in $instance.databases) {
            $source = $database.restore.source
            if ($source -is [string] -and $source -and $source -notmatch '^https?://') { $paths += $source }
        }
        foreach ($source in $paths) {
            $localPath = if ([IO.Path]::IsPathRooted($source)) { $source } else { Join-Path $directory $source }
            $null = Assert-LabDiagnosticPath -Path $localPath
        }
    }
    $result = Get-LabManifestValidationResult -Manifest $manifest -Json $json -ManifestPath $manifestPath
    $classes = @(foreach ($message in $result.Errors) {
        switch -Regex ($message) {
            '^Schema:' { 'SCHEMA'; break }
            '^SMTP_TEST_' { 'SMTP_TEST_SCOPE'; break }
            '\.collation:' { 'COLLATION'; break }
            '\.restore(?:[.:])' { 'BACKUP_SOURCE'; break }
            '\.postProvision:' { 'SQL_SCRIPT'; break }
            default { 'MANIFEST_RULE' }
        }
    })
    [pscustomobject]@{
        IsValid=[bool]$result.IsValid
        ErrorCount=@($result.Errors).Count
        WarningCount=@($result.Warnings).Count
        ErrorClasses=@($classes | Sort-Object -Unique)
    }
}

function Show-LabManifestCheckInteractive {
    $candidate = Read-Host '  Absoluter Pfad zur Manifestdatei (leer = zurück)'
    if ([string]::IsNullOrWhiteSpace($candidate)) { return }
    try {
        $view = Get-LabManifestCheckView -Path $candidate.Trim()
        $status = if ($view.IsValid) { 'Gültig' } else { 'Ungültig' }
        Write-Host ('{0} · {1} Fehler · {2} Hinweise' -f $status, $view.ErrorCount, $view.WarningCount)
        if ($view.ErrorClasses.Count) { Write-Host ('Betroffene Regeln: ' + ($view.ErrorClasses -join ', ')) }
    }
    catch { Write-Host 'Die lokale Manifestdatei konnte nicht geprüft werden.' -ForegroundColor Yellow }
    $null = Wait-LabConsoleAcknowledgement
}

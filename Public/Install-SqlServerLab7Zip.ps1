function Install-SqlServerLab7Zip {
    <#
    .SYNOPSIS
        Installiert 7-Zip optional über den Windows Package Manager.
    .DESCRIPTION
        Die Funktion wird nie automatisch aus einem Sample-Handler aufgerufen.
        Sie ist eine explizite, lokale Verwaltungsaktion für katalogisierte
        .7z-Backups. Voraussetzung ist Windows mit winget.
    .OUTPUTS
        PSCustomObject mit Status, gefundenem Pfad und Meldung.
    .EXAMPLE
        Install-SqlServerLab7Zip
        Installiert 7-Zip nach der PowerShell-Bestätigung, falls es noch fehlt.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param()

    $existing = Get-Lab7ZipExecutable
    if ($existing) {
        return [PSCustomObject]@{ Status = 'ALREADY_AVAILABLE'; Path = $existing.Path; Message = '7-Zip ist bereits verfügbar.' }
    }
    if (-not $IsWindows) {
        throw 'SEVENZIP_INSTALL_UNSUPPORTED: Die optionale winget-Installation ist nur unter Windows verfügbar.'
    }

    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) {
        throw 'SEVENZIP_INSTALL_WINGET_UNAVAILABLE: winget.exe wurde nicht gefunden. 7-Zip manuell installieren und erneut versuchen.'
    }
    if (-not $PSCmdlet.ShouldProcess('7-Zip (7zip.7zip)', 'über winget installieren')) {
        return [PSCustomObject]@{ Status = 'SKIPPED'; Message = '7-Zip-Installation nicht bestätigt.' }
    }

    $wingetPath = [string]$winget.Path
    $output = @(& $wingetPath install --id 7zip.7zip --exact --source winget --accept-package-agreements --accept-source-agreements 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "SEVENZIP_INSTALL_FAILED: winget ExitCode ${LASTEXITCODE}: $($output -join ' ')"
    }
    $installed = Get-Lab7ZipExecutable
    if (-not $installed) {
        throw 'SEVENZIP_INSTALL_NOT_DETECTED: winget meldete Erfolg, aber 7-Zip wurde nicht gefunden. PowerShell neu öffnen und erneut prüfen.'
    }
    return [PSCustomObject]@{ Status = 'INSTALLED'; Path = $installed.Path; Message = '7-Zip wurde optional installiert und erkannt.' }
}

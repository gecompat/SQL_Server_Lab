#Requires -Version 7.2

function Get-PowerShellDataFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Datei nicht gefunden: $Path"
    }

    try {
        $value = Import-PowerShellDataFile -Path $Path -ErrorAction Stop
        if ($value -is [System.Collections.IList] -and $value.Count -eq 1) {
            $value = $value[0]
        }
        if ($null -ne $value) {
            return $value
        }
    }
    catch {
        Write-Warning "Import-PowerShellDataFile fehlgeschlagen für '$Path': $($_.Exception.Message)"
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $value = [scriptblock]::Create($content).Invoke()
        if ($value -is [System.Collections.IList] -and $value.Count -eq 1) {
            $value = $value[0]
        }
        return $value
    }
    catch {
        throw "Daten aus '$Path' konnten nicht geladen werden: $($_.Exception.Message)"
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$moduleManifest = Get-PowerShellDataFile -Path $modulePath
$psaSettingsPath = Join-Path $repoRoot 'Tests' 'Static' 'PSScriptAnalyzerSettings.psd1'
$psaSettings = Get-PowerShellDataFile -Path $psaSettingsPath

Remove-Module -Name 'SqlServerLab' -Force -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop

$manifestFunctions = @($moduleManifest.FunctionsToExport | Where-Object { $_ -and $_ -ne '*' } | Sort-Object)
$exportedFunctions = @(Get-Module SqlServerLab | Select-Object -ExpandProperty ExportedFunctions | Select-Object -ExpandProperty Keys | Sort-Object)
$publicScripts = Get-ChildItem -Path (Join-Path $repoRoot 'Public') -Filter '*.ps1' -File | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) } | Sort-Object

Describe 'SqlServerLab-Modulmanifest' {
    It 'muss eine gültige Modulversion enthalten' {
        $moduleVersion = $moduleManifest.ModuleVersion
        if ([string]::IsNullOrWhiteSpace($moduleVersion)) {
            $moduleVersion = $moduleManifest.Version
        }
        if ([string]::IsNullOrWhiteSpace($moduleVersion)) {
            throw 'Das Modulmanifest enthält keine Modulversion.'
        }
    }

    It 'muss für jede in FunctionsToExport definierte Funktion eine aufrufbare Command-Definition haben' {
        foreach ($commandName in $manifestFunctions) {
            try {
                $null = Get-Command -Name $commandName -Module SqlServerLab -ErrorAction Stop
            }
            catch {
                throw "Manifestfunktion '$commandName' ist nicht aufrufbar: $($_.Exception.Message)"
            }
        }
    }

    It 'muss das im Manifest deklarierte Exportset konsistent mit dem importierten Modul exportieren' {
        $delta = Compare-Object -ReferenceObject $manifestFunctions -DifferenceObject $exportedFunctions
        if ($delta) {
            $items = ($delta | ForEach-Object { $_.InputObject }) -join ', '
            throw "Exportabweichung zwischen Manifest und Modul: $items"
        }
    }
}

Describe 'PSScriptAnalyzer-Grundlage' {
    It 'muss Fehler- und Warn-Seriousness in der projektspezifischen Baseline aktivieren' {
        if ($psaSettings.IncludeDefaultRules -ne $true) {
            throw 'PSScriptAnalyzer-Einstellung IncludeDefaultRules ist nicht aktiv.'
        }
        if ($psaSettings.Severity -notcontains 'Error' -or $psaSettings.Severity -notcontains 'Warning') {
            throw 'PSScriptAnalyzer-Baseline enthält nicht Error+Warning.'
        }
    }
}

Describe 'Statische Testskripte' {
    It 'müssen im definierten Ort erreichbar sein' {
        $required = @(
            (Join-Path 'Tests' 'Static' 'Invoke-ReleaseReadinessChecks.ps1'),
            (Join-Path 'Tests' 'Static' 'Invoke-PSScriptAnalyzerChecks.ps1'),
            (Join-Path 'Tests' 'Static' 'Invoke-PesterChecks.ps1')
        )
        foreach ($path in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $path))) {
                throw "Fehlender Test-Check: $path"
            }
        }
    }
}

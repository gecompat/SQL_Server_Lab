#Requires -Version 7.2

Describe 'SqlServerLab-Modulmanifest' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
        $manifestData = Import-PowerShellDataFile -Path $modulePath -ErrorAction Stop
        $moduleInfo = Import-Module -Name $modulePath -Force -PassThru -ErrorAction Stop

        $moduleVersion = [string]$manifestData.ModuleVersion
        $manifestFunctions = @(
            $manifestData.FunctionsToExport |
                ForEach-Object { if ($null -ne $_) { $_.ToString().Trim() } } |
                Where-Object { $_ -and $_ -ne '*' } |
                Sort-Object -Unique
        )
        $exportedFunctions = @(
            $moduleInfo.ExportedFunctions.Keys |
                ForEach-Object { if ($null -ne $_) { $_.ToString().Trim() } } |
                Where-Object { $_ -and $_ -ne '*' } |
                Sort-Object -Unique
        )
    }

    It 'muss eine gueltige Modulversion enthalten' {
        if ([string]::IsNullOrWhiteSpace($moduleVersion)) {
            throw 'Das Modulmanifest enthaelt keine Modulversion.'
        }

        try {
            $null = [version]$moduleVersion
        }
        catch {
            throw "Das Modulmanifest enthaelt eine ungueltige Modulversion: $moduleVersion"
        }
    }

    It 'muss fuer jede in FunctionsToExport definierte Funktion eine aufrufbare Command-Definition haben' {
        if ($manifestFunctions.Count -eq 0) {
            throw 'Das Modulmanifest definiert keine exportierten Funktionen.'
        }

        foreach ($commandName in $manifestFunctions) {
            try {
                $null = Get-Command -Name $commandName -Module $moduleInfo.Name -ErrorAction Stop
            }
            catch {
                throw "Manifestfunktion '$commandName' ist nicht aufrufbar: $($_.Exception.Message)"
            }
        }
    }

    It 'muss das im Manifest deklarierte Exportset konsistent mit dem importierten Modul exportieren' {
        if ($exportedFunctions.Count -eq 0) {
            throw 'Das importierte Modul exportiert keine Funktionen.'
        }

        $delta = Compare-Object -ReferenceObject $manifestFunctions -DifferenceObject $exportedFunctions
        if ($delta) {
            $items = ($delta | ForEach-Object { $_.InputObject }) -join ', '
            throw "Exportabweichung zwischen Manifest und Modul: $items"
        }
    }
}

Describe 'PSScriptAnalyzer-Grundlage' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $settingsPath = Join-Path $repoRoot 'Tests' 'Static' 'PSScriptAnalyzerSettings.psd1'
        $settings = Import-PowerShellDataFile -Path $settingsPath -ErrorAction Stop
        $severity = @($settings.Severity | ForEach-Object { [string]$_ })
    }

    It 'muss Fehler und Warnungen in der projektspezifischen Baseline aktivieren' {
        if ($settings.IncludeDefaultRules -ne $true) {
            throw 'PSScriptAnalyzer-Einstellung IncludeDefaultRules ist nicht aktiv.'
        }
        if ($severity -notcontains 'Error' -or $severity -notcontains 'Warning') {
            throw 'PSScriptAnalyzer-Baseline enthaelt nicht Error und Warning.'
        }
    }
}

Describe 'Statische Testskripte' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    }

    It 'muessen im definierten Ort erreichbar sein' {
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

    It 'darf bei regulaeren Pester-Laeufen keine Repository-Artefakte persistieren' {
        $runnerPath = Join-Path $repoRoot 'Tests' 'Static' 'Invoke-PesterChecks.ps1'
        $runnerText = Get-Content -LiteralPath $runnerPath -Raw -Encoding utf8
        if ($runnerText -match '\bOutputFile\b|TestResult\.OutputPath|TestResult\.Enabled\s*=\s*\$true') {
            throw 'Der Pester-Runner erzeugt weiterhin einen persistenten Testbericht.'
        }
        if ($runnerText -notmatch "Get-ChildItem[^\r\n]+-Filter 'Pester-Results-\*\.xml'" -or
            $runnerText -notmatch 'Remove-Item -LiteralPath \$legacyReport\.FullName') {
            throw 'Der Pester-Runner bereinigt seine früheren XML-Berichte nicht eng begrenzt.'
        }
    }
}

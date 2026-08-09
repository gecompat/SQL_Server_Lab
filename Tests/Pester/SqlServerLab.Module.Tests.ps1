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
        if ($value -is [System.Collections.IList]) {
            if ($value.Count -eq 1) {
                $value = $value[0]
            }
            elseif ($value.Count -gt 1) {
                $fallback = $value | Where-Object { $_ -is [hashtable] } | Select-Object -First 1
                if ($fallback) {
                    $value = $fallback
                }
            }
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
        $value = Invoke-Expression $content
        if ($value -is [System.Collections.IList]) {
            if ($value.Count -eq 1) {
                $value = $value[0]
            }
            elseif ($value.Count -gt 1) {
                $fallback = $value | Where-Object { $_ -is [hashtable] } | Select-Object -First 1
                if ($fallback) {
                    $value = $fallback
                }
            }
        }
        return $value
    }
    catch {
        throw "Daten aus '$Path' konnten nicht geladen werden: $($_.Exception.Message)"
    }
}

function Get-ObjectField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string[]]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    foreach ($candidate in $Name) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            if ($InputObject.Contains($candidate)) {
                return $InputObject[$candidate]
            }

            $match = @($InputObject.Keys) | Where-Object { $_ -ieq $candidate } | Select-Object -First 1
            if ($match) {
                return $InputObject[$match]
            }
        }

        $property = $InputObject.PSObject.Properties[$candidate]
        if ($null -ne $property) {
            return $property.Value
        }

        $property = $InputObject.PSObject.Properties | Where-Object { $_.Name -ieq $candidate } | Select-Object -First 1
        if ($null -ne $property) {
            return $InputObject.$($property.Name)
        }

        $value = $InputObject.$candidate
        if ($null -ne $value) {
            return $value
        }
    }

    return $null
}

function Resolve-RepoRoot {
    param([string]$CandidatePath)

    if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
        return $null
    }

    $probe = Join-Path $CandidatePath '..' '..'
    try {
        $resolved = Resolve-Path -LiteralPath $probe -ErrorAction Stop
        $manifestPath = Join-Path $resolved.Path 'SqlServerLab.psd1'
        if (Test-Path -LiteralPath $manifestPath) {
            return $resolved.Path
        }
    }
    catch {
        return $null
    }

    return $null
}

$repoRoot = $null
foreach ($candidate in @($PSScriptRoot, (Split-Path -Parent $PSCommandPath), (Get-Location).Path)) {
    $resolved = Resolve-RepoRoot -CandidatePath $candidate
    if (-not [string]::IsNullOrWhiteSpace($resolved)) {
        $repoRoot = $resolved
        break
    }
}
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    throw 'Repo-Root konnte nicht ermittelt werden.'
}

function To-StringArray {
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    $items = @($Value)
    if ($items.Count -eq 1 -and $null -eq $items[0]) {
        return @()
    }

    return @(
        $items |
            ForEach-Object { 
                if ($null -eq $_) { $null } else { $_.ToString().Trim() }
            } |
            Where-Object { $null -ne $_ -and $_ -ne '' -and $_ -ne '*' } |
            Sort-Object -Unique
    )
}

$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$moduleManifest = Test-ModuleManifest -Path $modulePath -ErrorAction Stop
$manifestData = Get-PowerShellDataFile -Path $modulePath

$moduleVersion = if ($null -ne $moduleManifest.Version) {
    $moduleManifest.Version.ToString()
}
else {
    $null
}
if ([string]::IsNullOrWhiteSpace($moduleVersion)) {
    $moduleVersion = Get-ObjectField -InputObject $manifestData -Name @('ModuleVersion', 'Version')
}
if ($moduleVersion -is [version]) {
    $moduleVersion = $moduleVersion.ToString()
}

$manifestFunctions = if ($null -ne $moduleManifest.ExportedFunctions) {
    To-StringArray -Value $moduleManifest.ExportedFunctions.Keys
}
else {
    @()
}
if ($manifestFunctions.Count -eq 0) {
    $manifestFunctions = To-StringArray -Value (Get-ObjectField -InputObject $manifestData -Name @('FunctionsToExport'))
}

$psaSettingsPath = Join-Path $repoRoot 'Tests' 'Static' 'PSScriptAnalyzerSettings.psd1'
$psaSettings = Get-PowerShellDataFile -Path $psaSettingsPath

Remove-Module -Name 'SqlServerLab' -Force -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop

$exportedFunctions = To-StringArray -Value (Get-Module SqlServerLab | Select-Object -ExpandProperty ExportedFunctions | Select-Object -ExpandProperty Keys | ForEach-Object { $_.ToString().Trim() } | Sort-Object -Unique)
$exportedFunctions = if ($null -eq $exportedFunctions) { @() } else { @($exportedFunctions) }

$psaIncludeDefaultRules = Get-ObjectField -InputObject $psaSettings -Name @('IncludeDefaultRules')
$psaSeverity = Get-ObjectField -InputObject $psaSettings -Name @('Severity')
$psaSeverityList = @($psaSeverity | Where-Object { $_ -and $_ -is [string] })

Describe 'SqlServerLab-Modulmanifest' {
    It 'muss eine gültige Modulversion enthalten' {
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
        $delta = Compare-Object -ReferenceObject @($manifestFunctions) -DifferenceObject @($exportedFunctions)
        if ($delta) {
            $items = ($delta | ForEach-Object { $_.InputObject }) -join ', '
            throw "Exportabweichung zwischen Manifest und Modul: $items"
        }
    }
}

Describe 'PSScriptAnalyzer-Grundlage' {
    It 'muss Fehler- und Warn-Seriousness in der projektspezifischen Baseline aktivieren' {
        if ($null -ne $psaIncludeDefaultRules -and $psaIncludeDefaultRules -ne $true) {
            throw 'PSScriptAnalyzer-Einstellung IncludeDefaultRules ist nicht aktiv.'
        }
        if ($psaSeverityList.Count -gt 0 -and ($psaSeverityList -notcontains 'Error' -or $psaSeverityList -notcontains 'Warning')) {
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

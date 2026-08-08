#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den Project-Adapter-Vertrag ohne SQL Server, Container oder Netzwerk.
.DESCRIPTION
    Validiert Schema, Aufloesung, Versions- und Capability-Gates sowie die
    Pfadgrenzen des Adapter-Roots anhand des synthetischen Beispieladapters und
    gezielt manipulierter Kopien in einem temporaeren Verzeichnis.
#>
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs,
)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'

if ($showHelpRequested) {

    Get-Help -Full -Name $PSCommandPath | Out-Host

    return

}

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Project Adapter Checks' -ForegroundColor Cyan

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-adapter-check-$([guid]::NewGuid().ToString('N'))"
try {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -ErrorAction Stop
    $module = Get-Module SqlServerLab

    foreach ($commandName in @('Test-SqlServerLabAdapter', 'Install-SqlServerLabAdapter')) {
        Add-CheckResult `
            -Name "Export verfuegbar: $commandName" `
            -Success ([bool](Get-Command $commandName -Module SqlServerLab -ErrorAction SilentlyContinue))
    }

    $exampleAdapterPath = Join-Path $repoRoot 'Adapters/Examples/synthetic-demo'
    $exampleJson = Get-Content -LiteralPath (Join-Path $exampleAdapterPath 'adapter.json') -Raw -Encoding utf8
    $schemaPath = Join-Path $repoRoot 'Schemas/project-adapter.schema.json'
    Add-CheckResult `
        -Name 'Beispieladapter entspricht dem Adapterschema' `
        -Success ($exampleJson | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)

    $ready = Test-SqlServerLabAdapter -Path $exampleAdapterPath
    Add-CheckResult `
        -Name 'Beispieladapter wird als ADAPTER_READY aufgeloest' `
        -Success ($ready.Status -eq 'ADAPTER_READY' -and $ready.IsReady -and
            $ready.ProjectId -eq 'synthetic-demo' -and
            $ready.Entrypoints.Keys.Count -eq 4) `
        -Message ("Status: {0}; Errors: {1}" -f $ready.Status, ($ready.Errors -join '; '))
    Add-CheckResult `
        -Name 'Adapter ohne reservierte Felder erzeugt keine Reserviert-Warnung' `
        -Success ((@($ready.Warnings) -match 'reserviert').Count -eq 0) `
        -Message ("Warnings: {0}" -f ($ready.Warnings -join '; '))

    # Manipulierte Kopien vorbereiten
    New-Item -Path $temporaryRoot -ItemType Directory -Force | Out-Null
    function Copy-AdapterVariant {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][scriptblock]$Mutate
        )

        $variantPath = Join-Path $temporaryRoot $Name
        Copy-Item -LiteralPath $exampleAdapterPath -Destination $variantPath -Recurse
        $definitionPath = Join-Path $variantPath 'adapter.json'
        $adapter = Get-Content -LiteralPath $definitionPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
        & $Mutate $adapter $variantPath
        $adapter | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $definitionPath -Encoding utf8
        return $variantPath
    }

    $unsupportedVersionPath = Copy-AdapterVariant -Name 'unsupported-version' -Mutate {
        param($adapter)
        $adapter.adapterContractVersion = '1.0'
    }
    $unsupportedVersion = Test-SqlServerLabAdapter -Path $unsupportedVersionPath
    Add-CheckResult `
        -Name 'Unbekannte Major-Vertragsversion wird abgelehnt' `
        -Success ($unsupportedVersion.Status -eq 'ADAPTER_UNSUPPORTED_CONTRACT' -and -not $unsupportedVersion.IsReady)

    $unsupportedCorePath = Copy-AdapterVariant -Name 'unsupported-core' -Mutate {
        param($adapter)
        $adapter.supportedLabCoreVersions = @('1.x')
    }
    $unsupportedCore = Test-SqlServerLabAdapter -Path $unsupportedCorePath
    Add-CheckResult `
        -Name 'Nicht unterstuetzte Lab-Core-Version wird abgelehnt' `
        -Success ($unsupportedCore.Status -eq 'ADAPTER_UNSUPPORTED_CONTRACT' -and -not $unsupportedCore.IsReady)

    $traversalPath = Copy-AdapterVariant -Name 'traversal' -Mutate {
        param($adapter)
        $adapter.entrypoints.install = '../escape.sql'
    }
    $traversal = Test-SqlServerLabAdapter -Path $traversalPath
    Add-CheckResult `
        -Name 'Pfad-Traversierung verletzt die Adapter-Root-Grenze' `
        -Success ($traversal.Status -eq 'PROJECT_ARTIFACT_SCOPE_VIOLATION' -and -not $traversal.IsReady)

    $missingEntrypointPath = Copy-AdapterVariant -Name 'missing-entrypoint' -Mutate {
        param($adapter, $variantPath)
        Remove-Item -LiteralPath (Join-Path $variantPath 'sql/install.sql') -Force
    }
    $missingEntrypoint = Test-SqlServerLabAdapter -Path $missingEntrypointPath
    Add-CheckResult `
        -Name 'Fehlende Entrypoint-Datei wird als ADAPTER_INVALID gemeldet' `
        -Success ($missingEntrypoint.Status -eq 'ADAPTER_INVALID' -and
            (@($missingEntrypoint.Errors) -match 'nicht gefunden').Count -gt 0)

    $reservedPath = Copy-AdapterVariant -Name 'reserved-fields' -Mutate {
        param($adapter)
        $adapter | Add-Member -NotePropertyName sqlPackageCatalogs -NotePropertyValue @('catalog/packages.json') -Force
    }
    $reserved = Test-SqlServerLabAdapter -Path $reservedPath
    Add-CheckResult `
        -Name 'Reservierte Package-Felder erzeugen eine Warnung, bleiben aber gueltig' `
        -Success ($reserved.IsReady -and (@($reserved.Warnings) -match 'reserviert').Count -gt 0)

    $malformedVersionPath = Copy-AdapterVariant -Name 'malformed-contract-version' -Mutate {
        param($adapter)
        $adapter.adapterContractVersion = 'v1.0'
    }
    $malformedVersion = $null
    $malformedVersionError = $null
    try {
        $malformedVersion = Test-SqlServerLabAdapter -Path $malformedVersionPath
    }
    catch {
        $malformedVersionError = $_.Exception.Message
    }
    Add-CheckResult `
        -Name 'Fehlerhafte Vertragsversion liefert ADAPTER_INVALID statt Exception' `
        -Success ($null -eq $malformedVersionError -and
            $malformedVersion.Status -eq 'ADAPTER_INVALID' -and -not $malformedVersion.IsReady) `
        -Message ($malformedVersionError ?? ("Status: {0}" -f $malformedVersion.Status))

    $missingCorePath = Copy-AdapterVariant -Name 'missing-core-versions' -Mutate {
        param($adapter)
        $adapter.PSObject.Properties.Remove('supportedLabCoreVersions')
    }
    $missingCore = $null
    $missingCoreError = $null
    try {
        $missingCore = Test-SqlServerLabAdapter -Path $missingCorePath
    }
    catch {
        $missingCoreError = $_.Exception.Message
    }
    Add-CheckResult `
        -Name 'Fehlendes supportedLabCoreVersions crasht nicht und meldet ADAPTER_INVALID' `
        -Success ($null -eq $missingCoreError -and
            $missingCore.Status -eq 'ADAPTER_INVALID' -and
            (@($missingCore.Errors) -match 'Lab-Core-Version').Count -eq 0) `
        -Message ($missingCoreError ?? ("Status: {0}; Errors: {1}" -f $missingCore.Status, ($missingCore.Errors -join '; ')))

    $unknownRun = $null
    $unknownRunError = $null
    try {
        $unknownRun = Test-SqlServerLabAdapter -Path $exampleAdapterPath -RunId 'no-such-run' -StateRoot $temporaryRoot
    }
    catch {
        $unknownRunError = $_.Exception.Message
    }
    Add-CheckResult `
        -Name 'Unbekannte RunId liefert strukturierte Fehler statt Exception' `
        -Success ($null -eq $unknownRunError -and -not $unknownRun.IsReady -and
            (@($unknownRun.Errors) -match 'Run-Aufloesung').Count -gt 0) `
        -Message ($unknownRunError ?? ("Errors: {0}" -f ($unknownRun.Errors -join '; ')))

    $nullListCompatibility = & $module {
        Test-LabProjectAdapterRunCompatibility `
            -Adapter ([PSCustomObject]@{ supportedSqlVersions = $null; requiredCapabilities = $null }) `
            -RunTarget ([PSCustomObject]@{ Provider = 'docker' }) `
            -InstanceVersion '2022'
    }
    Add-CheckResult `
        -Name 'Fehlende Versions- und Capability-Listen erzeugen keine Scheinfehler' `
        -Success ($nullListCompatibility.IsCompatible -and $nullListCompatibility.Errors.Count -eq 0) `
        -Message ("Errors: {0}" -f ($nullListCompatibility.Errors -join '; '))

    if ($IsWindows) {
        $junctionTargetPath = Join-Path $temporaryRoot 'junction-target'
        Copy-Item -LiteralPath (Join-Path $exampleAdapterPath 'sql') -Destination $junctionTargetPath -Recurse
        $junctionAdapterPath = Join-Path $temporaryRoot 'junction-adapter'
        New-Item -Path $junctionAdapterPath -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $exampleAdapterPath 'adapter.json') -Destination (Join-Path $junctionAdapterPath 'adapter.json')
        New-Item -ItemType Junction -Path (Join-Path $junctionAdapterPath 'sql') -Target $junctionTargetPath | Out-Null
        try {
            $junction = Test-SqlServerLabAdapter -Path $junctionAdapterPath
            Add-CheckResult `
                -Name 'Junction im Adapter-Root verletzt die Pfadgrenze' `
                -Success ($junction.Status -eq 'PROJECT_ARTIFACT_SCOPE_VIOLATION' -and -not $junction.IsReady) `
                -Message ("Status: {0}" -f $junction.Status)
        }
        finally {
            # Junction vor dem rekursiven Cleanup entfernen, ohne dem Ziel zu folgen.
            (Get-Item -LiteralPath (Join-Path $junctionAdapterPath 'sql') -Force).Delete()
        }
    }
    else {
        Write-Host '  SKIP  Junction-Pruefung (nur unter Windows)' -ForegroundColor Yellow
    }

    $compatibility = & $module {
        $adapter = [PSCustomObject]@{
            supportedSqlVersions = @('2022')
            requiredCapabilities = @('container-linux', 'sqlcmd')
        }
        $incompatibleTarget = [PSCustomObject]@{ Provider = 'hyperv' }
        $incompatible = Test-LabProjectAdapterRunCompatibility `
            -Adapter $adapter `
            -RunTarget $incompatibleTarget `
            -InstanceVersion '2019'
        $compatibleTarget = [PSCustomObject]@{ Provider = 'docker' }
        $compatible = Test-LabProjectAdapterRunCompatibility `
            -Adapter ([PSCustomObject]@{
                supportedSqlVersions = @('2022')
                requiredCapabilities = @('container-linux')
            }) `
            -RunTarget $compatibleTarget `
            -InstanceVersion '2022-CU16'

        [PSCustomObject]@{
            IncompatibleRejected = -not $incompatible.IsCompatible -and $incompatible.Errors.Count -ge 2
            CompatibleAccepted   = $compatible.IsCompatible
        }
    }
    Add-CheckResult `
        -Name 'Versions- und Capability-Gate lehnt inkompatible Ziele ab' `
        -Success $compatibility.IncompatibleRejected
    Add-CheckResult `
        -Name 'Kompatibles Ziel inklusive CU-Bezeichner wird akzeptiert' `
        -Success $compatibility.CompatibleAccepted
}
catch {
    Add-CheckResult -Name 'Project Adapter Testausfuehrung' -Success $false -Message $_.Exception.Message
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

exit 0


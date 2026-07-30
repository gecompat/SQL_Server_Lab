#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Manifest-Builder, Schema- und Fachvalidierung ohne Labressourcen.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Add-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Success,
        [string]$Message
    )

    if ($Success) {
        $script:passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
        return
    }

    $failure = if ($Message) { "$Name - $Message" } else { $Name }
    $script:failures.Add($failure)
    Write-Host "  FAIL  $failure" -ForegroundColor Red
}

Write-Host ''
Write-Host 'SQL_Server_Lab - Manifest Builder Checks' -ForegroundColor Cyan

Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -ErrorAction Stop

foreach ($commandName in @('New-SqlServerLabManifest', 'Test-SqlServerLabManifest')) {
    Add-CheckResult `
        -Name "Export verfuegbar: $commandName" `
        -Success ([bool](Get-Command $commandName -Module SqlServerLab -ErrorAction SilentlyContinue))
}

$module = Get-Module SqlServerLab
$schemaSupport = & $module {
    Test-LabManifestSchemaInputSupport -RootSchema (Get-LabManifestSchema)
}
Add-CheckResult `
    -Name 'Alle aktuellen Schemaknoten werden vom Wizard unterstuetzt' `
    -Success $schemaSupport.IsSupported `
    -Message ($schemaSupport.Errors -join '; ')

$wizardDraft = & $module {
    $originalString = (Get-Command Read-LabString).ScriptBlock
    $originalConfirm = (Get-Command Read-LabConfirm).ScriptBlock
    try {
        Set-Item Function:Read-LabString -Value {
            param([string]$Prompt)
            switch -Regex ($Prompt) {
                '^manifest\.name$'                  { return 'wizard-check' }
                '^manifest\.instances\[1\]\.id$'      { return 'primary' }
                '^manifest\.instances\[1\]\.version$' { return '2025' }
                default { throw "Unerwartete Testeingabe: $Prompt" }
            }
        }
        Set-Item Function:Read-LabConfirm -Value { param() return $false }
        New-LabManifestDraft -SchemaReference './Schemas/lab-manifest.schema.json'
    }
    finally {
        Set-Item Function:Read-LabString -Value $originalString
        Set-Item Function:Read-LabConfirm -Value $originalConfirm
    }
}
$wizardResult = Test-SqlServerLabManifest -InputObject $wizardDraft
Add-CheckResult `
    -Name 'Schema-Wizard bewahrt eine einzelne Instanz als Array' `
    -Success ($wizardDraft.instances -is [array] -and
        $wizardDraft.instances.Count -eq 1 -and
        $wizardResult.IsValid) `
    -Message ($wizardResult.Errors -join '; ')

$spConfigure = & $module {
    $originalString = (Get-Command Read-LabString).ScriptBlock
    $script:ManifestBuilderReadHostCall = 0
    try {
        Set-Item Function:Read-Host -Value {
            $script:ManifestBuilderReadHostCall++
            if ($script:ManifestBuilderReadHostCall -eq 1) {
                return 'optimize for ad hoc workloads'
            }
            return ''
        }
        Set-Item Function:Read-LabString -Value { param() return '1' }

        $schema = Get-LabManifestSchema
        $node = $schema.definitions.serverConfig.properties.spConfigure
        Read-LabManifestSchemaValue `
            -Node $node `
            -RootSchema $schema `
            -Path 'manifest.instances[1].serverConfig.spConfigure'
    }
    finally {
        Remove-Item Function:Read-Host -Force -ErrorAction SilentlyContinue
        Set-Item Function:Read-LabString -Value $originalString
        Remove-Variable ManifestBuilderReadHostCall -Scope Script -ErrorAction SilentlyContinue
    }
}
Add-CheckResult `
    -Name 'Freie spConfigure-Schluessel werden erfasst' `
    -Success ($spConfigure.'optimize for ad hoc workloads' -eq 1)

$minimal = [ordered]@{
    name      = 'manifest-check'
    instances = @(
        [ordered]@{
            id       = 'primary'
            version  = '2025'
            provider = 'docker'
        }
    )
}
$minimalResult = Test-SqlServerLabManifest -InputObject $minimal
Add-CheckResult `
    -Name 'Minimales Manifest ist gueltig' `
    -Success $minimalResult.IsValid `
    -Message ($minimalResult.Errors -join '; ')

$unknownField = [ordered]@{
    name      = 'unknown-field'
    instances = @(
        [ordered]@{
            id       = 'primary'
            version  = '2025'
            provider = 'docker'
            unknown  = $true
        }
    )
}
$unknownResult = Test-SqlServerLabManifest -InputObject $unknownField
Add-CheckResult `
    -Name 'Unbekannte Felder werden vom Schema abgelehnt' `
    -Success (-not $unknownResult.IsValid -and $unknownResult.Errors -match 'Schema:') `
    -Message ($unknownResult.Errors -join '; ')

$duplicateIds = [ordered]@{
    name      = 'duplicate-ids'
    instances = @(
        [ordered]@{ id = 'primary'; version = '2025'; provider = 'docker' },
        [ordered]@{ id = 'primary'; version = '2025'; provider = 'docker' }
    )
}
$duplicateResult = Test-SqlServerLabManifest -InputObject $duplicateIds
Add-CheckResult `
    -Name 'Doppelte Instanz-IDs werden abgelehnt' `
    -Success (-not $duplicateResult.IsValid -and $duplicateResult.Errors -match 'nicht eindeutig') `
    -Message ($duplicateResult.Errors -join '; ')

$mixedProviders = [ordered]@{
    name      = 'mixed-providers'
    instances = @(
        [ordered]@{ id = 'docker'; version = '2025'; provider = 'docker' },
        [ordered]@{ id = 'podman'; version = '2025'; provider = 'podman' }
    )
}
$mixedResult = Test-SqlServerLabManifest -InputObject $mixedProviders
Add-CheckResult `
    -Name 'Gemischte Docker-/Podman-Provider werden akzeptiert' `
    -Success $mixedResult.IsValid `
    -Message ($mixedResult.Errors -join '; ')

$incompatibleDatabase = [ordered]@{
    name      = 'compatibility-check'
    instances = @(
        [ordered]@{
            id        = 'primary'
            version   = '2019'
            provider  = 'docker'
            databases = @(
                [ordered]@{
                    name    = 'AppDB'
                    options = [ordered]@{ compatibility = 170 }
                }
            )
        }
    )
}
$compatibilityResult = Test-SqlServerLabManifest -InputObject $incompatibleDatabase
Add-CheckResult `
    -Name 'Zu hohes Compatibility Level wird abgelehnt' `
    -Success (-not $compatibilityResult.IsValid -and $compatibilityResult.Errors -match 'zu hoch') `
    -Message ($compatibilityResult.Errors -join '; ')

$preparedField = [ordered]@{
    name      = 'prepared-field'
    instances = @(
        [ordered]@{
            id           = 'primary'
            version      = '2025'
            provider     = 'docker'
            serverConfig = [ordered]@{ sqlAgent = $true }
        }
    )
}
$preparedResult = Test-SqlServerLabManifest -InputObject $preparedField
Add-CheckResult `
    -Name 'Vorbereitete Runtimefelder erzeugen Warnungen' `
    -Success ($preparedResult.IsValid -and $preparedResult.Warnings -match 'noch nicht zuverlaessig') `
    -Message (($preparedResult.Errors + $preparedResult.Warnings) -join '; ')

$unsupportedSample = [ordered]@{
    name      = 'unsupported-sample'
    instances = @(
        [ordered]@{
            id        = 'primary'
            version   = '2022'
            provider  = 'docker'
            databases = @(
                [ordered]@{
                    name   = 'StackOverflow'
                    sample = [ordered]@{ id = 'stackoverflow-50gb'; variant = '10gb' }
                }
            )
        }
    )
}
$sampleResult = Test-SqlServerLabManifest -InputObject $unsupportedSample
Add-CheckResult `
    -Name 'Nicht provisionierbare Samplevarianten werden abgelehnt' `
    -Success (-not $sampleResult.IsValid -and $sampleResult.Errors -match 'kein direktes .bak-Backup') `
    -Message ($sampleResult.Errors -join '; ')

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-manifest-check-$([guid]::NewGuid().ToString('N'))"
$temporaryManifest = Join-Path $temporaryDirectory 'generated.json'
try {
    $null = New-Item -ItemType Directory -Path $temporaryDirectory -Force
    $saved = New-SqlServerLabManifest `
        -Path $temporaryManifest `
        -InputObject $minimal `
        -PassThru
    $roundTrip = Test-SqlServerLabManifest -Path $temporaryManifest

    Add-CheckResult `
        -Name 'Nichtinteraktiver Entwurf wird atomar gespeichert und erneut validiert' `
        -Success ((Test-Path -LiteralPath $temporaryManifest -PathType Leaf) -and
            $saved.name -eq $minimal.name -and
            $roundTrip.IsValid) `
        -Message ($roundTrip.Errors -join '; ')
}
finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "`nMANIFEST BUILDER CHECKS: FAIL ($passed bestanden, $($failures.Count) fehlgeschlagen)" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host "`nMANIFEST BUILDER CHECKS: PASS ($passed Pruefungen)" -ForegroundColor Green
exit 0

#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft zentrale Code-, Katalog- und Dokumentationsvertraege von SQL_Server_Lab.
.DESCRIPTION
    Die Pruefung mutiert keine Labressourcen. Sie validiert PowerShell-Syntax,
    Modul-Exports, JSON-Dateien, relative Schema-Referenzen, Provider-Metadaten,
    zentrale Dokumentationslinks und bekannte veraltete Beispiele.
#>
[CmdletBinding()]
param(
    [switch]$SkipModuleImport
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Add-ValidationResult {
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

    $failureMessage = if ($Message) { "$Name - $Message" } else { $Name }
    $script:failures.Add($failureMessage)
    Write-Host "  FAIL  $failureMessage" -ForegroundColor Red
}

function Get-RepositoryFiles {
    param(
        [Parameter(Mandatory)][string[]]$Extensions
    )

    Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
        Where-Object {
            $_.FullName -notmatch '[\\/]_QuellRepo[\\/]' -and
            $_.FullName -notmatch '[\\/]private_Note[\\/]' -and
            $_.Extension -in $Extensions
        }
}

Write-Host ''
Write-Host 'SQL_Server_Lab - Static Contract Validation' -ForegroundColor Cyan
Write-Host "Repository: $repoRoot" -ForegroundColor DarkGray

# =============================================================================
# 1. PowerShell-Syntax
# =============================================================================
Write-Host "`n[1] PowerShell-Syntax" -ForegroundColor Cyan

$powerShellFiles = @(Get-RepositoryFiles -Extensions @('.ps1', '.psm1', '.psd1'))
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )

    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $file.FullName)
    Add-ValidationResult `
        -Name "PowerShell parse: $relativePath" `
        -Success ($parseErrors.Count -eq 0) `
        -Message (($parseErrors | ForEach-Object { $_.Message }) -join '; ')
}

# =============================================================================
# 2. JSON-Syntax und Referenzen
# =============================================================================
Write-Host "`n[2] JSON und Schema-Referenzen" -ForegroundColor Cyan

$jsonRoots = @(
    Join-Path $repoRoot 'Catalogs'
    Join-Path $repoRoot 'Schemas'
)

$jsonFiles = @(
    foreach ($jsonRoot in $jsonRoots) {
        if (Test-Path -LiteralPath $jsonRoot) {
            Get-ChildItem -LiteralPath $jsonRoot -Recurse -Filter '*.json' -File
        }
    }
)

foreach ($file in $jsonFiles) {
    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $file.FullName)
    try {
        $json = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        Add-ValidationResult -Name "JSON parse: $relativePath" -Success $true

        foreach ($referenceName in @('$schema', '$ref')) {
            $reference = $json.PSObject.Properties[$referenceName].Value
            if (-not $reference -or $reference -match '^https?://' -or $reference -match '^#') {
                continue
            }

            $referenceWithoutFragment = ([string]$reference -split '#', 2)[0]
            if (-not $referenceWithoutFragment) {
                continue
            }

            $targetPath = Join-Path $file.DirectoryName $referenceWithoutFragment
            Add-ValidationResult `
                -Name "$referenceName target: $relativePath" `
                -Success (Test-Path -LiteralPath $targetPath -PathType Leaf) `
                -Message "Nicht gefunden: $referenceWithoutFragment"
        }
    }
    catch {
        Add-ValidationResult `
            -Name "JSON parse: $relativePath" `
            -Success $false `
            -Message $_.Exception.Message
    }
}

# =============================================================================
# 3. Modulmanifest und Exporte
# =============================================================================
Write-Host "`n[3] Modulmanifest und Exporte" -ForegroundColor Cyan

$moduleManifestPath = Join-Path $repoRoot 'SqlServerLab.psd1'
try {
    $manifestData = Import-PowerShellDataFile -LiteralPath $moduleManifestPath
    $expectedFunctions = @($manifestData.FunctionsToExport | Sort-Object -Unique)

    Add-ValidationResult `
        -Name 'FunctionsToExport enthaelt keine Duplikate' `
        -Success ($expectedFunctions.Count -eq @($manifestData.FunctionsToExport).Count)

    foreach ($removedPlaceholder in @('Install-LabSoftware', 'Invoke-LabCleanup', 'Invoke-LabRecovery')) {
        Add-ValidationResult `
            -Name "Nicht implementierter Export entfernt: $removedPlaceholder" `
            -Success ($removedPlaceholder -notin $expectedFunctions)
    }

    if (-not $SkipModuleImport) {
        Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
        Import-Module $moduleManifestPath -Force -ErrorAction Stop
        $actualFunctions = @(
            Get-Command -Module SqlServerLab -CommandType Function |
                Select-Object -ExpandProperty Name |
                Sort-Object -Unique
        )

        $missingFunctions = @($expectedFunctions | Where-Object { $_ -notin $actualFunctions })
        $unexpectedFunctions = @($actualFunctions | Where-Object { $_ -notin $expectedFunctions })

        Add-ValidationResult `
            -Name 'Alle exportierten Funktionen sind verfuegbar' `
            -Success ($missingFunctions.Count -eq 0) `
            -Message ($missingFunctions -join ', ')

        Add-ValidationResult `
            -Name 'Keine unerwarteten Funktionen exportiert' `
            -Success ($unexpectedFunctions.Count -eq 0) `
            -Message ($unexpectedFunctions -join ', ')
    }
}
catch {
    Add-ValidationResult `
        -Name 'Modulmanifest und Import' `
        -Success $false `
        -Message $_.Exception.Message
}

# =============================================================================
# 4. Provider-Metadaten
# =============================================================================
Write-Host "`n[4] Provider-Metadaten" -ForegroundColor Cyan

$providerDefinitions = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Providers') -Filter 'provider.json' -Recurse -File
foreach ($providerDefinitionFile in $providerDefinitions) {
    $providerDirectory = $providerDefinitionFile.DirectoryName
    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $providerDefinitionFile.FullName)

    try {
        $providerDefinition = Get-Content -LiteralPath $providerDefinitionFile.FullName -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
        Add-ValidationResult -Name "Provider JSON: $relativePath" -Success ([bool]$providerDefinition.name)

        if ($providerDefinition.module) {
            $modulePath = Join-Path $providerDirectory $providerDefinition.module
            Add-ValidationResult `
                -Name "Provider module: $($providerDefinition.name)" `
                -Success (Test-Path -LiteralPath $modulePath -PathType Leaf) `
                -Message "Nicht gefunden: $($providerDefinition.module)"
        }
    }
    catch {
        Add-ValidationResult `
            -Name "Provider JSON: $relativePath" `
            -Success $false `
            -Message $_.Exception.Message
    }
}

# =============================================================================
# 5. Zentrale Dateien und relative Markdown-Links
# =============================================================================
Write-Host "`n[5] Zentrale Dokumentation" -ForegroundColor Cyan

$coreFiles = @(
    'README.md'
    'Documentation/README.md'
    'Documentation/User/Getting_Started.md'
    'Documentation/Quality/KNOWN_LIMITATIONS.md'
    'Catalogs/README.md'
    'Public/README.md'
    'Schemas/README.md'
    'Tests/README.md'
    '.ai/PROJECT_CONTEXT.md'
    '.ai/WORKING_RULES.md'
    '.ai/repo_map.yaml'
    'CONTRIBUTING.md'
    'CHANGELOG.md'
    'SECURITY.md'
)

foreach ($relativePath in $coreFiles) {
    $fullPath = Join-Path $repoRoot $relativePath
    Add-ValidationResult `
        -Name "Core file: $relativePath" `
        -Success (Test-Path -LiteralPath $fullPath -PathType Leaf)
}

$coreMarkdownFiles = $coreFiles |
    Where-Object { $_ -like '*.md' } |
    ForEach-Object { Join-Path $repoRoot $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }

$linkPattern = '\[[^\]]+\]\(([^)]+)\)'
foreach ($markdownFile in $coreMarkdownFiles) {
    $content = Get-Content -LiteralPath $markdownFile -Raw -Encoding utf8
    $relativeMarkdownPath = [System.IO.Path]::GetRelativePath($repoRoot, $markdownFile)

    foreach ($match in [regex]::Matches($content, $linkPattern)) {
        $target = $match.Groups[1].Value.Trim()
        if (-not $target -or $target -match '^(https?://|mailto:|#)') {
            continue
        }

        $targetWithoutAnchor = ($target -split '#', 2)[0]
        if (-not $targetWithoutAnchor) {
            continue
        }

        $decodedTarget = [System.Uri]::UnescapeDataString($targetWithoutAnchor)
        $resolvedTarget = Join-Path (Split-Path -Parent $markdownFile) $decodedTarget

        Add-ValidationResult `
            -Name "Link: $relativeMarkdownPath -> $targetWithoutAnchor" `
            -Success (Test-Path -LiteralPath $resolvedTarget) `
            -Message 'Ziel existiert nicht'
    }
}

# =============================================================================
# 6. Bekannte veraltete Aussagen
# =============================================================================
Write-Host "`n[6] Veraltete Aussagen und Beispiele" -ForegroundColor Cyan

$rootReadme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw -Encoding utf8
$gettingStarted = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\User\Getting_Started.md') -Raw -Encoding utf8
$testsReadme = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests\README.md') -Raw -Encoding utf8

Add-ValidationResult `
    -Name 'Root-README ist nicht mehr PLANNING_FOUNDATION' `
    -Success ($rootReadme -notmatch 'PLANNING_FOUNDATION')

Add-ValidationResult `
    -Name 'Keine lokale Entwicklerpfad-Vorgabe im Getting Started' `
    -Success ($gettingStarted -notmatch '(?i)E:\\GIT\\gecomp\\publ')

Add-ValidationResult `
    -Name 'SQL_SERVER_LAB_PATH wird nicht als implementiert dokumentiert' `
    -Success ($gettingStarted -notmatch '\|\s*`SQL_SERVER_LAB_PATH`\s*\|')

Add-ValidationResult `
    -Name 'Kein veraltetes Restore-Beispiel mit -RunId' `
    -Success ($gettingStarted -notmatch '(?is)```powershell.*?Restore-LabDatabase\s+-RunId')

Add-ValidationResult `
    -Name 'Kein veraltetes Restore-Beispiel mit -BackupUrl' `
    -Success ($gettingStarted -notmatch '(?is)```powershell.*?Restore-LabDatabase.*?-BackupUrl')

Add-ValidationResult `
    -Name 'Smoke-Test behauptet nicht alle Provider zu provisionieren' `
    -Success ($testsReadme -notmatch '(?i)prueft\s+ALLE\s+installierten\s+Provider')

# =============================================================================
# 7. Beispielmanifeste und referenzierte PostProvision-Dateien
# =============================================================================
Write-Host "`n[7] Beispielmanifeste" -ForegroundColor Cyan

$exampleManifests = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Schemas') -Filter 'example-*.json' -File
foreach ($manifestFile in $exampleManifests) {
    try {
        $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        foreach ($instance in @($manifest.instances)) {
            foreach ($scriptPath in @($instance.postProvision)) {
                if (-not $scriptPath) {
                    continue
                }
                $resolvedScriptPath = if ([System.IO.Path]::IsPathRooted($scriptPath)) {
                    $scriptPath
                }
                else {
                    Join-Path $manifestFile.DirectoryName $scriptPath
                }

                Add-ValidationResult `
                    -Name "PostProvision target: $($manifestFile.Name) -> $scriptPath" `
                    -Success (Test-Path -LiteralPath $resolvedScriptPath -PathType Leaf) `
                    -Message 'Referenzierte SQL-Datei fehlt'
            }
        }
    }
    catch {
        Add-ValidationResult `
            -Name "Example manifest: $($manifestFile.Name)" `
            -Success $false `
            -Message $_.Exception.Message
    }
}

# =============================================================================
# Ergebnis
# =============================================================================
Write-Host ''
Write-Host "Bestanden: $passed" -ForegroundColor Green
Write-Host "Fehlgeschlagen: $($failures.Count)" -ForegroundColor $(if ($failures.Count -eq 0) { 'Green' } else { 'Red' })

if ($failures.Count -gt 0) {
    Write-Host ''
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host 'Alle statischen Vertragspruefungen waren erfolgreich.' -ForegroundColor Green
exit 0

#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft zentrale Code-, Katalog- und Dokumentationsvertraege von SQL_Server_Lab.
.DESCRIPTION
    Die Pruefung mutiert keine Labressourcen. Sie validiert PowerShell-Syntax,
    Modul-Exports, JSON-Dateien, relative Schema-Referenzen, Provider-Metadaten,
    Command-Hilfe, zentrale Dokumentationslinks und bekannte veraltete Beispiele.
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
            $_.FullName -notmatch '[\\/]\.secrets[\\/]' -and
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

$schemaValidationTargets = @(
    @{ Data = 'Catalogs/sql-server-versions.json'; Schema = 'Schemas/version-catalog.schema.json' }
    @{ Data = 'Catalogs/sample-databases.json'; Schema = 'Schemas/sample-databases.schema.json' }
) + @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Schemas') -Filter 'example-*.json' -File |
        ForEach-Object {
            @{ Data = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName); Schema = 'Schemas/lab-manifest.schema.json' }
        }
)

foreach ($target in $schemaValidationTargets) {
    $dataPath = Join-Path $repoRoot $target.Data
    $schemaPath = Join-Path $repoRoot $target.Schema
    try {
        $valid = Get-Content -LiteralPath $dataPath -Raw -Encoding utf8 |
            Test-Json -SchemaFile $schemaPath -ErrorAction Stop
        Add-ValidationResult `
            -Name "Schema: $($target.Data)" `
            -Success $valid `
            -Message "Entspricht nicht $($target.Schema)"
    }
    catch {
        Add-ValidationResult `
            -Name "Schema: $($target.Data)" `
            -Success $false `
            -Message $_.Exception.Message
    }
}

$manifestSchema = Get-Content -LiteralPath (Join-Path $repoRoot 'Schemas/lab-manifest.schema.json') -Raw -Encoding utf8 |
    ConvertFrom-Json -Depth 100
$serverConfigProperties = $manifestSchema.definitions.serverConfig.properties.PSObject.Properties
$unclassifiedServerConfig = @(
    $serverConfigProperties | Where-Object {
        $_.Value.'x-runtimeStatus' -notin @('executable', 'reserved', 'partially-executable')
    } | Select-Object -ExpandProperty Name
)
Add-ValidationResult `
    -Name 'Alle serverConfig-Felder besitzen x-runtimeStatus' `
    -Success ($unclassifiedServerConfig.Count -eq 0) `
    -Message ($unclassifiedServerConfig -join ', ')

$reservedServerConfig = @(
    $serverConfigProperties | Where-Object { $_.Value.'x-runtimeStatus' -eq 'reserved' } |
        Select-Object -ExpandProperty Name
)
$reservedExampleHits = @()
foreach ($manifestFile in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Schemas') -Filter 'example-*.json' -File) {
    $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
    foreach ($instance in @($manifest.instances)) {
        foreach ($fieldName in $reservedServerConfig) {
            if ($instance.serverConfig -and $instance.serverConfig.PSObject.Properties.Name -contains $fieldName) {
                $reservedExampleHits += "$($manifestFile.Name):$fieldName"
            }
        }
        if ($instance.serverConfig.externalScripts.installMethod -eq 'pre-built') {
            $reservedExampleHits += "$($manifestFile.Name):externalScripts.installMethod=pre-built"
        }
    }
}
Add-ValidationResult `
    -Name 'Beispielmanifeste verwenden keine reservierten serverConfig-Felder' `
    -Success ($reservedExampleHits.Count -eq 0) `
    -Message ($reservedExampleHits -join ', ')

$sampleCatalog = Get-Content -LiteralPath (Join-Path $repoRoot 'Catalogs/sample-databases.json') -Raw -Encoding utf8 |
    ConvertFrom-Json -Depth 100
$invalidExecutableSamples = @()
$invalidArtifactContracts = @()
foreach ($sample in @($sampleCatalog.databases)) {
    foreach ($variant in $sample.versions.PSObject.Properties) {
        $definition = $variant.Value
        if ($definition.runtimeStatus -eq 'executable') {
            $hasIntegrityPath = ([string]$definition.sha256 -match '^[A-Fa-f0-9]{64}$') -or
                $definition.trustPolicy -eq 'interactive-once'
            if ($definition.artifactType -ne 'backup' -or
                [string]$definition.installation.kind -ne 'backup' -or
                [string]$definition.url -notmatch '(?i)\.bak$' -or
                -not $hasIntegrityPath) {
                $invalidExecutableSamples += "$($sample.id):$($variant.Name)"
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$definition.artifactType) -or
            [string]::IsNullOrWhiteSpace([string]$definition.handlerContractVersion) -or
            @($definition.expectedOutputs).Count -eq 0 -or
            [string]$definition.installation.kind -ne [string]$definition.artifactType) {
            $invalidArtifactContracts += "$($sample.id):$($variant.Name)"
            continue
        }

        $outputNames = @($definition.expectedOutputs | ForEach-Object { [string]$_.name })
        if (@($outputNames | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
            $invalidArtifactContracts += "$($sample.id):$($variant.Name) (doppelte Outputs)"
        }

        $hasHash = [string]$definition.sha256 -match '^[A-Fa-f0-9]{64}$'
        if (($hasHash -and ([string]::IsNullOrWhiteSpace([string]$definition.integrityOrigin) -or
                    $definition.trustPolicy -ne 'catalog-only')) -or
            (-not $hasHash -and ($null -ne $definition.integrityOrigin -or
                    $definition.trustPolicy -ne 'interactive-once'))) {
            $invalidArtifactContracts += "$($sample.id):$($variant.Name) (Integrity/Trust)"
        }
    }
}
Add-ValidationResult `
    -Name 'Ausfuehrbare Sample-Varianten sind Backup-Handler mit SHA-256 oder Trust-Pfad' `
    -Success ($invalidExecutableSamples.Count -eq 0) `
    -Message ($invalidExecutableSamples -join ', ')
Add-ValidationResult `
    -Name 'Sample-Varianten folgen dem typisierten Artifact-Vertrag' `
    -Success ($invalidArtifactContracts.Count -eq 0) `
    -Message ($invalidArtifactContracts -join ', ')

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

    foreach ($locale in @('de-DE', 'en-US')) {
        $aboutHelpPath = Join-Path $repoRoot $locale 'about_SqlServerLab.help.txt'
        $aboutHelpExists = Test-Path -LiteralPath $aboutHelpPath -PathType Leaf
        Add-ValidationResult `
            -Name "Modulhilfe vorhanden: $locale/about_SqlServerLab" `
            -Success $aboutHelpExists

        if ($aboutHelpExists) {
            $aboutHelpText = Get-Content -LiteralPath $aboutHelpPath -Raw -Encoding utf8
            $missingAboutCommands = @(
                $expectedFunctions |
                    Where-Object { $aboutHelpText -notmatch [regex]::Escape($_) }
            )
            Add-ValidationResult `
                -Name "Modulhilfe listet alle Exporte: $locale" `
                -Success ($missingAboutCommands.Count -eq 0) `
                -Message ($missingAboutCommands -join ', ')
        }
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

        $approvedVerbs = @(Get-Verb | Select-Object -ExpandProperty Verb)
        $commonParameters = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
            @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)

        foreach ($commandName in $expectedFunctions) {
            $command = Get-Command $commandName -Module SqlServerLab -ErrorAction Stop
            $help = Get-Help $commandName -Full -ErrorAction Stop
            $verb = ($commandName -split '-', 2)[0]
            $noun = ($commandName -split '-', 2)[1]
            $synopsis = ([string]$help.Synopsis -replace '\s+', ' ').Trim()
            $description = @($help.description | ForEach-Object { $_.Text }) -join ' '
            $outputTypes = @($help.returnValues.returnValue.type.name) -join ', '
            $missingParameterHelp = @()

            foreach ($parameterName in @($command.Parameters.Keys | Where-Object { $_ -notin $commonParameters })) {
                $parameterHelp = $help.parameters.parameter |
                    Where-Object { $_.Name -eq $parameterName } |
                    Select-Object -First 1
                $parameterDescription = @($parameterHelp.description | ForEach-Object { $_.Text }) -join ' '
                if ([string]::IsNullOrWhiteSpace($parameterDescription)) {
                    $missingParameterHelp += $parameterName
                }
            }

            $helpProblems = @()
            if ($verb -notin $approvedVerbs) { $helpProblems += "Verb '$verb' ist nicht zugelassen" }
            if ($noun -notmatch '^SqlServerLab') { $helpProblems += "Nomen '$noun' beginnt nicht mit SqlServerLab" }
            if ($command.Source -ne 'SqlServerLab') { $helpProblems += "Source ist '$($command.Source)'" }
            if ([string]::IsNullOrWhiteSpace($synopsis) -or $synopsis -match "^$([regex]::Escape($commandName)) \[") {
                $helpProblems += 'Synopsis fehlt oder ist automatisch erzeugt'
            }
            if ([string]::IsNullOrWhiteSpace($description)) { $helpProblems += 'Description fehlt' }
            if (@($help.examples.example).Count -eq 0) { $helpProblems += 'Example fehlt' }
            if ([string]::IsNullOrWhiteSpace($outputTypes)) { $helpProblems += 'Outputs fehlt' }
            if ($missingParameterHelp.Count -gt 0) {
                $helpProblems += "Parameterhilfe fehlt: $($missingParameterHelp -join ', ')"
            }

            Add-ValidationResult `
                -Name "Command-Hilfe und Benennung: $commandName" `
                -Success ($helpProblems.Count -eq 0) `
                -Message ($helpProblems -join '; ')
        }

        $moduleHelp = Get-Help about_SqlServerLab -ErrorAction SilentlyContinue
        Add-ValidationResult `
            -Name 'Get-Help about_SqlServerLab ist verfuegbar' `
            -Success ($null -ne $moduleHelp -and $moduleHelp.Name -eq 'about_SqlServerLab')
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
    'Documentation/Architecture/ARCHITECTURE.md'
    'Documentation/Standards/POWERSHELL_COMMAND_AND_HELP_STANDARD.md'
    'Documentation/User/README.md'
    'Documentation/User/INSTALLATION_WINDOWS.md'
    'Documentation/User/INSTALLATION_LINUX.md'
    'Documentation/User/Getting_Started.md'
    'Documentation/Development/README.md'
    'Documentation/Development/DEVELOPMENT_AND_TEST_SETUP_WINDOWS.md'
    'Documentation/Development/DEVELOPMENT_AND_TEST_SETUP_LINUX.md'
    'Documentation/HowTo/PODMAN_WINDOWS_NETWORKING.md'
    'Documentation/HowTo/MEDIA_ROOT_LAYOUT.md'
    'Documentation/Quality/KNOWN_LIMITATIONS.md'
    'Catalogs/README.md'
    'Public/README.md'
    'Schemas/README.md'
    'Tests/README.md'
    'Tools/README.md'
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

$apiIndexFiles = @(
    'README.md'
    'Documentation/README.md'
    'Documentation/Architecture/ARCHITECTURE.md'
    'Public/README.md'
)

foreach ($relativePath in $apiIndexFiles) {
    $apiIndexText = Get-Content -LiteralPath (Join-Path $repoRoot $relativePath) -Raw -Encoding utf8
    $missingExports = @(
        $expectedFunctions |
            Where-Object { $apiIndexText -notmatch [regex]::Escape($_) }
    )
    Add-ValidationResult `
        -Name "API-Index listet alle Exporte: $relativePath" `
        -Success ($missingExports.Count -eq 0) `
        -Message ($missingExports -join ', ')
}

# =============================================================================
# 6. Bekannte veraltete Aussagen
# =============================================================================
Write-Host "`n[6] Veraltete Aussagen und Beispiele" -ForegroundColor Cyan

$rootReadme = Get-Content -LiteralPath (Join-Path $repoRoot 'README.md') -Raw -Encoding utf8
$gettingStarted = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\User\Getting_Started.md') -Raw -Encoding utf8
$testsReadme = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests\README.md') -Raw -Encoding utf8

$legacyPublicCommands = @(
    'New-LabManifest'
    'Test-LabManifest'
    'New-LabDatabase'
    'Restore-LabDatabase'
    'Invoke-LabScript'
    'Test-LabResources'
)
$legacyCommandAllowlist = @(
    'CHANGELOG.md'
    'Documentation/Standards/POWERSHELL_COMMAND_AND_HELP_STANDARD.md'
    'Tests/Static/Invoke-DocumentationChecks.ps1'
)
$legacyCommandHits = @(
    Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
        Where-Object {
            $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName) -replace '\\', '/'
            $_.Extension -in @('.md', '.txt', '.ps1', '.psm1', '.psd1', '.json', '.yaml', '.yml') -and
                $relativePath -notmatch '^(?:_QuellRepo|private_Note|\.secrets)[\\/]' -and
                $relativePath -notin $legacyCommandAllowlist
        } |
        ForEach-Object {
            $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName) -replace '\\', '/'
            $text = Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8
            foreach ($legacyCommand in $legacyPublicCommands) {
                $pattern = '(?<![A-Za-z0-9_-])' + [regex]::Escape($legacyCommand) + '(?![A-Za-z0-9_-])'
                if ($text -match $pattern) {
                    "$relativePath`: $legacyCommand"
                }
            }
        }
)

Add-ValidationResult `
    -Name 'Keine alten Public-Command-Namen in aktiven Dateien' `
    -Success ($legacyCommandHits.Count -eq 0) `
    -Message ($legacyCommandHits -join '; ')

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
    -Name 'Getting Started dokumentiert RunId-basierten Restore' `
    -Success ($gettingStarted -match '(?is)Restore-SqlServerLabDatabase\s+.*?-RunId')

Add-ValidationResult `
    -Name 'Kein veraltetes Restore-Beispiel mit -BackupUrl' `
    -Success ($gettingStarted -notmatch '(?is)```powershell.*?Restore-SqlServerLabDatabase.*?-BackupUrl')

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

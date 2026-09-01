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
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs,
    [switch]$SkipModuleImport
)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'
if ($showHelpRequested) {
    Get-Help -Full -Name $PSCommandPath | Out-Host
    return
}


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
            $_.FullName -notmatch '[\\/]\.artifacts[\\/]' -and
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
    @{ Data = 'Catalogs/software.json'; Schema = 'Schemas/software-catalog.schema.json' }
) + @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Schemas') -Filter 'example-*.json' -File |
        ForEach-Object {
            @{ Data = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName); Schema = 'Schemas/lab-manifest.schema.json' }
        }
)

$manifestSchemaPath = Join-Path $repoRoot 'Schemas/lab-manifest.schema.json'
$manifestValidationSchema = $null
if (Test-Path -LiteralPath $manifestSchemaPath -PathType Leaf) {
    $manifestValidationSchemaObject = Get-Content -LiteralPath $manifestSchemaPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
    $storageIntentSchemaPath = Join-Path $repoRoot 'Schemas/lab-storage-intent.schema.json'
    if (Test-Path -LiteralPath $storageIntentSchemaPath -PathType Leaf) {
        $storageIntentSchema = Get-Content -LiteralPath $storageIntentSchemaPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        $storageIntentSchema.PSObject.Properties.Remove('$schema')
        $storageIntentSchema.PSObject.Properties.Remove('$id')
        $manifestValidationSchemaObject.definitions | Add-Member -MemberType NoteProperty -Name storageIntent -Value $storageIntentSchema -Force
        $manifestValidationSchemaObject.definitions.instance.properties.storageIntent.PSObject.Properties['$ref'].Value = '#/definitions/storageIntent'
        $manifestValidationSchema = $manifestValidationSchemaObject | ConvertTo-Json -Depth 100
    }
}

foreach ($target in $schemaValidationTargets) {
    $dataPath = Join-Path $repoRoot $target.Data
    $schemaPath = Join-Path $repoRoot $target.Schema
    try {
        $dataJson = Get-Content -LiteralPath $dataPath -Raw -Encoding utf8
        $valid = if ($target.Schema -eq 'Schemas/lab-manifest.schema.json' -and $manifestValidationSchema) {
            $dataJson | Test-Json -Schema $manifestValidationSchema -ErrorAction Stop
        }
        else {
            $dataJson | Test-Json -SchemaFile $schemaPath -ErrorAction Stop
        }
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
$externalScriptsProperties = $manifestSchema.definitions.serverConfig.properties.externalScripts.properties
$installMethodValueStatus = $externalScriptsProperties.installMethod.'x-runtimeValueStatus'
Add-ValidationResult `
    -Name 'Reservierte serverConfig-Vertraege sind vollstaendig maschinenlesbar' `
    -Success ($externalScriptsProperties.customImage.'x-runtimeStatus' -eq 'reserved' -and
        $installMethodValueStatus.'post-start' -eq 'executable' -and
        $installMethodValueStatus.'custom-image' -eq 'reserved' -and
        $installMethodValueStatus.'pre-built' -eq 'reserved' -and
        @($externalScriptsProperties.installMethod.enum).Count -eq @($installMethodValueStatus.PSObject.Properties).Count) `
    -Message 'customImage oder x-runtimeValueStatus fuer installMethod ist unvollstaendig.'
$reservedExampleHits = @()
foreach ($manifestFile in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Schemas') -Filter 'example-*.json' -File) {
    $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
    foreach ($instance in @($manifest.instances)) {
        foreach ($fieldName in $reservedServerConfig) {
            if ($instance.serverConfig -and $instance.serverConfig.PSObject.Properties.Name -contains $fieldName) {
                $reservedExampleHits += "$($manifestFile.Name):$fieldName"
            }
        }
        if ($instance.serverConfig.externalScripts.installMethod -in @('custom-image', 'pre-built')) {
            $reservedExampleHits += "$($manifestFile.Name):externalScripts.installMethod=$($instance.serverConfig.externalScripts.installMethod)"
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
            $expectedExtension = switch ([string]$definition.artifactType) {
                'backup' { '\.bak$' }
                'archive-backup' { '\.(zip|7z)$' }
                'sql-script' { '\.sql$' }
                default { $null }
            }
            if ([string]$definition.artifactType -notin @('backup', 'archive-backup', 'sql-script') -or
                [string]$definition.installation.kind -ne [string]$definition.artifactType -or
                -not $expectedExtension -or
                [string]$definition.url -notmatch "(?i)$expectedExtension" -or
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
    -Name 'Ausfuehrbare Sample-Varianten haben einen freigegebenen Handler mit SHA-256 oder Trust-Pfad' `
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
    'AGENTS.md'
    'README.md'
    'Documentation/README.md'
    'Documentation/Architecture/ARCHITECTURE.md'
    'Documentation/Architecture/LAB_DATA_AND_NATIVE_RUNTIME_STORAGE_DECISION.md'
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
    'Documentation/HowTo/HYPERV_WINDOWS_IMAGE_BUILD.md'
    'Documentation/Quality/KNOWN_LIMITATIONS.md'
    'Documentation/Quality/COST_EFFICIENT_DEVELOPMENT.md'
    'Documentation/Quality/LOCAL_VALIDATION_STRATEGY.md'
    'Documentation/Project_Planning/README.md'
    'Documentation/Project_Planning/DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md'
    'Documentation/Project_Planning/FUTURE_UI_WORKFLOW_PLAN_2026-08-08.md'
    'Documentation/Project_Planning/MASTER_IMPLEMENTATION_PLAN.md'
    'Documentation/Architecture/FUTURE_USE_CASES_AND_EXTENSION_GUARDRAILS.md'
    'Catalogs/README.md'
    'Public/README.md'
    'Schemas/README.md'
    'Tests/README.md'
    'Tools/README.md'
    '.ai/PROJECT_CONTEXT.md'
    '.ai/MODEL_ROUTING_POLICY.md'
    '.ai/WORKING_RULES.md'
    '.ai/repo_map.yaml'
    '.ai/IDENTITY_AND_ARTIFACT_REGISTRATION.md'
    '.ai/foundation/FOUNDATION_RULESET.md'
    '.ai/foundation/AI_REPOSITORY_FOUNDATION_NOTICE.md'
    '.ai/foundation/PROJECT_RULES.md'
    '.ai/foundation/SEMANTIC_INTEGRATION_POLICY.md'
    '.ai/foundation/PERSISTENT_IDENTITY_POLICY.md'
    '.ai/foundation/ARTIFACT_REGISTRATION_POLICY.md'
    '.ai/foundation/CENTRAL_ARTIFACT_REGISTRY_POLICY.md'
    '.ai/foundation/UPGRADE_APPLICABILITY_POLICY.md'
    '.ai/foundation/REPOSITORY_CONTINUITY_POLICY.md'
    '.ai/foundation/feature_catalog.json'
    '.ai/foundation/schemas/artifact-record.schema.json'
    '.ai/foundation/schemas/artifact-registry.schema.json'
    '.ai/foundation/schemas/artifact-registry-v2.schema.json'
    '.ai/foundation/schemas/artifact-registration-request.schema.json'
    '.ai/foundation/schemas/feature-catalog.schema.json'
    '.ai/foundation/schemas/upgrade-assessment.schema.json'
    '.ai/foundation/WORKING_RULES.md'
    '.ai/foundation/MODEL_ROUTING_POLICY.md'
    '.ai/foundation/VALIDATION_POLICY.md'
    '.ai/foundation/DATA_PRIVACY_AND_CONFIDENTIALITY.md'
    '.ai/foundation/SECURITY_AND_SAFE_OPERATIONS.md'
    '.ai/foundation/DOCUMENTATION_POLICY.md'
    '.ai/foundation/THIRD_PARTY_AND_LICENSING.md'
    '.ai/foundation/SOURCE_AND_EVIDENCE_POLICY.md'
    '.ai/foundation/DEPENDENCY_POLICY.md'
    '.ai/foundation/repo_map.yaml'
    '.github/copilot-instructions.md'
    'ops/sql-cu-policy.md'
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
$documentationIndex = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\README.md') -Raw -Encoding utf8
$gettingStarted = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\User\Getting_Started.md') -Raw -Encoding utf8
$sampleWizardArchitecture = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Architecture\SAMPLE_DATABASE_PROVISIONING_AND_MANIFEST_WIZARD.md') -Raw -Encoding utf8
$testsReadme = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests\README.md') -Raw -Encoding utf8
$localValidationStrategy = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Quality\LOCAL_VALIDATION_STRATEGY.md') -Raw -Encoding utf8
$repositoryContinuityRunbook = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Quality\REPOSITORY_CONTINUITY_RUNBOOK.md') -Raw -Encoding utf8
$costEfficientDevelopment = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Quality\COST_EFFICIENT_DEVELOPMENT.md') -Raw -Encoding utf8
$agentContract = Get-Content -LiteralPath (Join-Path $repoRoot 'AGENTS.md') -Raw -Encoding utf8
$modelRoutingPolicy = Get-Content -LiteralPath (Join-Path $repoRoot '.ai\MODEL_ROUTING_POLICY.md') -Raw -Encoding utf8
$projectContext = Get-Content -LiteralPath (Join-Path $repoRoot '.ai\PROJECT_CONTEXT.md') -Raw -Encoding utf8
$repoMap = Get-Content -LiteralPath (Join-Path $repoRoot '.ai\repo_map.yaml') -Raw -Encoding utf8
$foundationRuleset = Get-Content -LiteralPath (Join-Path $repoRoot '.ai\foundation\FOUNDATION_RULESET.md') -Raw -Encoding utf8
$foundationRepoMap = Get-Content -LiteralPath (Join-Path $repoRoot '.ai\foundation\repo_map.yaml') -Raw -Encoding utf8
$foundationNotice = Get-Content -LiteralPath (Join-Path $repoRoot '.ai\foundation\AI_REPOSITORY_FOUNDATION_NOTICE.md') -Raw -Encoding utf8
$foundationFeatureCatalog = Get-Content -LiteralPath (Join-Path $repoRoot '.ai\foundation\feature_catalog.json') -Raw -Encoding utf8
$identityRegistrationMapping = Get-Content -LiteralPath (Join-Path $repoRoot '.ai\IDENTITY_AND_ARTIFACT_REGISTRATION.md') -Raw -Encoding utf8
$copilotAdapter = Get-Content -LiteralPath (Join-Path $repoRoot '.github\copilot-instructions.md') -Raw -Encoding utf8
$sqlCuPolicy = Get-Content -LiteralPath (Join-Path $repoRoot 'ops\sql-cu-policy.md') -Raw -Encoding utf8
$masterImplementationPlan = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Project_Planning\MASTER_IMPLEMENTATION_PLAN.md') -Raw -Encoding utf8
$developmentExecutionPlan = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Project_Planning\DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md') -Raw -Encoding utf8
$persistentStorageBacklog = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Project_Planning\PERSISTENT_STORAGE_REUSE_AND_LAB_DATA_BACKLOG.md') -Raw -Encoding utf8
$labDataResidencyDecision = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Architecture\LAB_DATA_AND_NATIVE_RUNTIME_STORAGE_DECISION.md') -Raw -Encoding utf8
$batchWorkflowPlan = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Project_Planning\PROVIDER_NEUTRAL_BATCH_QUEUE_RESUME_WORKFLOW_2026-08-13.md') -Raw -Encoding utf8
$futureUseCases = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Architecture\FUTURE_USE_CASES_AND_EXTENSION_GUARDRAILS.md') -Raw -Encoding utf8
$knownLimitations = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Quality\KNOWN_LIMITATIONS.md') -Raw -Encoding utf8
$hyperVManifestRuntime = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\New-SqlServerLab.ps1') -Raw -Encoding utf8
$hyperVLabEnvironmentRuntime = Get-Content -LiteralPath (Join-Path $repoRoot 'Private\HyperVLabEnvironment.ps1') -Raw -Encoding utf8
$latestValidationResult = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Documentation\Quality') -Filter 'VALIDATION_RESULT_*.md' -File |
    Sort-Object -Property Name -Descending |
    Select-Object -First 1
$latestValidationMessage = if ($latestValidationResult) {
    "Erwartet: $($latestValidationResult.Name)"
}
else {
    'Kein Validation-Report vorhanden'
}

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
                $relativePath -notmatch '^(?:_QuellRepo|private_Note|\.secrets|\.artifacts)[\\/]' -and
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
    -Name 'Dokumentationsindex nennt die aktuelle Zahl oeffentlicher Exporte' `
    -Success ($documentationIndex -match [regex]::Escape("| Öffentliche API | $($expectedFunctions.Count) exportierte Funktionen |")) `
    -Message "Erwartet: $($expectedFunctions.Count)"

Add-ValidationResult `
    -Name 'Lokale Validierungsstrategie beschreibt den Matrixeinstieg korrekt' `
    -Success ($localValidationStrategy -match 'Invoke-SmokeMatrix\.ps1' -and $localValidationStrategy -notmatch 'kein übergeordnetes Skript')

Add-ValidationResult `
    -Name 'Agentenvertrag bindet Modellrouting und kosteneffiziente Tests ein' `
    -Success ($agentContract -match [regex]::Escape('.ai/MODEL_ROUTING_POLICY.md') -and
        $agentContract -match [regex]::Escape('Documentation/Quality/COST_EFFICIENT_DEVELOPMENT.md'))

$foundationBridgeBeginCount = ([regex]::Matches($agentContract, '<!-- AI_REPOSITORY_FOUNDATION:BEGIN v1 -->')).Count
$foundationBridgeEndCount = ([regex]::Matches($agentContract, '<!-- AI_REPOSITORY_FOUNDATION:END -->')).Count
Add-ValidationResult `
    -Name 'Agentenvertrag enthaelt genau einen Foundation-Bridge-Block' `
    -Success ($foundationBridgeBeginCount -eq 1 -and
        $foundationBridgeEndCount -eq 1 -and
        $agentContract -match [regex]::Escape('.ai/foundation/FOUNDATION_RULESET.md')) `
    -Message "BEGIN=$foundationBridgeBeginCount; END=$foundationBridgeEndCount"

Add-ValidationResult `
    -Name 'Foundation-Ruleset, Index und Feature-Katalog sind auf Version 1.7.0 gebunden' `
    -Success ($foundationRuleset -match 'Ruleset version: 1\.7\.0' -and
        $foundationRepoMap -match 'foundation_ruleset_version: 1\.7\.0' -and
        $foundationFeatureCatalog -match '"ruleset_version"\s*:\s*"1\.7\.0"' -and
        $foundationRuleset -match [regex]::Escape('UPGRADE_APPLICABILITY_POLICY.md') -and
        $foundationRuleset -match [regex]::Escape('REPOSITORY_CONTINUITY_POLICY.md'))

Add-ValidationResult `
    -Name 'Foundation-Provenienz enthaelt den vollstaendigen MIT-Hinweis' `
    -Success ($foundationNotice -match [regex]::Escape('Copyright (c) 2026 Gerhard P') -and
        $foundationNotice -match [regex]::Escape('Permission is hereby granted, free of charge') -and
        $foundationNotice -match [regex]::Escape('THE SOFTWARE IS PROVIDED "AS IS"'))

Add-ValidationResult `
    -Name 'Repo-Map dokumentiert Foundation-Quelle, Adapter und semantische Zuordnung' `
    -Success ($repoMap -match 'source_commit: d49f978f33001fcc098998ff7c04ffb209b28033' -and
        $repoMap -match 'ruleset_version: "1\.7\.0"' -and
        $repoMap -match 'github-copilot' -and
        $repoMap -match 'sql_cu_watch_policy: ops/sql-cu-policy\.md' -and
        $repoMap -match 'unresolved_conflicts: \[\]')

Add-ValidationResult `
    -Name 'Foundation-Upgrade bewertet alle sechs Kandidaten ohne stille Auslassung' `
    -Success ($repoMap -match 'artifact-registration: ALREADY_EQUIVALENT' -and
        $repoMap -match 'central-artifact-registry: NOT_APPLICABLE' -and
        $repoMap -match 'layered-validation: APPLY_DEFAULT' -and
        $repoMap -match 'repository-continuity-break-glass: RECOMMENDED' -and
        $repoMap -match 'semantic-integration: APPLY_DEFAULT' -and
        $repoMap -match 'semantic-upgrade-applicability: APPLY_DEFAULT')

Add-ValidationResult `
    -Name 'Repository-Continuity ist mit unveraenderlichem Kernschutz und PR-only Break-Glass umgesetzt' `
    -Success ($repoMap -match 'repository-continuity-break-glass:\s*\r?\n\s+decision: IMPLEMENTED' -and
        $repoMap -match 'core_safety_ruleset:' -and
        $repoMap -match 'bypass_actors: \[\]' -and
        $repoMap -match 'required_status_check: PR Gate' -and
        $repoMap -match 'bypass_mode: pull_request' -and
        $repositoryContinuityRunbook -match 'VALIDATION_FAILURE' -and
        $repositoryContinuityRunbook -match 'INFRASTRUCTURE_UNAVAILABLE' -and
        $repositoryContinuityRunbook -match 'UNKNOWN' -and
        $repositoryContinuityRunbook -match 'Core safety - main' -and
        $repositoryContinuityRunbook -match 'CI gates - main' -and
        $repositoryContinuityRunbook -match 'Nachholvalidierung')

Add-ValidationResult `
    -Name 'Projektmapping migriert keine Runtime-Authority auf die zentrale Foundation-Registry' `
    -Success ($identityRegistrationMapping -match 'Foundation 1\.7 identity and registration baseline' -and
        $identityRegistrationMapping -match 'no repository-native JSON Registration Authority' -and
        $identityRegistrationMapping -match '`artifact-registry-github` capability is not selected')

Add-ValidationResult `
    -Name 'Copilot-Adapter bleibt eine duenne Discovery-Bruecke' `
    -Success ($copilotAdapter -match [regex]::Escape('Use `AGENTS.md` as the canonical repository entry point.') -and
        $copilotAdapter -match 'discovery only' -and
        $copilotAdapter -notmatch 'CU/Slot Watch|Get-SqlServerCuStatus')

Add-ValidationResult `
    -Name 'CU-Watch-Governance bleibt in der kanonischen Projektquelle erhalten' `
    -Success ($sqlCuPolicy -match [regex]::Escape('.\Tools\Get-SqlServerCuStatus.ps1') -and
        $sqlCuPolicy -match 'UNCLEAR' -and
        $sqlCuPolicy -match 'Keine Risiko-Matrix')

Add-ValidationResult `
    -Name 'Verarbeitungsrichtlinie ist anbieterneutral und kostenoptimiert' `
    -Success ($modelRoutingPolicy -match 'unabhängig vom verwendeten KI-Anbieter' -and
        $modelRoutingPolicy -match 'möglichst geringen Gesamtkosten' -and
        $modelRoutingPolicy -match 'Preise, Fähigkeiten, Kontingente oder Modellwechsel werden nicht erfunden' -and
        $modelRoutingPolicy -match 'Systeme ohne Modellwechsel' -and
        $modelRoutingPolicy -match 'Tests werden niemals als erfolgreich bezeichnet')

Add-ValidationResult `
    -Name 'Modellrouting bildet die vier Foundation-Tiers semantisch ab' `
    -Success ($modelRoutingPolicy -match [regex]::Escape('| `LOCAL` |') -and
        $modelRoutingPolicy -match [regex]::Escape('| `ECONOMICAL` |') -and
        $modelRoutingPolicy -match [regex]::Escape('| `BALANCED` |') -and
        $modelRoutingPolicy -match [regex]::Escape('| `FRONTIER` |') -and
        $modelRoutingPolicy -match '(?s)Menschlicher Prüfaufwand.*allein weder das Tier erhöhen')

Add-ValidationResult `
    -Name 'Lokale Validierungsstrategie trennt Foundation-, Projekt- und Runtime-Scope' `
    -Success ($localValidationStrategy -match 'FOUNDATION_INTEGRITY' -and
        $localValidationStrategy -match 'PROJECT_SEMANTIC' -and
        $localValidationStrategy -match 'RUNTIME_EMPIRICAL' -and
        $localValidationStrategy -match '(?s)Foundation-Validator.*kein Nachweis' -and
        $localValidationStrategy -match 'VALIDATION_FAILURE' -and
        $localValidationStrategy -match 'INFRASTRUCTURE_UNAVAILABLE' -and
        $localValidationStrategy -match 'LF-/CRLF-Unterschiede')

Add-ValidationResult `
    -Name 'Kosteneffiziente Entwicklung bindet lokale Testauswahl und Logaggregation' `
    -Success ($costEfficientDevelopment -match 'Invoke-ImpactedChecks\.ps1' -and
        $costEfficientDevelopment -match [regex]::Escape('.artifacts/test-runs/'))

Add-ValidationResult `
    -Name 'Projektkontext beschreibt gemischten Docker-/Podman-Lifecycle nicht als offen' `
    -Success ($projectContext -notmatch 'gemeinsamer Lifecycle für gemischte Provider innerhalb eines Runs')

Add-ValidationResult `
    -Name 'Projektkontext bezeichnet Einzelskripte nicht als offenen Sample-Pfad' `
    -Success ($projectContext -notmatch 'SQL-Skript-Samples;')

Add-ValidationResult `
    -Name 'Projektkontext beschreibt die Batch-/Operation-Vertraege als implementiert' `
    -Success ($projectContext -match [regex]::Escape('SqlServerLab.Batch/1.0') -and
        $projectContext -match [regex]::Escape('SqlServerLab.Operation/1.0'))

Add-ValidationResult `
    -Name 'Projektkontext bildet den aktuellen Runtime- und Validierungsstand ab' `
    -Success ($projectContext -match [regex]::Escape('CONTAINER_CORE_IMPLEMENTED_HYPERV_SQL_CLI_ACCEPTED') -and
        $projectContext -match [regex]::Escape('| Stand | 2026-08-31 |') -and
        $projectContext -match 'realer Hyper-V-N5-Mehrgerätepfad' -and
        $projectContext -match 'drei reale Project-Adapter-Piloten' -and
        $projectContext -match 'SQL_PerformanceSchulung[\s\S]{0,160}SQL_Server_Analyze[\s\S]{0,160}SQL_Server_Toolbelt[\s\S]{0,240}Docker und Podman[\s\S]{0,100}end-to-end' -and
        $projectContext -notmatch 'ein verbleibender realer Project-Adapter-Pilot' -and
        $projectContext -notmatch 'External-Runtime-Varianten für SQL Server 2019, SQL Server 2025' -and
        $projectContext -notmatch 'offen bleiben echter Prozessabbruch, Manifest-Rerun und Windows-User-Gate' -and
        $projectContext -notmatch 'noch keinen positiven allgemeinen SQL-Runtime-Nachweis' -and
        $projectContext -notmatch 'fehlende Eval-ISO im Media-Root blockiert' -and
        $projectContext -notmatch 'physischer Hyper-V-Mehrgeräte-Nachweis für vier TempDB')

Add-ValidationResult `
    -Name 'Manifest-Wizard-Status beschreibt Navigation und Artifact-Planvorschau aktuell' `
    -Success ($projectContext -match 'schrittweiser Zurücknavigation' -and
        $projectContext -notmatch 'Zurück-Navigation sowie allgemeine Sample-/Artifact-' -and
        $knownLimitations -match 'Abbruch ohne partielle Datei' -and
        $knownLimitations -notmatch 'Wizard-Navigation mit Zurück und Sample-/Artifact-Planvorschau' -and
        $sampleWizardArchitecture -match 'Planvorschau `1\.1`' -and
        $gettingStarted -match 'Plan\.Instances\[\]\.Samples')

Add-ValidationResult `
    -Name 'Repo-Map und Known Limitations beschreiben Reconcile und abgeschlossene Gates aktuell' `
    -Success ($repoMap -match 'journalisierter Container-Reconcile fuer CPU, RAM, SQL max memory, Hostport, Autostart und External Runtimes' -and
        $repoMap -notmatch 'Reconcile ist auf den Lifecycle START/STOP begrenzt' -and
        $knownLimitations -match 'physische N5-Hyper-V-Mehrgeräte-\s*Nachweis wurde am 2026-08-30 abgeschlossen' -and
        $knownLimitations -match 'P0-Ressourcenroot-Bugfix ist nach der realen Legacy-SQL-Abnahme' -and
        $knownLimitations -notmatch 'positiver realer Lauf dieses Runners steht weiterhin aus' -and
        $knownLimitations -match 'Alle drei produktiven Pilotadapter' -and
        $knownLimitations -match 'toolbelt\.core\.console-message' -and
        $knownLimitations -match 'Gate N3 ist\s+damit geschlossen' -and
        $knownLimitations -notmatch 'verbleibenden Project-Adapter-Piloten für `SQL_Server_Toolbelt`' -and
        $knownLimitations -notmatch 'Die verbleibenden P0-Fehler')

Add-ValidationResult `
    -Name 'Repo-Map kennt den aktuellen Validierungsreport' `
    -Success ($latestValidationResult -and $repoMap -match [regex]::Escape("latest_validation_result: Documentation/Quality/$($latestValidationResult.Name)")) `
    -Message $latestValidationMessage

Add-ValidationResult `
    -Name 'Repo-Map beschreibt SQL-Skripte und Builder-Resume nicht als nicht implementiert' `
    -Success ($repoMap -notmatch 'SQL-Skript-, Bundle-, Archiv- und Attach-Handler noch nicht implementiert' -and $repoMap -notmatch 'unattended OS-/SQL-Image-Build und Resume nicht implementiert')

Add-ValidationResult `
    -Name 'Repo-Map beschreibt den real abgeschlossenen Generalize-Vertrag nicht als offen' `
    -Success ($repoMap -match 'CONSOLE_CUI_001_TO_020_AND_STORAGE_STATIC_COMPLETE_EXTERNAL_PROVIDER_GATES_OPEN' -and
        $repoMap -notmatch 'GENERALIZE_OPEN')

$sqlPreparedAcceptancePath = Join-Path $repoRoot 'Tests\Integration\Invoke-HyperVSqlPreparedImageAcceptance.ps1'
Add-ValidationResult `
    -Name 'Roadmap und Masterplan führen N3 bis N5 vollständig und evidenzgebunden' `
    -Success ($developmentExecutionPlan -match '(?m)^\| N3 \| `COMPLETE` \|' -and
        $developmentExecutionPlan -match '(?m)^\| N4 \| `COMPLETE` \|' -and
        $developmentExecutionPlan -match '(?m)^\| N5 \| `COMPLETE` \|' -and
        $developmentExecutionPlan -match '2/1/1-Verteilung auf drei lokalen physischen Geräten' -and
        $masterImplementationPlan -match '(?m)^\| N3 – Drei reale Project-Adapter-Piloten \| Wellen 6, 7 und 7a \| `COMPLETE`' -and
        $masterImplementationPlan -match '(?m)^\| N4 – Hyper-V Windows-/SQL-End-to-End \| Welle 4 \| `COMPLETE` \|' -and
        $masterImplementationPlan -match '(?m)^\| N5 – Storage- und Reconcile-Vertical-Slice \| Wellen 1, 3, 4 und 5; Storage-Konsolidierungsplan \| `COMPLETE`')

Add-ValidationResult `
    -Name 'PSR-002 bindet Lab_Data-Versprechen und Runtime-Hostgrenzen widerspruchsfrei' `
    -Success ($labDataResidencyDecision -match [regex]::Escape('SqlServerLab.LabDataResidencyDecision/1.0') -and
        $labDataResidencyDecision -match [regex]::Escape('BINDING_ARCHITECTURE_DECISION') -and
        $labDataResidencyDecision -match '(?s)`Lab_Data` bedeutet ausdrücklich \*\*nicht\*\*.*jedes\s+physische Byte' -and
        $labDataResidencyDecision -match 'globale Docker-Desktop-Disk' -and
        $labDataResidencyDecision -match 'Externe und unverifizierbare Objekte sind im normalen Audit `REPORT_ONLY`' -and
        $labDataResidencyDecision -match 'Neue Hyper-V-Ressourcen.*registrierten,\s*controller-eigenen `Lab_Data`-Root' -and
        $persistentStorageBacklog -match '(?m)^\| `PSR-002` .*\| `COMPLETE`:' -and
        $developmentExecutionPlan -notmatch '`PSR-002` ist noch offen' -and
        $repoMap -match 'lab_data_native_runtime_storage_decision: Documentation/Architecture/LAB_DATA_AND_NATIVE_RUNTIME_STORAGE_DECISION\.md')

Add-ValidationResult `
    -Name 'Roadmap beschreibt den real belegten Container-Reconcile-Stand widerspruchsfrei' `
    -Success ($developmentExecutionPlan -match [regex]::Escape('Container-`no-op`, `live`, `recreate`, Rollback und Persistenz sind für Docker und Podman real verifiziert') -and
        $developmentExecutionPlan -match [regex]::Escape('beliebige Mount-/Environment-Änderungen aus `CNT-214` bleiben offen') -and
        $developmentExecutionPlan -notmatch [regex]::Escape('reale `live`-/`recreate`-Änderungen offen'))

Add-ValidationResult `
    -Name 'Roadmap beschreibt den implementierten Hyper-V-Netzwerk-Reconcile-Slice widerspruchsfrei' `
    -Success ($developmentExecutionPlan -match '(?m)^\| M6 Reconcile-Breite \| `implemented_partial` \|' -and
        $developmentExecutionPlan -match '`NET-611` und der Planungsanteil von `NET-612` sind' -and
        $developmentExecutionPlan -match 'Rebinding,\s*Adapter-Neuanlage, Gastadressreparatur und positive native Repair-' -and
        $masterImplementationPlan -match 'journalisierter Network- und Resource-Reconcile' -and
        $masterImplementationPlan -notmatch 'Post-Provisioning-/Network-Manifest-Binding')

Add-ValidationResult `
    -Name 'Roadmap und Grenzen beschreiben HV-602 evidenzgebunden' `
    -Success ($developmentExecutionPlan -match '`HV-602` bindet\s*vCPU, statisches/dynamisches RAM und Min/Startup/Max' -and
        $knownLimitations -match 'SqlServerLab\.HyperVResourceIntent/1\.0' -and
        $knownLimitations -match 'ersetzt noch keinen positiven\s*nativen Hyper-V-Ressourcenlauf' -and
        $repoMap -match 'hyperv_resource_reconcile_contract: Private/HyperVResourceReconcile\.ps1')

Add-ValidationResult `
    -Name 'Reale SQL-Prepared-Image-Abnahme ist ausführbar und dokumentiert' `
    -Success ((Test-Path -LiteralPath $sqlPreparedAcceptancePath -PathType Leaf) -and
        $localValidationStrategy -match [regex]::Escape('Invoke-HyperVSqlPreparedImageAcceptance.ps1') -and
        $knownLimitations -match '(?s)SQL_PREPARED_SEALED.*SQL_READY_RUN.*Parent-Hash' -and
        $repoMap -match 'sql_prepared_build_acceptance: Tests/Integration/Invoke-HyperVSqlPreparedImageAcceptance.ps1')

Add-ValidationResult `
    -Name 'Masterplan trennt lokale Produktfunktion von optionaler CI-Validierung' `
    -Success ($masterImplementationPlan -notmatch 'keine CI/CD-Artefakte vorhanden' -and $masterImplementationPlan -match 'keine Produktabhängigkeit')

Add-ValidationResult `
    -Name 'Batch-Plan bildet implementierten Kern und real belegte Runtime-Abnahme ab' `
    -Success ($batchWorkflowPlan -match 'IMPLEMENTED_WITH_OPEN_RUNTIME_ACCEPTANCE' -and
        $batchWorkflowPlan -notmatch [regex]::Escape('| 1 Persistenter Kern | `PLANNED`') -and
        $batchWorkflowPlan -match 'Docker-/Podman-Bulk sowie Hyper-V-Slot-Bulk' -and
        $batchWorkflowPlan -match 'harter Docker-Scheduler-Abbruch' -and
        $batchWorkflowPlan -match 'Manifest-Rerun, Windows-User-Gate, Resume und Cleanup real verifiziert' -and
        $batchWorkflowPlan -match 'keine offene User-Gate-Kernabnahme' -and
        $batchWorkflowPlan -notmatch 'User-Gates offen')

Add-ValidationResult `
    -Name 'Historischer Architekturstatus ist als Snapshot gekennzeichnet' `
    -Success ($futureUseCases -match 'Historischer Implementierungsstatus')

$hyperVPreparedCloneImplemented = $hyperVManifestRuntime -match 'Invoke-HyperVLabUnattendedProvision' -and
    $hyperVLabEnvironmentRuntime -match 'Complete-HyperVLabSqlImage'
if ($hyperVPreparedCloneImplemented) {
    Add-ValidationResult `
        -Name 'Statusdokumentation ordnet Hyper-V CompleteImage dem Prepared-Image-Klonpfad zu' `
        -Success ($knownLimitations -match '(?s)Klonpfad.{0,160}CompleteImage' -and
            $masterImplementationPlan -match 'PrepareImage.*CompleteImage' -and
            $repoMap -match 'real_prepared_image_manifest_clone_to_SQL_READY_RUN')

    Add-ValidationResult `
        -Name 'Lokale Validierungsstrategie trennt validierten Referenzklon und breite offene Manifestbindung' `
        -Success ($localValidationStrategy -match 'SQL_PREPARED_SEALED' -and
            $localValidationStrategy -match 'breite Datenbank-, Software-, Post-Provisioning- und')
}

if (Test-Path -LiteralPath (Join-Path $repoRoot 'Tests\Integration\Invoke-MixedProviderSmokeTest.ps1') -PathType Leaf) {
    Add-ValidationResult `
        -Name 'Lokale Validierungsstrategie dokumentiert den implementierten Docker-/Podman-Mixed-Run' `
        -Success ($localValidationStrategy -match '(?m)^\| gemischter Provider-Run \| implementiert mit Podman-ProviderSubRun \| implementiert mit Docker-ProviderSubRun \| nicht unterstützt \|\r?$')
}

if ($latestValidationResult -and $latestValidationResult.Name -match '^VALIDATION_RESULT_(?<date>\d{4}-\d{2}-\d{2})\.md$') {
    $latestValidationDate = $Matches.date
    $expectedLatestResult = "latest_validation_result: Documentation/Quality/$($latestValidationResult.Name)"
    $expectedConfirmedResult = "(?ms)last_confirmed_result:\s*date: `"$([regex]::Escape($latestValidationDate))`"\s*source: Documentation/Quality/$([regex]::Escape($latestValidationResult.Name))"
    Add-ValidationResult `
        -Name 'Repo-Map synchronisiert aktuellen und letzten bestätigten Validierungsreport' `
        -Success ($repoMap -match [regex]::Escape($expectedLatestResult) -and $repoMap -match $expectedConfirmedResult) `
        -Message "Erwartet: $($latestValidationResult.Name)"
}

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

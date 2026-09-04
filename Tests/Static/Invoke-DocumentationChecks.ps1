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

function Test-FoundationUpgradeAssessmentContract {
    param(
        [Parameter(Mandatory)][object]$Assessment,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedCandidates,
        [Parameter(Mandatory)][string]$InstalledVersion,
        [Parameter(Mandatory)][string]$SourceVersion,
        [Parameter(Mandatory)][string]$SourceRef
    )

    $issues = [System.Collections.Generic.List[string]]::new()
    if ([string]$Assessment.installed_version -ne $InstalledVersion) {
        $issues.Add("installed_version=$($Assessment.installed_version)")
    }
    if ([string]$Assessment.source_version -ne $SourceVersion) {
        $issues.Add("source_version=$($Assessment.source_version)")
    }
    if ([string]$Assessment.source_ref -ne $SourceRef) {
        $issues.Add("source_ref=$($Assessment.source_ref)")
    }

    $records = @($Assessment.assessments)
    $recordIds = @($records | ForEach-Object { [string]$_.feature_id })
    $duplicateIds = @($recordIds | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    if ($duplicateIds.Count -gt 0) {
        $issues.Add("duplicate feature_id: $($duplicateIds -join ', ')")
    }

    $missingIds = @($ExpectedCandidates.Keys | Where-Object { $_ -notin $recordIds })
    $unexpectedIds = @($recordIds | Where-Object { -not $ExpectedCandidates.Contains($_) })
    if ($missingIds.Count -gt 0) {
        $issues.Add("missing feature_id: $($missingIds -join ', ')")
    }
    if ($unexpectedIds.Count -gt 0) {
        $issues.Add("unexpected feature_id: $($unexpectedIds -join ', ')")
    }

    foreach ($featureId in $ExpectedCandidates.Keys) {
        $matchingRecords = @($records | Where-Object { [string]$_.feature_id -eq $featureId })
        if ($matchingRecords.Count -ne 1) {
            continue
        }

        $record = $matchingRecords[0]
        $expected = $ExpectedCandidates[$featureId]
        $actualReasons = @($record.candidate_reasons | ForEach-Object { [string]$_ })
        $reasonDiff = @(Compare-Object -ReferenceObject @($expected.Reasons) -DifferenceObject $actualReasons)
        if ($reasonDiff.Count -gt 0) {
            $issues.Add("$featureId candidate_reasons")
        }
        if ([string]$record.classification -ne [string]$expected.Classification) {
            $issues.Add("$featureId classification=$($record.classification)")
        }
        if (@($record.evidence).Count -eq 0 -or @($record.evidence | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
            $issues.Add("$featureId evidence")
        }
        if ([string]::IsNullOrWhiteSpace([string]$record.rationale)) {
            $issues.Add("$featureId rationale")
        }
        $expectedCapabilities = if ($SourceVersion -eq '1.8.0' -and $featureId -eq 'rule-context-cache') { @('rule-context-cache') } else { @() }
        $actualCapabilities = @($record.selected_capabilities)
        $capabilitiesMatch = if ($expectedCapabilities.Count -eq 0) { $actualCapabilities.Count -eq 0 } else { @(Compare-Object -ReferenceObject $expectedCapabilities -DifferenceObject $actualCapabilities).Count -eq 0 }
        if (-not $record.PSObject.Properties['selected_capabilities'] -or -not $capabilitiesMatch) {
            $issues.Add("$featureId selected_capabilities")
        }
        if ([string]$expected.Classification -eq 'RECOMMENDED' -and [string]::IsNullOrWhiteSpace([string]$record.recommendation)) {
            $issues.Add("$featureId recommendation")
        }
    }

    [pscustomobject]@{
        Success = $issues.Count -eq 0
        Message = $issues -join '; '
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
                'bacpac' { '\.bacpac$' }
                default { $null }
            }
            if ([string]$definition.artifactType -notin @('backup', 'archive-backup', 'sql-script', 'bacpac') -or
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
    'Documentation/HowTo/END_TO_END_TEST_ENVIRONMENT.md'
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
    '.ai/foundation-upgrade-assessments/1.4.0-to-1.7.0.json'
    '.ai/foundation-upgrade-assessments/1.7.0-to-1.8.0.json'
    '.ai/foundation/FOUNDATION_RULESET.md'
    '.ai/foundation/AI_REPOSITORY_FOUNDATION_NOTICE.md'
    '.ai/foundation/PROJECT_RULES.md'
    '.ai/foundation/SEMANTIC_INTEGRATION_POLICY.md'
    '.ai/foundation/PERSISTENT_IDENTITY_POLICY.md'
    '.ai/foundation/ARTIFACT_REGISTRATION_POLICY.md'
    '.ai/foundation/CENTRAL_ARTIFACT_REGISTRY_POLICY.md'
    '.ai/foundation/UPGRADE_APPLICABILITY_POLICY.md'
    '.ai/foundation/REPOSITORY_CONTINUITY_POLICY.md'
    '.ai/foundation/RULE_CONTEXT_CACHE_POLICY.md'
    '.ai/foundation/feature_catalog.json'
    '.ai/foundation/schemas/artifact-record.schema.json'
    '.ai/foundation/schemas/artifact-registry.schema.json'
    '.ai/foundation/schemas/artifact-registry-v2.schema.json'
    '.ai/foundation/schemas/artifact-registration-request.schema.json'
    '.ai/foundation/schemas/feature-catalog.schema.json'
    '.ai/foundation/schemas/upgrade-assessment.schema.json'
    '.ai/foundation/schemas/rule-context-cache.schema.json'
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
$foundationUpgradeAssessmentPath = Join-Path $repoRoot '.ai\foundation-upgrade-assessments\1.4.0-to-1.7.0.json'
$foundationUpgradeAssessmentSchemaPath = Join-Path $repoRoot '.ai\foundation\schemas\upgrade-assessment.schema.json'
$foundationUpgradeAssessmentJson = Get-Content -LiteralPath $foundationUpgradeAssessmentPath -Raw -Encoding utf8
$foundationUpgradeAssessment = $foundationUpgradeAssessmentJson | ConvertFrom-Json -Depth 100
$currentFoundationUpgradeAssessmentPath = Join-Path $repoRoot '.ai\foundation-upgrade-assessments\1.7.0-to-1.8.0.json'
$currentFoundationUpgradeAssessmentJson = Get-Content -LiteralPath $currentFoundationUpgradeAssessmentPath -Raw -Encoding utf8
$currentFoundationUpgradeAssessment = $currentFoundationUpgradeAssessmentJson | ConvertFrom-Json -Depth 100
$foundationRuleset = Get-Content -LiteralPath (Join-Path $repoRoot '.ai\foundation\FOUNDATION_RULESET.md') -Raw -Encoding utf8
$foundationRepoMap = Get-Content -LiteralPath (Join-Path $repoRoot '.ai\foundation\repo_map.yaml') -Raw -Encoding utf8
$foundationNotice = Get-Content -LiteralPath (Join-Path $repoRoot '.ai\foundation\AI_REPOSITORY_FOUNDATION_NOTICE.md') -Raw -Encoding utf8
$foundationFeatureCatalog = Get-Content -LiteralPath (Join-Path $repoRoot '.ai\foundation\feature_catalog.json') -Raw -Encoding utf8
$identityRegistrationMapping = Get-Content -LiteralPath (Join-Path $repoRoot '.ai\IDENTITY_AND_ARTIFACT_REGISTRATION.md') -Raw -Encoding utf8
$copilotAdapter = Get-Content -LiteralPath (Join-Path $repoRoot '.github\copilot-instructions.md') -Raw -Encoding utf8
$sqlCuPolicy = Get-Content -LiteralPath (Join-Path $repoRoot 'ops\sql-cu-policy.md') -Raw -Encoding utf8
$masterImplementationPlan = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Project_Planning\MASTER_IMPLEMENTATION_PLAN.md') -Raw -Encoding utf8
$developmentExecutionPlan = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Project_Planning\DEVELOPMENT_EXECUTION_PLAN_2026-08-08.md') -Raw -Encoding utf8
$projectPlanningIndex = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Project_Planning\README.md') -Raw -Encoding utf8
$hyperVResourceRootBacklog = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Project_Planning\HYPERV_LAB_DATA_RESOURCE_ROOT_BUGFIX_BACKLOG.md') -Raw -Encoding utf8
$persistentStorageBacklog = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Project_Planning\PERSISTENT_STORAGE_REUSE_AND_LAB_DATA_BACKLOG.md') -Raw -Encoding utf8
$labDataResidencyDecision = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Architecture\LAB_DATA_AND_NATIVE_RUNTIME_STORAGE_DECISION.md') -Raw -Encoding utf8
$batchWorkflowPlan = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Project_Planning\PROVIDER_NEUTRAL_BATCH_QUEUE_RESUME_WORKFLOW_2026-08-13.md') -Raw -Encoding utf8
$futureUseCases = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Architecture\FUTURE_USE_CASES_AND_EXTENSION_GUARDRAILS.md') -Raw -Encoding utf8
$knownLimitations = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Quality\KNOWN_LIMITATIONS.md') -Raw -Encoding utf8
$publicReadme = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\README.md') -Raw -Encoding utf8
$removalPlanCommand = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\Get-SqlServerLabPersistentStorageRemovalPlan.ps1') -Raw -Encoding utf8
$workflowActionCommand = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\Invoke-SqlServerLabWorkflowAction.ps1') -Raw -Encoding utf8
$architecture = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Architecture\LAB_DATA_AND_NATIVE_RUNTIME_STORAGE_DECISION.md') -Raw -Encoding utf8
$cliAcceptanceMatrix = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Quality\CLI_ACCEPTANCE_MATRIX.md') -Raw -Encoding utf8
$endToEndTestEnvironment = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\HowTo\END_TO_END_TEST_ENVIRONMENT.md') -Raw -Encoding utf8
$hyperVSlotWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\HowTo\HYPERV_SLOT_SQL_WORKFLOW.md') -Raw -Encoding utf8
$hyperVWindowsImageBuild = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\HowTo\HYPERV_WINDOWS_IMAGE_BUILD.md') -Raw -Encoding utf8
$automatedTestEnvironments = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\User\AUTOMATED_TEST_ENVIRONMENTS.md') -Raw -Encoding utf8
$sqlConnectionCenter = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\User\SQL_CONNECTION_CENTER.md') -Raw -Encoding utf8
$interactiveWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\User\INTERACTIVE_WORKFLOW.md') -Raw -Encoding utf8
$interactiveMenu = Get-Content -LiteralPath (Join-Path $repoRoot 'Public\Invoke-SqlServerLab.ps1') -Raw -Encoding utf8
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

$requiredTestEnvironmentKeys = @(
    'LINUX_2019_LATEST'
    'LINUX_2022_LATEST'
    'LINUX_2025_LATEST'
    'WINDOWS_2019_BASE'
    'WINDOWS_2022_BASE'
    'WINDOWS_2025_BASE'
)
$missingTestEnvironmentKeys = @(
    $requiredTestEnvironmentKeys |
        Where-Object { $endToEndTestEnvironment -notmatch [regex]::Escape($_) }
)
Add-ValidationResult `
    -Name 'End-to-End-Runbook bindet die vollständige Sechs-Ziele-Matrix' `
    -Success ($missingTestEnvironmentKeys.Count -eq 0) `
    -Message ($missingTestEnvironmentKeys -join ', ')

Add-ValidationResult `
    -Name 'End-to-End-Runbook bindet aktuelle Operator-Einstiege und Readiness' `
    -Success ($endToEndTestEnvironment -match [regex]::Escape('-Action Image') -and
        $endToEndTestEnvironment -match [regex]::Escape('-Action AutomatedTestEnvironment') -and
        $endToEndTestEnvironment -match [regex]::Escape('-Action ConnectionCenter') -and
        $endToEndTestEnvironment -match [regex]::Escape('Datenbanken und Verbindungen') -and
        $endToEndTestEnvironment -match [regex]::Escape('Verbindungszentrale und SSMS-Endpunkte') -and
        $endToEndTestEnvironment -match [regex]::Escape('CMS verwalten und synchronisieren') -and
        $endToEndTestEnvironment -match [regex]::Escape('SQL_SLOT_READY') -and
        $endToEndTestEnvironment -match 'groupStatus\s*=\s*READY')

Add-ValidationResult `
    -Name 'End-to-End-Runbook schützt Testgruppe vor CMS-Uebernahme' `
    -Success ($endToEndTestEnvironment -match 'Keines der\s+sechs geschützten Testgruppenmitglieder darf als CMS verwendet werden' -and
        $endToEndTestEnvironment -match 'Kompakten persistenten CMS automatisch erstellen' -and
        $endToEndTestEnvironment -match 'SQL Server-Authentifizierung')

Add-ValidationResult `
    -Name 'Operator-Indizes verlinken das End-to-End-Runbook' `
    -Success ($rootReadme -match [regex]::Escape('Documentation/HowTo/END_TO_END_TEST_ENVIRONMENT.md') -and
        $documentationIndex -match [regex]::Escape('HowTo/END_TO_END_TEST_ENVIRONMENT.md') -and
        $repoMap -match [regex]::Escape('operator_end_to_end_test_environment: Documentation/HowTo/END_TO_END_TEST_ENVIRONMENT.md'))

$staleOperatorMenuText = @(
    if ($automatedTestEnvironments -match 'Über den Hauptmenüpunkt\s+\*\*\[e\]') { 'AUTOMATED_TEST_ENVIRONMENTS: [e]' }
    if ($sqlConnectionCenter -match 'mit\s+`\[k\]`\s+erreichbar') { 'SQL_CONNECTION_CENTER: [k]' }
    if ($hyperVSlotWorkflow -match '\[i\]\s*(?:→|->)\s*\[4\]') { 'HYPERV_SLOT_SQL_WORKFLOW: [i] -> [4]' }
    if ($hyperVWindowsImageBuild -match 'Alternativ im Hauptmenü\s+`i`') { 'HYPERV_WINDOWS_IMAGE_BUILD: Hauptmenü i' }
    if ($interactiveWorkflow -match '\[i\]\s*(?:→|->)\s*\[4\]') { 'INTERACTIVE_WORKFLOW: [i] -> [4]' }
    if ($interactiveMenu -match 'Unter \[k\] -> \[4\]' -or
        $interactiveMenu -match '\[e\] -> \[r\]' -or
        $interactiveMenu -match 'unter \[i\] -> \[4\]' -or
        $interactiveMenu -match 'Hauptmenü \[[rd]\]') { 'Invoke-SqlServerLab: veralteter Menüpfad' }
)
Add-ValidationResult `
    -Name 'Operator-Dokumente und Hilfetexte verwenden keine veralteten Einstiege' `
    -Success ($staleOperatorMenuText.Count -eq 0) `
    -Message ($staleOperatorMenuText -join '; ')

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
    -Name 'Foundation-Ruleset, Index und Feature-Katalog sind auf Version 1.8.0 gebunden' `
    -Success ($foundationRuleset -match 'Ruleset version: 1\.8\.0' -and
        $foundationRepoMap -match 'foundation_ruleset_version: 1\.8\.0' -and
        $foundationFeatureCatalog -match '"ruleset_version"\s*:\s*"1\.8\.0"' -and
        $foundationRuleset -match [regex]::Escape('UPGRADE_APPLICABILITY_POLICY.md') -and
        $foundationRuleset -match [regex]::Escape('REPOSITORY_CONTINUITY_POLICY.md') -and
        $foundationRuleset -match [regex]::Escape('RULE_CONTEXT_CACHE_POLICY.md'))

Add-ValidationResult `
    -Name 'Foundation-Provenienz enthaelt den vollstaendigen MIT-Hinweis' `
    -Success ($foundationNotice -match [regex]::Escape('Copyright (c) 2026 Gerhard P') -and
        $foundationNotice -match [regex]::Escape('Permission is hereby granted, free of charge') -and
        $foundationNotice -match [regex]::Escape('THE SOFTWARE IS PROVIDED "AS IS"'))

Add-ValidationResult `
    -Name 'Repo-Map dokumentiert Foundation-Quelle, Adapter und semantische Zuordnung' `
    -Success ($repoMap -match 'source_commit: 7ddc29988b23570f462e46ebf527f8dfdd05fd75' -and
        $repoMap -match 'ruleset_version: "1\.8\.0"' -and
        $repoMap -match 'github-copilot' -and
        $repoMap -match 'sql_cu_watch_policy: ops/sql-cu-policy\.md' -and
        $repoMap -match 'current_record: \.ai/foundation-upgrade-assessments/1\.7\.0-to-1\.8\.0\.json' -and
        $repoMap -match 'rule-context-cache' -and
        $repoMap -match 'unresolved_conflicts: \[\]')

$foundationUpgradeAssessmentSchemaValid = $false
$foundationUpgradeAssessmentSchemaMessage = $null
try {
    $foundationUpgradeAssessmentSchemaValid = $foundationUpgradeAssessmentJson |
        Test-Json -SchemaFile $foundationUpgradeAssessmentSchemaPath -ErrorAction Stop
}
catch {
    $foundationUpgradeAssessmentSchemaMessage = $_.Exception.Message
}
Add-ValidationResult `
    -Name 'Foundation-Upgrade-Assessment entspricht dem installierten Schema' `
    -Success $foundationUpgradeAssessmentSchemaValid `
    -Message $foundationUpgradeAssessmentSchemaMessage

$currentFoundationUpgradeAssessmentSchemaValid = $false
$currentFoundationUpgradeAssessmentSchemaMessage = $null
try {
    $currentFoundationUpgradeAssessmentSchemaValid = $currentFoundationUpgradeAssessmentJson |
        Test-Json -SchemaFile $foundationUpgradeAssessmentSchemaPath -ErrorAction Stop
}
catch {
    $currentFoundationUpgradeAssessmentSchemaMessage = $_.Exception.Message
}
Add-ValidationResult `
    -Name 'Aktuelles Foundation-Upgrade-Assessment entspricht dem installierten Schema' `
    -Success $currentFoundationUpgradeAssessmentSchemaValid `
    -Message $currentFoundationUpgradeAssessmentSchemaMessage

$expectedFoundationUpgradeCandidates = [ordered]@{
    'artifact-registration' = @{
        Reasons = @('material_change:1.6.0')
        Classification = 'ALREADY_EQUIVALENT'
    }
    'central-artifact-registry' = @{
        Reasons = @('introduced_in:1.6.0')
        Classification = 'NOT_APPLICABLE'
    }
    'layered-validation' = @{
        Reasons = @('material_change:1.7.0')
        Classification = 'APPLY_DEFAULT'
    }
    'repository-continuity-break-glass' = @{
        Reasons = @('introduced_in:1.7.0')
        Classification = 'RECOMMENDED'
    }
    'semantic-integration' = @{
        Reasons = @('material_change:1.5.0')
        Classification = 'APPLY_DEFAULT'
    }
    'semantic-upgrade-applicability' = @{
        Reasons = @('introduced_in:1.5.0')
        Classification = 'APPLY_DEFAULT'
    }
}
$foundationUpgradeContract = Test-FoundationUpgradeAssessmentContract `
    -Assessment $foundationUpgradeAssessment `
    -ExpectedCandidates $expectedFoundationUpgradeCandidates `
    -InstalledVersion '1.4.0' `
    -SourceVersion '1.7.0' `
    -SourceRef 'd49f978f33001fcc098998ff7c04ffb209b28033'
Add-ValidationResult `
    -Name 'Foundation-Upgrade bewertet den exakten Sechser-Delta samt Gruenden und Evidence' `
    -Success $foundationUpgradeContract.Success `
    -Message $foundationUpgradeContract.Message

$missingEvidenceFixture = $foundationUpgradeAssessmentJson | ConvertFrom-Json -Depth 100
$missingEvidenceFixture.assessments[0].evidence = @()
$missingEvidenceResult = Test-FoundationUpgradeAssessmentContract `
    -Assessment $missingEvidenceFixture `
    -ExpectedCandidates $expectedFoundationUpgradeCandidates `
    -InstalledVersion '1.4.0' `
    -SourceVersion '1.7.0' `
    -SourceRef 'd49f978f33001fcc098998ff7c04ffb209b28033'
Add-ValidationResult `
    -Name 'Foundation-Upgrade-Vertrag verwirft fehlende Repository-Evidence' `
    -Success (-not $missingEvidenceResult.Success)

$missingCandidateFixture = $foundationUpgradeAssessmentJson | ConvertFrom-Json -Depth 100
$missingCandidateFixture.assessments = @($missingCandidateFixture.assessments | Select-Object -Skip 1)
$missingCandidateResult = Test-FoundationUpgradeAssessmentContract `
    -Assessment $missingCandidateFixture `
    -ExpectedCandidates $expectedFoundationUpgradeCandidates `
    -InstalledVersion '1.4.0' `
    -SourceVersion '1.7.0' `
    -SourceRef 'd49f978f33001fcc098998ff7c04ffb209b28033'
Add-ValidationResult `
    -Name 'Foundation-Upgrade-Vertrag verwirft still ausgelassene Delta-Kandidaten' `
    -Success (-not $missingCandidateResult.Success)

$expectedCurrentFoundationUpgradeCandidates = [ordered]@{
    'rule-context-cache' = @{
        Reasons = @('introduced_in:1.8.0')
        Classification = 'RECOMMENDED'
    }
}
$currentFoundationUpgradeContract = Test-FoundationUpgradeAssessmentContract `
    -Assessment $currentFoundationUpgradeAssessment `
    -ExpectedCandidates $expectedCurrentFoundationUpgradeCandidates `
    -InstalledVersion '1.7.0' `
    -SourceVersion '1.8.0' `
    -SourceRef '7ddc29988b23570f462e46ebf527f8dfdd05fd75'
Add-ValidationResult `
    -Name 'Aktuelles Foundation-Upgrade bewertet rule-context-cache mit Evidence und ohne voreilige Capability-Auswahl' `
    -Success $currentFoundationUpgradeContract.Success `
    -Message $currentFoundationUpgradeContract.Message

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
    -Success ($identityRegistrationMapping -match 'Foundation 1\.8 identity and registration baseline' -and
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
        $projectContext -match [regex]::Escape('| Stand | 2026-09-02 |') -and
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
        $knownLimitations -match '1\. Den synthetisch implementierten Hyper-V-' -and
        $knownLimitations -notmatch 'Den P0-Bugfix für Hyper-V-Ressourcenroots' -and
        $hyperVResourceRootBacklog -match '\| Status \| `COMPLETE` seit 2026-08-31 \|' -and
        $hyperVResourceRootBacklog -notmatch 'IN_PROGRESS / P0' -and
        $persistentStorageBacklog -match 'P0-Bugfix[\s\S]+ist seit 2026-08-31 abgeschlossen' -and
        $persistentStorageBacklog -notmatch 'bleibt vorrangig' -and
        $projectPlanningIndex -match 'Abgeschlossener P0-Bugfix' -and
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
    -Name 'PSR-001 inventarisiert lokales Runtime-Backing und Speichernutzung read-only vollständig' `
    -Success ($persistentStorageBacklog -match '(?m)^\| `PSR-001` .*\| `COMPLETE`:' -and
        $persistentStorageBacklog -match 'über ihre tatsächlichen VHDX- und\s*Konfigurationsdateien hostseitig aufgelöst' -and
        $persistentStorageBacklog -match 'Images, Container, Volumes und Build-\s*Cache werden als normalisierte Runtime-Klassen erfasst' -and
        $knownLimitations -match 'physische Host-Backing unterstützter lokaler Installationen ist\s*im Storage-Residency-Audit `VERIFIED`' -and
        $knownLimitations -match '`SHARED_EXTERNAL`/`REPORT_ONLY`' -and
        $repoMap -match 'physical_runtime_backing_and_configuration_inventory' -and
        $repoMap -match 'runtime_image_container_volume_build_cache_inventory' -and
        $repoMap -match 'physical_host_backing_vhdx_and_configuration')

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
    -Name 'PSR-003 dokumentiert generischen Katalogkern und sicheren Exchange-Workspace-Slice' `
    -Success ($persistentStorageBacklog -match '(?m)^`ACTIVE / 7_TOP_LEVEL_PACKAGES_REMAIN / PSR_001_002_005_007_008_013_014_COMPLETE / PSR_003_004_011_PARTIAL / PSR_006_READ_ONLY / PSR_009_010_012_IMPLEMENTED_CORE`' -and
        $persistentStorageBacklog -match '(?m)^\| `PSR-003` .*\| `IMPLEMENTED_PARTIAL`:' -and
        $persistentStorageBacklog -match [regex]::Escape('SqlServerLab.PersistentStorageCatalog/1.0') -and
        $persistentStorageBacklog -match [regex]::Escape('SqlServerLab.PersistentStoragePlan/1.0') -and
        $persistentStorageBacklog -match 'generischer CAS-/Preview-Mutationskern mit genau einem rollbackfähigen Revisionscommit' -and
        $persistentStorageBacklog -match 'exklusive Lease/Freigabe regulärer `-PersistentData`-Containerstores' -and
        $persistentStorageBacklog -match 'stabiler Datenbankreferenzen' -and
        $persistentStorageBacklog -match 'Paket-Katalogcommit quarantänisiert Library-Eintrag und Recovery-Journal' -and
        $persistentStorageBacklog -match 'Compare-and-Swap über die erwartete Revision' -and
        $persistentStorageBacklog -match 'darauf vereinheitlichte `BACKUP_SET`-/`DATABASE_PACKAGE`-Writer' -and
        $persistentStorageBacklog -match 'vorhandene `BackupSetId`-, `DatabasePackageId`- oder\s*`ExchangeWorkspaceId`-Einträge' -and
        $persistentStorageBacklog -match '`-WhatIf` ohne Katalogmutation' -and
        $knownLimitations -match 'Reguläre Docker-/Podman-Labs mit[\s\S]*?`-PersistentData`[\s\S]*?exklusive Run-Lease' -and
        $knownLimitations -match 'stabile aktive `DATABASE`-Referenzen' -and
        $knownLimitations -match 'Sync-SqlServerLabPersistentStorageArtifact' -and
        $knownLimitations -match 'gemeinsamen Katalog-Mutationskern mit read-only Preview, erwarteter Revision' -and
        $knownLimitations -match 'Backup-Set und Datenbankpaket verwenden dafür\s*denselben Artifact-Writer' -and
        $knownLimitations -match 'Noch nicht implementiert sind die Umstellung\s*der übrigen Instanzstore-Writer' -and
        $knownLimitations -match '`BACKUP_SET` beziehungsweise `DATABASE_PACKAGE`' -and
        $repoMap -match 'persistent_storage_catalog: Private/PersistentStorageCatalog\.ps1' -and
        $repoMap -match 'persistent_storage_artifact_sync: Public/Sync-SqlServerLabPersistentStorageArtifact\.ps1' -and
        $repoMap -match 'persistent_storage_catalog_schema: Schemas/persistent-storage-catalog\.schema\.json' -and
        $repoMap -match 'persistent_storage_plan_schema: Schemas/persistent-storage-plan\.schema\.json' -and
        $repoMap -match 'persistent_storage_artifact_sync_result_schema: Schemas/persistent-storage-artifact-sync-result\.schema\.json' -and
        $repoMap -match 'validation_persistent_storage_catalog: Tests/Static/Invoke-PersistentStorageCatalogChecks\.ps1')

Add-ValidationResult `
    -Name 'PSR-011 inventarisiert Datenbankpakete in CLI und Browser stabil und pfadfrei' `
    -Success ($persistentStorageBacklog -match '(?m)^\| `PSR-011` .*\| `IMPLEMENTED_PARTIAL`:' -and
        $persistentStorageBacklog -match '`DatabasePackageId`' -and
        $persistentStorageBacklog -match '`-VerifyIntegrity`' -and
        $knownLimitations -match 'CLI-/Browser-Attach unterstützt Hyper-V-Ziele per stabiler Run-/Instanz-ID' -and
        $knownLimitations -match 'Ein freier Zielpfad ist nicht Teil des Vertrags' -and
        $repoMap -match 'database_package_inventory: Public/Get-SqlServerLabDatabasePackage\.ps1' -and
        $repoMap -match 'database_package_attach: Public/Invoke-SqlServerLabDatabasePackageAttach\.ps1' -and
        $repoMap -match 'database_package_hyperv_attach: Providers/HyperV/HyperVDatabasePackage\.ps1')

Add-ValidationResult `
    -Name 'PSR-004 führt Retain, Backup, Container-Package und Kombination journalisiert aus' `
    -Success ($persistentStorageBacklog -match '(?m)^\| `PSR-004` .*\| `IMPLEMENTED_PARTIAL`:' -and
        $persistentStorageBacklog -match [regex]::Escape('SqlServerLab.PersistentStorageRemovalIntent/1.0') -and
        $persistentStorageBacklog -match [regex]::Escape('SqlServerLab.PersistentStorageRemovalPlan/1.0') -and
        $persistentStorageBacklog -match '`CHECKSUM` und `RESTORE VERIFYONLY`' -and
        $persistentStorageBacklog -match 'geheimnisfreies\s*Journal' -and
        $persistentStorageBacklog -match '(?s)`DELETE_WITH_RUN`.*persistierter.*?`DELETE_PENDING`.*?`DETACHED`' -and
        $persistentStorageBacklog -match '(?ms)^\| `PSR-004` .*`DELETE_WITH_RUN`.*`DELETE_PENDING`.*`DETACHED`.*$' -and
        $persistentStorageBacklog -match '(?ms)^\| `PSR-011` .*öffentliche finale Delete.*`DELETE_WITH_RUN`.*$' -and
        $developmentExecutionPlan -match '(?s)`DELETE_WITH_RUN`.*persistierter.*?`DELETE_PENDING`.*?`DETACHED`' -and
        $knownLimitations -match 'Executor unterstützt für Docker-/Podman-Instanzstores inzwischen\s*`RETAIN_INSTANCE_STORE`, `BACKUP_ON_REMOVE`, `PACKAGE_ON_REMOVE` und' -and
        $knownLimitations -match 'MDF/NDF/LDF-Dateien' -and
        $knownLimitations -match '(?s)`BACKUP_AND_PACKAGE`.*Backup.*Offline' -and
        $knownLimitations -match '(?s)`EXTERNAL_UNMANAGED`.*SourceMutated=false' -and
        $knownLimitations -match '(?s)`DELETE_WITH_RUN`.*persistierter.*?`DELETE_PENDING`.*?`DETACHED`.*?fehlendem Volume' -and
        $knownLimitations -match '(?s)vor\s+der ersten Runtime-Mutation eine UUID.*?`sql-server-lab\.persistent-storage-id`.*?keine zusätzliche Delete-Autorität' -and
        $knownLimitations -match '(?s)exakt einem erwarteten Container.*?revisionsgeschützt.*?`RUN_SCOPED`/\s*`RUN_CLEANUP`' -and
        $knownLimitations -match '(?s)Run-Cleanup entfernt.*?`sql-server-lab\.run-id`.*?`sql-server-lab\.scope-id`.*?Recovery-Pfad' -and
        $publicReadme -match '(?s)`PACKAGE_ON_REMOVE`.*`BACKUP_AND_PACKAGE`.*`EXTERNAL_UNMANAGED`.*ausschließlich die eigene Katalogbindung.*`DELETE_WITH_RUN`.*rungebundenen Containerstore.*jede andere endgültige Löschung bleiben blockiert' -and
        $removalPlanCommand -match '(?s)RETAIN_INSTANCE_STORE, BACKUP_ON_REMOVE, PACKAGE_ON_REMOVE und\s*BACKUP_AND_PACKAGE startbar.*?DELETE_WITH_RUN.*?RUN_SCOPED/RUN_CLEANUP' -and
        $workflowActionCommand -match '(?s)RETAIN_INSTANCE_STORE,\s*BACKUP_ON_REMOVE, PACKAGE_ON_REMOVE und BACKUP_AND_PACKAGE aus.*?DELETE_WITH_RUN.*?RUN_SCOPED/RUN_CLEANUP.*?DELETE_PENDING.*?Missing-Volume-Nachweis' -and
        $architecture -match '(?s)BACKUP_AND_PACKAGE.*Backup vor dem Offline-Schritt' -and
        $cliAcceptanceMatrix -match '(?s)MDF/NDF/LDF-Package-on-Remove und `BACKUP_AND_PACKAGE`.*Backup vor Offline-Schritt' -and
        $repoMap -match 'persistent_storage_removal_plan: Private/PersistentStorageRemovalPlan\.ps1' -and
        $repoMap -match 'persistent_storage_removal_executor: Private/PersistentStorageRemovalExecutor\.ps1' -and
        $repoMap -match 'container_database_package: Private/ContainerDatabasePackage\.ps1' -and
        $repoMap -match 'persistent_storage_removal_action: Public/Invoke-SqlServerLabPersistentStorageRemoval\.ps1' -and
        $repoMap -match 'persistent_storage_removal_intent_schema: Schemas/persistent-storage-removal-intent\.schema\.json' -and
        $repoMap -match 'persistent_storage_removal_plan_schema: Schemas/persistent-storage-removal-plan\.schema\.json' -and
        $repoMap -match 'persistent_storage_removal_journal_schema: Schemas/persistent-storage-removal-journal\.schema\.json' -and
        $repoMap -match 'validation_persistent_storage_removal_plan: Tests/Static/Invoke-PersistentStorageRemovalPlanChecks\.ps1' -and
        $repoMap -match 'validation_persistent_storage_removal_executor: Tests/Static/Invoke-PersistentStorageRemovalExecutorChecks\.ps1' -and
        $repoMap -match 'acceptance_persistent_storage_removal_executor: Tests/Integration/Invoke-PersistentStorageRemovalExecutorAcceptance\.ps1')

Add-ValidationResult `
    -Name 'PSR-005 dokumentiert stabilen Container-Store-Continue-/Clone-Core und reale Provider-Evidence' `
    -Success ($persistentStorageBacklog -match '(?m)^\| `PSR-005` .*\| `IMPLEMENTED`:' -and
        $persistentStorageBacklog -match [regex]::Escape('SqlServerLab.ContainerInstanceStoreIntent/1.0') -and
        $persistentStorageBacklog -match 'Docker und Podman getrennt\s*real belegt' -and
        $persistentStorageBacklog -match 'operationsgebundene Quell-Lease' -and
        $persistentStorageBacklog -match 'atomarer Zielcommit plus Quellfreigabe' -and
        $persistentStorageBacklog -match 'rollenfester External-Runtime-Mehr-Volume-Vertrag' -and
        $knownLimitations -match 'Commitfehler verhindert `COMPLETED`' -and
        $knownLimitations -match 'öffentliche CLI-/GUI-\s*Erstellungsflow nutzt denselben Core' -and
        $knownLimitations -match 'Unvollständige oder ungelabelte\s*Legacy-Sidecargruppen bleiben fail-closed' -and
        $repoMap -match 'container_instance_store: Private/ContainerInstanceStore\.ps1' -and
        $repoMap -match 'validation_container_instance_store: Tests/Static/Invoke-ContainerInstanceStoreChecks\.ps1' -and
        $repoMap -match 'acceptance_container_instance_store: Tests/Integration/Invoke-ContainerInstanceStoreAcceptance\.ps1')

Add-ValidationResult `
    -Name 'PSR-006 dokumentiert sanitisierte Runtime-Reichweite und REPORT_ONLY-Hostgrenze mit realer Evidence' `
    -Success ($persistentStorageBacklog -match '(?m)^\| `PSR-006` .*\| `IMPLEMENTED_READ_ONLY`:' -and
        $persistentStorageBacklog -match [regex]::Escape('SqlServerLab.ContainerRuntimeScope/1.0') -and
        $persistentStorageBacklog -match 'Docker-\s*Desktop- sowie Podman-WSL-Runtime belegt' -and
        $knownLimitations -match 'Runtime-Scope veröffentlicht davon\s*nur Status und Anzahl' -and
        $knownLimitations -match 'Dedizierte Lab-Runtimes sind erst nach einem separaten\s*Ownership-' -and
        $repoMap -match 'container_runtime_scope: Private/ContainerRuntimeScope\.ps1' -and
        $repoMap -match 'container_runtime_scope_schema: Schemas/container-runtime-scope\.schema\.json' -and
        $repoMap -match 'validation_container_runtime_scope: Tests/Static/Invoke-ContainerRuntimeScopeChecks\.ps1' -and
        $repoMap -match 'acceptance_container_runtime_scope: Tests/Integration/Invoke-ContainerRuntimeScopeAcceptance\.ps1')

Add-ValidationResult `
    -Name 'PSR-007 dokumentiert den vollständigen pfadfreien Hyper-V-VHDX-Lifecycle ohne falsche Datenbankbereitschaft' `
    -Success ($persistentStorageBacklog -match '(?m)^\| `PSR-007` .*\| `COMPLETE`:' -and
        $persistentStorageBacklog -match [regex]::Escape('SqlServerLab.HyperVPersistentDataIntent/1.0') -and
        $persistentStorageBacklog -match 'CLONE -> REATTACH -> RELEASE' -and
        $persistentStorageBacklog -match 'DatabaseFilesOnline=false' -and
        $knownLimitations -match 'reale\s*Hostnachweis (?:ist|sind) grün' -and
        $knownLimitations -match 'atomar(?:er|en)\s*Katalogcommit' -and
        $knownLimitations -match 'explizite SQL-Restore-/Attach-Schritt bleibt ein\s*getrennter' -and
        $repoMap -match 'hyperv_persistent_data_drive: Private/HyperVPersistentDataDrive\.ps1' -and
        $repoMap -match 'hyperv_persistent_data_intent_schema: Schemas/hyperv-persistent-data-intent\.schema\.json' -and
        $repoMap -match 'hyperv_persistent_data_detach_evidence_schema: Schemas/hyperv-persistent-data-detach-evidence\.schema\.json' -and
        $repoMap -match 'validation_hyperv_persistent_data_drive: Tests/Static/Invoke-HyperVPersistentDataDriveChecks\.ps1' -and
        $repoMap -match 'acceptance_hyperv_persistent_data_drive: Tests/Integration/Invoke-HyperVPersistentDataDriveAcceptance\.ps1')

Add-ValidationResult `
    -Name 'PSR-008 ist nur für tatsächlich unterstützte Provider-Capabilities abgeschlossen' `
    -Success ($persistentStorageBacklog -match '(?m)^\| `PSR-008` .*\| `COMPLETE`:' -and
        $persistentStorageBacklog -match '7_TOP_LEVEL_PACKAGES_REMAIN' -and
        $persistentStorageBacklog -match 'Cross-Provider-FILESTREAM.*`NOT_APPLICABLE`' -and
        $persistentStorageBacklog -match 'SQL Server\s*2025 auf Linux' -and
        $knownLimitations -match 'FILESTREAM-Cross-Provider-Lauf\s*ist in der aktuellen Matrix nicht möglich' -and
        $knownLimitations -match 'echte\s*FILESTREAM-Inhaltsevidence' -and
        $localValidationStrategy -match 'Kriterium ist `NOT_APPLICABLE`' -and
        $repoMap -match 'acceptance_backup_library_cross_provider: Tests/Integration/Invoke-BackupLibraryCrossProviderAcceptance\.ps1')

Add-ValidationResult `
    -Name 'PSR-014 bindet die idempotente Ersteinrichtung an Core, Konsole und Dokumentation' `
    -Success ($persistentStorageBacklog -match '(?m)^\| `PSR-014` .*\| `COMPLETE`:' -and
        $persistentStorageBacklog -match 'Von den 14 kanonischen PSR-Arbeitspaketen sind `PSR-001`, `PSR-002`, `PSR-005`,\s*`PSR-007`, `PSR-008`, `PSR-013` und `PSR-014` abgeschlossen\. Damit verbleiben sieben Top-Level-Pakete' -and
        $persistentStorageBacklog -match 'vor jeder Mutation fail-closed abgelehnt' -and
        $projectContext -match 'gemeinsamer idempotenter\s*Ersteinrichtungsassistent' -and
        $knownLimitations -match 'nichtleeren, noch nicht\s*controllergebundenen `Lab_Data`-Ordner' -and
        $repoMap -match 'initial_setup_contract: Private/InitialSetup\.ps1' -and
        $repoMap -match 'validation_initial_setup: Tests/Static/Invoke-InitialSetupChecks\.ps1')

Add-ValidationResult `
    -Name 'PSR-010 trennt Datenbankartefakte von Serverobjekten, TDE-Keymaterial und externen Services' `
    -Success ($persistentStorageBacklog -match '(?m)^\| `PSR-010` .*\| `IMPLEMENTED_CORE`:' -and
        $persistentStorageBacklog -match [regex]::Escape('SqlServerLab.DatabaseMigrationDependencyInventory/1.0') -and
        $persistentStorageBacklog -match [regex]::Escape('FullInstanceMigration=false') -and
        $knownLimitations -match '(?s)Serverkonfiguration, SSISDB und SSAS.*?`NOT_OBSERVABLE`' -and
        $knownLimitations -match '(?s)Objekt-, Host-, Credential- und Schlüsselnamen.*?nicht\s*persistiert' -and
        $knownLimitations -match '(?s)Persistierte Migrationskategorien und Warnungen.*?`DatabasePackageId`.*?CLI und Browser.*?ohne SQL erneut' -and
        $knownLimitations -match '`Get-SqlServerLabDatabaseMigrationDependency`' -and
        $repoMap -match 'database_migration_dependency_inventory: Private/DatabaseMigrationDependency\.ps1' -and
        $repoMap -match 'database_migration_dependency_public_inventory: Public/Get-SqlServerLabDatabaseMigrationDependency\.ps1' -and
        $repoMap -match 'database_migration_dependency_inventory_schema: Schemas/database-migration-dependency-inventory\.schema\.json' -and
        $repoMap -match 'validation_database_migration_dependency: Tests/Static/Invoke-DatabaseMigrationDependencyChecks\.ps1' -and
        $repoMap -match 'public_sanitized_migration_boundary_projection')

Add-ValidationResult `
    -Name 'PSR-012 trennt Retention, Residuen, Recovery und unverifizierbare Evidence read-only' `
    -Success ($persistentStorageBacklog -match '(?m)^\| `PSR-012` .*\| `IMPLEMENTED_CORE`:' -and
        $persistentStorageBacklog -match [regex]::Escape('SqlServerLab.CleanupFindings/1.0') -and
        $persistentStorageBacklog -match [regex]::Escape('AutomaticMutationAllowed=false') -and
        $knownLimitations -match 'bewusst retained und geteilte Ressourcen, unerwartete Residuen' -and
        $knownLimitations -match [regex]::Escape('AutomaticMutationAllowed=false') -and
        $repoMap -match 'cleanup_audit_findings: Private/CleanupAuditFindings\.ps1' -and
        $repoMap -match 'cleanup_audit_schema: Schemas/lab-cleanup-audit\.schema\.json')

Add-ValidationResult `
    -Name 'PSR-013 dokumentiert die journalisierte Location- und Hyper-V-Storage-Migration evidenzgebunden' `
    -Success ($persistentStorageBacklog -match '(?m)^\| `PSR-013` .*\| `COMPLETE`:' -and
        $persistentStorageBacklog -match [regex]::Escape('SqlServerLab.StorageMigrationPlan/1.0') -and
        $persistentStorageBacklog -match 'Copy/Hash/Referenzumschaltung' -and
        $persistentStorageBacklog -match 'Container-Bind-Mounts bleiben ein expliziter Plan-Blocker' -and
        $localValidationStrategy -match 'Invoke-StorageMigrationChecks\.ps1' -and
        $localValidationStrategy -match 'allgemeine `Lab_Data`-Parent-Migration' -and
        $repoMap -match 'validation_storage_migration: Tests/Static/Invoke-StorageMigrationChecks\.ps1' -and
        $repoMap -match 'storage_migration_plan_schema: Schemas/lab-storage-migration-plan\.schema\.json' -and
        $repoMap -match 'storage_migration_journal_schema: Schemas/lab-storage-migration-journal\.schema\.json')

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

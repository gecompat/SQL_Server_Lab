<#
.SYNOPSIS
    Schema-gesteuerte Eingabe und fachliche Validierung fuer Lab-Manifeste.
#>

function Get-LabManifestSchema {
    [CmdletBinding()]
    param()

    $schemaPath = Join-Path $script:SchemasPath 'lab-manifest.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        throw "Manifest-Schema nicht gefunden: $schemaPath"
    }

    return Get-Content -LiteralPath $schemaPath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
}

function Get-LabManifestInputContextLines {
    <#
    .SYNOPSIS
        Erzeugt die kontextbezogenen Hinweise fuer einen Wizard-Eingabeknoten.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$RootSchema,
        [Parameter(Mandatory)][string]$Path,
        [bool]$IsRequired,
        [string]$ManifestDirectory
    )

    $resolvedNode = Resolve-LabManifestSchemaNode -Node $Node -RootSchema $RootSchema
    $lines = [System.Collections.Generic.List[string]]::new()
    $uiProperty = $resolvedNode.PSObject.Properties['x-ui']
    $ui = if ($uiProperty) { $uiProperty.Value } else { $null }

    if ($ui -and $ui.label) {
        $lines.Add("Eingabe: $($ui.label)")
    }
    if ($ui -and $ui.help) {
        $lines.Add([string]$ui.help)
    }
    elseif ($resolvedNode.description) {
        $lines.Add([string]$resolvedNode.description)
    }

    $lines.Add($(if ($IsRequired) { 'Pflichtfeld.' } else { 'Optionales Feld.' }))

    if ($null -ne $resolvedNode.PSObject.Properties['default']) {
        $lines.Add("Default: $($resolvedNode.default)")
    }
    else {
        $lines.Add('Default: keiner.')
    }

    if ($ui -and $ui.defaultReason) {
        $lines.Add("Default-Begruendung: $($ui.defaultReason)")
    }

    if ($ui -and $ui.pathKind) {
        $lines.Add("Pfadart: $($ui.pathKind); Scope: $($ui.pathScope).")
        $lines.Add("Bezugsbasis relativer Werte: $($ui.pathBase).")
        $lines.Add("Beim Plan vorhanden: $($ui.mustExistAtPlan); Erzeugung: $($ui.createdByRuntime).")
    }

    if ($ui -and $ui.sideEffects) {
        $lines.Add("Auswirkung: $($ui.sideEffects)")
    }

    $examples = @($resolvedNode.examples | Where-Object { $null -ne $_ })
    if ($examples.Count -gt 0) {
        $lines.Add("Beispiel: $($examples[0])")
    }

    return @($lines)
}

function Write-LabManifestInputContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$RootSchema,
        [Parameter(Mandatory)][string]$Path,
        [bool]$IsRequired,
        [string]$ManifestDirectory
    )

    foreach ($line in @(Get-LabManifestInputContextLines `
            -Node $Node `
            -RootSchema $RootSchema `
            -Path $Path `
            -IsRequired:$IsRequired `
            -ManifestDirectory $ManifestDirectory)) {
        Write-Host "  $line" -ForegroundColor DarkGray
    }
}

function Write-LabManifestPathPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$Value,
        [string]$ManifestDirectory
    )

    $uiProperty = $Node.PSObject.Properties['x-ui']
    if (-not $uiProperty -or -not $uiProperty.Value.pathKind) {
        return
    }

    $ui = $uiProperty.Value
    if ($Value -match '^https?://') {
        Write-Host "  Aufgeloeste Vorschau: Remote-Artifact $Value" -ForegroundColor DarkGray
        return
    }

    if ($ui.pathBase -notmatch '^manifest-directory') {
        Write-Host "  Aufgeloeste Vorschau: Wert wird im Scope '$($ui.pathScope)' verwendet." -ForegroundColor DarkGray
        return
    }

    $basePath = if ($ManifestDirectory) { $ManifestDirectory } else { $PWD.Path }
    try {
        $preview = if ([System.IO.Path]::IsPathRooted($Value)) {
            [System.IO.Path]::GetFullPath($Value)
        }
        else {
            [System.IO.Path]::GetFullPath((Join-Path $basePath $Value))
        }
        Write-Host "  Aufgeloeste Vorschau: $preview" -ForegroundColor DarkGray
    }
    catch {
        Write-LabWarning "Pfadvorschau konnte nicht aufgeloest werden: $($_.Exception.Message)"
    }
}

function Test-LabManifestPathUiMetadata {
    <#
    .SYNOPSIS
        Prueft die verbindlichen x-ui-Pfadsemantiken des Manifest-Schemas.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RootSchema
    )

    $nodes = [ordered]@{
        'instances[].postProvision[]' = $RootSchema.definitions.instance.properties.postProvision.items
        'databases[].restore.source' = $RootSchema.definitions.database.properties.restore.properties.source
        'serverConfig.defaultPaths.data' = $RootSchema.definitions.serverConfig.properties.defaultPaths.properties.data
        'serverConfig.defaultPaths.log' = $RootSchema.definitions.serverConfig.properties.defaultPaths.properties.log
        'serverConfig.defaultPaths.backup' = $RootSchema.definitions.serverConfig.properties.defaultPaths.properties.backup
        'serverConfig.defaultPaths.tempdb' = $RootSchema.definitions.serverConfig.properties.defaultPaths.properties.tempdb
        'tempdbFile.path' = $RootSchema.definitions.tempdbFile.properties.path
        'drive.containerPath' = $RootSchema.definitions.drive.properties.containerPath
        'drive.hostPath' = $RootSchema.definitions.drive.properties.hostPath
        'dbFileExtended.path' = $RootSchema.definitions.dbFileExtended.properties.path
    }
    $requiredProperties = @('pathKind', 'pathBase', 'pathScope', 'mustExistAtPlan', 'createdByRuntime')
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $nodes.GetEnumerator()) {
        $uiProperty = $entry.Value.PSObject.Properties['x-ui']
        if (-not $uiProperty) {
            $errors.Add("$($entry.Key): x-ui fehlt.")
            continue
        }
        foreach ($propertyName in $requiredProperties) {
            if ($null -eq $uiProperty.Value.PSObject.Properties[$propertyName]) {
                $errors.Add("$($entry.Key): x-ui.$propertyName fehlt.")
            }
        }
    }

    return [PSCustomObject]@{
        IsValid = $errors.Count -eq 0
        Errors  = @($errors)
    }
}

function Resolve-LabManifestSchemaNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$RootSchema
    )

    $reference = $Node.PSObject.Properties['$ref'].Value
    if (-not $reference) {
        return $Node
    }
    if ($reference -notmatch '^#/definitions/([^/]+)$') {
        throw "Nicht unterstuetzte Schema-Referenz: $reference"
    }

    $definition = $RootSchema.definitions.PSObject.Properties[$Matches[1]].Value
    if (-not $definition) {
        throw "Schema-Definition nicht gefunden: $reference"
    }
    return $definition
}

function Test-LabManifestSchemaInputSupport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RootSchema
    )

    $unsupported = [System.Collections.Generic.List[string]]::new()

    function Test-SchemaNode {
        param(
            [Parameter(Mandatory)]$Node,
            [Parameter(Mandatory)][string]$Path
        )

        try {
            $resolvedNode = Resolve-LabManifestSchemaNode -Node $Node -RootSchema $RootSchema
        }
        catch {
            $unsupported.Add("${Path}: $($_.Exception.Message)")
            return
        }

        if ($resolvedNode.oneOf) {
            $alternativeIndex = 0
            foreach ($alternative in @($resolvedNode.oneOf | Where-Object { $null -ne $_ })) {
                $alternativeIndex++
                Test-SchemaNode -Node $alternative -Path "$Path.oneOf[$alternativeIndex]"
            }
            return
        }

        $supportedTypes = @('object', 'array', 'boolean', 'integer', 'number', 'string')
        if ($resolvedNode.type -notin $supportedTypes) {
            $unsupported.Add("${Path}: Schematyp '$($resolvedNode.type)' wird nicht unterstuetzt.")
            return
        }

        if ($resolvedNode.type -eq 'object') {
            foreach ($property in @($resolvedNode.properties.PSObject.Properties | Where-Object { $null -ne $_ })) {
                Test-SchemaNode -Node $property.Value -Path "$Path.$($property.Name)"
            }
            if ($resolvedNode.additionalProperties -and $resolvedNode.additionalProperties -isnot [bool]) {
                Test-SchemaNode -Node $resolvedNode.additionalProperties -Path "$Path.*"
            }
        }
        elseif ($resolvedNode.type -eq 'array') {
            if ($null -eq $resolvedNode.items) {
                $unsupported.Add("${Path}: Array besitzt kein items-Schema.")
            }
            else {
                Test-SchemaNode -Node $resolvedNode.items -Path "$Path[]"
            }
        }
    }

    Test-SchemaNode -Node $RootSchema -Path 'manifest'
    return [PSCustomObject]@{
        IsSupported = $unsupported.Count -eq 0
        Errors      = @($unsupported)
    }
}

function Select-LabManifestSampleReference {
    <#
    .SYNOPSIS
        Katalogauswahl fuer eine Sample-Referenz im Manifest-Wizard.
    .DESCRIPTION
        Zeigt alle mit dem Backup-Handler installierbaren Varianten mit
        erwarteter Datenbank, Groesse und Lizenz. Der Rueckgabewert enthaelt
        nur ID und Variante; Source und SHA-256 werden erst beim Provisionieren
        aufgeloest und im Run Lock festgehalten.
    #>
    [CmdletBinding()]
    param(
        [string]$Path = 'sample'
    )

    $variants = @(Get-LabExecutableSampleVariant)
    if ($variants.Count -eq 0) {
        return $null
    }

    $options = @($variants | ForEach-Object {
        "$($_.DisplayName) [$($_.SampleId):$($_.Variant)] -> Datenbank $($_.ExpectedDatabase), $($_.DownloadSizeMB) MB, Lizenz $($_.License)"
    }) + 'Sample-ID manuell eingeben'

    $selected = Read-LabChoice -Options $options -Prompt "$Path - Katalogauswahl"
    if ($selected -ge $variants.Count) {
        return $null
    }

    $variant = $variants[$selected]
    Write-Host "  Hinweis: Der Datenbankname dieser Instanz muss '$($variant.ExpectedDatabase)' lauten." -ForegroundColor DarkGray
    if (-not $variant.ExpectedSha256) {
        Write-Host '  Hinweis: Ohne Katalog-SHA-256 fragt die Provisionierung einmalig nach Vertrauen (interactive-once).' -ForegroundColor DarkGray
    }

    return [ordered]@{
        id      = $variant.SampleId
        variant = $variant.Variant
    }
}

function Read-LabManifestScalar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('string', 'integer', 'number')]$Type,
        [string]$ManifestDirectory
    )

    $hasDefault = $null -ne $Node.PSObject.Properties['default']
    $default = if ($hasDefault) { [string]$Node.default } else { '' }

    while ($true) {
        $raw = Read-LabString -Prompt $Path -Default $default

        if ($Type -eq 'string') {
            if ($Node.minLength -and $raw.Length -lt [int]$Node.minLength) {
                Write-LabWarning "Mindestens $($Node.minLength) Zeichen erforderlich."
                continue
            }
            if ($Node.pattern -and $raw -notmatch $Node.pattern) {
                Write-LabWarning "Eingabe entspricht nicht dem Muster: $($Node.pattern)"
                continue
            }
            if ($Node.format -eq 'uri') {
                $uri = $null
                if (-not [uri]::TryCreate($raw, [UriKind]::Absolute, [ref]$uri)) {
                    Write-LabWarning 'Bitte eine absolute URI eingeben.'
                    continue
                }
            }
            Write-LabManifestPathPreview -Node $Node -Value $raw -ManifestDirectory $ManifestDirectory
            return $raw
        }

        if ($Type -eq 'integer') {
            $number = [long]0
            if (-not [long]::TryParse($raw, [ref]$number)) {
                Write-LabWarning 'Bitte eine ganze Zahl eingeben.'
                continue
            }
        }
        else {
            $number = [double]0
            $parsed = [double]::TryParse(
                $raw,
                [Globalization.NumberStyles]::Number,
                [Globalization.CultureInfo]::CurrentCulture,
                [ref]$number
            )
            if (-not $parsed) {
                $parsed = [double]::TryParse(
                    $raw,
                    [Globalization.NumberStyles]::Number,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$number
                )
            }
            if (-not $parsed) {
                Write-LabWarning 'Bitte eine Zahl eingeben.'
                continue
            }
        }

        if ($null -ne $Node.PSObject.Properties['minimum'] -and $number -lt $Node.minimum) {
            Write-LabWarning "Der kleinste erlaubte Wert ist $($Node.minimum)."
            continue
        }
        if ($null -ne $Node.PSObject.Properties['maximum'] -and $number -gt $Node.maximum) {
            Write-LabWarning "Der groesste erlaubte Wert ist $($Node.maximum)."
            continue
        }
        return $number
    }
}

function Read-LabManifestSchemaValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$RootSchema,
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ExcludedProperties = @(),
        [string]$ManifestDirectory,
        [switch]$SuppressInputContext
    )

    $Node = Resolve-LabManifestSchemaNode -Node $Node -RootSchema $RootSchema

    if ($Node.oneOf) {
        if (-not $SuppressInputContext) {
            Write-LabManifestInputContext `
                -Node $Node `
                -RootSchema $RootSchema `
                -Path $Path `
                -ManifestDirectory $ManifestDirectory
        }
        $alternatives = @($Node.oneOf)
        $labels = @($alternatives | ForEach-Object {
            $alternative = Resolve-LabManifestSchemaNode -Node $_ -RootSchema $RootSchema
            switch ($alternative.type) {
                'boolean' { 'Einfach: Ja/Nein' }
                'object'  { 'Detaillierte Konfiguration' }
                default   { [string]$alternative.type }
            }
        })
        $selected = Read-LabChoice -Options $labels -Prompt "$Path - Eingabeform"
        return Read-LabManifestSchemaValue `
            -Node $alternatives[$selected] `
            -RootSchema $RootSchema `
            -Path $Path `
            -ManifestDirectory $ManifestDirectory
    }

    $enumValues = @($Node.enum | Where-Object { $null -ne $_ })
    if ($enumValues.Count -gt 0) {
        if (-not $SuppressInputContext) {
            Write-LabManifestInputContext `
                -Node $Node `
                -RootSchema $RootSchema `
                -Path $Path `
                -ManifestDirectory $ManifestDirectory
        }
        $defaultIndex = 1
        if ($null -ne $Node.PSObject.Properties['default']) {
            $matchedIndex = [array]::IndexOf($enumValues, $Node.default)
            if ($matchedIndex -ge 0) {
                $defaultIndex = $matchedIndex + 1
            }
        }
        $selected = Read-LabChoice `
            -Options @($enumValues | ForEach-Object { [string]$_ }) `
            -Prompt $Path `
            -Default $defaultIndex
        return $enumValues[$selected]
    }

    switch ($Node.type) {
        'object' {
            if ($Path -match '\.sample$') {
                $sampleReference = Select-LabManifestSampleReference -Path $Path
                if ($sampleReference) {
                    return $sampleReference
                }
            }

            $result = [ordered]@{}
            $requiredNames = @($Node.required)

            foreach ($property in @($Node.properties.PSObject.Properties | Where-Object { $null -ne $_ })) {
                if ($property.Name -in $ExcludedProperties) {
                    continue
                }

                $propertyPath = "$Path.$($property.Name)"
                $isRequired = $property.Name -in $requiredNames
                $include = $isRequired
                if (-not $isRequired) {
                    Write-LabManifestInputContext `
                        -Node $property.Value `
                        -RootSchema $RootSchema `
                        -Path $propertyPath `
                        -IsRequired:$false `
                        -ManifestDirectory $ManifestDirectory
                    $include = Read-LabConfirm -Prompt "Optionales Feld '$propertyPath' erfassen?" -Default $false
                }

                if ($include) {
                    $result[$property.Name] = Read-LabManifestSchemaValue `
                        -Node $property.Value `
                        -RootSchema $RootSchema `
                        -Path $propertyPath `
                        -ManifestDirectory $ManifestDirectory `
                        -SuppressInputContext:(!$isRequired)
                }
            }

            $additionalSchema = $Node.additionalProperties
            if ($additionalSchema -and $additionalSchema -isnot [bool]) {
                while ($true) {
                    $key = Read-Host "$Path - weiterer Schluessel [Enter beendet]"
                    if ([string]::IsNullOrWhiteSpace($key)) {
                        break
                    }
                    if ($result.Contains($key)) {
                        Write-LabWarning "Schluessel '$key' wurde bereits erfasst."
                        continue
                    }
                    $result[$key] = Read-LabManifestSchemaValue `
                        -Node $additionalSchema `
                        -RootSchema $RootSchema `
                        -Path "$Path.$key" `
                        -ManifestDirectory $ManifestDirectory
                }
            }
            return $result
        }
        'array' {
            $items = [System.Collections.Generic.List[object]]::new()
            $minimumItems = if ($Node.minItems) { [int]$Node.minItems } else { 1 }

            do {
                $itemNumber = $items.Count + 1
                $items.Add((Read-LabManifestSchemaValue `
                    -Node $Node.items `
                    -RootSchema $RootSchema `
                    -Path "$Path[$itemNumber]" `
                    -ManifestDirectory $ManifestDirectory))

                $addAnother = Read-LabConfirm -Prompt "Weiteren Eintrag zu '$Path' hinzufuegen?" -Default $false
            } while ($items.Count -lt $minimumItems -or $addAnother)

            Write-Output -NoEnumerate ($items.ToArray())
            return
        }
        'boolean' {
            if (-not $SuppressInputContext) {
                Write-LabManifestInputContext `
                    -Node $Node `
                    -RootSchema $RootSchema `
                    -Path $Path `
                    -ManifestDirectory $ManifestDirectory
            }
            $default = if ($null -ne $Node.PSObject.Properties['default']) {
                [bool]$Node.default
            }
            else {
                $false
            }
            return Read-LabConfirm -Prompt $Path -Default $default
        }
        'integer' {
            if (-not $SuppressInputContext) {
                Write-LabManifestInputContext -Node $Node -RootSchema $RootSchema -Path $Path -ManifestDirectory $ManifestDirectory
            }
            return Read-LabManifestScalar -Node $Node -Path $Path -Type integer -ManifestDirectory $ManifestDirectory
        }
        'number' {
            if (-not $SuppressInputContext) {
                Write-LabManifestInputContext -Node $Node -RootSchema $RootSchema -Path $Path -ManifestDirectory $ManifestDirectory
            }
            return Read-LabManifestScalar -Node $Node -Path $Path -Type number -ManifestDirectory $ManifestDirectory
        }
        'string' {
            if (-not $SuppressInputContext) {
                Write-LabManifestInputContext -Node $Node -RootSchema $RootSchema -Path $Path -ManifestDirectory $ManifestDirectory
            }
            return Read-LabManifestScalar -Node $Node -Path $Path -Type string -ManifestDirectory $ManifestDirectory
        }
        default {
            throw "Nicht unterstuetzter Schematyp '$($Node.type)' bei $Path."
        }
    }
}

function New-LabManifestDraft {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SchemaReference,
        [string]$ManifestDirectory = $PWD.Path
    )

    $schema = Get-LabManifestSchema
    $supportResult = Test-LabManifestSchemaInputSupport -RootSchema $schema
    if (-not $supportResult.IsSupported) {
        throw "Manifest-Schema kann nicht vollstaendig erfasst werden:`n  - $($supportResult.Errors -join "`n  - ")"
    }

    $entered = Read-LabManifestSchemaValue `
        -Node $schema `
        -RootSchema $schema `
        -Path 'manifest' `
        -ExcludedProperties @('$schema') `
        -ManifestDirectory $ManifestDirectory

    $manifest = [ordered]@{ '$schema' = $SchemaReference }
    foreach ($key in $entered.Keys) {
        $manifest[$key] = $entered[$key]
    }
    return $manifest
}

function Get-LabManifestValidationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Json,
        [string]$ManifestPath
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $schemaResult = Test-LabManifestSchema -Json $Json
    foreach ($schemaError in $schemaResult.Errors) {
        $errors.Add("Schema: $schemaError")
    }

    if (-not $schemaResult.IsValid) {
        return [PSCustomObject]@{
            IsValid  = $false
            Errors   = @($errors | Select-Object -Unique)
            Warnings = @()
        }
    }

    $manifestDirectory = if ($ManifestPath) {
        Split-Path -Parent ([System.IO.Path]::GetFullPath($ManifestPath))
    }
    else {
        $PWD.Path
    }

    $instanceIds = @($Manifest.instances | ForEach-Object { [string]$_.id })
    foreach ($duplicateId in @($instanceIds | Group-Object | Where-Object Count -gt 1)) {
        $errors.Add("Instanz-ID '$($duplicateId.Name)' ist nicht eindeutig.")
    }

    $effectiveProviders = [System.Collections.Generic.List[string]]::new()
    foreach ($instance in @($Manifest.instances)) {
        $instancePath = "instances[$($instance.id)]"
        $effectiveProvider = if ($instance.provider) {
            [string]$instance.provider
        }
        else {
            Resolve-ProviderAutoSelect -Instance $instance
        }
        $effectiveProviders.Add($effectiveProvider)

        if ($effectiveProvider -notin @('docker', 'podman', 'hyperv')) {
            $errors.Add("${instancePath}: Provider '$effectiveProvider' ist nicht implementiert.")
        }
        if ($effectiveProvider -in @('docker', 'podman') -and $instance.os -eq 'windows') {
            $errors.Add("${instancePath}: Windows wird vom Provider '$effectiveProvider' nicht unterstuetzt.")
        }
        if ($effectiveProvider -eq 'hyperv') {
            if ($instance.os -and $instance.os -ne 'windows') {
                $errors.Add("${instancePath}.os: Hyper-V-Prepared-Images benötigen os 'windows'.")
            }
            if (-not $instance.hyperv -or -not $instance.hyperv.preparedImageId) {
                $errors.Add("${instancePath}.hyperv.preparedImageId: Ein veröffentlichtes SQL-Prepared-Image ist erforderlich.")
            }
            if (@($instance.databases | Where-Object { $null -ne $_ }).Count -gt 0 -or
                @($instance.postProvision | Where-Object { $null -ne $_ }).Count -gt 0 -or
                @($instance.software | Where-Object { $null -ne $_ }).Count -gt 0 -or
                @($instance.drives | Where-Object { $null -ne $_ }).Count -gt 0) {
                $errors.Add("${instancePath}: Datenbanken, Software, freie Drives und Post-Provision-Skripte sind für den Hyper-V-Manifestpfad noch nicht atomar implementiert.")
            }
        }
        elseif ($instance.software) {
            $errors.Add("$instancePath.software: Software-Installationen benötigen den Hyper-V-Manifestpfad.")
        }

        $versionCheck = Test-SqlServerVersionSupported -VersionId $instance.version
        if (-not $versionCheck.Supported) {
            $errors.Add("$instancePath.version: $($versionCheck.Message)")
        }
        elseif ($versionCheck.Message) {
            $warnings.Add("$instancePath.version: $($versionCheck.Message)")
        }

        if ($effectiveProvider -in @('docker', 'podman')) {
            try {
                $null = Get-SqlServerDockerImage -VersionId $instance.version
            }
            catch {
                $errors.Add("$instancePath.version: $($_.Exception.Message)")
            }
        }

        $versionDefinition = Get-SqlServerVersion -VersionId $instance.version
        $databases = @($instance.databases | Where-Object { $null -ne $_ })
        $databaseNames = @($databases | ForEach-Object { [string]$_.name })
        foreach ($duplicateDatabase in @($databaseNames | Group-Object | Where-Object Count -gt 1)) {
            $errors.Add("${instancePath}: Datenbankname '$($duplicateDatabase.Name)' ist nicht eindeutig.")
        }

        foreach ($database in $databases) {
            $databasePath = "$instancePath.databases[$($database.name)]"
            if ($database.restore -and $database.sample) {
                $errors.Add("${databasePath}: 'restore' und 'sample' duerfen nicht gemeinsam verwendet werden.")
            }
            if (($database.restore -or $database.sample) -and $database.files) {
                $warnings.Add("$databasePath.files: Dateidefinitionen werden bei Restore/Sample derzeit ignoriert.")
            }

            $databaseFiles = @(
                @($database.files.data) + @($database.files.log) |
                    Where-Object { $null -ne $_ }
            )
            $logicalFileNames = @($databaseFiles | ForEach-Object { [string]$_.name })
            foreach ($duplicateFile in @($logicalFileNames | Group-Object | Where-Object Count -gt 1)) {
                $errors.Add("$databasePath.files: Logischer Dateiname '$($duplicateFile.Name)' ist nicht eindeutig.")
            }
            foreach ($file in $databaseFiles) {
                if ([string]::IsNullOrWhiteSpace($file.name)) {
                    $errors.Add("$databasePath.files: Logische Dateinamen duerfen nicht leer sein.")
                }
                if ($file.filegrowthMB -and $file.filegrowthPercent) {
                    $errors.Add("$databasePath.files[$($file.name)]: filegrowthMB und filegrowthPercent sind Alternativen.")
                }
                if ($file.filegrowthPercent -or $null -ne $file.PSObject.Properties['maxSizeMB']) {
                    $warnings.Add("$databasePath.files[$($file.name)]: filegrowthPercent und maxSizeMB werden von der Runtime noch nicht angewendet.")
                }
            }

            if ($database.options.compatibility -and $versionDefinition -and
                [int]$database.options.compatibility -gt [int]$versionDefinition.compatibilityLevel) {
                $errors.Add("$databasePath.options.compatibility: Level $($database.options.compatibility) ist fuer SQL Server $($instance.version) zu hoch.")
            }
            if ($database.options.autoClose -eq $true) {
                $warnings.Add("$databasePath.options.autoClose: AUTO_CLOSE ist fuer Serverbetrieb nicht empfohlen.")
            }
            if ($database.options.autoShrink -eq $true) {
                $warnings.Add("$databasePath.options.autoShrink: AUTO_SHRINK kann Fragmentierung verursachen.")
            }
            if ($database.options.pageVerify -eq 'NONE') {
                $warnings.Add("$databasePath.options.pageVerify: NONE deaktiviert die Seitenpruefung.")
            }
            if ($database.options.delayedDurability -eq 'FORCED') {
                $warnings.Add("$databasePath.options.delayedDurability: FORCED kann bei Ausfaellen Datenverlust verursachen.")
            }

            if ($database.restore) {
                $source = [string]$database.restore.source
                $isUrl = $source -match '^https?://'
                if ($database.restore.type -eq 'url' -and -not $isUrl) {
                    $errors.Add("$databasePath.restore: type 'url' erfordert eine HTTP(S)-URL.")
                }
                if ($database.restore.type -eq 'file' -and $isUrl) {
                    $errors.Add("$databasePath.restore: type 'file' kann keine HTTP(S)-URL verwenden.")
                }
                if (-not $isUrl) {
                    $localPath = if ([System.IO.Path]::IsPathRooted($source)) {
                        $source
                    }
                    else {
                        Join-Path $manifestDirectory $source
                    }
                    if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
                        $errors.Add("$databasePath.restore.source: Lokale Backup-Datei nicht gefunden: $localPath")
                    }
                }
            }

            if ($database.sample) {
                try {
                    $null = Resolve-LabSampleRestore `
                        -SampleDefinition $database.sample `
                        -SqlVersion $instance.version `
                        -TargetDatabaseName $database.name
                }
                catch {
                    $errors.Add("$databasePath.sample: $($_.Exception.Message)")
                }
            }
        }

        if ($instance.serverConfig -and
            $instance.serverConfig.memory -and
            $null -ne $instance.serverConfig.memory.minMB -and
            $null -ne $instance.serverConfig.memory.maxMB -and
            [int]$instance.serverConfig.memory.minMB -gt [int]$instance.serverConfig.memory.maxMB) {
            $errors.Add("$instancePath.serverConfig.memory: minMB darf maxMB nicht ueberschreiten.")
        }

        foreach ($traceFlag in @($instance.serverConfig.traceFlags | Where-Object { $null -ne $_ })) {
            if ([int]$traceFlag -le 0) {
                $errors.Add("$instancePath.serverConfig.traceFlags: '$traceFlag' muss positiv sein.")
            }
        }

        $preparedServerFields = @(
            'collation', 'defaultPaths', 'sqlAgent', 'clrEnabled', 'filestream',
            'containedDatabases', 'authMode', 'errorLogRetention', 'instantFileInit'
        )
        foreach ($fieldName in $preparedServerFields) {
            if ($instance.serverConfig.PSObject.Properties.Name -contains $fieldName) {
                $warnings.Add("$instancePath.serverConfig.$fieldName ist im Schema vorbereitet, wird aber noch nicht zuverlaessig angewendet.")
            }
        }
        if ($instance.serverConfig.externalScripts.customImage) {
            $warnings.Add("$instancePath.serverConfig.externalScripts.customImage wird noch nicht in die Provider-Imageauswahl uebernommen.")
        }
        if ($instance.serverConfig.externalScripts.installMethod -eq 'pre-built') {
            $warnings.Add("$instancePath.serverConfig.externalScripts.installMethod 'pre-built' ist noch nicht implementiert.")
        }

        $drives = @($instance.drives | Where-Object { $null -ne $_ })
        $driveIds = @($drives | ForEach-Object { [string]$_.id })
        foreach ($duplicateDrive in @($driveIds | Group-Object | Where-Object Count -gt 1)) {
            $errors.Add("$instancePath.drives: Drive-ID '$($duplicateDrive.Name)' ist nicht eindeutig.")
        }
        foreach ($drive in $drives) {
            if ([string]::IsNullOrWhiteSpace($drive.id)) {
                $errors.Add("$instancePath.drives: Drive-IDs duerfen nicht leer sein.")
            }
            if ([string]::IsNullOrWhiteSpace($drive.containerPath)) {
                $errors.Add("$instancePath.drives[$($drive.id)].containerPath darf nicht leer sein.")
            }
            if ($drive.sizeLimitGB) {
                $warnings.Add("$instancePath.drives[$($drive.id)].sizeLimitGB ist nur Metadatum und wird nicht erzwungen.")
            }
        }

        foreach ($scriptPath in @($instance.postProvision | Where-Object { $null -ne $_ })) {
            if ([string]::IsNullOrWhiteSpace($scriptPath)) {
                $errors.Add("$instancePath.postProvision: Skriptpfade duerfen nicht leer sein.")
                continue
            }
            $absoluteScriptPath = if ([System.IO.Path]::IsPathRooted($scriptPath)) {
                $scriptPath
            }
            else {
                Join-Path $manifestDirectory $scriptPath
            }
            if (-not (Test-Path -LiteralPath $absoluteScriptPath -PathType Leaf)) {
                $errors.Add("$instancePath.postProvision: SQL-Skript nicht gefunden: $absoluteScriptPath")
            }
        }
    }

    $hyperVInstances = @($Manifest.instances | Where-Object {
        $candidateProvider = if ($_.provider) { [string]$_.provider } else { Resolve-ProviderAutoSelect -Instance $_ }
        $candidateProvider -eq 'hyperv'
    })
    if ($hyperVInstances.Count -gt 0 -and $Manifest.instances.Count -ne 1) {
        $errors.Add('Hyper-V-Manifestbereitstellung unterstützt genau eine Hyper-V-Instanz und keine Mischung mit Container-Instanzen.')
    }
    if ($Manifest.persistentData -and $Manifest.persistentData.enabled -eq $true -and $Manifest.persistentData.dataRoot -and
        -not [System.IO.Path]::IsPathRooted([string]$Manifest.persistentData.dataRoot)) {
        $warnings.Add('persistentData.dataRoot wird relativ zum Manifest-Verzeichnis aufgelöst.')
    }

    if ($Manifest.resourceOverrides.maxMemoryMB -or $Manifest.resourceOverrides.maxCpus) {
        $warnings.Add('resourceOverrides.maxMemoryMB/maxCpus werden derzeit nicht in Provider-Limits uebernommen.')
    }
    if ($Manifest.resourceOverrides.skipAssessment -eq $true) {
        $warnings.Add('resourceOverrides.skipAssessment deaktiviert die Ressourcenpruefung vor der Provisionierung.')
    }

    return [PSCustomObject]@{
        IsValid  = $errors.Count -eq 0
        Errors   = @($errors | Select-Object -Unique)
        Warnings = @($warnings | Select-Object -Unique)
    }
}

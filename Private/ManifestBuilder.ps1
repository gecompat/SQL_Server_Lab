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

function Read-LabManifestScalar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('string', 'integer', 'number')]$Type
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
        [string[]]$ExcludedProperties = @()
    )

    $Node = Resolve-LabManifestSchemaNode -Node $Node -RootSchema $RootSchema

    if ($Node.oneOf) {
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
            -Path $Path
    }

    $enumValues = @($Node.enum | Where-Object { $null -ne $_ })
    if ($enumValues.Count -gt 0) {
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
                    $description = [string]$property.Value.description
                    if (-not $description) {
                        $resolvedProperty = Resolve-LabManifestSchemaNode `
                            -Node $property.Value `
                            -RootSchema $RootSchema
                        $description = [string]$resolvedProperty.description
                    }
                    if ($description) {
                        Write-Host "  $description" -ForegroundColor DarkGray
                    }
                    $include = Read-LabConfirm -Prompt "Optionales Feld '$propertyPath' erfassen?" -Default $false
                }

                if ($include) {
                    $result[$property.Name] = Read-LabManifestSchemaValue `
                        -Node $property.Value `
                        -RootSchema $RootSchema `
                        -Path $propertyPath
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
                        -Path "$Path.$key"
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
                    -Path "$Path[$itemNumber]"))

                $addAnother = Read-LabConfirm -Prompt "Weiteren Eintrag zu '$Path' hinzufuegen?" -Default $false
            } while ($items.Count -lt $minimumItems -or $addAnother)

            Write-Output -NoEnumerate ($items.ToArray())
            return
        }
        'boolean' {
            $default = if ($null -ne $Node.PSObject.Properties['default']) {
                [bool]$Node.default
            }
            else {
                $false
            }
            return Read-LabConfirm -Prompt $Path -Default $default
        }
        'integer' {
            return Read-LabManifestScalar -Node $Node -Path $Path -Type integer
        }
        'number' {
            return Read-LabManifestScalar -Node $Node -Path $Path -Type number
        }
        'string' {
            return Read-LabManifestScalar -Node $Node -Path $Path -Type string
        }
        default {
            throw "Nicht unterstuetzter Schematyp '$($Node.type)' bei $Path."
        }
    }
}

function New-LabManifestDraft {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SchemaReference
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
        -ExcludedProperties @('$schema')

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

        if ($effectiveProvider -notin @('docker', 'podman')) {
            $errors.Add("${instancePath}: Provider '$effectiveProvider' ist noch nicht implementiert.")
        }
        if ($effectiveProvider -in @('docker', 'podman') -and $instance.os -eq 'windows') {
            $errors.Add("${instancePath}: Windows wird vom Provider '$effectiveProvider' nicht unterstuetzt.")
        }
        if ($instance.software) {
            $errors.Add("$instancePath.software: Software-Installationen benoetigen den noch nicht implementierten Hyper-V-Provider.")
        }

        $versionCheck = Test-SqlServerVersionSupported -VersionId $instance.version
        if (-not $versionCheck.Supported) {
            $errors.Add("$instancePath.version: $($versionCheck.Message)")
        }
        elseif ($versionCheck.Message) {
            $warnings.Add("$instancePath.version: $($versionCheck.Message)")
        }

        try {
            $null = Get-SqlServerDockerImage -VersionId $instance.version
        }
        catch {
            $errors.Add("$instancePath.version: $($_.Exception.Message)")
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
                        -SqlVersion $instance.version
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

    if (@($effectiveProviders | Sort-Object -Unique).Count -gt 1) {
        $errors.Add('Gemischte Provider innerhalb eines Runs sind noch nicht implementiert.')
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
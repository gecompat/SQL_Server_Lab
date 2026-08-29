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
    if ($reference -eq 'lab-storage-intent.schema.json') {
        $schemaPath = Join-Path $script:SchemasPath 'lab-storage-intent.schema.json'
        return Get-Content -LiteralPath $schemaPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
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

function New-LabManifestNavigationResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Help', 'Back', 'Summary', 'Cancel')][string]$Action)

    return [PSCustomObject]@{
        PSTypeName = 'SqlServerLab.ManifestNavigation'
        Action = $Action
    }
}

function Test-LabManifestNavigationResult {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    return $null -ne $InputObject -and
        [string]$InputObject.PSTypeNames[0] -eq 'SqlServerLab.ManifestNavigation'
}

function Read-LabManifestChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Options,
        [Parameter(Mandatory)][string]$Prompt,
        [int]$Default = 1
    )

    $navigationOptions = @(
        '? Hilfe erneut anzeigen',
        '< Zum vorherigen Schritt',
        '= Aktuelle Zusammenfassung',
        '! Wizard abbrechen'
    )
    $selected = Read-LabChoice -Options @($Options + $navigationOptions) -Prompt $Prompt -Default $Default
    if ($selected -lt $Options.Count) {
        return $selected
    }

    switch ($selected - $Options.Count) {
        0 { return New-LabManifestNavigationResult -Action Help }
        1 { return New-LabManifestNavigationResult -Action Back }
        2 { return New-LabManifestNavigationResult -Action Summary }
        3 { return New-LabManifestNavigationResult -Action Cancel }
    }
}

function Write-LabManifestDraftSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][object]$Draft
    )

    Write-LabHeader "Manifest-Zusammenfassung: $Path"
    if ($null -eq $Draft -or ($Draft -is [System.Collections.IDictionary] -and $Draft.Count -eq 0)) {
        Write-LabInfo 'Noch keine Werte in diesem Abschnitt erfasst.'
        return
    }
    Write-Host ($Draft | ConvertTo-Json -Depth 30) -ForegroundColor DarkGray
}

function Select-LabManifestSampleReference {
    <#
    .SYNOPSIS
        Katalogauswahl fuer eine Sample-Referenz im Manifest-Wizard.
    .DESCRIPTION
        Zeigt alle mit dem Sample-Handler installierbaren Varianten mit
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

    $selected = Read-LabManifestChoice -Options $options -Prompt "$Path - Katalogauswahl"
    if (Test-LabManifestNavigationResult -InputObject $selected) {
        return $selected
    }
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

function Select-LabManifestExternalRuntimeReferences {
    <#
    .SYNOPSIS
        Katalogauswahl der im aktuellen Instanzkontext freigegebenen External Runtimes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$InstanceDraft,
        [string]$Path = 'software'
    )

    $instance = [PSCustomObject]$InstanceDraft
    $provider = if ($InstanceDraft.Contains('provider')) { [string]$InstanceDraft['provider'] } else { Resolve-ProviderAutoSelect -Instance $instance }
    $operatingSystem = if ($InstanceDraft.Contains('os')) {
        [string]$InstanceDraft['os']
    }
    elseif ($provider -eq 'hyperv') {
        'windows'
    }
    else {
        'linux'
    }
    $sqlVersion = [string]$InstanceDraft['version']

    if ($provider -eq 'hyperv') {
        Write-LabWarning "${Path}: Der Hyper-V-Manifestpfad bindet Software noch nicht atomar; es wird keine Variante angeboten."
        Write-Output -NoEnumerate ([object[]]@())
        return
    }

    $options = @(Get-LabExternalRuntimeSelectionOptions -SqlVersion $sqlVersion `
        -Provider $provider -OperatingSystem $operatingSystem)
    if ($options.Count -eq 0) {
        Write-LabWarning "${Path}: Fuer SQL $sqlVersion und $provider/$operatingSystem ist keine freigegebene External-Runtime-Variante vorhanden."
        Write-Output -NoEnumerate ([object[]]@())
        return
    }

    $selected = [System.Collections.Generic.List[object]]::new()
    :RuntimeSelection while ($true) {
        $remaining = @($options | Where-Object { @($selected.SoftwareId) -notcontains [string]$_.SoftwareId })
        if ($remaining.Count -eq 0) {
            break
        }
        $labels = @($remaining | ForEach-Object {
            "$($_.Language) $($_.RuntimeVersion) [$($_.VariantId)] - $($_.InstallationMethod), $($_.ArtifactCount) Artifacts, $($_.PackageLockCount) Package Locks"
        }) + 'Auswahl abschliessen'
        $choice = Read-LabManifestChoice -Options $labels -Prompt "$Path - freigegebene Variante"
        if (Test-LabManifestNavigationResult -InputObject $choice) {
            if ($choice.Action -eq 'Back' -and $selected.Count -gt 0) {
                $selected.RemoveAt($selected.Count - 1)
                continue RuntimeSelection
            }
            if ($choice.Action -eq 'Summary') {
                Write-LabManifestDraftSummary -Path $Path -Draft @($selected)
                continue RuntimeSelection
            }
            return $choice
        }
        if ($choice -ge $remaining.Count) {
            break
        }
        $selected.Add($remaining[$choice])
    }

    $manifestItems = @($selected | ForEach-Object {
        [ordered]@{
            id = [string]$_.SoftwareId
            version = [string]$_.RuntimeVersion
            variant = [string]$_.VariantId
            scope = 'sqlExternalRuntime'
            installMethod = 'catalog'
            optional = $false
        }
    })
    Write-Output -NoEnumerate ([object[]]$manifestItems)
}

function Write-LabManifestPlanPreview {
    <#
    .SYNOPSIS
        Zeigt die strukturierte, mutationsfreie Runtime- und Artifact-Planvorschau.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    $runtimeEntries = @($Plan.Instances | ForEach-Object { @($_.ExternalRuntimes.Entries) })
    $sampleEntries = @($Plan.Instances | ForEach-Object { @($_.Samples) })
    if ($runtimeEntries.Count -eq 0 -and $sampleEntries.Count -eq 0) {
        return
    }

    Write-LabHeader 'Manifest-Planvorschau'
    foreach ($instancePlan in @($Plan.Instances)) {
        foreach ($entry in @($instancePlan.ExternalRuntimes.Entries)) {
            Write-LabStatus -Label "$($instancePlan.InstanceId) / $($entry.Language)" `
                -Value "$($entry.Status), $($entry.ChangeClassification.Highest)"
            if ([string]$entry.Status -ne 'RESOLVED') {
                Write-LabWarning "  $($entry.ReasonCode): $($entry.Reason)"
                continue
            }
            Write-LabInfo "  Variante: $($entry.VariantId); Runtime: $($entry.RuntimeVersion); PlanKey: $($entry.PlanKey.Substring(0, 16))"
            Write-LabInfo "  Downloads: $(@($entry.Downloads).Count); Derived-Image-Build: $($entry.BuildDerivedImage); Gastmutation: $($entry.GuestMutation)"
            Write-LabInfo "  Reboots/Restarts: $(@($entry.Reboots) -join ', '); Downtime: $($entry.Downtime); Package Locks: $(@($entry.PackageLocks).Count)"
            Write-LabInfo "  Verification: $($entry.Verification.type) / $($entry.Verification.probeId)"
        }
        foreach ($sample in @($instancePlan.Samples)) {
            Write-LabStatus -Label "$($instancePlan.InstanceId) / $($sample.DatabaseName)" `
                -Value "$($sample.Status), $($sample.ArtifactType)"
            if ([string]$sample.Status -ne 'RESOLVED') {
                Write-LabWarning "  $($sample.Reason)"
                continue
            }
            Write-LabInfo "  Sample: $($sample.SampleId):$($sample.Variant); Outputs: $(@($sample.ExpectedOutputs.name) -join ', ')"
            Write-LabInfo "  Quelle: $($sample.Source); Lizenz: $($sample.License)"
            Write-LabInfo "  Download: $($sample.DownloadSizeMB) MB; Installation: $($sample.EstimatedInstallSizeMB) MB; Handler: $($sample.ArtifactType)/$($sample.HandlerContractVersion)"
            Write-LabInfo "  Integritaet: $($sample.IntegrityStatus); Trust: $($sample.TrustPolicy); Idempotenz: $($sample.IdempotencyMode)"
        }
    }
}

function Write-LabManifestSummary {
    <#
    .SYNOPSIS
        Zeigt den validierten Manifestentwurf vor einer möglichen Speicherung.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$Validation
    )

    Write-LabHeader 'Manifest-Zusammenfassung vor dem Speichern'
    Write-LabStatus -Label 'Lab' -Value ([string]$Manifest.name)
    Write-LabStatus -Label 'Instanzen' -Value (@($Manifest.instances).Count)
    foreach ($instance in @($Manifest.instances)) {
        $instancePlan = @($Validation.Plan.Instances | Where-Object InstanceId -eq ([string]$instance.id))[0]
        $provider = if ($instancePlan) { [string]$instancePlan.Provider } else { [string]$instance.provider }
        Write-LabStatus -Label ([string]$instance.id) -Value "SQL $($instance.version), $provider, Profil $($instance.profile ?? 'standard')"
        $databases = @($instance.databases | Where-Object { $null -ne $_ })
        if ($databases.Count -gt 0) {
            Write-LabInfo "  Datenbanken: $(@($databases | ForEach-Object { if ($_.sample) { \"$($_.name) [Sample $($_.sample.id):$($_.sample.variant)]\" } elseif ($_.restore) { \"$($_.name) [Restore]\" } else { [string]$_.name } }) -join ', ')"
        }
        $drives = @($instance.drives | Where-Object { $null -ne $_ })
        if ($drives.Count -gt 0) {
            Write-LabInfo "  Storage: $(@($drives | ForEach-Object { \"$($_.id) -> $($_.containerPath)\" }) -join ', ')"
        }
        $softwareItems = @($instance.software | Where-Object { $null -ne $_ })
        if ($softwareItems.Count -gt 0) {
            Write-LabInfo "  Software: $(@($softwareItems.id) -join ', ')"
        }
        $postProvisionScripts = @($instance.postProvision | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($postProvisionScripts.Count -gt 0) {
            Write-LabInfo "  Post-Provision: $($postProvisionScripts -join ', ')"
        }
    }
    Write-LabStatus -Label 'Validierung' -Value "$(@($Validation.Errors).Count) Fehler, $(@($Validation.Warnings).Count) Warnungen"
    Write-LabInfo 'Mutation: Erst die spätere Provisionierung verändert Runtime und SQL; dieser Wizard schreibt ausschließlich das validierte Manifest.'
    Write-LabInfo 'Cleanup: Runtime-Ressourcen werden beim Provisionieren vor der ersten Mutation an den scopegebundenen Cleanup-Plan gebunden.'
}

function Read-LabManifestScalar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)]$RootSchema,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('string', 'integer', 'number')]$Type,
        [string]$ManifestDirectory
    )

    $hasDefault = $null -ne $Node.PSObject.Properties['default']
    $default = if ($hasDefault) { [string]$Node.default } else { '' }

    :ScalarInput while ($true) {
        $raw = Read-LabString -Prompt $Path -Default $default
        switch ([string]$raw) {
            '?' {
                Write-LabManifestInputContext -Node $Node -RootSchema $RootSchema -Path $Path -ManifestDirectory $ManifestDirectory
                continue ScalarInput
            }
            '<' { return New-LabManifestNavigationResult -Action Back }
            '=' { return New-LabManifestNavigationResult -Action Summary }
            '!' { return New-LabManifestNavigationResult -Action Cancel }
        }

        if ($Type -eq 'string') {
            if ($Node.minLength -and $raw.Length -lt [int]$Node.minLength) {
                Write-LabWarning "Mindestens $($Node.minLength) Zeichen erforderlich."
                continue ScalarInput
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
        $selected = Read-LabManifestChoice -Options $labels -Prompt "$Path - Eingabeform"
        if (Test-LabManifestNavigationResult -InputObject $selected) {
            if ($selected.Action -eq 'Help') {
                Write-LabManifestInputContext -Node $Node -RootSchema $RootSchema -Path $Path -ManifestDirectory $ManifestDirectory
                return Read-LabManifestSchemaValue -Node $Node -RootSchema $RootSchema -Path $Path -ExcludedProperties $ExcludedProperties -ManifestDirectory $ManifestDirectory -SuppressInputContext
            }
            return $selected
        }
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
        $selected = Read-LabManifestChoice `
            -Options @($enumValues | ForEach-Object { [string]$_ }) `
            -Prompt $Path `
            -Default $defaultIndex
        if (Test-LabManifestNavigationResult -InputObject $selected) {
            if ($selected.Action -eq 'Help') {
                Write-LabManifestInputContext -Node $Node -RootSchema $RootSchema -Path $Path -ManifestDirectory $ManifestDirectory
                return Read-LabManifestSchemaValue -Node $Node -RootSchema $RootSchema -Path $Path -ExcludedProperties $ExcludedProperties -ManifestDirectory $ManifestDirectory -SuppressInputContext
            }
            return $selected
        }
        return $enumValues[$selected]
    }

    switch ($Node.type) {
        'object' {
            if ($Path -match '\.sample$') {
                $sampleReference = Select-LabManifestSampleReference -Path $Path
                if (Test-LabManifestNavigationResult -InputObject $sampleReference) {
                    return $sampleReference
                }
                if ($sampleReference) {
                    return $sampleReference
                }
            }

            $result = [ordered]@{}
            $requiredNames = @($Node.required)
            $properties = @($Node.properties.PSObject.Properties | Where-Object {
                $null -ne $_ -and $_.Name -notin $ExcludedProperties
            })
            $propertyIndex = 0

            :PropertyLoop while ($propertyIndex -lt $properties.Count) {
                $property = $properties[$propertyIndex]

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
                    $includeChoice = Read-LabManifestChoice `
                        -Options @('Feld erfassen', 'Feld ueberspringen') `
                        -Prompt "Optionales Feld '$propertyPath'" `
                        -Default 2
                    if (Test-LabManifestNavigationResult -InputObject $includeChoice) {
                        switch ($includeChoice.Action) {
                            'Help' { continue PropertyLoop }
                            'Summary' { Write-LabManifestDraftSummary -Path $Path -Draft $result; continue PropertyLoop }
                            'Cancel' { return $includeChoice }
                            'Back' {
                                if ($propertyIndex -eq 0) { return $includeChoice }
                                $propertyIndex--
                                [void]$result.Remove($properties[$propertyIndex].Name)
                                continue PropertyLoop
                            }
                        }
                    }
                    $include = $includeChoice -eq 0
                }

                if ($include) {
                    $value = if ($property.Name -eq 'software' -and $Path -match '^manifest\.instances\[\d+\]$') {
                        Select-LabManifestExternalRuntimeReferences -InstanceDraft $result -Path $propertyPath
                    }
                    else {
                        Read-LabManifestSchemaValue `
                            -Node $property.Value `
                            -RootSchema $RootSchema `
                            -Path $propertyPath `
                            -ManifestDirectory $ManifestDirectory `
                            -SuppressInputContext:(!$isRequired)
                    }
                    if (Test-LabManifestNavigationResult -InputObject $value) {
                        switch ($value.Action) {
                            'Help' {
                                Write-LabManifestInputContext -Node $property.Value -RootSchema $RootSchema -Path $propertyPath -IsRequired:$isRequired -ManifestDirectory $ManifestDirectory
                                continue PropertyLoop
                            }
                            'Summary' { Write-LabManifestDraftSummary -Path $Path -Draft $result; continue PropertyLoop }
                            'Cancel' { return $value }
                            'Back' {
                                if ($propertyIndex -eq 0) { return $value }
                                $propertyIndex--
                                [void]$result.Remove($properties[$propertyIndex].Name)
                                continue PropertyLoop
                            }
                        }
                    }
                    $result[$property.Name] = $value
                }
                else {
                    [void]$result.Remove($property.Name)
                }
                $propertyIndex++
            }

            $additionalSchema = $Node.additionalProperties
            if ($additionalSchema -and $additionalSchema -isnot [bool]) {
                while ($true) {
                    $key = Read-Host "$Path - weiterer Schluessel [Enter beendet, < zurueck, = Zusammenfassung, ! Abbruch]"
                    if ([string]::IsNullOrWhiteSpace($key)) {
                        break
                    }
                    if ($key -eq '=') { Write-LabManifestDraftSummary -Path $Path -Draft $result; continue }
                    if ($key -eq '!') { return New-LabManifestNavigationResult -Action Cancel }
                    if ($key -eq '<') {
                        $lastKey = @($result.Keys | Select-Object -Last 1)
                        if ($lastKey.Count -eq 0) { return New-LabManifestNavigationResult -Action Back }
                        [void]$result.Remove([string]$lastKey[0])
                        continue
                    }
                    if ($key -eq '?') {
                        Write-LabInfo 'Ein freier Schluessel wird nach dem zusätzlichen Schema validiert; Enter beendet diesen Abschnitt.'
                        continue
                    }
                    if ($result.Contains($key)) {
                        Write-LabWarning "Schluessel '$key' wurde bereits erfasst."
                        continue
                    }
                    $additionalValue = Read-LabManifestSchemaValue `
                        -Node $additionalSchema `
                        -RootSchema $RootSchema `
                        -Path "$Path.$key" `
                        -ManifestDirectory $ManifestDirectory
                    if (Test-LabManifestNavigationResult -InputObject $additionalValue) {
                        if ($additionalValue.Action -eq 'Cancel') { return $additionalValue }
                        if ($additionalValue.Action -eq 'Summary') { Write-LabManifestDraftSummary -Path $Path -Draft $result }
                        continue
                    }
                    $result[$key] = $additionalValue
                }
            }
            return $result
        }
        'array' {
            $items = [System.Collections.Generic.List[object]]::new()
            $minimumItems = if ($Node.minItems) { [int]$Node.minItems } else { 1 }

            :ItemLoop while ($true) {
                $itemNumber = $items.Count + 1
                $itemValue = Read-LabManifestSchemaValue `
                    -Node $Node.items `
                    -RootSchema $RootSchema `
                    -Path "$Path[$itemNumber]" `
                    -ManifestDirectory $ManifestDirectory
                if (Test-LabManifestNavigationResult -InputObject $itemValue) {
                    switch ($itemValue.Action) {
                        'Help' { continue ItemLoop }
                        'Summary' { Write-LabManifestDraftSummary -Path $Path -Draft @($items); continue ItemLoop }
                        'Cancel' { return $itemValue }
                        'Back' {
                            if ($items.Count -eq 0) { return $itemValue }
                            $items.RemoveAt($items.Count - 1)
                            continue ItemLoop
                        }
                    }
                }
                $items.Add($itemValue)

                if ($items.Count -lt $minimumItems) { continue }
                $nextChoice = Read-LabManifestChoice `
                    -Options @('Weiteren Eintrag hinzufuegen', 'Array abschliessen') `
                    -Prompt $Path `
                    -Default 2
                if (Test-LabManifestNavigationResult -InputObject $nextChoice) {
                    switch ($nextChoice.Action) {
                        'Help' { Write-LabInfo "Das Array '$Path' enthaelt aktuell $($items.Count) Eintrag(e)."; continue ItemLoop }
                        'Summary' { Write-LabManifestDraftSummary -Path $Path -Draft @($items); continue ItemLoop }
                        'Cancel' { return $nextChoice }
                        'Back' { $items.RemoveAt($items.Count - 1); continue ItemLoop }
                    }
                }
                if ($nextChoice -eq 1) { break }
            }

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
            $selected = Read-LabManifestChoice -Options @('Ja', 'Nein') -Prompt $Path -Default $(if ($default) { 1 } else { 2 })
            if (Test-LabManifestNavigationResult -InputObject $selected) {
                if ($selected.Action -eq 'Help') {
                    Write-LabManifestInputContext -Node $Node -RootSchema $RootSchema -Path $Path -ManifestDirectory $ManifestDirectory
                    return Read-LabManifestSchemaValue -Node $Node -RootSchema $RootSchema -Path $Path -ManifestDirectory $ManifestDirectory -SuppressInputContext
                }
                return $selected
            }
            return $selected -eq 0
        }
        'integer' {
            if (-not $SuppressInputContext) {
                Write-LabManifestInputContext -Node $Node -RootSchema $RootSchema -Path $Path -ManifestDirectory $ManifestDirectory
            }
            return Read-LabManifestScalar -Node $Node -RootSchema $RootSchema -Path $Path -Type integer -ManifestDirectory $ManifestDirectory
        }
        'number' {
            if (-not $SuppressInputContext) {
                Write-LabManifestInputContext -Node $Node -RootSchema $RootSchema -Path $Path -ManifestDirectory $ManifestDirectory
            }
            return Read-LabManifestScalar -Node $Node -RootSchema $RootSchema -Path $Path -Type number -ManifestDirectory $ManifestDirectory
        }
        'string' {
            if (-not $SuppressInputContext) {
                Write-LabManifestInputContext -Node $Node -RootSchema $RootSchema -Path $Path -ManifestDirectory $ManifestDirectory
            }
            return Read-LabManifestScalar -Node $Node -RootSchema $RootSchema -Path $Path -Type string -ManifestDirectory $ManifestDirectory
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

    if (Test-LabManifestNavigationResult -InputObject $entered) {
        return $entered
    }

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
    $instancePlanPreviews = [System.Collections.Generic.List[object]]::new()
    $schemaResult = Test-LabManifestSchema -Json $Json
    foreach ($schemaError in $schemaResult.Errors) {
        $errors.Add("Schema: $schemaError")
    }

    if (-not $schemaResult.IsValid) {
        return [PSCustomObject]@{
            IsValid  = $false
            Errors   = @($errors | Select-Object -Unique)
            Warnings = @()
            Plan     = [PSCustomObject]@{
                Contract = [PSCustomObject]@{ Name='SqlServerLab.ManifestPlanPreview'; Version='1.1' }
                Instances = @()
            }
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
        $runtimePlans = [System.Collections.Generic.List[object]]::new()
        $samplePlans = [System.Collections.Generic.List[object]]::new()
        $effectiveProvider = if ($instance.provider) {
            [string]$instance.provider
        }
        else {
            Resolve-ProviderAutoSelect -Instance $instance
        }
        $effectiveProviders.Add($effectiveProvider)

        if ($instance.autostart -and $instance.hyperv -and $instance.hyperv.autostart -and
            [string]$instance.autostart -ne [string]$instance.hyperv.autostart) {
            $errors.Add("${instancePath}: autostart und hyperv.autostart widersprechen einander.")
        }

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
                $warnings.Add("${instancePath}.hyperv.preparedImageId: Nicht gesetzt; zur Laufzeit wird deterministisch die höchste lokale SQL_PREPARED_SEALED-Vorlage auf Windows Server Standard Evaluation mit Desktop Experience gewählt.")
            }
            if (@($instance.databases | Where-Object { $null -ne $_ }).Count -gt 0 -or
                @($instance.postProvision | Where-Object { $null -ne $_ }).Count -gt 0 -or
                @($instance.software | Where-Object { $null -ne $_ }).Count -gt 0) {
                $errors.Add("${instancePath}: Datenbanken, Software und Post-Provision-Skripte sind für den Hyper-V-Manifestpfad noch nicht atomar implementiert.")
            }
            $hyperVDriveLetters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($drive in @($instance.drives | Where-Object { $_ })) {
                if ($drive.hostPath) {
                    $errors.Add("${instancePath}.drives[$($drive.id)].hostPath: Hyper-V-Zusatz-VHDX werden ausschließlich run-lokal erzeugt; Host-Mounts sind nicht zulässig.")
                }
                if (-not $drive.sizeLimitGB) {
                    $errors.Add("${instancePath}.drives[$($drive.id)].sizeLimitGB: Für Hyper-V-Zusatz-VHDX ist eine explizite Größe erforderlich.")
                }
                if ([string]$drive.containerPath -notmatch '^[D-Zd-z]:\\(?:[^<>:"/|?*\r\n]+(?:\\[^<>:"/|?*\r\n]+)*)?$') {
                    $errors.Add("${instancePath}.drives[$($drive.id)].containerPath: Hyper-V benötigt einen absoluten Windows-Gastpfad ab Laufwerk D:.")
                }
                else {
                    $driveLetter = ([string]$drive.containerPath).Substring(0, 1)
                    if (-not $hyperVDriveLetters.Add($driveLetter)) {
                        $errors.Add("${instancePath}.drives: Gastlaufwerk '$driveLetter' ist mehrfach belegt.")
                    }
                }
                if ([string]$drive.type -eq 'tmpfs') {
                    $errors.Add("${instancePath}.drives[$($drive.id)].type: tmpfs wird von Hyper-V nicht unterstützt.")
                }
            }
        }
        elseif (@($instance.software | Where-Object {
            $_ -and [string]$_.id -notin @('sql-python', 'sql-r', 'sql-java', 'sql-csharp')
        }).Count -gt 0) {
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
        if ($effectiveProvider -in @('docker', 'podman', 'hyperv')) {
            try {
                $runtimeRequests = @(ConvertTo-LabExternalRuntimeRequests `
                    -Software @($instance.software) `
                    -ExternalScripts $(if ($instance.serverConfig) { $instance.serverConfig.externalScripts } else { $null }))
                $effectiveOperatingSystem = if ($instance.os) {
                    [string]$instance.os
                }
                elseif ($effectiveProvider -eq 'hyperv') {
                    'windows'
                }
                else {
                    'linux'
                }
                foreach ($runtimeRequest in $runtimeRequests) {
                    $runtimePlan = Resolve-LabExternalRuntimePlan `
                        -SoftwareItem $runtimeRequest `
                        -SqlVersion ([string]$instance.version) `
                        -Provider $effectiveProvider `
                        -OperatingSystem $effectiveOperatingSystem
                    $runtimePlans.Add($runtimePlan)
                    if ([string]$runtimePlan.Status -ne 'RESOLVED') {
                        $errors.Add("$instancePath.software[$($runtimePlan.SoftwareId)]: $($runtimePlan.ReasonCode) - $($runtimePlan.Reason)")
                    }
                }
            }
            catch {
                $errors.Add("$instancePath.software: $($_.Exception.Message)")
            }
        }
        $instancePlanPreviews.Add([PSCustomObject]@{
            InstanceId = [string]$instance.id
            SqlVersion = [string]$instance.version
            Provider = $effectiveProvider
            OperatingSystem = if ($instance.os) { [string]$instance.os } elseif ($effectiveProvider -eq 'hyperv') { 'windows' } else { 'linux' }
            ExternalRuntimes = Get-LabExternalRuntimePlanPreview -DesiredPlans @($runtimePlans)
            Samples = $samplePlans
        })
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
                if ($isUrl -and -not $database.restore.sha256) {
                    $warnings.Add("$databasePath.restore.sha256 fehlt: Im unbeaufsichtigten Manifest-Standard endet der Download mit TRUST_REQUIRED.")
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
                    $samplePlan = Resolve-LabSampleRestore `
                        -SampleDefinition $database.sample `
                        -SqlVersion $instance.version `
                        -TargetDatabaseName $database.name
                    $samplePlans.Add([PSCustomObject]@{
                        DatabaseName = [string]$database.name
                        SampleId = [string]$samplePlan.sampleId
                        Variant = [string]$samplePlan.sampleVariant
                        Status = 'RESOLVED'
                        ArtifactType = [string]$samplePlan.artifactType
                        HandlerContractVersion = [string]$samplePlan.handlerContractVersion
                        Source = [string]$samplePlan.source
                        SourcePage = [string]$samplePlan.sourcePage
                        License = [string]$samplePlan.license
                        ExpectedOutputs = @($samplePlan.expectedOutputs)
                        DownloadSizeMB = $samplePlan.downloadSizeMB
                        EstimatedInstallSizeMB = $samplePlan.estimatedInstallSizeMB
                        IntegrityStatus = if ($samplePlan.expectedSha256) { 'catalog-sha256' } else { 'trust-required' }
                        ExpectedSha256 = [string]$samplePlan.expectedSha256
                        TrustPolicy = [string]$samplePlan.trustPolicy
                        IdempotencyMode = [string]$samplePlan.idempotencyMode
                        InstallationKind = [string]$samplePlan.installation.kind
                        Reason = $null
                    })
                }
                catch {
                    $errors.Add("$databasePath.sample: $($_.Exception.Message)")
                    $samplePlans.Add([PSCustomObject]@{
                        DatabaseName = [string]$database.name
                        SampleId = [string]$database.sample.id
                        Variant = [string]$database.sample.variant
                        Status = 'UNRESOLVED'
                        ArtifactType = $null
                        HandlerContractVersion = $null
                        Source = $null
                        SourcePage = $null
                        License = $null
                        ExpectedOutputs = @()
                        DownloadSizeMB = $null
                        EstimatedInstallSizeMB = $null
                        IntegrityStatus = 'unknown'
                        ExpectedSha256 = $null
                        TrustPolicy = $null
                        IdempotencyMode = $null
                        InstallationKind = $null
                        Reason = $_.Exception.Message
                    })
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
            if ($drive.hostPath -and [string]$drive.accessMode -eq 'readWrite' -and
                -not ($Manifest.expertActions -and $Manifest.expertActions.hostWriteMounts -eq $true)) {
                $errors.Add("$instancePath.drives[$($drive.id)]: Schreibende Host-Mounts erfordern expertActions.hostWriteMounts=true und beim Start -AllowExpertHostWriteMounts.")
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
    if ($Manifest.automation -and $Manifest.automation.mode -eq 'interactive') {
        $warnings.Add('automation.mode interactive ist ein expliziter Kompatibilitätsmodus; der Manifest-Primärweg ist unattended.')
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
        Plan     = [PSCustomObject]@{
            Contract = [PSCustomObject]@{ Name='SqlServerLab.ManifestPlanPreview'; Version='1.1' }
            Instances = @($instancePlanPreviews)
        }
    }
}

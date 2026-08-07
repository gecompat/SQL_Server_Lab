<#
.SYNOPSIS
    Manifest-Parser fuer SQL_Server_Lab.
.DESCRIPTION
    Liest JSON-Manifeste, validiert Pflichtfelder, wendet Defaults an und
    loest relative Pfade sowie unterstuetzte Sample-Datenbanken auf.
#>

function Test-LabManifestSchema {
    <#
    .SYNOPSIS
        Validiert Manifest-JSON gegen das autoritative JSON-Schema.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Json
    )

    $schemaPath = Join-Path $script:SchemasPath 'lab-manifest.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        throw "Manifest-Schema nicht gefunden: $schemaPath"
    }

    $schemaErrors = @()
    $isValid = Test-Json `
        -Json $Json `
        -SchemaFile $schemaPath `
        -ErrorAction SilentlyContinue `
        -ErrorVariable schemaErrors

    return [PSCustomObject]@{
        IsValid = [bool]$isValid
        Errors  = @($schemaErrors | ForEach-Object { $_.Exception.Message } | Select-Object -Unique)
    }
}

function Read-LabManifest {
    <#
    .SYNOPSIS
        Liest und normalisiert ein Lab-Manifest.
    .PARAMETER Path
        Pfad zur Manifest-JSON-Datei.
    .OUTPUTS
        PSCustomObject mit aufgeloestem Manifest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Manifest nicht gefunden: $Path"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $raw = Get-Content -LiteralPath $resolvedPath -Raw -Encoding utf8

    try {
        $manifest = $raw | ConvertFrom-Json -Depth 30
    }
    catch {
        throw "Manifest-JSON ungueltig: $resolvedPath - $($_.Exception.Message)"
    }

    $schemaResult = Test-LabManifestSchema -Json $raw
    if (-not $schemaResult.IsValid) {
        $details = if ($schemaResult.Errors.Count -gt 0) {
            $schemaResult.Errors -join "`n  - "
        }
        else {
            'Unbekannter Schemafehler'
        }
        throw "Manifest-Schema-Validierung fehlgeschlagen:`n  - $details"
    }

    $errors = @()
    if (-not $manifest.name) {
        $errors += 'Feld "name" fehlt'
    }
    if (-not $manifest.instances -or $manifest.instances.Count -eq 0) {
        $errors += 'Feld "instances" fehlt oder ist leer'
    }

    if ($manifest.instances) {
        for ($index = 0; $index -lt $manifest.instances.Count; $index++) {
            $instance = $manifest.instances[$index]
            if (-not $instance.id) {
                $errors += "instances[$index]: Feld 'id' fehlt"
            }
            if (-not $instance.version) {
                $errors += "instances[$index]: Feld 'version' fehlt"
            }

            if ($instance.databases) {
                for ($databaseIndex = 0; $databaseIndex -lt $instance.databases.Count; $databaseIndex++) {
                    $database = $instance.databases[$databaseIndex]
                    if (-not $database.name) {
                        $errors += "instances[$index].databases[$databaseIndex]: Feld 'name' fehlt"
                    }
                    if ($database.restore -and $database.sample) {
                        $errors += "instances[$index].databases[$databaseIndex]: 'restore' und 'sample' duerfen nicht gemeinsam verwendet werden"
                    }
                }
            }
        }
    }

    if ($errors.Count -gt 0) {
        throw "Manifest-Validierung fehlgeschlagen:`n  - $($errors -join "`n  - ")"
    }

    $semanticResult = Get-LabManifestValidationResult `
        -Manifest $manifest `
        -Json $raw `
        -ManifestPath $resolvedPath
    foreach ($warning in $semanticResult.Warnings) {
        Write-LabWarning $warning
    }
    if (-not $semanticResult.IsValid) {
        throw "Manifest-Fachvalidierung fehlgeschlagen:`n  - $($semanticResult.Errors -join "`n  - ")"
    }

    return Resolve-ManifestDefaults -Manifest $manifest -ManifestPath $resolvedPath
}

function Resolve-LabSampleArtifact {
    <#
    .SYNOPSIS
        Loest eine Sample-Referenz in den gemeinsamen Artifact-Vertrag auf.

    .DESCRIPTION
        Diese Funktion liest ausschliesslich Katalogmetadaten und startet keine
        Acquisition oder Installation. Spezifische Handler muessen den
        Artifact Type sowie runtimeStatus anschliessend selbst pruefen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SampleDefinition,
        [Parameter(Mandatory)]
        [string]$SqlVersion
    )

    $sample = Get-LabSampleDatabase -Id $SampleDefinition.id
    if (-not $sample) {
        throw "Sample-Datenbank '$($SampleDefinition.id)' wurde im Katalog nicht gefunden."
    }

    $baseVersionText = ([string]$SqlVersion -split '-', 2)[0]
    if ($sample.minSqlVersion -and [int]$baseVersionText -lt [int]$sample.minSqlVersion) {
        throw "Sample-Datenbank '$($sample.id)' benoetigt mindestens SQL Server $($sample.minSqlVersion)."
    }

    $variant = if ($SampleDefinition.variant) { [string]$SampleDefinition.variant } else { 'full' }
    $variantProperty = $sample.versions.PSObject.Properties |
        Where-Object { $_.Name -eq $variant } |
        Select-Object -First 1

    if (-not $variantProperty) {
        $available = $sample.versions.PSObject.Properties.Name -join ', '
        throw "Variante '$variant' ist fuer Sample '$($sample.id)' nicht vorhanden. Verfuegbar: $available"
    }

    $variantDefinition = $variantProperty.Value
    $source = [string]$variantDefinition.url
    if (-not $source) {
        throw "Sample '$($sample.id)' Variante '$variant' besitzt keine Download-URL."
    }

    return [PSCustomObject]@{
        sampleId                = [string]$sample.id
        sampleVariant           = $variant
        artifactType            = [string]$variantDefinition.artifactType
        handlerContractVersion  = [string]$variantDefinition.handlerContractVersion
        source                  = $source
        sourcePage              = [string]$sample.source
        license                 = [string]$sample.license
        downloadSizeMB          = $variantDefinition.downloadSizeMB
        estimatedInstallSizeMB  = $variantDefinition.estimatedInstallSizeMB
        resourceEstimateStatus  = [string]$variantDefinition.resourceEstimateStatus
        expectedSha256          = if ($variantDefinition.sha256) { ([string]$variantDefinition.sha256).ToLowerInvariant() } else { $null }
        integrityOrigin         = $variantDefinition.integrityOrigin
        trustPolicy             = [string]$variantDefinition.trustPolicy
        compatibility           = $variantDefinition.compatibility
        expectedOutputs         = @($variantDefinition.expectedOutputs | ForEach-Object {
            [PSCustomObject]@{
                name = [string]$_.name
                kind = [string]$_.kind
            }
        })
        installation            = $variantDefinition.installation
        runtimeStatus           = [string]$variantDefinition.runtimeStatus
    }
}

function Resolve-LabSampleRestore {
    <#
    .SYNOPSIS
        Loest eine Sample-Referenz in einen aktuell unterstuetzten Installationsvertrag auf.

    .DESCRIPTION
        Unterstützt direkte Backups, ZIP-Backups und einzelne T-SQL-Skripte.
        Eine fehlende Katalogpruefsumme ist zulaessig; die Integritaet wird dann
        zur Laufzeit ueber den Trust-Pfad (interactive-once) des Artifact
        Resolvers gesichert. Nicht interaktive Laeufe enden dort mit
        TRUST_REQUIRED.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SampleDefinition,
        [Parameter(Mandatory)]
        [string]$SqlVersion,
        [Parameter(Mandatory)]
        [string]$TargetDatabaseName
    )

    $artifact = Resolve-LabSampleArtifact `
        -SampleDefinition $SampleDefinition `
        -SqlVersion $SqlVersion

    if ($artifact.runtimeStatus -ne 'executable') {
        throw "Sample '$($artifact.sampleId)' Variante '$($artifact.sampleVariant)' ist nur beschreibend katalogisiert und nicht fuer die automatische Ausfuehrung freigegeben."
    }
    if ($artifact.artifactType -notin @('backup', 'archive-backup', 'sql-script') -or
        [string]$artifact.installation.kind -ne [string]$artifact.artifactType) {
        throw "Sample '$($artifact.sampleId)' Variante '$($artifact.sampleVariant)' hat Artifact Type '$($artifact.artifactType)'. Der Manifestpfad unterstuetzt diesen Handler nicht."
    }
    if ([string]::IsNullOrWhiteSpace($artifact.expectedSha256) -and $artifact.trustPolicy -ne 'interactive-once') {
        throw "Sample '$($artifact.sampleId)' Variante '$($artifact.sampleVariant)' besitzt weder eine verifizierte SHA-256-Pruefsumme noch einen interaktiven Trust-Pfad."
    }
    if ($artifact.expectedOutputs.Count -ne 1 -or $artifact.expectedOutputs[0].kind -ne 'database') {
        throw "Sample '$($artifact.sampleId)' Variante '$($artifact.sampleVariant)' kann nicht als einzelner Backup-Restore verwendet werden, weil die erwarteten Ausgaben nicht eindeutig sind."
    }
    if ($artifact.expectedOutputs[0].name -ne $TargetDatabaseName) {
        throw "Sample '$($artifact.sampleId)' Variante '$($artifact.sampleVariant)' erwartet die Datenbank '$($artifact.expectedOutputs[0].name)', nicht '$TargetDatabaseName'."
    }

    return [PSCustomObject]@{
        source                  = $artifact.source
        type                    = 'url'
        replace                 = $false
        sampleId                = $artifact.sampleId
        sampleVariant           = $artifact.sampleVariant
        artifactType            = $artifact.artifactType
        handlerContractVersion  = $artifact.handlerContractVersion
        license                 = $artifact.license
        sourcePage              = $artifact.sourcePage
        expectedOutputs         = $artifact.expectedOutputs
        expectedSha256          = $artifact.expectedSha256
        integrityOrigin         = $artifact.integrityOrigin
        trustPolicy             = $artifact.trustPolicy
        compatibility           = $artifact.compatibility
        idempotencyMode         = [string]$artifact.installation.idempotencyMode
        installation            = $artifact.installation
        downloadSizeMB          = $artifact.downloadSizeMB
        estimatedInstallSizeMB  = $artifact.estimatedInstallSizeMB
    }
}

function Resolve-ManifestDefaults {
    <#
    .SYNOPSIS
        Wendet Defaults auf alle Instanzen an und loest Pfade auf.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Manifest,
        [string]$ManifestPath
    )

    $manifestDirectory = if ($ManifestPath) {
        Split-Path -Parent $ManifestPath
    }
    else {
        $PWD.Path
    }

    $resolvedInstances = @()

    foreach ($instance in $Manifest.instances) {
        $resolved = [PSCustomObject]@{
            id            = $instance.id
            version       = $instance.version
            provider      = if ($instance.provider) { $instance.provider } else { 'docker' }
            os            = if ($instance.os) { $instance.os } else { 'linux' }
            profile       = if ($instance.profile) { $instance.profile } else { 'standard' }
            collation     = if ($instance.collation) { $instance.collation } else { 'SQL_Latin1_General_CP1_CS_AS' }
            databases     = @()
            drives        = @()
            serverConfig  = $null
            software      = @()
            postProvision = @()
            hyperv        = $null
        }

        if (-not $instance.provider) {
            $resolved.provider = Resolve-ProviderAutoSelect -Instance $instance
        }

        if ($instance.databases) {
            foreach ($database in $instance.databases) {
                if ($database.restore -and $database.sample) {
                    throw "Datenbank '$($database.name)': 'restore' und 'sample' sind Alternativen und duerfen nicht gemeinsam angegeben werden."
                }

                $restoreDefinition = $null

                if ($database.sample) {
                    $restoreDefinition = Resolve-LabSampleRestore `
                        -SampleDefinition $database.sample `
                        -SqlVersion $resolved.version `
                        -TargetDatabaseName $database.name
                }
                elseif ($database.restore) {
                    $source = [string]$database.restore.source
                    if (-not $source) {
                        throw "Datenbank '$($database.name)': restore.source fehlt."
                    }

                    if ($source -notmatch '^https?://' -and -not [System.IO.Path]::IsPathRooted($source)) {
                        $source = Join-Path $manifestDirectory $source
                    }

                    $restoreDefinition = [PSCustomObject]@{
                        source  = $source
                        type    = if ($database.restore.type) { $database.restore.type } else { 'auto' }
                        replace = if ($null -ne $database.restore.replace) { [bool]$database.restore.replace } else { $true }
                        expectedSha256 = $null
                    }
                }

                $resolvedDatabase = [PSCustomObject]@{
                    name      = $database.name
                    collation = if ($database.collation) { $database.collation } else { $resolved.collation }
                    options   = if ($database.options) { $database.options } else { @{ queryStore = $true } }
                    files     = Resolve-DatabaseFiles -DatabaseDef $database
                    restore   = $restoreDefinition
                    sample    = if ($database.sample) { $database.sample } else { $null }
                }

                $resolved.databases += $resolvedDatabase
            }
        }

        if ($instance.drives) {
            foreach ($drive in $instance.drives) {
                $hostPath = $drive.hostPath
                if ($hostPath -and -not [System.IO.Path]::IsPathRooted($hostPath)) {
                    $hostPath = Join-Path $manifestDirectory $hostPath
                }

                $resolved.drives += [PSCustomObject]@{
                    id            = $drive.id
                    containerPath = $drive.containerPath
                    hostPath      = $hostPath
                    sizeLimitGB   = $drive.sizeLimitGB
                    type          = if ($drive.type) { $drive.type } else { 'auto' }
                }
            }
        }

        if ($instance.serverConfig) {
            $config = $instance.serverConfig
            $resolved.serverConfig = [PSCustomObject]@{
                memory = if ($config.memory) {
                    [PSCustomObject]@{
                        minMB = $config.memory.minMB
                        maxMB = $config.memory.maxMB
                    }
                }
                else {
                    $null
                }
                tempdb = if ($config.tempdb) {
                    [PSCustomObject]@{
                        dataFiles = @($config.tempdb.dataFiles)
                        logFile   = $config.tempdb.logFile
                        equalSize = if ($null -ne $config.tempdb.equalSize) { [bool]$config.tempdb.equalSize } else { $true }
                    }
                }
                else {
                    $null
                }
                maxDop           = if ($null -ne $config.maxDop) { $config.maxDop } else { 0 }
                costThreshold    = if ($null -ne $config.costThreshold) { $config.costThreshold } else { 5 }
                traceFlags       = if ($config.traceFlags) { @($config.traceFlags) } else { @() }
                spConfigure      = $config.spConfigure
                externalScripts = $config.externalScripts
            }
        }

        if ($instance.software) {
            foreach ($softwareItem in $instance.software) {
                $resolved.software += [PSCustomObject]@{
                    id       = $softwareItem.id
                    source   = $softwareItem.source
                    package  = $softwareItem.package
                    url      = $softwareItem.url
                    command  = $softwareItem.command
                    optional = if ($null -ne $softwareItem.optional) { [bool]$softwareItem.optional } else { $true }
                }
            }
        }

        if ($instance.postProvision) {
            foreach ($scriptPath in $instance.postProvision) {
                $absolutePath = if ([System.IO.Path]::IsPathRooted($scriptPath)) {
                    $scriptPath
                }
                else {
                    Join-Path $manifestDirectory $scriptPath
                }
                $resolved.postProvision += $absolutePath
            }
        }

        if ($instance.hyperv) {
            $resolved.hyperv = [PSCustomObject]@{
                preparedImageId   = [string]$instance.hyperv.preparedImageId
                switchName        = [string]$instance.hyperv.switchName
                memoryStartupMB   = if ($instance.hyperv.memoryStartupMB) { [int]$instance.hyperv.memoryStartupMB } else { 4096 }
                processorCount    = if ($instance.hyperv.processorCount) { [int]$instance.hyperv.processorCount } else { 4 }
                guestPasswordMode = if ($instance.hyperv.guestPasswordMode) { [string]$instance.hyperv.guestPasswordMode } else { 'generated' }
            }
        }

        $resolvedInstances += $resolved
    }

    $persistentDataRoot = if ($Manifest.persistentData -and $Manifest.persistentData.dataRoot) {
        [string]$Manifest.persistentData.dataRoot
    }
    else { $null }
    if ($persistentDataRoot -and -not [System.IO.Path]::IsPathRooted($persistentDataRoot)) {
        $persistentDataRoot = Join-Path $manifestDirectory $persistentDataRoot
    }

    return [PSCustomObject]@{
        name              = $Manifest.name
        description       = $Manifest.description
        instances         = $resolvedInstances
        resourceOverrides = $Manifest.resourceOverrides
        persistentData    = [PSCustomObject]@{
            enabled    = [bool]($Manifest.persistentData -and $Manifest.persistentData.enabled -eq $true)
            dataRoot   = $persistentDataRoot
            dataDiskGB = if ($Manifest.persistentData -and $Manifest.persistentData.dataDiskGB) { [int]$Manifest.persistentData.dataDiskGB } else { 128 }
        }
        manifestPath      = $ManifestPath
    }
}

function Resolve-ProviderAutoSelect {
    [CmdletBinding()]
    param($Instance)

    if ($Instance.software) {
        $guiApplications = @('ssms', 'vscode', 'az-data-studio', 'visual-studio')
        $hasGuiApplication = $Instance.software | Where-Object { $_.id -in $guiApplications }
        if ($hasGuiApplication) {
            return 'hyperv'
        }
    }

    if ($Instance.os -eq 'windows') {
        return 'hyperv'
    }

    return 'docker'
}

function Resolve-DatabaseFiles {
    [CmdletBinding()]
    param($DatabaseDef)

    $files = @{
        data = @()
        log  = @()
    }

    if ($DatabaseDef.files -and $DatabaseDef.files.data) {
        foreach ($file in $DatabaseDef.files.data) {
            $files.data += @{
                name         = $file.name
                path         = $file.path
                sizeMB       = if ($file.sizeMB) { $file.sizeMB } else { 64 }
                filegrowthMB = if ($file.filegrowthMB) { $file.filegrowthMB } else { 64 }
            }
        }
    }
    else {
        $files.data += @{
            name         = "$($DatabaseDef.name)_Data"
            path         = $null
            sizeMB       = 64
            filegrowthMB = 64
        }
    }

    if ($DatabaseDef.files -and $DatabaseDef.files.log) {
        foreach ($file in $DatabaseDef.files.log) {
            $files.log += @{
                name         = $file.name
                path         = $file.path
                sizeMB       = if ($file.sizeMB) { $file.sizeMB } else { 32 }
                filegrowthMB = if ($file.filegrowthMB) { $file.filegrowthMB } else { 32 }
            }
        }
    }
    else {
        $files.log += @{
            name         = "$($DatabaseDef.name)_Log"
            path         = $null
            sizeMB       = 32
            filegrowthMB = 32
        }
    }

    return $files
}

<#
.SYNOPSIS
    Manifest-Parser fuer SQL_Server_Lab.
.DESCRIPTION
    Liest JSON-Manifeste, validiert Pflichtfelder, wendet Defaults an und
    loest relative Pfade sowie unterstuetzte Sample-Datenbanken auf.
#>

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

    return Resolve-ManifestDefaults -Manifest $manifest -ManifestPath $resolvedPath
}

function Resolve-LabSampleRestore {
    <#
    .SYNOPSIS
        Loest eine Sample-Referenz in einen unterstuetzten Backup-Restore auf.
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

    if ($variantDefinition.type -and $variantDefinition.type -ne 'backup') {
        throw "Sample '$($sample.id)' Variante '$variant' hat den Typ '$($variantDefinition.type)'. Der Manifestpfad unterstuetzt derzeit nur direkte .bak-Restores."
    }

    if ($source -notmatch '(?i)\.bak(?:$|\?)') {
        throw "Sample '$($sample.id)' Variante '$variant' ist kein direktes .bak-Backup und kann derzeit nicht automatisch bereitgestellt werden."
    }

    return [PSCustomObject]@{
        source        = $source
        type          = 'url'
        replace       = $true
        sampleId      = $sample.id
        sampleVariant = $variant
        license       = $sample.license
        sourcePage    = $sample.source
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
                        -SqlVersion $resolved.version
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

        $resolvedInstances += $resolved
    }

    return [PSCustomObject]@{
        name              = $Manifest.name
        description       = $Manifest.description
        instances         = $resolvedInstances
        resourceOverrides = $Manifest.resourceOverrides
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

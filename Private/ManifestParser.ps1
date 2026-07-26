<#
.SYNOPSIS
    Manifest-Parser fuer SQL_Server_Lab.
.DESCRIPTION
    Liest JSON-Manifeste, validiert Pflichtfelder, wendet Defaults an
    und liefert eine aufgeloeste Instanz-Liste zurueck.
#>

function Read-LabManifest {
    <#
    .SYNOPSIS Liest und validiert ein Lab-Manifest.
    .PARAMETER Path Pfad zur Manifest-JSON-Datei.
    .OUTPUTS PSCustomObject mit aufgeloestem Manifest.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Manifest nicht gefunden: $Path"
    }

    $raw = Get-Content $Path -Raw -Encoding utf8
    try {
        $manifest = $raw | ConvertFrom-Json -Depth 20
    }
    catch {
        throw "Manifest-JSON ungueltig: $Path - $_"
    }

    # Pflichtfeld-Validierung
    $errors = @()
    if (-not $manifest.name) { $errors += 'Feld "name" fehlt' }
    if (-not $manifest.instances -or $manifest.instances.Count -eq 0) {
        $errors += 'Feld "instances" fehlt oder leer'
    }

    if ($manifest.instances) {
        for ($i = 0; $i -lt $manifest.instances.Count; $i++) {
            $inst = $manifest.instances[$i]
            if (-not $inst.id) { $errors += "instances[$i]: Feld 'id' fehlt" }
            if (-not $inst.version) { $errors += "instances[$i]: Feld 'version' fehlt" }
        }
    }

    if ($errors.Count -gt 0) {
        throw "Manifest-Validierung fehlgeschlagen:`n  - $($errors -join "`n  - ")"
    }

    # Defaults anwenden
    $resolved = Resolve-ManifestDefaults -Manifest $manifest -ManifestPath $Path
    return $resolved
}

function Resolve-ManifestDefaults {
    <#
    .SYNOPSIS Wendet Defaults auf alle Instanzen an.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [string]$ManifestPath
    )

    $manifestDir = if ($ManifestPath) { Split-Path $ManifestPath -Parent } else { $PWD.Path }

    $resolvedInstances = @()
    foreach ($inst in $Manifest.instances) {
        $resolved = [PSCustomObject]@{
            id         = $inst.id
            version    = $inst.version
            provider   = if ($inst.provider) { $inst.provider } else { 'docker' }
            os         = if ($inst.os) { $inst.os } else { 'linux' }
            profile    = if ($inst.profile) { $inst.profile } else { 'standard' }
            collation  = if ($inst.collation) { $inst.collation } else { 'SQL_Latin1_General_CP1_CS_AS' }
            databases  = @()
            drives     = @()
            serverConfig = $null
            software   = @()
            postProvision = @()
        }

        # Provider Auto-Select
        if (-not $inst.provider) {
            $resolved.provider = Resolve-ProviderAutoSelect -Instance $inst
        }

        # Datenbanken aufloesen
        if ($inst.databases) {
            foreach ($db in $inst.databases) {
                $resolvedDb = [PSCustomObject]@{
                    name      = $db.name
                    collation = if ($db.collation) { $db.collation } else { $resolved.collation }
                    options   = if ($db.options) { $db.options } else { @{ queryStore = $true } }
                    files     = Resolve-DatabaseFiles -DatabaseDef $db
                    restore   = if ($db.restore) {
                        [PSCustomObject]@{
                            source  = $db.restore.source
                            type    = if ($db.restore.type) { $db.restore.type } else { 'auto' }
                            replace = if ($null -ne $db.restore.replace) { $db.restore.replace } else { $true }
                        }
                    } else { $null }
                }
                $resolved.databases += $resolvedDb
            }
        }

        # Drives (Volume-Mounts)
        if ($inst.drives) {
            foreach ($drv in $inst.drives) {
                $resolved.drives += [PSCustomObject]@{
                    id            = $drv.id
                    containerPath = $drv.containerPath
                    hostPath      = $drv.hostPath
                    sizeLimitGB   = $drv.sizeLimitGB
                    type          = if ($drv.type) { $drv.type } else { 'auto' }
                }
            }
        }

        # Server-Konfiguration (Memory, TempDB, MaxDOP, etc.)
        if ($inst.serverConfig) {
            $cfg = $inst.serverConfig
            $resolved.serverConfig = [PSCustomObject]@{
                collation      = $cfg.collation
                memory         = if ($cfg.memory) {
                    [PSCustomObject]@{ minMB = $cfg.memory.minMB; maxMB = $cfg.memory.maxMB }
                } else { $null }
                tempdb         = if ($cfg.tempdb) {
                    [PSCustomObject]@{
                        dataFiles = @($cfg.tempdb.dataFiles)
                        logFile   = $cfg.tempdb.logFile
                        equalSize = if ($null -ne $cfg.tempdb.equalSize) { $cfg.tempdb.equalSize } else { $true }
                    }
                } else { $null }
                maxDop         = if ($null -ne $cfg.maxDop) { $cfg.maxDop } else { 0 }
                costThreshold  = if ($null -ne $cfg.costThreshold) { $cfg.costThreshold } else { 5 }
                traceFlags     = if ($cfg.traceFlags) { @($cfg.traceFlags) } else { @() }
                spConfigure    = $cfg.spConfigure
            }
        }

        # Software
        if ($inst.software) {
            foreach ($sw in $inst.software) {
                $resolved.software += [PSCustomObject]@{
                    id       = $sw.id
                    source   = $sw.source
                    package  = $sw.package
                    url      = $sw.url
                    command  = $sw.command
                    optional = if ($null -ne $sw.optional) { $sw.optional } else { $true }
                }
            }
        }

        # PostProvision-Pfade relativ zum Manifest aufloesen
        if ($inst.postProvision) {
            foreach ($script in $inst.postProvision) {
                $absPath = if ([System.IO.Path]::IsPathRooted($script)) {
                    $script
                } else {
                    Join-Path $manifestDir $script
                }
                $resolved.postProvision += $absPath
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
    <#
    .SYNOPSIS Waehlt den Provider automatisch basierend auf Anforderungen.
    #>
    [CmdletBinding()]
    param($Instance)

    # GUI-Software -> HyperV
    if ($Instance.software) {
        $guiApps = @('ssms', 'vscode', 'az-data-studio', 'visual-studio')
        $hasGui = $Instance.software | Where-Object { $_.id -in $guiApps }
        if ($hasGui) { return 'hyperv' }
    }

    # Windows OS -> HyperV
    if ($Instance.os -eq 'windows') { return 'hyperv' }

    # Default: Docker
    return 'docker'
}

function Resolve-DatabaseFiles {
    <#
    .SYNOPSIS Loest Datenbank-File-Definitionen auf (mit Defaults).
    #>
    [CmdletBinding()]
    param($DatabaseDef)

    $files = @{ data = @(); log = @() }

    if ($DatabaseDef.files -and $DatabaseDef.files.data) {
        foreach ($f in $DatabaseDef.files.data) {
            $files.data += @{
                name         = $f.name
                sizeMB       = if ($f.sizeMB) { $f.sizeMB } else { 64 }
                filegrowthMB = if ($f.filegrowthMB) { $f.filegrowthMB } else { 64 }
            }
        }
    }
    else {
        # Default: 1 Data File
        $files.data += @{ name = "$($DatabaseDef.name)_Data"; sizeMB = 64; filegrowthMB = 64 }
    }

    if ($DatabaseDef.files -and $DatabaseDef.files.log) {
        foreach ($f in $DatabaseDef.files.log) {
            $files.log += @{
                name         = $f.name
                sizeMB       = if ($f.sizeMB) { $f.sizeMB } else { 32 }
                filegrowthMB = if ($f.filegrowthMB) { $f.filegrowthMB } else { 32 }
            }
        }
    }
    else {
        # Default: 1 Log File
        $files.log += @{ name = "$($DatabaseDef.name)_Log"; sizeMB = 32; filegrowthMB = 32 }
    }

    return $files
}

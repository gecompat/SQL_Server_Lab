<#
.SYNOPSIS
    Operatorfunktionen fuer den lokalen Hyper-V-Windows-Image-Build.
.DESCRIPTION
    Bindet den internen Image-Builder an die kanonische Media-Root-Struktur,
    verwaltet einzelne SHA-256-Sidecars und stellt sichere, resumierbare
    Operationen fuer Menue und Direkt-Aktion bereit.
#>

function Get-HyperVImageBuildPlans {
    [CmdletBinding()]
    param(
        [string]$StateRoot,
        [switch]$IncludeCleanedUp
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $buildRoot = Join-Path $StateRoot 'image-builds/hyperv'
    if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $buildRoot -Directory -Force |
            Sort-Object Name |
            ForEach-Object {
                if ($_.Name -notmatch '^[a-f0-9-]{36}$') { return }
                Get-HyperVImageBuildPlan -BuildId $_.Name -StateRoot $StateRoot
            } |
            Where-Object {
                $null -ne $_ -and ($IncludeCleanedUp -or [string]$_.state -ne 'CLEANED_UP')
            }
    )
}

function Get-HyperVMediaHashSidecarSummary {
    <# .SYNOPSIS Liest den Status eines portablen ISO-SHA-256-Sidecars ohne die ISO zu verändern. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MediaRoot, [Parameter(Mandatory)][string]$RelativePath)

    $portableRelative = $RelativePath.Replace('\', '/')
    $hashPath = Join-Path (Join-Path $MediaRoot 'Hashes') ($RelativePath.Replace('/', '\') + '.sha256')
    if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
        return [PSCustomObject]@{ HashPath = $hashPath; HashStatus = 'MISSING'; ExpectedSha256 = $null }
    }
    $content = (Get-Content -LiteralPath $hashPath -Raw -Encoding utf8).Trim()
    if ($content -notmatch '^(?<sha>[A-Fa-f0-9]{64})\s{2}(?<relative>.+)$' -or
        -not $Matches['relative'].Replace('\', '/').Equals($portableRelative, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [PSCustomObject]@{ HashPath = $hashPath; HashStatus = 'INVALID'; ExpectedSha256 = $null }
    }
    return [PSCustomObject]@{ HashPath = $hashPath; HashStatus = 'SIDECAR_READY'; ExpectedSha256 = $Matches['sha'].ToLowerInvariant() }
}

function Get-HyperVMediaDiscoveryCache {
    <# .SYNOPSIS Lädt erkannte ISO-Metadaten eines Media Root, ohne ISO-Dateien einzuhängen. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MediaRoot, [Parameter(Mandatory)][ValidateSet('windows', 'sql')][string]$Kind)

    $path = Join-Path (Join-Path $MediaRoot 'Evidence') ("{0}-media-discovery-cache.json" -f $Kind)
    $cache = @{}
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $cache }
    try {
        $document = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
        if ([string]$document.contractVersion -ne '1' -or [string]$document.kind -ne $Kind) { return $cache }
        foreach ($entry in @($document.entries)) {
            if ($entry.path -and $entry.items) { $cache[[string]$entry.path] = @($entry.items) }
        }
    }
    catch {
        Write-LabWarning "Media-Erkennungscache wird ignoriert: $($_.Exception.Message)"
    }
    return $cache
}

function Save-HyperVMediaDiscoveryCache {
    <# .SYNOPSIS Schreibt nur abgeleitete ISO-Metadaten; die ISO selbst bleibt unverändert. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][ValidateSet('windows', 'sql')][string]$Kind,
        [Parameter(Mandatory)][hashtable]$Cache
    )

    try {
        $evidenceRoot = Join-Path $MediaRoot 'Evidence'
        New-Item -Path $evidenceRoot -ItemType Directory -Force | Out-Null
        $document = [PSCustomObject]@{
            contractVersion = '1'; kind = $Kind; generatedAt = Get-LabTimestamp
            entries = @($Cache.GetEnumerator() | Sort-Object Key | ForEach-Object {
                [PSCustomObject]@{ path = $_.Key; items = @($_.Value) }
            })
        }
        Write-LabArtifactJsonAtomic -Path (Join-Path $evidenceRoot ("{0}-media-discovery-cache.json" -f $Kind)) -InputObject $document
    }
    catch {
        # Ein schreibgeschützter Media Root darf die dynamische Erkennung nicht
        # verhindern; dann bleibt sie innerhalb der laufenden Sitzung gecacht.
        Write-LabWarning "Media-Erkennungscache konnte nicht gespeichert werden: $($_.Exception.Message)"
    }
}

function Get-HyperVWindowsInstallationMediaInfo {
    <# .SYNOPSIS Liest Windows-Server- und Windows-Client-Version, Edition und Installationsart direkt aus einer ISO. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IsoPath)

    if (-not $IsWindows) { throw 'HYPERV_WINDOWS_MEDIA_DISCOVERY_WINDOWS_ONLY' }
    $resolvedIso = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).Path
    $diskImage = Get-DiskImage -ImagePath $resolvedIso -ErrorAction Stop
    $wasAttached = [bool]$diskImage.Attached
    try {
        if (-not $wasAttached) { $diskImage = Mount-DiskImage -ImagePath $resolvedIso -PassThru -ErrorAction Stop }
        $installers = @($diskImage | Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter } | ForEach-Object {
            foreach ($name in @('install.wim', 'install.esd')) {
                $candidate = ('{0}:\sources\{1}' -f [string]$_.DriveLetter, $name)
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate }
            }
        })
        if ($installers.Count -ne 1) { throw "HYPERV_WINDOWS_MEDIA_INSTALL_IMAGE_NOT_UNIQUE: ISO=$([IO.Path]::GetFileName($resolvedIso)); images=$($installers.Count)" }
        $variants = @(
            Get-WindowsImage -ImagePath $installers[0].FullName -ErrorAction Stop | ForEach-Object {
                $name = [string]$_.ImageName
                # Ältere Semi-Annual-Channel-Medien nennen das Image lediglich
                # "Windows Server, version 1709". Ergänzende DISM-Metadaten
                # und ausschließlich der ISO-Dateiname liefern dann die fehlende
                # Jahres-/Editionsinformation. Der Inhalt des install.wim/esd
                # bleibt weiterhin die maßgebliche Quelle.
                $imageDescription = [string]$_.ImageDescription
                $editionId = [string]$_.EditionId
                $metadataText = "$name $imageDescription $editionId"
                $fallbackText = "$metadataText $([IO.Path]::GetFileName($resolvedIso))"
                $operatingSystemId = $null
                $edition = $null
                $installationType = 'desktop-experience'
                if ($metadataText -match '(?i)Windows Server (?<year>20\d{2})') {
                    $year = [string]$Matches.year
                    $operatingSystemId = "windows-server-$year"
                    $editionBase = if ($metadataText -match '(?i)Datacenter') { 'datacenter' } elseif ($metadataText -match '(?i)Standard') { 'standard' } elseif ($metadataText -match '(?i)Azure Edition') { 'azure-edition' } else { $null }
                    if ($editionBase) {
                        $edition = if ($metadataText -match '(?i)(evaluation|eval)') { "$editionBase-evaluation" } else { $editionBase }
                    }
                    # Windows Server 2016/2019 nennen Desktop Experience nicht
                    # immer aus. Ihre Core-Abbilder tragen dafür üblicherweise
                    # CORE im Image-Namen; aktuelle Medien verwenden den
                    # expliziten Desktop-Experience-Zusatz.
                    $installationType = if ($metadataText -match '(?i)Desktop Experience' -or ($year -le '2019' -and $metadataText -notmatch '(?i)CORE')) { 'desktop-experience' } else { 'core' }
                }
                elseif ($metadataText -match '(?i)Windows (?<major>10|11)') {
                    $major = [string]$Matches.major
                    $operatingSystemId = "windows-$major"
                    $editionBase = if ($metadataText -match '(?i)Enterprise') { 'enterprise' } elseif ($metadataText -match '(?i)Education') { 'education' } elseif ($metadataText -match '(?i)Pro(fessional)?') { 'professional' } elseif ($metadataText -match '(?i)Home') { 'home' } else { $null }
                    if ($editionBase) {
                        if ($metadataText -match '(?i)LTSC') { $editionBase += '-ltsc' }
                        $edition = if ($metadataText -match '(?i)(evaluation|eval)') { "$editionBase-evaluation" } else { $editionBase }
                    }
                }
                elseif ($metadataText -match '(?i)Windows Server,? version 1709' -and $fallbackText -match '(?i)(2016|winsrv2016)') {
                    $operatingSystemId = 'windows-server-2016'
                    $editionBase = if ($fallbackText -match '(?i)Datacenter') { 'datacenter' } elseif ($fallbackText -match '(?i)Standard') { 'standard' } else { $null }
                    if ($editionBase) {
                        $edition = if ($metadataText -match '(?i)(evaluation|eval)') { "$editionBase-evaluation" } else { $editionBase }
                    }
                    $installationType = if ($metadataText -match '(?i)(CORE|Server Core)') { 'core' } else { 'desktop-experience' }
                }
                if (-not $operatingSystemId -or -not $edition) { return }
                [PSCustomObject]@{
                    OperatingSystemId = $operatingSystemId
                    WindowsEdition = $edition
                    InstallationType = $installationType
                    ImageName = $name; ImageIndex = [int]$_.ImageIndex
                }
            }
        )
        if ($variants.Count -eq 0) { throw "HYPERV_WINDOWS_MEDIA_VARIANTS_UNRECOGNIZED: $([IO.Path]::GetFileName($resolvedIso))" }
        return $variants
    }
    finally {
        if (-not $wasAttached) { $null = Dismount-DiskImage -ImagePath $resolvedIso -ErrorAction SilentlyContinue }
    }
}

function Get-HyperVWindowsMediaLicenseType {
    <# .SYNOPSIS Leitet den Lizenztyp aus der direkt erkannten Windows-Edition ab. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WindowsEdition)

    if ($WindowsEdition -match '(?i)(^|-)evaluation$') { return 'evaluation' }
    return 'licensed'
}

function Test-HyperVSqlPreparedWindowsMediaCompatibility {
    <#
    .SYNOPSIS
        Kennzeichnet erkannte Windows-Medien für den SQL-Prepared-Workflow.
    .DESCRIPTION
        Der Benutzer entscheidet über die erkannte Windows-/SQL-Kombination.
        Die Funktion sperrt keine gültig erkannten Windows-Server- oder
        Windows-Client-Medien vorab; echte Installations-, SQL-Setup- oder
        Sysprep-Fehler bleiben dagegen sichtbar und terminal.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OperatingSystemId)

    $recognizedWindows = $OperatingSystemId -match '^windows-(server-)?[0-9]+$'
    return [PSCustomObject]@{
        Compatible = $recognizedWindows
        Reason = if ($recognizedWindows) { 'Erkanntes Windows-Medium; die Windows-/SQL-Kombination wird auf Benutzerwunsch ausgeführt.' } else { "Kein unterstütztes Windows-Medienformat: '$OperatingSystemId'." }
    }
}

function Test-HyperVWindowsMediaDiscoveryRetry {
    <#
    .SYNOPSIS
        Kennzeichnet fluechtige Medien-Erkennungsfehler, die nicht persistiert werden duerfen.
    .DESCRIPTION
        Das Einhaengen einer Windows-ISO kann in einer nicht erhoehten Sitzung
        fehlschlagen. Dieser Zustand sagt nichts ueber das Medium aus und muss
        bei einem erneuten (gegebenenfalls erhoehten) Aufruf erneut geprueft
        werden.
    #>
    [CmdletBinding()]
    param($Cached)

    return @($Cached | Where-Object {
        [string]$_.State -eq 'RETRY_ELEVATED' -or
        [string]$_.Message -match '(?i)(erh.\s*hte Rechte|elevated (privilege|rights)|access (is )?denied|zugriff verweigert)'
    }).Count -gt 0
}

function Get-HyperVWindowsInstallationMediaCandidates {
    <# .SYNOPSIS Findet Windows-Server- und Windows-Client-ISOs in jeder Medien-Unterstruktur. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MediaRoot)

    $resolvedRoot = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    if (-not $script:HyperVWindowsMediaScanCache) { $script:HyperVWindowsMediaScanCache = @{} }
    if (-not $script:HyperVWindowsMediaScanCacheRoots) { $script:HyperVWindowsMediaScanCacheRoots = @{} }
    $rootKey = $resolvedRoot.ToLowerInvariant()
    if (-not $script:HyperVWindowsMediaScanCacheRoots.ContainsKey($rootKey)) {
        foreach ($entry in (Get-HyperVMediaDiscoveryCache -MediaRoot $resolvedRoot -Kind windows).GetEnumerator()) {
            $script:HyperVWindowsMediaScanCache[$entry.Key] = @($entry.Value)
        }
        $script:HyperVWindowsMediaScanCacheRoots[$rootKey] = $true
    }
    # SQL-, Hash- und Evidenzordner gehören anderen Workflows. Alle übrigen
    # Unterordner dürfen frei benannt oder umsortiert werden.
    $excludedRoots = @('SQL', 'Hashes', 'Evidence', 'Exports', '.git')
    $items = @(Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse -Force | Where-Object {
        if ($_.Extension -ine '.iso') { return $false }
        $relative = [IO.Path]::GetRelativePath($resolvedRoot, $_.FullName).Replace('\', '/')
        $topLevel = ($relative -split '/')[0]
        return $topLevel -notin $excludedRoots
    })
    $knownPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $cacheChanged = $false
    foreach ($item in $items) {
        $null = $knownPaths.Add($item.FullName)
        $fingerprint = "$($item.Length):$($item.LastWriteTimeUtc.Ticks)"
        $cached = $script:HyperVWindowsMediaScanCache[$item.FullName]
        if (-not $cached -or $cached.Fingerprint -ne $fingerprint -or (Test-HyperVWindowsMediaDiscoveryRetry -Cached $cached)) {
            $relativePath = [IO.Path]::GetRelativePath($resolvedRoot, $item.FullName).Replace('\', '/')
            try {
                $variants = @(Get-HyperVWindowsInstallationMediaInfo -IsoPath $item.FullName | ForEach-Object {
                    [PSCustomObject]@{ Fingerprint = $fingerprint; MediaId = $relativePath; OperatingSystemId = $_.OperatingSystemId; WindowsEdition = $_.WindowsEdition; InstallationType = $_.InstallationType; ImageName = $_.ImageName; ImageIndex = $_.ImageIndex; State = 'READY'; Message = 'Windows-Installationsabbild wurde direkt aus der ISO erkannt.' }
                })
                $cached = $variants
            }
            catch {
                $message = [string]$_.Exception.Message
                $requiresElevation = $message -match '(?i)(erh.\s*hte Rechte|elevated (privilege|rights)|access (is )?denied|zugriff verweigert)'
                $cached = @([PSCustomObject]@{
                    Fingerprint = $fingerprint; MediaId = $relativePath; OperatingSystemId = $null
                    WindowsEdition = $null; InstallationType = $null; ImageName = $null; ImageIndex = $null
                    State = if ($requiresElevation) { 'RETRY_ELEVATED' } else { 'UNRECOGNIZED' }
                    Message = $message
                })
            }
            $script:HyperVWindowsMediaScanCache[$item.FullName] = $cached
            $cacheChanged = $true
        }
    }
    foreach ($path in @($script:HyperVWindowsMediaScanCache.Keys)) { if ($path.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) -and -not $knownPaths.Contains($path)) { $script:HyperVWindowsMediaScanCache.Remove($path); $cacheChanged = $true } }
    if ($cacheChanged) {
        $persistentCache = @{}
        foreach ($path in @($script:HyperVWindowsMediaScanCache.Keys | Where-Object { $_.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) })) {
            $entry = $script:HyperVWindowsMediaScanCache[$path]
            if (-not (Test-HyperVWindowsMediaDiscoveryRetry -Cached $entry)) {
                $persistentCache[$path] = $entry
            }
        }
        Save-HyperVMediaDiscoveryCache -MediaRoot $resolvedRoot -Kind windows -Cache $persistentCache
    }
    return @($script:HyperVWindowsMediaScanCache.GetEnumerator() | Where-Object { $_.Key.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $_.Value } | ForEach-Object {
        $summary = Get-HyperVMediaHashSidecarSummary -MediaRoot $resolvedRoot -RelativePath $_.MediaId
        $_ | Add-Member -NotePropertyName HashPath -NotePropertyValue $summary.HashPath -Force
        $_ | Add-Member -NotePropertyName HashStatus -NotePropertyValue $summary.HashStatus -Force
        $_ | Add-Member -NotePropertyName ExpectedSha256 -NotePropertyValue $summary.ExpectedSha256 -Force
        $_
    } | Sort-Object OperatingSystemId, WindowsEdition, InstallationType, MediaId)
}

function Resolve-HyperVWindowsInstallationMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$OperatingSystemId,
        [string]$WindowsMediaPath,
        [string]$WindowsEdition,
        [string]$InstallationType
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw 'HYPERV_MEDIA_ROOT_NOT_FOUND'
    }
    if ($WindowsMediaPath) {
        if ([IO.Path]::IsPathRooted($WindowsMediaPath) -or $WindowsMediaPath -match '(^|[\\/])\.\.([\\/]|$)') { throw 'HYPERV_WINDOWS_MEDIA_PATH_INVALID' }
        $iso = Get-Item -LiteralPath (Join-Path $resolvedRoot ($WindowsMediaPath.Replace('/', '\'))) -ErrorAction Stop
        $rootPrefix = $resolvedRoot.TrimEnd('\') + '\'
        if ($iso.Extension -ine '.iso' -or -not $iso.FullName.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'HYPERV_WINDOWS_MEDIA_PATH_INVALID' }
        $variants = @(Get-HyperVWindowsInstallationMediaInfo -IsoPath $iso.FullName)
        $match = @($variants | Where-Object {
            $_.OperatingSystemId -eq $OperatingSystemId -and
            (-not $WindowsEdition -or $_.WindowsEdition -eq $WindowsEdition) -and
            (-not $InstallationType -or $_.InstallationType -eq $InstallationType)
        })
        if ($match.Count -ne 1) { throw "HYPERV_WINDOWS_MEDIA_VARIANT_MISMATCH: $WindowsMediaPath" }
    }
    else {
        $legacyServerVersion = if ($OperatingSystemId -match '^windows-server-(?<version>20\d{2})$') { [string]$Matches.version } else { $null }
        $matches = @(Get-HyperVWindowsInstallationMediaCandidates -MediaRoot $resolvedRoot | Where-Object {
            $_.State -eq 'READY' -and $_.OperatingSystemId -eq $OperatingSystemId -and
            (-not $WindowsEdition -or $_.WindowsEdition -eq $WindowsEdition) -and
            (-not $InstallationType -or $_.InstallationType -eq $InstallationType)
        })
        if ($matches.Count -eq 0 -and $legacyServerVersion) {
            # Rückwärtskompatibilität für vorhandene kanonische Media Roots;
            # die UI übergibt stets den erkannten relativen Pfad und benötigt
            # diesen Fallback daher nicht.
            $isoDirectory = Join-Path $resolvedRoot "WindowsServer/$legacyServerVersion/Eval/ISO"
            $legacyIsoFiles = if (Test-Path -LiteralPath $isoDirectory -PathType Container) {
                @(Get-ChildItem -LiteralPath $isoDirectory -File -Force | Where-Object { $_.Extension -ieq '.iso' })
            } else { @() }
            if ($legacyIsoFiles.Count -eq 1) { $iso = $legacyIsoFiles[0] }
            if ($legacyIsoFiles.Count -gt 1) { throw "HYPERV_WINDOWS_MEDIA_AMBIGUOUS: $($legacyIsoFiles.Name -join ', ')" }
        }
        if (-not $iso -and $matches.Count -eq 0) { throw "HYPERV_WINDOWS_MEDIA_NOT_FOUND: $OperatingSystemId" }
        if ($matches.Count -gt 1) { throw "HYPERV_WINDOWS_MEDIA_AMBIGUOUS: $($matches.MediaId -join ', ')" }
        if (-not $iso) { $iso = Get-Item -LiteralPath (Join-Path $resolvedRoot ($matches[0].MediaId.Replace('/', '\'))) -ErrorAction Stop }
    }
    $relativePath = [System.IO.Path]::GetRelativePath($resolvedRoot, $iso.FullName)
    if ($relativePath.StartsWith('..')) { throw 'HYPERV_WINDOWS_MEDIA_OUTSIDE_ROOT' }
    $portableRelative = $relativePath.Replace('\', '/')
    $hashPath = Join-Path (Join-Path $resolvedRoot 'Hashes') ($relativePath + '.sha256')
    $expectedSha256 = $null
    $hashStatus = 'MISSING'

    if (Test-Path -LiteralPath $hashPath -PathType Leaf) {
        $hashContent = (Get-Content -LiteralPath $hashPath -Raw -Encoding utf8).Trim()
        if ($hashContent -notmatch '^(?<sha>[A-Fa-f0-9]{64})\s{2}(?<relative>.+)$') {
            throw "HYPERV_WINDOWS_MEDIA_HASH_INVALID: $hashPath"
        }
        $sidecarRelative = $Matches['relative'].Replace('\', '/')
        $comparison = if ($IsWindows) {
            [System.StringComparison]::OrdinalIgnoreCase
        }
        else {
            [System.StringComparison]::Ordinal
        }
        if (-not $sidecarRelative.Equals($portableRelative, $comparison)) {
            throw "HYPERV_WINDOWS_MEDIA_HASH_PATH_MISMATCH: $hashPath"
        }
        $expectedSha256 = $Matches['sha'].ToLowerInvariant()
        $hashStatus = 'SIDECAR_READY'
    }

    return [PSCustomObject]@{
        MediaRoot        = $resolvedRoot
        OperatingSystemId = $OperatingSystemId
        IsoPath          = $iso.FullName
        RelativePath     = $portableRelative
        LengthBytes      = [long]$iso.Length
        HashPath         = $hashPath
        HashStatus       = $hashStatus
        ExpectedSha256   = $expectedSha256
    }
}

function New-HyperVWindowsMediaHashSidecar {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$OperatingSystemId,
        [string]$WindowsMediaPath,
        [string]$WindowsEdition,
        [string]$InstallationType
    )

    $media = Resolve-HyperVWindowsInstallationMedia `
        -MediaRoot $MediaRoot `
        -OperatingSystemId $OperatingSystemId -WindowsMediaPath $WindowsMediaPath -WindowsEdition $WindowsEdition -InstallationType $InstallationType
    if ($media.HashStatus -eq 'SIDECAR_READY') {
        return $media
    }

    $digest = (Get-FileHash -LiteralPath $media.IsoPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $hashDirectory = Split-Path -Parent $media.HashPath
    if ($PSCmdlet.ShouldProcess($media.HashPath, 'SHA-256-Sidecar fuer Windows-ISO schreiben')) {
        New-Item -Path $hashDirectory -ItemType Directory -Force | Out-Null
        $content = "$digest  $($media.RelativePath)"
        Set-Content -LiteralPath $media.HashPath -Value $content -Encoding utf8NoBOM
    }

    if ($WhatIfPreference) {
        return [PSCustomObject]@{
            MediaRoot        = $media.MediaRoot
            OperatingSystemId = $media.OperatingSystemId
            IsoPath          = $media.IsoPath
            RelativePath     = $media.RelativePath
            LengthBytes      = $media.LengthBytes
            HashPath         = $media.HashPath
            HashStatus       = 'WHAT_IF'
            ExpectedSha256   = $digest
        }
    }

    return Resolve-HyperVWindowsInstallationMedia `
        -MediaRoot $MediaRoot `
        -OperatingSystemId $OperatingSystemId -WindowsMediaPath $WindowsMediaPath -WindowsEdition $WindowsEdition -InstallationType $InstallationType
}

function Set-HyperVWindowsMediaHashSidecar {
    <# .SYNOPSIS Prüft einen vom Benutzer eingegebenen offiziellen SHA-256 und speichert ihn als Sidecar. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$OperatingSystemId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
        [string]$WindowsMediaPath, [string]$WindowsEdition, [string]$InstallationType
    )
    $media = Resolve-HyperVWindowsInstallationMedia -MediaRoot $MediaRoot -OperatingSystemId $OperatingSystemId -WindowsMediaPath $WindowsMediaPath -WindowsEdition $WindowsEdition -InstallationType $InstallationType
    $actual = (Get-FileHash -LiteralPath $media.IsoPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) { throw "HYPERV_WINDOWS_MEDIA_HASH_MISMATCH: ISO=$($media.RelativePath)" }
    New-Item -Path (Split-Path -Parent $media.HashPath) -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath $media.HashPath -Value "$actual  $($media.RelativePath)" -Encoding utf8NoBOM
    return Resolve-HyperVWindowsInstallationMedia -MediaRoot $MediaRoot -OperatingSystemId $OperatingSystemId -WindowsMediaPath $WindowsMediaPath -WindowsEdition $WindowsEdition -InstallationType $InstallationType
}

function Initialize-HyperVWindowsImageBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$OperatingSystemId,
        [Parameter(Mandatory)][string]$Edition,
        [Parameter(Mandatory)]
        [ValidateSet('core', 'desktop-experience')]
        [string]$InstallationType,
        [ValidateSet('licensed', 'evaluation')]
        [string]$LicenseType = 'evaluation',
        [ValidateRange(32GB, 1TB)][long]$OsDiskSizeBytes = 80GB,
        [ValidateRange(2GB, 1TB)][long]$MemoryStartupBytes = 4GB,
        [ValidateRange(1, 64)][int]$ProcessorCount = 4,
        [string]$Language = 'en-US',
        [string]$WindowsMediaPath,
        [ValidateSet('none', 'space')][string]$InitialMediaKey = 'space',
        [string]$StateRoot
    )

    $media = Resolve-HyperVWindowsInstallationMedia `
        -MediaRoot $MediaRoot `
        -OperatingSystemId $OperatingSystemId -WindowsMediaPath $WindowsMediaPath -WindowsEdition $Edition -InstallationType $InstallationType
    if ($media.HashStatus -ne 'SIDECAR_READY' -or -not $media.ExpectedSha256) {
        throw "HYPERV_WINDOWS_MEDIA_HASH_REQUIRED: $($media.HashPath)"
    }

    $plan = New-HyperVWindowsImageBuildPlan `
        -IsoPath $media.IsoPath `
        -ExpectedSha256 $media.ExpectedSha256 `
        -OperatingSystemId $OperatingSystemId `
        -Edition $Edition `
        -InstallationType $InstallationType `
        -Language $Language `
        -LicenseType $LicenseType `
        -InitialMediaKey $InitialMediaKey `
        -OsDiskSizeBytes $OsDiskSizeBytes `
        -StateRoot $StateRoot

    try {
        $builder = New-HyperVWindowsImageBuilder `
            -BuildId $plan.buildId `
            -MemoryStartupBytes $MemoryStartupBytes `
            -ProcessorCount $ProcessorCount `
            -StateRoot $StateRoot
        return Set-HyperVImageBuildManualAction `
            -BuildId $builder.buildId `
            -StateRoot $StateRoot
    }
    catch {
        try {
            $null = Set-HyperVImageBuildState `
                -BuildId $plan.buildId `
                -State FAILED `
                -Reason $_.Exception.Message `
                -StateRoot $StateRoot
        }
        catch { }
        throw
    }
}

function Confirm-HyperVWindowsImageInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [switch]$AcceptDetectedInstallationType,
        [string]$StateRoot
    )

    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
    if ($build.state -ne 'MANUAL_ACTION_REQUIRED') {
        throw 'HYPERV_IMAGE_BUILD_NOT_WAITING_FOR_INSTALLATION'
    }
    if (-not $build.builder -or -not $build.builder.vmName) {
        throw 'HYPERV_IMAGE_BUILD_VM_MISSING'
    }

    $receipt = Invoke-HyperVPowerShellDirect `
        -VMName ([string]$build.builder.vmName) `
        -ExpectedRunId $BuildId `
        -ExpectedScopeId ([string]$build.scopeId) `
        -Credential $Credential `
        -ArgumentList @([string]$build.buildId, [string]$build.scopeId) `
        -ScriptBlock {
            param($ExpectedBuildId, $ExpectedScopeId)
            $ErrorActionPreference = 'Stop'
            $currentVersion = Get-ItemProperty `
                -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
                -ErrorAction Stop
            [PSCustomObject]@{
                contractVersion = '1'
                buildId = $ExpectedBuildId
                scopeId = $ExpectedScopeId
                productName = [string]$currentVersion.ProductName
                editionId = [string]$currentVersion.EditionID
                installationType = [string]$currentVersion.InstallationType
                currentBuild = [string]$currentVersion.CurrentBuild
                displayVersion = [string]$currentVersion.DisplayVersion
                computerName = [string]$env:COMPUTERNAME
                observedAt = [datetime]::UtcNow.ToString('o')
            }
        }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or
        [string]$receipt.contractVersion -ne '1' -or
        [string]$receipt.buildId -ne [string]$build.buildId -or
        [string]$receipt.scopeId -ne [string]$build.scopeId -or
        -not [string]$receipt.productName -or
        -not [string]$receipt.editionId -or
        -not [string]$receipt.installationType -or
        -not [string]$receipt.currentBuild -or
        -not [string]$receipt.computerName -or
        -not [string]$receipt.observedAt) {
        throw 'HYPERV_IMAGE_INSTALLATION_RECEIPT_INVALID'
    }

    $expectedVersion = [string]$build.operatingSystem.id -replace '^windows-(server-)?', ''
    if ([string]$receipt.productName -notmatch [regex]::Escape($expectedVersion)) {
        throw "HYPERV_IMAGE_INSTALLATION_VERSION_MISMATCH: erwartet $expectedVersion, erkannt $($receipt.productName)"
    }

    $expectedEditionPattern = switch -Regex ([string]$build.operatingSystem.edition) {
        '^standard-evaluation$'   { '^ServerStandardEval'; break }
        '^datacenter-evaluation$' { '^ServerDatacenterEval'; break }
        '^enterprise-evaluation$' { '^EnterpriseEval'; break }
        default { throw "HYPERV_IMAGE_INSTALLATION_EDITION_UNSUPPORTED: $($build.operatingSystem.edition)" }
    }
    if ([string]$receipt.editionId -notmatch $expectedEditionPattern) {
        throw "HYPERV_IMAGE_INSTALLATION_EDITION_MISMATCH: erwartet $($build.operatingSystem.edition), erkannt $($receipt.editionId)"
    }

    $detectedInstallationType = switch ([string]$receipt.installationType) {
        'Server Core' { 'core' }
        'Server'      { 'desktop-experience' }
        'Client'      { 'desktop-experience' }
        default { throw "HYPERV_IMAGE_INSTALLATION_TYPE_UNKNOWN: $($receipt.installationType)" }
    }
    $requestedInstallationType = [string]$build.operatingSystem.installationType
    $metadataAdjusted = $false
    if ($detectedInstallationType -ne $requestedInstallationType) {
        if (-not $AcceptDetectedInstallationType) {
            throw "HYPERV_IMAGE_INSTALLATION_TYPE_MISMATCH: erwartet $requestedInstallationType, erkannt $detectedInstallationType"
        }
        $build.operatingSystem.installationType = $detectedInstallationType
        $metadataAdjusted = $true
    }

    $evidence = [PSCustomObject]@{
        contractVersion = '1'
        verified = $true
        productName = [string]$receipt.productName
        editionId = [string]$receipt.editionId
        installationType = $detectedInstallationType
        requestedInstallationType = $requestedInstallationType
        metadataAdjusted = $metadataAdjusted
        currentBuild = [string]$receipt.currentBuild
        displayVersion = [string]$receipt.displayVersion
        computerName = [string]$receipt.computerName
        observedAt = [string]$receipt.observedAt
        acceptedAt = Get-LabTimestamp
    }
    $build | Add-Member -NotePropertyName installationEvidence -NotePropertyValue $evidence -Force
    Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
}

function Invoke-HyperVInitialMediaBootInteraction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][string]$VMName,
        [ValidateRange(1, 30)][int]$Attempts = 30,
        [ValidateRange(50, 2000)][int]$IntervalMilliseconds = 750,
        [string]$StateRoot
    )

    $isSqlBuild = $false
    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build -and (Get-Command Get-HyperVSqlImageBuildPlan -ErrorAction SilentlyContinue)) {
        $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
        $isSqlBuild = $null -ne $build
    }
    if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
    if ($build.initialMediaBootReceipt) { return $build.initialMediaBootReceipt }

    $bootMedia = if ($isSqlBuild) { $build.windowsMedia } else { $build.media }
    $initialMediaKey = [string]$bootMedia.bootInteraction.initialMediaKey
    if ([string]::IsNullOrWhiteSpace($initialMediaKey)) {
        # Portable migration for unfinished Windows builds created before the
        # boot-interaction contract existed.
        $initialMediaKey = 'space'
        $bootMedia | Add-Member -NotePropertyName bootInteraction `
            -NotePropertyValue ([PSCustomObject]@{ initialMediaKey = $initialMediaKey }) -Force
    }
    if ($initialMediaKey -notin @('none', 'space')) {
        throw 'HYPERV_INITIAL_MEDIA_KEY_INVALID'
    }

    $successfulSends = 0
    if ($initialMediaKey -eq 'space') {
        $lastError = $null
        Start-Sleep -Milliseconds 750
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            try {
                $escapedVmName = $VMName.Replace("'", "''")
                $computerSystem = @(Get-CimInstance -Namespace 'root/virtualization/v2' `
                    -ClassName Msvm_ComputerSystem `
                    -Filter "ElementName='$escapedVmName'" -ErrorAction Stop)[0]
                if (-not $computerSystem) { throw 'HYPERV_BUILDER_VM_CIM_NOT_FOUND' }
                $keyboard = @(Get-CimAssociatedInstance -InputObject $computerSystem `
                    -Association Msvm_SystemDevice -ResultClassName Msvm_Keyboard -ErrorAction Stop)[0]
                if (-not $keyboard) { throw 'HYPERV_BUILDER_KEYBOARD_NOT_FOUND' }
                $result = Invoke-CimMethod -InputObject $keyboard -MethodName TypeKey `
                    -Arguments @{ keyCode = [uint32]0x20 } -ErrorAction Stop
                if ([uint32]$result.ReturnValue -eq 0) { $successfulSends++ }
                else { $lastError = "TypeKey=$($result.ReturnValue)" }
            }
            catch { $lastError = $_.Exception.Message }
            if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds $IntervalMilliseconds }
        }
        if ($successfulSends -eq 0) {
            throw "HYPERV_INITIAL_MEDIA_KEY_SEND_FAILED: $lastError"
        }
    }

    $receipt = [PSCustomObject]@{
        contractVersion = '1'; phase = 'initial-media-boot'
        initialMediaKey = $initialMediaKey
        status = if ($initialMediaKey -eq 'none') { 'SKIPPED' } else { 'SENT' }
        attempts = if ($initialMediaKey -eq 'none') { 0 } else { $Attempts }
        successfulSends = $successfulSends
        completedAt = Get-LabTimestamp
    }
    $build | Add-Member -NotePropertyName initialMediaBootReceipt -NotePropertyValue $receipt -Force
    if ($isSqlBuild) {
        Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    }
    else {
        Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    }
    return $receipt
}

function Start-HyperVWindowsImageBuildVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [string]$StateRoot
    )

    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
    if ($build.state -notin @('BUILDER_READY', 'MANUAL_ACTION_REQUIRED')) {
        throw 'HYPERV_IMAGE_BUILD_VM_NOT_STARTABLE'
    }
    if (-not $build.builder -or -not $build.builder.vmName) {
        throw 'HYPERV_IMAGE_BUILD_VM_MISSING'
    }

    $instance = Start-HyperVInstance `
        -VMName ([string]$build.builder.vmName) `
        -ExpectedRunId $BuildId `
        -ExpectedScopeId ([string]$build.scopeId)
    $receipt = Invoke-HyperVInitialMediaBootInteraction `
        -BuildId $BuildId -VMName ([string]$build.builder.vmName) -StateRoot $StateRoot
    $instance | Add-Member -NotePropertyName InitialMediaBoot -NotePropertyValue $receipt -Force
    return $instance
}

function Remove-HyperVWindowsImageBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [string]$StateRoot
    )

    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_IMAGE_BUILD_NOT_FOUND' }
    $cleanup = Invoke-CleanupPlan `
        -RunDir $build.BuildDirectory `
        -ScopeId ([string]$build.scopeId)
    $build = Get-HyperVImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    $build | Add-Member -NotePropertyName cleanupStatus -NotePropertyValue ([string]$cleanup.Status) -Force
    Write-HyperVImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    if ([string]$cleanup.Status -eq 'CLEANUP_SUCCEEDED') {
        $build = Set-HyperVImageBuildState -BuildId $BuildId -State CLEANED_UP -Reason 'Unfertiger Windows-Builder samt VM und buildlokaler VHDX aufgeraeumt' -StateRoot $StateRoot
    }
    return [PSCustomObject]@{
        BuildId = $BuildId
        Status  = [string]$cleanup.Status
        Cleanup = $cleanup
        Build   = $build
    }
}

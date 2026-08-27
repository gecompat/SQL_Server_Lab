<#
.SYNOPSIS
    Resumierbarer SQL-PrepareImage-Builder fuer Hyper-V.
.DESCRIPTION
    Der empfohlene Pfad erzeugt eine neue VM direkt aus der Windows-ISO,
    installiert danach SQL Server PrepareImage und fuehrt genau einen finalen
    Windows-Sysprep aus. Der historische Baseline-Pfad bleibt nur fuer
    run-lokale Abnahme-VMs erhalten.
#>

function Write-HyperVSqlImageBuildState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildDirectory, [Parameter(Mandatory)]$State)

    $State.updatedAt = Get-LabTimestamp
    $serializable = $State | Select-Object * -ExcludeProperty BuildDirectory
    Write-LabArtifactJsonAtomic -Path (Join-Path $BuildDirectory 'build-state.json') -InputObject $serializable
}

function Get-HyperVSqlImageBuildPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildId, [string]$StateRoot)

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    if ($BuildId -notmatch '^[a-f0-9-]{36}$') { throw 'HYPERV_SQL_IMAGE_BUILD_ID_INVALID' }
    $directory = Join-Path (Join-Path $StateRoot 'image-builds/hyperv-sql') $BuildId
    $statePath = Join-Path $directory 'build-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    $state | Add-Member -NotePropertyName BuildDirectory -NotePropertyValue $directory -Force
    return $state
}

function Get-HyperVSqlImageBuildPlans {
    [CmdletBinding()]
    param(
        [string]$StateRoot,
        [switch]$IncludeCleanedUp
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $buildRoot = Join-Path $StateRoot 'image-builds/hyperv-sql'
    if (-not (Test-Path -LiteralPath $buildRoot -PathType Container)) { return @() }
    return @(
        Get-ChildItem -LiteralPath $buildRoot -Directory -Force |
            Sort-Object Name |
            ForEach-Object {
                if ($_.Name -match '^[a-f0-9-]{36}$') {
                    Get-HyperVSqlImageBuildPlan -BuildId $_.Name -StateRoot $StateRoot
                }
            } |
            Where-Object {
                $null -ne $_ -and ($IncludeCleanedUp -or [string]$_.state -ne 'CLEANED_UP')
            }
    )
}

function Set-HyperVSqlImageBuildState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)]
        [ValidateSet(
            'MEDIA_VERIFIED', 'MANUAL_ACTION_REQUIRED', 'OOBE_AUTOMATION_RUNNING', 'OOBE_COMPLETED',
            'REBOOT_REQUIRED', 'RESUME_PENDING', 'SQL_PREPARED_SEALED',
            'SQL_INSTALL_RUNNING', 'SQL_INSTALL_REBOOT_REQUIRED', 'SQL_READY_RUN', 'TESTS_PASSED', 'FAILED',
            'CLEANED_UP'
        )]
        [string]$State,
        [Parameter(Mandatory)][string]$Reason,
        [string]$StateRoot
    )

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_SQL_IMAGE_BUILD_NOT_FOUND' }
    $build.state = $State
    $build.stateHistory = @($build.stateHistory + [PSCustomObject]@{
        state = $State; timestamp = Get-LabTimestamp; reason = $Reason
    })
    Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
}

function Get-HyperVSqlVersionFromMajor {
    <# .SYNOPSIS Ordnet die von SQL Setup gemeldete Hauptversion einer Produktversion zu. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$MajorVersion)

    $known = @{ 11 = '2012'; 12 = '2014'; 13 = '2016'; 14 = '2017'; 15 = '2019'; 16 = '2022'; 17 = '2025' }
    if ($known.ContainsKey($MajorVersion)) { return $known[$MajorVersion] }
    return "major-$MajorVersion"
}

function Get-HyperVSqlMajorVersionFromVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SqlVersion)

    if ($SqlVersion -match '^major-(?<major>\d+)$') { return [int]$Matches.major }
    $known = @{ '2012' = 11; '2014' = 12; '2016' = 13; '2017' = 14; '2019' = 15; '2022' = 16; '2025' = 17 }
    if ($known.ContainsKey($SqlVersion)) { return [int]$known[$SqlVersion] }
    throw "HYPERV_SQL_MEDIA_VERSION_UNKNOWN: $SqlVersion"
}

function Get-HyperVSqlMediaEditionFromPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ($Path -match '(?i)(?:^|[\\/_\-.])standard(?:$|[\\/_\-.])') { return 'Standard' }
    if ($Path -match '(?i)(?:^|[\\/_\-.])(?:eval|evaluation)(?:$|[\\/_\-.])') { return 'Eval' }
    if ($Path -match '(?i)(?:^|[\\/_\-.])(?:enterprise|developer)(?:$|[\\/_\-.])') { return 'Enterprise' }
    return $null
}

function ConvertTo-HyperVSqlMediaEdition {
    <#
    .SYNOPSIS Übersetzt die im Artifact gespeicherte SQL-Produktedition in den Medien-Schlüssel.
    .DESCRIPTION Artifacts speichern die von SQL Setup verwendete Produktedition
    (z. B. EnterpriseDeveloper), die Medienverwaltung hingegen die kurze
    Verzeichnis-/Auswahlbezeichnung (Enterprise). Beide Formen müssen für
    bereits veröffentlichte Images dauerhaft kompatibel bleiben.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SqlEdition)

    switch -Regex ($SqlEdition.Trim()) {
        '^(Eval|Evaluation)$' { return 'Eval' }
        '^(Enterprise|EnterpriseDeveloper)$' { return 'Enterprise' }
        '^(Standard|StandardDeveloper)$' { return 'Standard' }
        default { throw "HYPERV_SQL_MEDIA_EDITION_UNSUPPORTED: $SqlEdition" }
    }
}

function Get-HyperVSqlInstallationMediaInfo {
    <# .SYNOPSIS Erkennt SQL Server direkt aus setup.exe einer ISO. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IsoPath)

    if (-not $IsWindows) { throw 'HYPERV_SQL_MEDIA_DISCOVERY_WINDOWS_ONLY' }
    $resolvedIso = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).Path
    $diskImage = Get-DiskImage -ImagePath $resolvedIso -ErrorAction Stop
    $wasAttached = [bool]$diskImage.Attached
    try {
        if (-not $wasAttached) { $diskImage = Mount-DiskImage -ImagePath $resolvedIso -PassThru -ErrorAction Stop }
        $setupFiles = @($diskImage | Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter } | ForEach-Object {
            $candidate = ('{0}:\\setup.exe' -f [string]$_.DriveLetter)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate }
        })
        if ($setupFiles.Count -ne 1) { throw "HYPERV_SQL_MEDIA_SETUP_NOT_UNIQUE: ISO=$([IO.Path]::GetFileName($resolvedIso)); setup.exe=$($setupFiles.Count)" }
        $setupVersion = [string]$setupFiles[0].VersionInfo.ProductVersion
        if (-not $setupVersion) { $setupVersion = [string]$setupFiles[0].VersionInfo.FileVersion }
        if ($setupVersion -notmatch '(?<!\d)(?<major>\d{2})\.') { throw "HYPERV_SQL_MEDIA_VERSION_UNREADABLE: $setupVersion" }
        $major = [int]$Matches.major
        return [PSCustomObject]@{ SqlVersion = Get-HyperVSqlVersionFromMajor -MajorVersion $major; MajorVersion = $major; SetupVersion = $setupVersion }
    }
    finally {
        if (-not $wasAttached) { $null = Dismount-DiskImage -ImagePath $resolvedIso -ErrorAction SilentlyContinue }
    }
}

function Get-HyperVSqlInstallationMediaCandidates {
    <#
    .SYNOPSIS Findet und erkennt alle SQL-ISOs unter dem Media Root.
    .DESCRIPTION Neue oder geaenderte Dateien werden beim naechsten Scan automatisch erkannt.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MediaRoot)

    $resolvedRoot = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    $sqlRoot = Join-Path $resolvedRoot 'SQL'
    if (-not (Test-Path -LiteralPath $sqlRoot -PathType Container)) { return @() }
    if (-not $script:HyperVSqlMediaScanCache) { $script:HyperVSqlMediaScanCache = @{} }
    if (-not $script:HyperVSqlMediaScanCacheRoots) { $script:HyperVSqlMediaScanCacheRoots = @{} }
    $rootKey = $resolvedRoot.ToLowerInvariant()
    if (-not $script:HyperVSqlMediaScanCacheRoots.ContainsKey($rootKey)) {
        foreach ($entry in (Get-HyperVMediaDiscoveryCache -MediaRoot $resolvedRoot -Kind sql).GetEnumerator()) {
            $script:HyperVSqlMediaScanCache[$entry.Key] = @($entry.Value)
        }
        $script:HyperVSqlMediaScanCacheRoots[$rootKey] = $true
    }
    $items = @(Get-ChildItem -LiteralPath $sqlRoot -File -Recurse -Force | Where-Object { $_.Extension -ieq '.iso' })
    $knownPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $cacheChanged = $false
    foreach ($item in $items) {
        $null = $knownPaths.Add($item.FullName)
        $fingerprint = "$($item.Length):$($item.LastWriteTimeUtc.Ticks)"
        $cached = $script:HyperVSqlMediaScanCache[$item.FullName]
        if (-not $cached -or $cached.Fingerprint -ne $fingerprint) {
        $relativePath = [IO.Path]::GetRelativePath($resolvedRoot, $item.FullName).Replace('\', '/')
            try {
                $info = Get-HyperVSqlInstallationMediaInfo -IsoPath $item.FullName
                $edition = Get-HyperVSqlMediaEditionFromPath -Path $relativePath
                $cached = [PSCustomObject]@{ Fingerprint = $fingerprint; MediaId = $relativePath; SqlVersion = $info.SqlVersion; MajorVersion = $info.MajorVersion; SetupVersion = $info.SetupVersion; MediaEdition = $edition; EditionDetected = [bool]$edition; State = 'READY'; Message = 'SQL Setup wurde direkt aus der ISO erkannt.' }
            }
            catch {
                $cached = [PSCustomObject]@{ Fingerprint = $fingerprint; MediaId = $relativePath; SqlVersion = $null; MajorVersion = $null; SetupVersion = $null; MediaEdition = (Get-HyperVSqlMediaEditionFromPath -Path $relativePath); EditionDetected = $false; State = 'UNRECOGNIZED'; Message = $_.Exception.Message }
            }
            $script:HyperVSqlMediaScanCache[$item.FullName] = $cached
            $cacheChanged = $true
        }
    }
    foreach ($path in @($script:HyperVSqlMediaScanCache.Keys)) { if ($path.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) -and -not $knownPaths.Contains($path)) { $script:HyperVSqlMediaScanCache.Remove($path); $cacheChanged = $true } }
    if ($cacheChanged) {
        $persistentCache = @{}
        foreach ($path in @($script:HyperVSqlMediaScanCache.Keys | Where-Object { $_.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) })) {
            $persistentCache[$path] = $script:HyperVSqlMediaScanCache[$path]
        }
        Save-HyperVMediaDiscoveryCache -MediaRoot $resolvedRoot -Kind sql -Cache $persistentCache
    }
    return @($script:HyperVSqlMediaScanCache.GetEnumerator() | Where-Object { $_.Key.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $_.Value } | ForEach-Object {
        $summary = Get-HyperVMediaHashSidecarSummary -MediaRoot $resolvedRoot -RelativePath $_.MediaId
        $_ | Add-Member -NotePropertyName HashPath -NotePropertyValue $summary.HashPath -Force
        $_ | Add-Member -NotePropertyName HashStatus -NotePropertyValue $summary.HashStatus -Force
        $_ | Add-Member -NotePropertyName ExpectedSha256 -NotePropertyValue $summary.ExpectedSha256 -Force
        $_
    } | Sort-Object SqlVersion, MediaId)
}

function Resolve-HyperVSqlInstallationMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$SqlVersion,
        [ValidateSet('Eval', 'Enterprise', 'Standard')][string]$MediaEdition = 'Eval',
        [string]$SqlMediaPath
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw 'HYPERV_MEDIA_ROOT_NOT_FOUND'
    }
    if ($SqlMediaPath) {
        if ([IO.Path]::IsPathRooted($SqlMediaPath) -or $SqlMediaPath -match '(^|[\\/])\.\.([\\/]|$)') { throw 'HYPERV_SQL_MEDIA_PATH_INVALID' }
        $candidatePath = Join-Path $resolvedRoot ($SqlMediaPath.Replace('/', '\'))
        $iso = Get-Item -LiteralPath $candidatePath -ErrorAction Stop
        $sqlRoot = (Resolve-Path -LiteralPath (Join-Path $resolvedRoot 'SQL') -ErrorAction Stop).Path
        $sqlRootPrefix = $sqlRoot.TrimEnd('\') + '\'
        if ($iso.Extension -ine '.iso' -or -not $iso.FullName.StartsWith($sqlRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'HYPERV_SQL_MEDIA_PATH_INVALID' }
        $detected = Get-HyperVSqlInstallationMediaInfo -IsoPath $iso.FullName
        if ($detected.SqlVersion -ne $SqlVersion) { throw "HYPERV_SQL_MEDIA_VERSION_MISMATCH: erwartet SQL $SqlVersion; erkannt $($detected.SqlVersion)" }
        $detectedEdition = Get-HyperVSqlMediaEditionFromPath -Path $SqlMediaPath
        if (-not $detectedEdition) { throw "HYPERV_SQL_MEDIA_EDITION_UNRECOGNIZED: $SqlMediaPath" }
        if ($detectedEdition -ne $MediaEdition) { throw "HYPERV_SQL_MEDIA_EDITION_MISMATCH: erwartet $MediaEdition; erkannt $detectedEdition" }
    }
    else {
        $isoDirectory = Join-Path $resolvedRoot "SQL/$SqlVersion/$MediaEdition/ISO"
        if (-not (Test-Path -LiteralPath $isoDirectory -PathType Container)) {
            $versionDirectory = Join-Path $resolvedRoot "SQL/$SqlVersion"
            $editionDirectories = if (Test-Path -LiteralPath $versionDirectory -PathType Container) {
                @(Get-ChildItem -LiteralPath $versionDirectory -Directory -Force | Where-Object {
                    $_.Name -like "${MediaEdition}_*" -and (Test-Path -LiteralPath (Join-Path $_.FullName 'ISO') -PathType Container)
                })
            }
            else { @() }
            if ($editionDirectories.Count -eq 0) { throw "HYPERV_SQL_MEDIA_DIRECTORY_NOT_FOUND: $isoDirectory" }
            if ($editionDirectories.Count -gt 1) {
                throw "HYPERV_SQL_MEDIA_EDITION_DIRECTORY_AMBIGUOUS: $($editionDirectories.Name -join ', ')"
            }
            $isoDirectory = Join-Path $editionDirectories[0].FullName 'ISO'
        }
        $isoFiles = @(Get-ChildItem -LiteralPath $isoDirectory -File -Force | Where-Object Extension -IEQ '.iso')
        if ($isoFiles.Count -eq 0) { throw "HYPERV_SQL_MEDIA_NOT_FOUND: $isoDirectory" }
        if ($isoFiles.Count -gt 1) { throw "HYPERV_SQL_MEDIA_AMBIGUOUS: $($isoFiles.Name -join ', ')" }
        $iso = $isoFiles[0]
    }
    if (-not (Test-WindowsInstallationIso -Path $iso.FullName)) { throw 'HYPERV_SQL_MEDIA_INVALID_ISO' }
    $relativePath = [System.IO.Path]::GetRelativePath($resolvedRoot, $iso.FullName)
    if ($relativePath.StartsWith('..')) { throw 'HYPERV_SQL_MEDIA_OUTSIDE_ROOT' }
    $portableRelative = $relativePath.Replace('\', '/')
    $hashPath = Join-Path (Join-Path $resolvedRoot 'Hashes') ($relativePath + '.sha256')
    $expectedSha256 = $null
    $hashStatus = 'MISSING'
    if (Test-Path -LiteralPath $hashPath -PathType Leaf) {
        $content = (Get-Content -LiteralPath $hashPath -Raw -Encoding utf8).Trim()
        if ($content -notmatch '^(?<sha>[A-Fa-f0-9]{64})\s{2}(?<relative>.+)$') {
            throw "HYPERV_SQL_MEDIA_HASH_INVALID: $hashPath"
        }
        $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if (-not $Matches['relative'].Replace('\', '/').Equals($portableRelative, $comparison)) {
            throw "HYPERV_SQL_MEDIA_HASH_PATH_MISMATCH: $hashPath"
        }
        $expectedSha256 = $Matches['sha'].ToLowerInvariant()
        $hashStatus = 'SIDECAR_READY'
    }
    return [PSCustomObject]@{
        MediaRoot = $resolvedRoot; SqlVersion = $SqlVersion; MediaEdition = $MediaEdition
        IsoPath = $iso.FullName; RelativePath = $portableRelative; LengthBytes = [long]$iso.Length
        HashPath = $hashPath; HashStatus = $hashStatus; ExpectedSha256 = $expectedSha256
    }
}

function Get-HyperVSqlSetupVersionPattern {
    <#
    .SYNOPSIS
        Liefert das erwartete Versionsmuster einer SQL-Setup-Datei.
    .DESCRIPTION
        SQL Server 2019, 2022 und 2025 können je nach Medium entweder die
        Produkt-Major-Version oder die Jahreskennzeichnung in den Dateiversionen
        melden. Beide Kennzeichnungen gehören jeweils zum selben SQL-Medium.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SqlVersion)

    $major = Get-HyperVSqlMajorVersionFromVersion -SqlVersion $SqlVersion
    if ($SqlVersion -match '^major-\d+$') { return "(?<!\d)$major\." }
    $yearMarker = '{0:d4}' -f ($major * 10)
    return "(?<!\d)(?:$major|$SqlVersion\.$yearMarker)\."
}

function Confirm-HyperVSqlInstallationMediaVersion {
    <#
    .SYNOPSIS
        Prüft die SQL-Hauptversion direkt aus der ISO, bevor eine VM entsteht.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][string]$SqlVersion
    )

    if (-not $IsWindows) { throw 'HYPERV_SQL_MEDIA_VERSION_CHECK_WINDOWS_ONLY' }
    $resolvedIso = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).Path
    $diskImage = Get-DiskImage -ImagePath $resolvedIso -ErrorAction Stop
    $wasAttached = [bool]$diskImage.Attached
    try {
        if (-not $wasAttached) {
            $diskImage = Mount-DiskImage -ImagePath $resolvedIso -PassThru -ErrorAction Stop
        }
        $info = Get-HyperVSqlInstallationMediaInfo -IsoPath $resolvedIso
        $setupVersion = $info.SetupVersion
        if ($info.SqlVersion -ne $SqlVersion) { throw "HYPERV_SQL_MEDIA_VERSION_MISMATCH: erwartet SQL $SqlVersion; erkannt $($info.SqlVersion) ($setupVersion); ISO=$([IO.Path]::GetFileName($resolvedIso))" }
        return [PSCustomObject]@{
            SqlVersion = $SqlVersion
            SetupVersion = $setupVersion
            IsoName = [IO.Path]::GetFileName($resolvedIso)
        }
    }
    finally {
        if (-not $wasAttached) {
            Dismount-DiskImage -ImagePath $resolvedIso -ErrorAction SilentlyContinue
        }
    }
}

function Get-HyperVSqlOfflineImageState {
    <#
    .SYNOPSIS
        Liest den Windows-ImageState aus einer ausgeschalteten Builder-VHDX.
    .DESCRIPTION
        Wird ausschliesslich fuer die Wiederaufnahme verwendet, falls Sysprep
        das integrierte Administratorpasswort bereits zurueckgesetzt hat und
        damit PowerShell Direct absichtlich nicht mehr moeglich ist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][string]$MountRoot
    )

    New-Item -Path $MountRoot -ItemType Directory -Force | Out-Null
    $mounted = $null; $partition = $null; $accessPathAdded = $false
    $hiveName = "SQL_Server_Lab_Offline_$([guid]::NewGuid().ToString('N'))"; $hiveLoaded = $false
    try {
        try { $mounted = Mount-VHD -Path $VhdxPath -PassThru -ErrorAction Stop }
        catch {
            if ($_.Exception.Message -match '0x80070522|erforderliches Recht|required privilege') {
                throw 'HYPERV_SQL_OFFLINE_INSPECTION_REQUIRES_ELEVATED_RUNNER'
            }
            throw
        }
        $disk = $mounted | Get-Disk -ErrorAction Stop
        foreach ($candidate in @($disk | Get-Partition -ErrorAction Stop | Where-Object Size -GT 4GB)) {
            $candidateRoot = if ($candidate.DriveLetter) { "$($candidate.DriveLetter):\" } else { $null }
            if (-not $candidateRoot) {
                Add-PartitionAccessPath -DiskNumber $candidate.DiskNumber -PartitionNumber $candidate.PartitionNumber `
                    -AccessPath ($MountRoot.TrimEnd('\') + '\') -ErrorAction Stop
                $candidateRoot = $MountRoot.TrimEnd('\') + '\'; $accessPathAdded = $true
            }
            $softwareHive = Join-Path $candidateRoot 'Windows/System32/Config/SOFTWARE'
            if (Test-Path -LiteralPath $softwareHive -PathType Leaf) {
                $partition = $candidate
                & reg.exe load "HKLM\$hiveName" $softwareHive | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'HYPERV_SQL_OFFLINE_SOFTWARE_HIVE_LOAD_FAILED' }
                $hiveLoaded = $true
                $imageState = [string](Get-ItemPropertyValue `
                    -LiteralPath "Registry::HKEY_LOCAL_MACHINE\$hiveName\Microsoft\Windows\CurrentVersion\Setup\State" `
                    -Name ImageState -ErrorAction Stop)
                $sysprepErrorPath = Join-Path $candidateRoot 'Windows/System32/Sysprep/Panther/setuperr.log'
                $sysprepActionPath = Join-Path $candidateRoot 'Windows/System32/Sysprep/Panther/setupact.log'
                $logLines = @()
                foreach ($logPath in @($sysprepErrorPath, $sysprepActionPath) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) {
                    $lines = @(Get-Content -LiteralPath $logPath -Tail 100 -ErrorAction SilentlyContinue)
                    $relevant = @($lines | Where-Object { $_ -match '(?i)error|failed|failure|fatal|package|sysprep' } | Select-Object -Last 12)
                    if ($relevant.Count -gt 0) { $logLines += $relevant }
                }
                $sysprepDetail = (($logLines -join ' ') -replace '\s+', ' ').Trim()
                if ($sysprepDetail.Length -gt 1600) { $sysprepDetail = $sysprepDetail.Substring(0, 1600) }
                return [PSCustomObject]@{
                    ImageState = $imageState
                    SysprepDetail = $sysprepDetail
                }
            }
            if ($accessPathAdded) {
                Remove-PartitionAccessPath -DiskNumber $candidate.DiskNumber -PartitionNumber $candidate.PartitionNumber `
                    -AccessPath ($MountRoot.TrimEnd('\') + '\') -ErrorAction Stop
                $accessPathAdded = $false
            }
        }
        throw 'HYPERV_SQL_OFFLINE_WINDOWS_PARTITION_NOT_FOUND'
    }
    finally {
        if ($hiveLoaded) { & reg.exe unload "HKLM\$hiveName" | Out-Null }
        if ($accessPathAdded -and $partition) {
            Remove-PartitionAccessPath -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber `
                -AccessPath ($MountRoot.TrimEnd('\') + '\') -ErrorAction SilentlyContinue
        }
        if ($mounted) { Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $MountRoot -Force -ErrorAction SilentlyContinue
    }
}

function Get-HyperVSqlSysprepFailureReason {
    <#
    .SYNOPSIS
        Uebersetzt bekannte Sysprep-Abbrueche in eine handlungsfaehige Meldung.
    .DESCRIPTION
        Die Sysprep-Panther-Logs bleiben im Build-Verzeichnis als Detail
        erhalten. Die Menueausgabe soll aber nicht durch einen langen Logtail
        unlesbar werden und insbesondere den nicht reparierbaren Rearm-Fall
        eindeutig von einem SQL- oder Gastzugriffsproblem abgrenzen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ImageState,
        [string]$SysprepDetail
    )

    if ($SysprepDetail -match '(?i)SLReArmWindows|0xC004D307') {
        return 'WINDOWS_SYSPREP_REARM_LIMIT_REACHED: Die maximale Anzahl von Windows-Lizenz-Rearms wurde erreicht. Diesen Builder mit Aktion 12 aufraeumen und ein frisches SQL-Prepared-Image mit Aktion 7 neu beginnen. Der neue Pfad installiert Windows und SQL in derselben VM und verwendet nur einen finalen Sysprep.'
    }
    $detail = if ($SysprepDetail) { "; Sysprep=$SysprepDetail" } else { '' }
    return "HYPERV_SQL_IMAGE_GENERALIZATION_RECOVERY_INVALID_STATE: $ImageState$detail"
}

function New-HyperVSqlMediaHashSidecar {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$SqlVersion,
        [ValidateSet('Eval', 'Enterprise', 'Standard')][string]$MediaEdition = 'Eval',
        [string]$SqlMediaPath
    )

    $media = Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $MediaEdition -SqlMediaPath $SqlMediaPath
    if ($media.HashStatus -eq 'SIDECAR_READY') { return $media }
    $digest = (Get-FileHash -LiteralPath $media.IsoPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($PSCmdlet.ShouldProcess($media.HashPath, 'SHA-256-Sidecar fuer SQL-Server-ISO schreiben')) {
        New-Item -Path (Split-Path -Parent $media.HashPath) -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $media.HashPath -Value "$digest  $($media.RelativePath)" -Encoding utf8NoBOM
    }
    if ($WhatIfPreference) {
        $media.HashStatus = 'WHAT_IF'; $media.ExpectedSha256 = $digest
        return $media
    }
    return Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $MediaEdition -SqlMediaPath $SqlMediaPath
}

function New-HyperVSqlImageBuildPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ImageArtifactId,
        [Parameter(Mandatory)][string]$IsoPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$SqlVersion,
        [Parameter(Mandatory)][ValidateSet('Eval', 'Enterprise', 'Standard')][string]$SqlEdition,
        [string[]]$SqlFeatures = @('SQLENGINE', 'FULLTEXT', 'REPLICATION'),
        [ValidateLength(1, 80)][string]$ImageName,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $artifact = Get-HyperVImageArtifact -ArtifactId $ImageArtifactId -StateRoot $StateRoot
    if (-not $artifact -or $artifact.artifactState -ne 'OS_SEALED') { throw 'HYPERV_SQL_IMAGE_OS_BASELINE_REQUIRED' }
    if ($artifact.license.type -eq 'evaluation' -and $artifact.license.evaluationExpiresAt -and
        ([datetime]$artifact.license.evaluationExpiresAt).ToUniversalTime() -lt [datetime]::UtcNow.AddDays(30)) {
        throw 'HYPERV_SQL_IMAGE_OS_EVALUATION_EXPIRING'
    }
    $resolvedIso = (Resolve-Path -LiteralPath $IsoPath -ErrorAction Stop).Path
    if (-not (Test-WindowsInstallationIso -Path $resolvedIso)) { throw 'HYPERV_SQL_MEDIA_INVALID_ISO' }
    $sha256 = (Get-FileHash -LiteralPath $resolvedIso -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha256 -ne $ExpectedSha256.ToLowerInvariant()) { throw 'HYPERV_SQL_MEDIA_INTEGRITY_MISMATCH' }
    $normalizedFeatures = @($SqlFeatures | ForEach-Object { ([string]$_).ToUpperInvariant() } | Sort-Object -Unique)
    if ($normalizedFeatures.Count -eq 0 -or @($normalizedFeatures | Where-Object { $_ -notin @('SQLENGINE', 'FULLTEXT', 'REPLICATION', 'ADVANCEDANALYTICS') }).Count -gt 0) {
        throw 'HYPERV_SQL_FEATURES_UNSUPPORTED'
    }

    $buildId = New-LabGuid
    $scopeId = New-LabGuid
    $buildDirectory = Join-Path (Join-Path $StateRoot 'image-builds/hyperv-sql') $buildId
    New-Item -Path $buildDirectory -ItemType Directory -Force | Out-Null
    $null = New-CleanupPlan -RunDir $buildDirectory -RunId $buildId -ScopeId $scopeId `
        -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-hyperv'; provider = 'hyperv' })
    Write-LabArtifactJsonAtomic -Path (Join-Path $buildDirectory 'build-local.json') -InputObject ([PSCustomObject]@{
        sqlIsoPath = $resolvedIso
    })
    $timestamp = Get-LabTimestamp
    $state = [PSCustomObject]@{
        contractVersion = '2'; buildKind = 'hyperv-sql-prepare-image'; buildId = $buildId; scopeId = $scopeId
        provisioningMode = 'sealed-os-baseline'; displayName = $ImageName
        state = 'MEDIA_VERIFIED'; stateHistory = @([PSCustomObject]@{
            state = 'MEDIA_VERIFIED'; timestamp = $timestamp; reason = 'OS-Artifact und SQL-ISO SHA-256 verifiziert'
        })
        parentArtifact = [PSCustomObject]@{
            artifactId = [string]$artifact.artifactId; sha256 = [string]$artifact.sha256
            operatingSystem = $artifact.operatingSystem; license = $artifact.license
        }
        sql = [PSCustomObject]@{
            version = $SqlVersion
            mediaEdition = $SqlEdition
            edition = switch ($SqlEdition) {
                'Eval' { 'Evaluation' }
                'Enterprise' { 'EnterpriseDeveloper' }
                'Standard' { 'StandardDeveloper' }
            }
            license = [PSCustomObject]@{
                type = if ($SqlEdition -eq 'Eval') { 'evaluation' } else { 'developer' }
                evaluationStartsAt = if ($SqlEdition -eq 'Eval') { 'complete-image' } else { $null }
                evaluationExpiresAt = $null
                productionUseAllowed = $false
            }
            features = $normalizedFeatures
            mediaSha256 = $sha256; setupBuild = $null
        }
        builder = $null; manualAction = $null; setupEvidence = $null; generalizationEvidence = $null
        sealPostconditions = $null; artifact = $null; cleanupStatus = $null
        createdAt = $timestamp; updatedAt = $timestamp
    }
    Write-HyperVSqlImageBuildState -BuildDirectory $buildDirectory -State $state
    return Get-HyperVSqlImageBuildPlan -BuildId $buildId -StateRoot $StateRoot
}

function New-HyperVSqlFreshImageBuildPlan {
    <#
    .SYNOPSIS
        Erstellt den Plan fuer ein SQL-Prepared-Image aus zwei Originalmedien.
    .DESCRIPTION
        Windows und SQL werden in derselben frischen VHDX installiert. Erst
        danach wird Windows einmalig generalisiert und das Image versiegelt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WindowsIsoPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedWindowsSha256,
        [Parameter(Mandatory)][ValidatePattern('^windows-(server-)?[0-9]+$')][string]$OperatingSystemId,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$WindowsEdition,
        [Parameter(Mandatory)][ValidateSet('core', 'desktop-experience')][string]$InstallationType,
        [Parameter(Mandatory)][string]$SqlIsoPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSqlSha256,
        [Parameter(Mandatory)][string]$SqlVersion,
        [Parameter(Mandatory)][ValidateSet('Eval', 'Enterprise', 'Standard')][string]$SqlEdition,
        [string[]]$SqlFeatures = @('SQLENGINE', 'FULLTEXT', 'REPLICATION'),
        [ValidateLength(1, 80)][string]$ImageName,
        [ValidateRange(32GB, 1TB)][long]$OsDiskSizeBytes = 80GB,
        [string]$StateRoot
    )

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $windowsIso = (Resolve-Path -LiteralPath $WindowsIsoPath -ErrorAction Stop).Path
    $sqlIso = (Resolve-Path -LiteralPath $SqlIsoPath -ErrorAction Stop).Path
    if (-not (Test-WindowsInstallationIso -Path $windowsIso)) { throw 'HYPERV_SQL_WINDOWS_MEDIA_INVALID_ISO' }
    if (-not (Test-WindowsInstallationIso -Path $sqlIso)) { throw 'HYPERV_SQL_MEDIA_INVALID_ISO' }
    $windowsSha256 = (Get-FileHash -LiteralPath $windowsIso -Algorithm SHA256).Hash.ToLowerInvariant()
    $sqlSha256 = (Get-FileHash -LiteralPath $sqlIso -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($windowsSha256 -ne $ExpectedWindowsSha256.ToLowerInvariant()) { throw 'HYPERV_SQL_WINDOWS_MEDIA_INTEGRITY_MISMATCH' }
    if ($sqlSha256 -ne $ExpectedSqlSha256.ToLowerInvariant()) { throw 'HYPERV_SQL_MEDIA_INTEGRITY_MISMATCH' }
    $features = @($SqlFeatures | ForEach-Object { ([string]$_).ToUpperInvariant() } | Sort-Object -Unique)
    if ($features.Count -eq 0 -or @($features | Where-Object { $_ -notin @('SQLENGINE', 'FULLTEXT', 'REPLICATION', 'ADVANCEDANALYTICS') }).Count -gt 0) {
        throw 'HYPERV_SQL_FEATURES_UNSUPPORTED'
    }

    $buildId = New-LabGuid; $scopeId = New-LabGuid
    $buildDirectory = Join-Path (Join-Path $StateRoot 'image-builds/hyperv-sql') $buildId
    New-Item -Path $buildDirectory -ItemType Directory -Force | Out-Null
    $null = New-CleanupPlan -RunDir $buildDirectory -RunId $buildId -ScopeId $scopeId `
        -ProviderSubRuns @([PSCustomObject]@{ id = 'provider-hyperv'; provider = 'hyperv' })
    Write-LabArtifactJsonAtomic -Path (Join-Path $buildDirectory 'build-local.json') -InputObject ([PSCustomObject]@{
        windowsIsoPath = $windowsIso; sqlIsoPath = $sqlIso
    })
    $operatingSystemVersion = if ($OperatingSystemId -match '^windows-(?:server-)?(?<version>[0-9]+)$') { [string]$Matches.version } else { $OperatingSystemId }
    $operatingSystem = [PSCustomObject]@{
        id = $OperatingSystemId; version = $operatingSystemVersion; edition = $WindowsEdition
        installationType = $InstallationType; language = 'en-US'; architecture = 'x64'
    }
    $license = [PSCustomObject]@{ type = (Get-HyperVWindowsMediaLicenseType -WindowsEdition $WindowsEdition); evaluationExpiresAt = $null }
    $timestamp = Get-LabTimestamp
    $state = [PSCustomObject]@{
        contractVersion = '2'; buildKind = 'hyperv-sql-prepare-image-fresh-windows'; buildId = $buildId; scopeId = $scopeId
        provisioningMode = 'fresh-windows-media'; displayName = $ImageName; state = 'MEDIA_VERIFIED'
        stateHistory = @([PSCustomObject]@{ state = 'MEDIA_VERIFIED'; timestamp = $timestamp; reason = 'Windows- und SQL-ISO SHA-256 verifiziert; ein finaler Sysprep vorgesehen' })
        operatingSystem = $operatingSystem; license = $license; windowsMedia = [PSCustomObject]@{
            sha256 = $windowsSha256
            bootInteraction = [PSCustomObject]@{ initialMediaKey = 'space' }
        }
        parentArtifact = [PSCustomObject]@{ artifactId = $null; source = 'fresh-windows-media'; operatingSystem = $operatingSystem; license = $license }
        resources = [PSCustomObject]@{ osDiskSizeBytes = $OsDiskSizeBytes }
        sql = [PSCustomObject]@{
            version = $SqlVersion; mediaEdition = $SqlEdition
            edition = switch ($SqlEdition) { 'Eval' { 'Evaluation' }; 'Enterprise' { 'EnterpriseDeveloper' }; 'Standard' { 'StandardDeveloper' } }
            license = [PSCustomObject]@{ type = if ($SqlEdition -eq 'Eval') { 'evaluation' } else { 'developer' }; evaluationStartsAt = if ($SqlEdition -eq 'Eval') { 'complete-image' } else { $null }; evaluationExpiresAt = $null; productionUseAllowed = $false }
            features = $features; mediaSha256 = $sqlSha256; setupBuild = $null
        }
        builder = $null; manualAction = $null; installationEvidence = $null; setupEvidence = $null; generalizationEvidence = $null
        sealPostconditions = $null; artifact = $null; cleanupStatus = $null; createdAt = $timestamp; updatedAt = $timestamp
    }
    Write-HyperVSqlImageBuildState -BuildDirectory $buildDirectory -State $state
    return Get-HyperVSqlImageBuildPlan -BuildId $buildId -StateRoot $StateRoot
}

function Set-HyperVSqlMediaHashSidecar {
    <# .SYNOPSIS Prüft einen eingegebenen offiziellen SQL-ISO-SHA-256 und speichert ihn als Sidecar. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$SqlVersion,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
        [ValidateSet('Eval', 'Enterprise', 'Standard')][string]$MediaEdition = 'Eval',
        [string]$SqlMediaPath
    )
    $media = Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $MediaEdition -SqlMediaPath $SqlMediaPath
    $actual = (Get-FileHash -LiteralPath $media.IsoPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) { throw "HYPERV_SQL_MEDIA_HASH_MISMATCH: ISO=$($media.RelativePath)" }
    New-Item -Path (Split-Path -Parent $media.HashPath) -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath $media.HashPath -Value "$actual  $($media.RelativePath)" -Encoding utf8NoBOM
    return Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $MediaEdition -SqlMediaPath $SqlMediaPath
}

function Initialize-HyperVSqlPreparedImageBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$ImageArtifactId,
        [Parameter(Mandatory)][string]$SqlVersion,
        [ValidateSet('Eval', 'Enterprise', 'Standard')][string]$MediaEdition = 'Eval',
        [string]$SqlMediaPath,
        [string[]]$SqlFeatures = @('SQLENGINE', 'FULLTEXT', 'REPLICATION'),
        [ValidateLength(1, 80)][string]$ImageName,
        [ValidateRange(2GB, 1TB)][long]$MemoryStartupBytes = 4GB,
        [ValidateRange(1, 64)][int]$ProcessorCount = 4,
        [string]$StateRoot
    )

    $media = Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $MediaEdition -SqlMediaPath $SqlMediaPath
    if ($media.HashStatus -ne 'SIDECAR_READY') { throw "HYPERV_SQL_MEDIA_HASH_REQUIRED: $($media.HashPath)" }
    $null = Confirm-HyperVSqlInstallationMediaVersion -IsoPath $media.IsoPath -SqlVersion $SqlVersion
    $labNetwork = Ensure-LabHyperVNetwork
    $planArguments = @{
        ImageArtifactId = $ImageArtifactId
        IsoPath = $media.IsoPath
        ExpectedSha256 = $media.ExpectedSha256
        SqlVersion = $SqlVersion
        SqlEdition = $MediaEdition
        SqlFeatures = $SqlFeatures
        StateRoot = $StateRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($ImageName)) { $planArguments.ImageName = $ImageName.Trim() }
    $plan = New-HyperVSqlImageBuildPlan @planArguments
    try {
        $instance = New-HyperVInstance -ImageArtifactId $ImageArtifactId -StateRoot $StateRoot `
            -RunDirectory $plan.BuildDirectory -RunId $plan.buildId -ScopeId $plan.scopeId `
            -InstanceId "sql-image-$SqlVersion" -MemoryStartupBytes $MemoryStartupBytes -ProcessorCount $ProcessorCount `
            -SwitchName $labNetwork.Name
        $managed = Get-HyperVManagedVM -VMName $instance.VMName -ExpectedRunId $plan.buildId -ExpectedScopeId $plan.scopeId
        $null = Add-VMDvdDrive -VM $managed.VM -Path $media.IsoPath -ErrorAction Stop
        $plan.builder = [PSCustomObject]@{
            vmName = [string]$instance.VMName
            osDiskRelativePath = [System.IO.Path]::GetRelativePath($plan.BuildDirectory, $instance.ChildVhdxPath).Replace('\', '/')
            generation = 2; secureBoot = $true; networkAttached = $true
        }
        $plan | Add-Member -NotePropertyName labNetwork -NotePropertyValue $labNetwork -Force
        $plan.manualAction = [PSCustomObject]@{
            stepId = 'complete-windows-oobe'; challenge = New-LabGuid
            instruction = 'VM starten, lokales Administratorpasswort setzen und einmal anmelden'
            requestedAt = Get-LabTimestamp
        }
        Write-HyperVSqlImageBuildState -BuildDirectory $plan.BuildDirectory -State $plan
        return Set-HyperVSqlImageBuildState -BuildId $plan.buildId -State MANUAL_ACTION_REQUIRED `
            -Reason 'Differencing-VM bereit; Windows-OOBE und lokales Administratorpasswort erforderlich' -StateRoot $StateRoot
    }
    catch {
        try { $null = Set-HyperVSqlImageBuildState -BuildId $plan.buildId -State FAILED -Reason $_.Exception.Message -StateRoot $StateRoot } catch { }
        throw
    }
}

function Initialize-HyperVSqlFreshPreparedImageBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][ValidatePattern('^windows-(server-)?[0-9]+$')][string]$OperatingSystemId,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$WindowsEdition,
        [Parameter(Mandatory)][ValidateSet('core', 'desktop-experience')][string]$InstallationType,
        [string]$WindowsMediaPath,
        [Parameter(Mandatory)][string]$SqlVersion,
        [ValidateSet('Eval', 'Enterprise', 'Standard')][string]$MediaEdition = 'Eval',
        [string]$SqlMediaPath,
        [string[]]$SqlFeatures = @('SQLENGINE', 'FULLTEXT', 'REPLICATION'),
        [ValidateLength(1, 80)][string]$ImageName,
        [ValidateRange(32GB, 1TB)][long]$OsDiskSizeBytes = 80GB,
        [ValidateRange(2GB, 1TB)][long]$MemoryStartupBytes = 4GB,
        [ValidateRange(1, 64)][int]$ProcessorCount = 4,
        [string]$StateRoot
    )

    $windowsMedia = Resolve-HyperVWindowsInstallationMedia -MediaRoot $MediaRoot -OperatingSystemId $OperatingSystemId -WindowsMediaPath $WindowsMediaPath -WindowsEdition $WindowsEdition -InstallationType $InstallationType
    if ($windowsMedia.HashStatus -ne 'SIDECAR_READY') { throw "HYPERV_SQL_WINDOWS_MEDIA_HASH_REQUIRED: $($windowsMedia.HashPath)" }
    $sqlMedia = Resolve-HyperVSqlInstallationMedia -MediaRoot $MediaRoot -SqlVersion $SqlVersion -MediaEdition $MediaEdition -SqlMediaPath $SqlMediaPath
    if ($sqlMedia.HashStatus -ne 'SIDECAR_READY') { throw "HYPERV_SQL_MEDIA_HASH_REQUIRED: $($sqlMedia.HashPath)" }
    $null = Confirm-HyperVSqlInstallationMediaVersion -IsoPath $sqlMedia.IsoPath -SqlVersion $SqlVersion
    $labNetwork = Ensure-LabHyperVNetwork
    $planArguments = @{
        WindowsIsoPath = $windowsMedia.IsoPath
        ExpectedWindowsSha256 = $windowsMedia.ExpectedSha256
        OperatingSystemId = $OperatingSystemId
        WindowsEdition = $WindowsEdition
        InstallationType = $InstallationType
        SqlIsoPath = $sqlMedia.IsoPath
        ExpectedSqlSha256 = $sqlMedia.ExpectedSha256
        SqlVersion = $SqlVersion
        SqlEdition = $MediaEdition
        SqlFeatures = $SqlFeatures
        OsDiskSizeBytes = $OsDiskSizeBytes
        StateRoot = $StateRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($ImageName)) { $planArguments.ImageName = $ImageName.Trim() }
    $plan = New-HyperVSqlFreshImageBuildPlan @planArguments
    try {
        $resourceRoot = Join-Path $plan.BuildDirectory 'resources/hyperv'
        $runPrefix = $plan.buildId.Replace('-', '').Substring(0, 8).ToLowerInvariant()
        $vmName = "sql-lab-sql-image-$SqlVersion-$runPrefix"
        $diskPath = Join-Path $resourceRoot "$vmName.vhdx"
        $null = Add-CleanupStep -RunDir $plan.BuildDirectory -ResourceType vhdx -ResourceId $diskPath -Action remove `
            -Provider hyperv -ProviderSubRunId provider-hyperv -Compensation 'Remove fresh Windows SQL image VHDX'
        $null = Add-CleanupStep -RunDir $plan.BuildDirectory -ResourceType vm -ResourceId $vmName -Action remove `
            -Provider hyperv -ProviderSubRunId provider-hyperv -Compensation 'Remove fresh Windows SQL image builder VM'
        New-Item -Path $resourceRoot -ItemType Directory -Force | Out-Null
        $null = New-VHD -Path $diskPath -Dynamic -SizeBytes $OsDiskSizeBytes -ErrorAction Stop
        $vm = New-VM -Name $vmName -Generation 2 -MemoryStartupBytes $MemoryStartupBytes -VHDPath $diskPath `
            -Path $resourceRoot -SwitchName $labNetwork.Name -ErrorAction Stop
        # Do not inherit Hyper-V's unbounded dynamic-memory default (commonly 1 TB).
        $memoryMinimumBytes = [long][Math]::Max([double]512MB, [double]$MemoryStartupBytes / 2)
        $memoryMaximumBytes = [long][Math]::Min([double]1TB, [double]$MemoryStartupBytes * 2)
        $null = Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -MinimumBytes $memoryMinimumBytes `
            -StartupBytes $MemoryStartupBytes -MaximumBytes $memoryMaximumBytes -ErrorAction Stop
        $notes = ConvertTo-HyperVLabNotes -RunId $plan.buildId -ScopeId $plan.scopeId -InstanceId "sql-image-$SqlVersion" -ChildVhdxPath $diskPath
        $null = Set-VM -VM $vm -Notes $notes -AutomaticCheckpointsEnabled $false -ErrorAction Stop
        $null = Set-VMProcessor -VM $vm -Count $ProcessorCount -ErrorAction Stop
        $null = Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -ErrorAction Stop
        $windowsDvd = Add-VMDvdDrive -VM $vm -Path $windowsMedia.IsoPath -Passthru -ErrorAction Stop
        $null = Add-VMDvdDrive -VM $vm -Path $sqlMedia.IsoPath -ErrorAction Stop
        $null = Set-VMFirmware -VM $vm -FirstBootDevice $windowsDvd -ErrorAction Stop
        $plan.builder = [PSCustomObject]@{
            vmName = $vmName; osDiskRelativePath = "resources/hyperv/$vmName.vhdx"
            generation = 2; secureBoot = $true; networkAttached = $true; diskKind = 'fresh-dynamic'
        }
        $plan | Add-Member -NotePropertyName labNetwork -NotePropertyValue $labNetwork -Force
        $plan.manualAction = [PSCustomObject]@{
            stepId = 'install-fresh-windows-then-prepare-sql'; challenge = New-LabGuid
            instruction = 'Windows aus der DVD installieren, OOBE abschliessen und einmal lokal als Administrator anmelden'
            requestedAt = Get-LabTimestamp
        }
        Write-HyperVSqlImageBuildState -BuildDirectory $plan.BuildDirectory -State $plan
        return Set-HyperVSqlImageBuildState -BuildId $plan.buildId -State MANUAL_ACTION_REQUIRED `
            -Reason 'Frische Windows-VM mit Windows- und SQL-ISO bereit; ein finaler Sysprep nach SQL PrepareImage vorgesehen' -StateRoot $StateRoot
    }
    catch {
        try { $null = Set-HyperVSqlImageBuildState -BuildId $plan.buildId -State FAILED -Reason $_.Exception.Message -StateRoot $StateRoot } catch { }
        throw
    }
}

function Start-HyperVSqlImageBuildVM {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildId, [string]$StateRoot)

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build -or $build.state -notin @('MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED')) {
        throw 'HYPERV_SQL_IMAGE_BUILD_VM_NOT_STARTABLE'
    }
    $instance = Start-HyperVInstance -VMName ([string]$build.builder.vmName) `
        -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId
    if ([string]$build.provisioningMode -eq 'fresh-windows-media') {
        $receipt = Invoke-HyperVInitialMediaBootInteraction `
            -BuildId $BuildId -VMName ([string]$build.builder.vmName) -StateRoot $StateRoot
        $instance | Add-Member -NotePropertyName InitialMediaBoot -NotePropertyValue $receipt -Force
    }
    return $instance
}

function Confirm-HyperVSqlFreshWindowsInstallation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Build, [Parameter(Mandatory)][PSCredential]$Credential, [string]$StateRoot)

    if ([string]$Build.provisioningMode -ne 'fresh-windows-media' -or $Build.installationEvidence) { return $Build }
    $receipt = Invoke-HyperVPowerShellDirect -VMName ([string]$Build.builder.vmName) `
        -ExpectedRunId ([string]$Build.buildId) -ExpectedScopeId ([string]$Build.scopeId) -Credential $Credential `
        -ArgumentList @([string]$Build.buildId, [string]$Build.scopeId) -ScriptBlock {
            param($ExpectedBuildId, $ExpectedScopeId)
            $current = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            [PSCustomObject]@{
                contractVersion = '1'; buildId = $ExpectedBuildId; scopeId = $ExpectedScopeId
                productName = [string]$current.ProductName; editionId = [string]$current.EditionID
                installationType = [string]$current.InstallationType; currentBuild = [string]$current.CurrentBuild
            }
        }
    $receipt = @($receipt)[-1]
    if (-not $receipt -or [string]$receipt.contractVersion -ne '1' -or
        [string]$receipt.buildId -ne [string]$Build.buildId -or [string]$receipt.scopeId -ne [string]$Build.scopeId) {
        throw 'HYPERV_SQL_WINDOWS_INSTALLATION_RECEIPT_INVALID'
    }
    $expectedOperatingSystemId = [string]$Build.operatingSystem.id
    $expectedProductPattern = if ($expectedOperatingSystemId -match '^windows-server-') { 'Windows Server' } elseif ($expectedOperatingSystemId -match '^windows-(?<version>[0-9]+)$') { "Windows $($Matches.version)" } else { 'Windows' }
    if ([string]$receipt.productName -notmatch $expectedProductPattern) {
        throw "HYPERV_SQL_WINDOWS_INSTALLATION_VERSION_MISMATCH: erwartet $expectedOperatingSystemId, erkannt $($receipt.productName)"
    }
    $editionBase = ([string]$Build.operatingSystem.edition -replace '-evaluation$', '')
    $editionId = switch -Regex ($editionBase) {
        '^standard$' { 'ServerStandard'; break }
        '^datacenter$' { 'ServerDatacenter'; break }
        '^azure-edition$' { 'ServerAzure'; break }
        '^enterprise' { 'Enterprise'; break }
        '^education' { 'Education'; break }
        '^professional' { 'Professional'; break }
        '^home$' { 'Core'; break }
        default { [regex]::Escape($editionBase) }
    }
    # EditionID unterscheidet sich zwischen Windows-Versionen (z. B.
    # Enterprise, EnterpriseEval oder EnterpriseS). Der aus der ISO gewählte
    # Editionsstamm muss passen; die Evaluation ist bereits im Build-Lizenztyp
    # erfasst und wird nicht künstlich als Setup-Blockade verwendet.
    $editionPattern = "^$editionId"
    if ([string]$receipt.editionId -notmatch $editionPattern) {
        $osLabel = ($expectedOperatingSystemId -replace '^windows-server-', 'Windows Server ')
        $osLabel = ($osLabel -replace '^windows-', 'Windows ')
        $editionLabel = ((Get-Culture).TextInfo.ToTitleCase(($editionBase -replace '-', ' ')))
        $expectedLabel = "$osLabel $editionLabel"
        if ([string]$Build.license.type -eq 'evaluation') { $expectedLabel += ' Evaluation' }
        $typeLabel = if ([string]$Build.operatingSystem.installationType -eq 'core') { 'Server Core Installation' } else { 'Desktop Experience' }
        throw "HYPERV_SQL_WINDOWS_INSTALLATION_EDITION_MISMATCH: erwartet $($Build.operatingSystem.edition), erkannt $($receipt.editionId). In VMConnect Windows vor SQL-Setup neu installieren und '$expectedLabel ($typeLabel)' auswählen."
    }
    $actualType = switch ([string]$receipt.installationType) { 'Server Core' { 'core' }; 'Server' { 'desktop-experience' }; 'Client' { 'desktop-experience' }; default { 'unknown' } }
    if ($actualType -ne [string]$Build.operatingSystem.installationType) { throw "HYPERV_SQL_WINDOWS_INSTALLATION_TYPE_MISMATCH: erwartet $($Build.operatingSystem.installationType), erkannt $actualType" }
    $Build | Add-Member -NotePropertyName installationEvidence -NotePropertyValue ([PSCustomObject]@{
        verified = $true; productName = [string]$receipt.productName; editionId = [string]$receipt.editionId
        installationType = $actualType; currentBuild = [string]$receipt.currentBuild; acceptedAt = Get-LabTimestamp
    }) -Force
    Write-HyperVSqlImageBuildState -BuildDirectory $Build.BuildDirectory -State $Build
    return Get-HyperVSqlImageBuildPlan -BuildId ([string]$Build.buildId) -StateRoot $StateRoot
}

function Wait-HyperVSqlImageBuildGuestRestart {
    <#
    .SYNOPSIS Wartet nach einem von SQL Setup angeforderten Neustart auf den neuen Gast-Boot.
    .DESCRIPTION Ein bloßes PowerShell-Direct-Readiness-Probe kann unmittelbar nach
    `shutdown /r` noch die alte Sitzung treffen. Deshalb wird die Bootzeit vor
    dem SQL-Setup-Reset mit der anschließend beobachteten Bootzeit verglichen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Build,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][string]$PreviousBootTime,
        [ValidateRange(30, 1800)][int]$TimeoutSeconds = 600
    )

    $fallbackAddress = if ($Build.labNetwork) {
        Get-LabNetworkGuestAddress -Network $Build.labNetwork -Identity ([string]$Build.buildId)
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastStatus = 'Neustart noch nicht beobachtet.'
    $lastProgressSeconds = -30
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (($stopwatch.Elapsed.TotalSeconds - $lastProgressSeconds) -ge 30) {
            $lastProgressSeconds = $stopwatch.Elapsed.TotalSeconds
            Write-LabInfo "SQL Setup: warte auf Gast-Neustart ($([int]$stopwatch.Elapsed.TotalSeconds)s/$TimeoutSeconds, $lastStatus)"
        }
        try {
            $probe = Invoke-HyperVPowerShellDirect -VMName ([string]$Build.builder.vmName) `
                -ExpectedRunId ([string]$Build.buildId) -ExpectedScopeId ([string]$Build.scopeId) `
                -Credential $Credential -FallbackAddress $fallbackAddress -ScriptBlock {
                    [PSCustomObject]@{
                        bootTime = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
                        imageState = [string](Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState -ErrorAction Stop)
                    }
                }
            $probe = @($probe)[-1]
            if ($probe -and [string]$probe.bootTime -ne $PreviousBootTime -and [string]$probe.imageState -eq 'IMAGE_STATE_COMPLETE') {
                $stopwatch.Stop()
                return [PSCustomObject]@{ Ready = $true; BootTime = [string]$probe.bootTime; Duration = $stopwatch.Elapsed; Message = 'SQL-Setup-Neustart abgeschlossen.' }
            }
            $lastStatus = if ($probe) { "Bootzeit noch unverändert ($($probe.bootTime))." } else { 'Kein PowerShell-Direct-Resultat.' }
        }
        catch {
            $lastStatus = $_.Exception.Message
        }
        Start-Sleep -Seconds 2
    }
    $stopwatch.Stop()
    return [PSCustomObject]@{ Ready = $false; BootTime = $null; Duration = $stopwatch.Elapsed; Message = "SQL-Setup-Neustart Timeout: $lastStatus" }
}

function Invoke-HyperVSqlPrepareAndGeneralize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [ValidateRange(60, 10800)][int]$SetupTimeoutSeconds = 7200,
        [ValidateRange(30, 1800)][int]$ShutdownTimeoutSeconds = 300,
        [string]$StateRoot
    )

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build -or $build.state -notin @('MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED')) {
        throw 'HYPERV_SQL_IMAGE_BUILD_NOT_READY'
    }
    $vmName = [string]$build.builder.vmName
    $managed = Get-HyperVManagedVM -VMName $vmName -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId
    if (-not $managed -or [string]$managed.VM.State -ne 'Running') { throw 'HYPERV_SQL_IMAGE_BUILD_VM_MUST_BE_RUNNING' }
    $build = Confirm-HyperVSqlFreshWindowsInstallation -Build $build -Credential $Credential -StateRoot $StateRoot
    $setupVersionPattern = Get-HyperVSqlSetupVersionPattern -SqlVersion $build.sql.version

    # Nach erfolgreichem PrepareImage wird dessen Receipt unmittelbar
    # persistiert. Scheitert erst das anschliessende Sysprep, darf ein
    # Wiederholungsaufruf SQL Setup nicht ein zweites Mal ausfuehren.
    if ($build.state -eq 'MANUAL_ACTION_REQUIRED' -and -not $build.setupEvidence) {
        $receipt = Invoke-HyperVPowerShellDirect -VMName $vmName -ExpectedRunId $build.buildId `
            -ExpectedScopeId $build.scopeId -Credential $Credential `
            -ArgumentList @($build.buildId, $build.scopeId, $build.manualAction.challenge, $build.sql.version, $setupVersionPattern, ($build.sql.features -join ','), $SetupTimeoutSeconds) `
            -ScriptBlock {
                param($ExpectedBuildId, $ExpectedScopeId, $Challenge, $ExpectedSqlVersion, $ExpectedSetupVersionPattern, $FeaturesCsv, $TimeoutSeconds)
                $ErrorActionPreference = 'Stop'
                $Features = @([string]$FeaturesCsv -split ',' | Where-Object { $_ })
                $allSetup = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object {
                    $candidate = Join-Path ([string]$_.DeviceID + '\') 'setup.exe'
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate }
                })
                $setup = @($allSetup | Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_.VersionInfo.FileVersion) -and
                    [string]$_.VersionInfo.FileVersion -match $ExpectedSetupVersionPattern
                })
                if ($setup.Count -ne 1) {
                    $observed = @($allSetup | ForEach-Object { "$($_.FullName)=$($_.VersionInfo.FileVersion)" }) -join '; '
                    throw "SQL_SETUP_MEDIA_NOT_UNIQUE: passendeSQLSetups=$($setup.Count); gefunden=$observed"
                }
                $setupVersion = [string]$setup[0].VersionInfo.FileVersion
                $arguments = @(
                    '/Q', '/ACTION=PrepareImage', "/FEATURES=$(@($Features) -join ',')",
                    '/INSTANCEID=MSSQLSERVER', '/ENU=True', '/IACCEPTSQLSERVERLICENSETERMS', '/INDICATEPROGRESS'
                )
                $process = Start-Process -FilePath $setup[0].FullName -ArgumentList $arguments -PassThru -NoNewWindow
                if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    throw "SQL_SETUP_PREPARE_IMAGE_TIMEOUT: $TimeoutSeconds"
                }
                $exitCode = $null
                try { $exitCode = [int]$process.ExitCode } catch { }
                if ($exitCode -notin @(0, 3010)) {
                    $logRoot = Join-Path $env:ProgramFiles 'Microsoft SQL Server'
                    $summary = @(Get-ChildItem -LiteralPath $logRoot -Filter 'Summary.txt' -File -Recurse -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)[0]
                    $detail = 'Summary.txt nicht gefunden'
                    if ($summary) {
                        $lines = @(Get-Content -LiteralPath $summary.FullName -Tail 80 -ErrorAction SilentlyContinue)
                        $relevant = @($lines | Where-Object { $_ -match '(?i)error|failed|failure|exit code|result' } | Select-Object -Last 8)
                        if ($relevant.Count -eq 0) { $relevant = @($lines | Select-Object -Last 8) }
                        $detail = (($relevant -join ' ') -replace '\s+', ' ').Trim()
                        if ($detail.Length -gt 1200) { $detail = $detail.Substring(0, 1200) }
                        $detail = "Summary=$($summary.FullName); Detail=$detail"
                    }
                    $reportedExitCode = if ($null -eq $exitCode) { 'unbekannt' } else { [string]$exitCode }
                    throw "SQL_SETUP_PREPARE_IMAGE_FAILED: ExitCode=$reportedExitCode; $detail"
                }
                $bootTimeBeforeRestart = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
                if ($exitCode -eq 3010) { $null = & shutdown.exe /r /t 15 /f /d p:4:1 }
                [PSCustomObject]@{
                    contractVersion = '1'; buildId = $ExpectedBuildId; scopeId = $ExpectedScopeId
                    challenge = $Challenge; action = 'PrepareImage'; sqlVersion = $ExpectedSqlVersion
                    setupFileVersion = $setupVersion; features = @($Features); exitCode = $exitCode
                    rebootScheduled = ($exitCode -eq 3010); bootTimeBeforeRestart = $bootTimeBeforeRestart; completedAt = [datetime]::UtcNow.ToString('o')
                }
            }
        $receipt = @($receipt)[-1]
        if (-not $receipt -or [string]$receipt.contractVersion -ne '1' -or
            [string]$receipt.buildId -ne [string]$build.buildId -or [string]$receipt.scopeId -ne [string]$build.scopeId -or
            [string]$receipt.challenge -ne [string]$build.manualAction.challenge -or [string]$receipt.action -ne 'PrepareImage' -or
            [string]$receipt.sqlVersion -ne [string]$build.sql.version -or [int]$receipt.exitCode -notin @(0, 3010) -or
            (@($receipt.features | Sort-Object -Unique) -join '|') -ne (@($build.sql.features | Sort-Object -Unique) -join '|') -or
            -not [string]$receipt.setupFileVersion -or -not [string]$receipt.completedAt) {
            throw 'HYPERV_SQL_PREPARE_RECEIPT_INVALID'
        }
        $build.setupEvidence = [PSCustomObject]@{
            action = 'PrepareImage'; sqlVersion = [string]$receipt.sqlVersion; setupFileVersion = [string]$receipt.setupFileVersion
            features = @($receipt.features | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            exitCode = [int]$receipt.exitCode; completedAt = [string]$receipt.completedAt; acceptedAt = Get-LabTimestamp
        }
        $build.sql.setupBuild = [string]$receipt.setupFileVersion
        Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
        if ([int]$receipt.exitCode -eq 3010) {
            $build = Set-HyperVSqlImageBuildState -BuildId $BuildId -State REBOOT_REQUIRED `
                -Reason 'SQL PrepareImage erfolgreich; von Setup angeforderter Neustart laeuft' -StateRoot $StateRoot
            Write-LabInfo 'SQL PrepareImage hat einen Neustart angefordert; der automatische Ablauf wartet auf den neuen Gast-Boot.'
            $restarted = Wait-HyperVSqlImageBuildGuestRestart -Build $build -Credential $Credential `
                -PreviousBootTime ([string]$receipt.bootTimeBeforeRestart) -TimeoutSeconds $ShutdownTimeoutSeconds
            if (-not $restarted.Ready) { throw "HYPERV_SQL_IMAGE_REBOOT_RECONNECT_TIMEOUT: $($restarted.Message)" }
            $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
        }
        else { $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot }
    }

    if (-not $build.setupEvidence -or [string]$build.setupEvidence.action -ne 'PrepareImage') {
        throw 'HYPERV_SQL_PREPARE_EVIDENCE_MISSING'
    }
    $sysprep = Invoke-HyperVPowerShellDirect -VMName $vmName -ExpectedRunId $build.buildId `
        -ExpectedScopeId $build.scopeId -Credential $Credential `
        -ArgumentList @($build.buildId, $build.scopeId, $build.manualAction.challenge) `
        -ScriptBlock {
            param($ExpectedBuildId, $ExpectedScopeId, $Challenge)
            $ErrorActionPreference = 'Stop'
            $imageState = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
            # Ein zuvor gestartetes Sysprep kann nach der Rueckkehr von /quit
            # noch den Zwischenzustand UNDEPLOYABLE zeigen. In diesem Fall
            # keinesfalls ein zweites Sysprep starten, sondern dessen Abschluss
            # abwarten. Ein bereits final generalisiertes Image wird ebenfalls
            # nur noch in den kontrollierten Shutdown ueberfuehrt.
            if ($imageState -notin @('IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE', 'IMAGE_STATE_UNDEPLOYABLE')) {
                $sysprepPath = Join-Path $env:SystemRoot 'System32\Sysprep\Sysprep.exe'
                $process = Start-Process -FilePath $sysprepPath `
                    -ArgumentList @('/generalize', '/oobe', '/mode:vm', '/quit', '/quiet') -Wait -PassThru
                if ($process.ExitCode -ne 0) { throw "WINDOWS_SYSPREP_FAILED: $($process.ExitCode)" }
            }
            # Sysprep /quit beendet den Prozess, bevor Windows Setup seinen
            # ImageState zwingend auf den finalen Generalize-Zustand geschrieben
            # hat. IMAGE_STATE_UNDEPLOYABLE ist in diesem kurzen Intervall kein
            # belastbarer Endzustand; deshalb begrenzt auf den dokumentierten
            # Zielzustand warten statt unmittelbar nach dem Prozessende lesen.
            # Auf realen Systemen kann die Nachbereitung von Sysprep deutlich
            # laenger als der Sysprep-Prozess selbst dauern. Zehn Minuten sind
            # weiterhin begrenzt, vermeiden aber einen falschen Fehler, wenn
            # IMAGE_STATE_UNDEPLOYABLE noch berechtigt im Uebergang steht.
            $stateDeadline = [datetime]::UtcNow.AddSeconds(600)
            do {
                $imageState = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
                if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }
                Start-Sleep -Seconds 2
            } while ([datetime]::UtcNow -lt $stateDeadline)
            if ($imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { throw "WINDOWS_SYSPREP_STATE_INVALID: $imageState" }
            $null = & shutdown.exe /s /t 15 /f /d p:4:1
            [PSCustomObject]@{
                contractVersion = '1'; buildId = $ExpectedBuildId; scopeId = $ExpectedScopeId; challenge = $Challenge
                sysprepExitCode = 0; imageState = $imageState; completedAt = [datetime]::UtcNow.ToString('o')
            }
        }
    $sysprep = @($sysprep)[-1]
    if (-not $sysprep -or [string]$sysprep.buildId -ne [string]$build.buildId -or
        [string]$sysprep.scopeId -ne [string]$build.scopeId -or [string]$sysprep.challenge -ne [string]$build.manualAction.challenge -or
        [int]$sysprep.sysprepExitCode -ne 0 -or [string]$sysprep.imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
        throw 'HYPERV_SQL_IMAGE_SYSPREP_RECEIPT_INVALID'
    }
    $deadline = [datetime]::UtcNow.AddSeconds($ShutdownTimeoutSeconds)
    do {
        $managed = Get-HyperVManagedVM -VMName $vmName -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId
        if (-not $managed) { throw 'HYPERV_SQL_IMAGE_BUILD_VM_MISSING_DURING_SHUTDOWN' }
        if ([string]$managed.VM.State -eq 'Off') { break }
        Start-Sleep -Seconds 2
    } while ([datetime]::UtcNow -lt $deadline)
    if ([string]$managed.VM.State -ne 'Off') { throw 'HYPERV_SQL_IMAGE_BUILD_SHUTDOWN_TIMEOUT' }

    $build.generalizationEvidence = [PSCustomObject]@{
        source = 'powershell-direct'; challenge = [string]$sysprep.challenge
        imageState = [string]$sysprep.imageState; sysprepExitCode = 0
        shutdownObserved = $true; completedAt = [string]$sysprep.completedAt; acceptedAt = Get-LabTimestamp
    }
    Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Set-HyperVSqlImageBuildState -BuildId $BuildId -State RESUME_PENDING `
        -Reason 'SQL PrepareImage, Windows-Generalize und Gast-Shutdown technisch verifiziert' -StateRoot $StateRoot
}

function Complete-HyperVSqlPreparedImageBuild {
    <#
    .SYNOPSIS Führt nach der einmaligen Windows-Installation den vollständigen Prepared-Image-Abschluss aus.
    .DESCRIPTION Der reguläre Pfad umfasst SQL PrepareImage, einen eventuell
    erforderlichen SQL-Setup-Neustart, den finalen Windows-Sysprep, das
    Herunterfahren, Hashen und die immutable Veröffentlichung. Manuelle
    Einzelaktionen bleiben ausschließlich für Diagnose und Recovery bestehen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [ValidateRange(60, 10800)][int]$SetupTimeoutSeconds = 7200,
        [ValidateRange(30, 1800)][int]$ShutdownTimeoutSeconds = 600,
        [Nullable[datetime]]$EvaluationExpiresAt,
        [string]$StateRoot
    )

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_SQL_IMAGE_BUILD_NOT_FOUND' }
    if ([string]$build.state -in @('MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED')) {
        Write-LabInfo 'Automatischer Abschluss 1/3: SQL PrepareImage, notwendige Neustarts und finaler Sysprep werden ausgeführt.'
        $build = Invoke-HyperVSqlPrepareAndGeneralize -BuildId $BuildId -Credential $Credential `
            -SetupTimeoutSeconds $SetupTimeoutSeconds -ShutdownTimeoutSeconds $ShutdownTimeoutSeconds -StateRoot $StateRoot
    }
    if ([string]$build.state -ne 'RESUME_PENDING') {
        throw "HYPERV_SQL_IMAGE_AUTOMATION_NOT_READY: $($build.state)"
    }

    if (-not $EvaluationExpiresAt -and [string]$build.license.type -eq 'evaluation' -and -not $build.parentArtifact.license.evaluationExpiresAt) {
        # Der Wert ist nur Metadatum zum Evaluation-Medium. Er vermeidet im
        # unbeaufsichtigten Ablauf einen sonst nicht automatisierbaren Prompt.
        $EvaluationExpiresAt = (Get-Date).Date.AddDays(180)
    }
    Write-LabInfo 'Automatischer Abschluss 2/3: SQL-Prepared-VHDX wird verifiziert, abgeflacht und unveränderlich veröffentlicht.'
    $published = Publish-HyperVSqlPreparedImageBuild -BuildId $BuildId -EvaluationExpiresAt $EvaluationExpiresAt -StateRoot $StateRoot
    Write-LabSuccess 'Automatischer Abschluss 3/3: SQL-Prepared-Image ist veröffentlicht und für neue Klone bereit.'
    return $published
}

function Resume-HyperVSqlPreparedImageGeneralization {
    <#
    .SYNOPSIS
        Uebernimmt einen nach Sysprep bereits generalisierten SQL-Builder.
    .DESCRIPTION
        Der Recovery-Pfad ist nur fuer Builds vorgesehen, deren SQL
        PrepareImage-Receipt bereits persistiert wurde. Er faehrt die VM nach
        expliziter Menue-Bestaetigung aus und validiert den finalen Windows
        ImageState offline, ohne ein zurueckgesetztes Gastpasswort zu benötigen.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildId, [string]$StateRoot)

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build -or $build.state -ne 'MANUAL_ACTION_REQUIRED' -or
        -not $build.setupEvidence -or [string]$build.setupEvidence.action -ne 'PrepareImage') {
        throw 'HYPERV_SQL_IMAGE_GENERALIZATION_RECOVERY_NOT_READY'
    }
    $managed = Get-HyperVManagedVM -VMName ([string]$build.builder.vmName) `
        -ExpectedRunId ([string]$build.buildId) -ExpectedScopeId ([string]$build.scopeId)
    if (-not $managed) { throw 'HYPERV_SQL_IMAGE_GENERALIZATION_RECOVERY_VM_MISSING' }
    if ([string]$managed.VM.State -ne 'Off') {
        $null = Stop-HyperVInstance -VMName ([string]$build.builder.vmName) `
            -ExpectedRunId ([string]$build.buildId) -ExpectedScopeId ([string]$build.scopeId)
    }
    $vhdxPath = Join-Path $build.BuildDirectory ([string]$build.builder.osDiskRelativePath)
    $inspection = Get-HyperVSqlOfflineImageState -VhdxPath $vhdxPath `
        -MountRoot (Join-Path $build.BuildDirectory 'offline-generalization-inspection')
    $imageState = [string]$inspection.ImageState
    if ($imageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') {
        $reason = Get-HyperVSqlSysprepFailureReason -ImageState $imageState -SysprepDetail ([string]$inspection.SysprepDetail)
        $build | Add-Member -NotePropertyName lastError -NotePropertyValue $reason -Force
        $build | Add-Member -NotePropertyName sysprepFailureDetail -NotePropertyValue ([string]$inspection.SysprepDetail) -Force
        Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
        $null = Set-HyperVSqlImageBuildState -BuildId $BuildId -State FAILED -Reason $reason -StateRoot $StateRoot
        throw $reason
    }
    $build.generalizationEvidence = [PSCustomObject]@{
        source = 'offline-inspection'; challenge = [string]$build.manualAction.challenge
        imageState = $imageState; sysprepExitCode = $null; shutdownObserved = $true
        completedAt = Get-LabTimestamp; acceptedAt = Get-LabTimestamp
    }
    Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return Set-HyperVSqlImageBuildState -BuildId $BuildId -State RESUME_PENDING `
        -Reason 'Bereits generalisierter SQL-Builder nach Offline-ImageState-Pruefung uebernommen' -StateRoot $StateRoot
}

function Publish-HyperVSqlPreparedImageBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildId,
        [Nullable[datetime]]$EvaluationExpiresAt,
        [string]$StateRoot
    )

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_SQL_IMAGE_BUILD_NOT_FOUND' }
    if ($build.state -eq 'SQL_PREPARED_SEALED') {
        $existing = Get-HyperVImageArtifact -ArtifactId $build.artifact.artifactId -StateRoot $StateRoot
        return [PSCustomObject]@{ Status = $build.state; Build = $build; Artifact = $existing }
    }
    if ($build.state -ne 'RESUME_PENDING' -or -not $build.setupEvidence -or -not $build.generalizationEvidence) {
        throw 'HYPERV_SQL_IMAGE_BUILD_NOT_READY_TO_SEAL'
    }
    if ($build.generalizationEvidence.shutdownObserved -ne $true -or
        [string]$build.generalizationEvidence.challenge -ne [string]$build.manualAction.challenge) {
        throw 'HYPERV_SQL_IMAGE_GENERALIZATION_EVIDENCE_INVALID'
    }
    $managed = Get-HyperVManagedVM -VMName $build.builder.vmName -ExpectedRunId $build.buildId -ExpectedScopeId $build.scopeId
    if (-not $managed) { throw 'HYPERV_SQL_IMAGE_BUILD_VM_MISSING' }
    if ([string]$managed.VM.State -ne 'Off') { throw 'HYPERV_SQL_IMAGE_BUILD_VM_MUST_BE_OFF' }
    if (@(Get-VMSnapshot -VM $managed.VM -ErrorAction Stop).Count -gt 0) { throw 'HYPERV_SQL_IMAGE_BUILD_CHECKPOINTS_PRESENT' }
    $childPath = Join-Path $build.BuildDirectory ([string]$build.builder.osDiskRelativePath)
    if (-not (Test-HyperVPathWithinRunDirectory -Path $childPath -RunDirectory $build.BuildDirectory) -or
        -not (Test-Path -LiteralPath $childPath -PathType Leaf)) { throw 'HYPERV_SQL_IMAGE_BUILD_DISK_SCOPE_INVALID' }
    if (-not ([System.IO.Path]::GetFullPath($childPath).Equals([System.IO.Path]::GetFullPath([string]$managed.Identity.childVhdxPath), [System.StringComparison]::OrdinalIgnoreCase))) {
        throw 'HYPERV_SQL_IMAGE_BUILD_DISK_IDENTITY_MISMATCH'
    }

    $flatPath = Join-Path (Join-Path $build.BuildDirectory 'resources/hyperv') "sql-prepared-$BuildId.vhdx"
    if (-not (Test-HyperVPathWithinRunDirectory -Path $flatPath -RunDirectory $build.BuildDirectory)) {
        throw 'HYPERV_SQL_IMAGE_FLAT_DISK_SCOPE_INVALID'
    }
    if (-not (Test-Path -LiteralPath $flatPath)) {
        $null = Add-CleanupStep -RunDir $build.BuildDirectory -ResourceType vhdx -ResourceId $flatPath -Action remove `
            -Provider hyperv -ProviderSubRunId provider-hyperv -Compensation 'Remove flattened SQL prepared VHDX'
        Convert-VHD -Path $childPath -DestinationPath $flatPath -VHDType Dynamic -ErrorAction Stop
    }
    if (-not (Test-HyperVVhdxSignature -Path $flatPath)) { throw 'HYPERV_SQL_IMAGE_FLAT_DISK_INVALID' }
    (Get-Item -LiteralPath $flatPath -Force).IsReadOnly = $true
    $sha256 = (Get-FileHash -LiteralPath $flatPath -Algorithm SHA256).Hash
    $parent = $build.parentArtifact
    $expiry = if ($EvaluationExpiresAt) { $EvaluationExpiresAt } elseif ($parent.license.evaluationExpiresAt) { [datetime]$parent.license.evaluationExpiresAt } else { $null }
    if ([string]$parent.license.type -eq 'evaluation' -and -not $expiry) { throw 'HYPERV_SQL_IMAGE_EVALUATION_EXPIRY_REQUIRED' }
    $displayNameArgument = @{}
    if (-not [string]::IsNullOrWhiteSpace([string]$build.displayName)) {
        $displayNameArgument.DisplayName = ([string]$build.displayName).Trim()
    }
    $artifact = Import-HyperVImageArtifact -VhdxPath $flatPath -ExpectedSha256 $sha256 `
        -ArtifactState SQL_PREPARED_SEALED -OperatingSystemId $parent.operatingSystem.id `
        -OperatingSystemVersion $parent.operatingSystem.version -Edition $parent.operatingSystem.edition `
        -InstallationType $parent.operatingSystem.installationType -Language $parent.operatingSystem.language `
        -LicenseType $parent.license.type -IntegrityOrigin generated-by-runtime -Generalized -SqlPrepared `
        -SqlVersion $build.sql.version -SqlEdition $build.sql.edition -SqlBuild $build.sql.setupBuild `
        -SqlFeatures @($build.sql.features) -SqlLicenseType $build.sql.license.type `
        -EvaluationExpiresAt $expiry @displayNameArgument -StateRoot $StateRoot
    if (-not $artifact -or $artifact.artifactState -ne 'SQL_PREPARED_SEALED' -or $artifact.sha256 -ne $sha256.ToLowerInvariant()) {
        throw 'HYPERV_SQL_IMAGE_ARTIFACT_PUBLICATION_FAILED'
    }
    # Registry-Import und Hash-Verifikation sind abgeschlossen, bevor VM und
    # buildlokale Differencing-/Flattened-VHDX entfernt werden.
    $null = Remove-HyperVInstance -VMName $build.builder.vmName -ExpectedScopeId $build.scopeId `
        -ExpectedRunDirectory $build.BuildDirectory -RequireOff
    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    $build.sealPostconditions = [PSCustomObject]@{
        identityValidated = $true; vmOff = $true; checkpointsAbsent = $true
        differencingChainFlattened = $true; validatedAt = Get-LabTimestamp
    }
    $build.artifact = [PSCustomObject]@{
        artifactId = [string]$artifact.artifactId; artifactState = [string]$artifact.artifactState
        sha256 = [string]$artifact.sha256; publishedAt = Get-LabTimestamp
    }
    Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    $build = Set-HyperVSqlImageBuildState -BuildId $BuildId -State SQL_PREPARED_SEALED `
        -Reason 'Eigenstaendige SQL-PrepareImage-VHDX immutable in Registry veroeffentlicht' -StateRoot $StateRoot
    $cleanup = Invoke-CleanupPlan -RunDir $build.BuildDirectory -ScopeId $build.scopeId
    $build.cleanupStatus = [string]$cleanup.Status
    Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    return [PSCustomObject]@{ Status = 'SQL_PREPARED_SEALED'; Build = $build; Artifact = $artifact; Cleanup = $cleanup }
}

function Remove-HyperVSqlImageBuild {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildId, [string]$StateRoot)

    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    if (-not $build) { throw 'HYPERV_SQL_IMAGE_BUILD_NOT_FOUND' }
    $cleanup = Invoke-CleanupPlan -RunDir $build.BuildDirectory -ScopeId $build.scopeId
    $build = Get-HyperVSqlImageBuildPlan -BuildId $BuildId -StateRoot $StateRoot
    $build.cleanupStatus = [string]$cleanup.Status
    Write-HyperVSqlImageBuildState -BuildDirectory $build.BuildDirectory -State $build
    if ([string]$cleanup.Status -eq 'CLEANUP_SUCCEEDED') {
        Remove-LabSecrets -Path $build.BuildDirectory
        $build = Set-HyperVSqlImageBuildState -BuildId $BuildId -State CLEANED_UP -Reason 'Unfertiger SQL-Builder samt VM und buildlokaler VHDX aufgeraeumt' -StateRoot $StateRoot
    }
    return [PSCustomObject]@{ BuildId = $BuildId; Status = [string]$cleanup.Status; Cleanup = $cleanup; Build = $build }
}

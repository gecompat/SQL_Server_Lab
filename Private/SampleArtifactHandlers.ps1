<#
.SYNOPSIS
    Sample-Artifact-Handler fuer den gemeinsamen Installations-Lifecycle.
.DESCRIPTION
    Implementiert die freigegebenen Sample-Handler aus dem Sample-Zielvertrag:
    direkte Backups, ZIP-/7z-Archive mit genau einem katalogisierten Backup,
    einzelne T-SQL-Skripte und sichere ZIP-Script-Bundles. Acquisition und Integritaet laufen ueber den
    Artifact Resolver (Trust Store, Cache, Quarantaene, Run Lock), danach
    folgen Idempotenzpruefung, Apply und Output-Verification. Alle Ergebnisse verwenden stabile Statusklassen
    (DATASET_READY, TRUST_REQUIRED, SAMPLE_OUTPUT_CONFLICT,
    SAMPLE_INSTALLATION_FAILED, SAMPLE_VERIFICATION_FAILED, RECOVERY_REQUIRED).
#>

function Get-LabExecutableSampleVariant {
    <#
    .SYNOPSIS
        Listet automatisch installierbare Sample-Varianten des Katalogs auf.
    .DESCRIPTION
        Liefert nur Varianten, fuer die ein freigegebener Runtime-Handler
        vorhanden ist: direkte Backups, ZIP-/7z-Backups, einzelne T-SQL-Skripte,
        Script Bundles und BACPAC-Imports. BACPAC verlangt beim Lauf ein
        gebundenes SqlPackage-Container-Tool. Bundles duerfen mehrere erwartete
        Datenbanken definieren.
        Optional wird nach SQL-Version gefiltert.
    #>
    [CmdletBinding()]
    param(
        [string]$SqlVersion
    )

    $baseVersion = $null
    if ($SqlVersion) {
        $baseVersionText = ([string]$SqlVersion -split '-', 2)[0]
        if ($baseVersionText -match '^\d{4}$') {
            $baseVersion = [int]$baseVersionText
        }
    }

    $results = @()
    foreach ($sample in @(Get-LabSampleDatabase)) {
        if ($baseVersion -and $sample.minSqlVersion -and [int]$sample.minSqlVersion -gt $baseVersion) {
            continue
        }

        foreach ($variantProperty in @($sample.versions.PSObject.Properties)) {
            $definition = $variantProperty.Value
            if ($definition.runtimeStatus -ne 'executable' -or
                $definition.artifactType -notin @('backup', 'archive-backup', 'sql-script', 'script-bundle', 'bacpac') -or
                [string]$definition.installation.kind -ne [string]$definition.artifactType) {
                continue
            }

            $outputs = @($definition.expectedOutputs)
            if ($outputs.Count -eq 0 -or @($outputs | Where-Object { $_.kind -ne 'database' }).Count -gt 0) {
                continue
            }
            if ($definition.artifactType -ne 'script-bundle' -and $outputs.Count -ne 1) {
                continue
            }

            $results += [PSCustomObject]@{
                SampleId               = [string]$sample.id
                Variant                = [string]$variantProperty.Name
                DisplayName            = [string]$sample.displayName
                Description            = [string]$sample.description
                Category               = [string]$sample.category
                License                = [string]$sample.license
                SourcePage             = [string]$sample.source
                Source                 = [string]$definition.url
                ArtifactType           = [string]$definition.artifactType
                Installation           = $definition.installation
                ExpectedDatabase       = [string]$outputs[0].name
                ExpectedDatabases      = @($outputs | ForEach-Object { [string]$_.name })
                DownloadSizeMB         = $definition.downloadSizeMB
                EstimatedInstallSizeMB = $definition.estimatedInstallSizeMB
                MinSqlVersion          = [string]$sample.minSqlVersion
                Compatibility          = $definition.compatibility
                ExpectedSha256         = if ($definition.sha256) { ([string]$definition.sha256).ToLowerInvariant() } else { $null }
                TrustPolicy            = [string]$definition.trustPolicy
            }
        }
    }

    return @($results)
}

function Get-LabSampleArtifactLocalStatus {
    <#
    .SYNOPSIS
        Ermittelt Trust- und Cache-Status einer Sample-Variante read-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$SampleId,
        [Parameter(Mandatory)][string]$SampleVariant,
        [string]$ExpectedSha256,
        [string]$StateRoot,
        [string]$TestDataRoot
    )

    $knownSha256 = if ($ExpectedSha256) { $ExpectedSha256.ToLowerInvariant() } else { $null }
    $trustStatus = 'TRUST_REQUIRED'

    if ($knownSha256) {
        $trustStatus = 'catalog-verified'
    }
    else {
        $trustRecord = Get-LabArtifactTrustRecord `
            -Source $Source `
            -SampleId $SampleId `
            -SampleVariant $SampleVariant `
            -StateRoot $StateRoot
        if ($trustRecord) {
            $trustStatus = [string]$trustRecord.integrityOrigin
            $knownSha256 = [string]$trustRecord.sha256
        }
    }

    $cacheStatus = 'MISS'
    if ($knownSha256 -and (Get-LabArtifactCacheEntry -Sha256 $knownSha256 -StateRoot $StateRoot -TestDataRoot $TestDataRoot)) {
        $cacheStatus = 'HIT'
    }

    return [PSCustomObject]@{
        TrustStatus = $trustStatus
        CacheStatus = $cacheStatus
        KnownSha256 = $knownSha256
    }
}

function Get-LabArchiveBackupPayload {
    <#
    .SYNOPSIS
        Extrahiert ein katalogisiertes .bak aus einem verifizierten ZIP- oder
        7z-Archiv temporär.
    .DESCRIPTION
        Es wird ausschliesslich der exakte, im Katalog vereinbarte Payload-Pfad
        extrahiert. Das verhindert Mehrdeutigkeit sowie Archivpfad-Traversal; das
        Arbeitsverzeichnis wird vom aufrufenden Handler immer wieder entfernt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$PayloadPath,
        [Parameter(Mandatory)][ValidateSet('zip', '7z')][string]$ArchiveFormat,
        [string]$RunDirectory
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "SAMPLE_ARCHIVE_NOT_FOUND: $ArchivePath"
    }

    $normalizedPayload = ($PayloadPath -replace '\\', '/').TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($normalizedPayload) -or
        $normalizedPayload -match '(^|/)\.\.(/|$)' -or
        [System.IO.Path]::IsPathRooted($normalizedPayload) -or
        $normalizedPayload -notmatch '(?i)\.bak$') {
        throw "SAMPLE_ARCHIVE_PAYLOAD_INVALID: '$PayloadPath' ist kein sicherer relativer .bak-Pfad."
    }

    $temporaryBase = if ($RunDirectory -and (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
        Join-Path $RunDirectory 'artifact-work'
    }
    else {
        Join-Path ([System.IO.Path]::GetTempPath()) 'sql-server-lab-artifacts'
    }
    $workingDirectory = Join-Path $temporaryBase ([guid]::NewGuid().ToString('N'))
    New-Item -Path $workingDirectory -ItemType Directory -Force | Out-Null

    try {
        if ($ArchiveFormat -eq 'zip') {
            Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
            $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
            try {
                $matches = @($archive.Entries | Where-Object {
                    $_.FullName.Replace('\\', '/') -ieq $normalizedPayload
                })
                if ($matches.Count -ne 1 -or $matches[0].Length -le 0) {
                    throw "SAMPLE_ARCHIVE_PAYLOAD_NOT_FOUND: ZIP muss genau die katalogisierte Backup-Payload '$normalizedPayload' enthalten."
                }

                $targetPath = Join-Path $workingDirectory ($normalizedPayload -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                $targetRoot = [System.IO.Path]::GetFullPath($workingDirectory + [System.IO.Path]::DirectorySeparatorChar)
                $fullTargetPath = [System.IO.Path]::GetFullPath($targetPath)
                if (-not $fullTargetPath.StartsWith($targetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "SAMPLE_ARCHIVE_PAYLOAD_INVALID: ZIP-Payload verlaesst das temporaere Arbeitsverzeichnis."
                }

                $targetDirectory = Split-Path -Parent $fullTargetPath
                New-Item -Path $targetDirectory -ItemType Directory -Force | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($matches[0], $fullTargetPath, $false)
                return [PSCustomObject]@{
                    Path             = $fullTargetPath
                    WorkingDirectory = $workingDirectory
                }
            }
            finally {
                $archive.Dispose()
            }
        }

        $sevenZip = Get-Lab7ZipExecutable
        if (-not $sevenZip) {
            throw 'SAMPLE_ARCHIVE_7ZIP_UNAVAILABLE: Für katalogisierte .7z-Backups wird 7-Zip benötigt. Optional installieren: Install-SqlServerLab7Zip.'
        }
        $sevenZipPath = [string]$sevenZip.Path

        $listing = @(& $sevenZipPath l -slt $ArchivePath $normalizedPayload 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "SAMPLE_ARCHIVE_INSPECTION_FAILED: 7-Zip konnte '$normalizedPayload' nicht prüfen (ExitCode $LASTEXITCODE): $($listing -join ' ')"
        }
        $payloadMatches = @($listing | Where-Object {
            $line = ([string]$_).Trim()
            if ($line -notmatch '^Path\s*=\s*(.+)$') { return $false }
            (($Matches[1] -replace '\\', '/') -ieq $normalizedPayload)
        })
        if ($payloadMatches.Count -ne 1) {
            throw "SAMPLE_ARCHIVE_PAYLOAD_NOT_FOUND: 7z muss genau die katalogisierte Backup-Payload '$normalizedPayload' enthalten."
        }

        # "e" entpackt ohne Archivpfade. Damit kann ein Archiveintrag nie aus
        # dem Arbeitsverzeichnis ausbrechen; der sichere Katalogpfad wählt die
        # einzige erlaubte Payload eindeutig aus.
        $targetFileName = [System.IO.Path]::GetFileName($normalizedPayload)
        $output = @(& $sevenZipPath e $ArchivePath ("-o{0}" -f $workingDirectory) '-y' $normalizedPayload 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "SAMPLE_ARCHIVE_EXTRACTION_FAILED: 7-Zip konnte '$normalizedPayload' nicht extrahieren (ExitCode $LASTEXITCODE): $($output -join ' ')"
        }
        $fullTargetPath = Join-Path $workingDirectory $targetFileName
        if (-not (Test-Path -LiteralPath $fullTargetPath -PathType Leaf) -or (Get-Item -LiteralPath $fullTargetPath).Length -le 0) {
            throw "SAMPLE_ARCHIVE_PAYLOAD_NOT_FOUND: 7z muss genau die katalogisierte Backup-Payload '$normalizedPayload' enthalten."
        }
        return [PSCustomObject]@{
            Path             = $fullTargetPath
            WorkingDirectory = $workingDirectory
        }
    }
    catch {
        if (Test-Path -LiteralPath $workingDirectory) {
            Remove-Item -LiteralPath $workingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Get-LabAttachPayloadLayout {
    <#
    .SYNOPSIS
        Validiert den katalogisierten Layout-Vertrag eines Attach-Artefakts.
    .DESCRIPTION
        Attach-Dateien werden nur über eine vollständige, eindeutige Liste
        relativer Archivpfade adressiert. Der Vertrag verlangt genau eine
        primaere MDF und mindestens eine LDF; weitere Daten-Dateien duerfen
        MDF oder NDF sein. Diese Funktion liest oder extrahiert keine Datei.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$PayloadLayout
    )

    $entries = @($PayloadLayout)
    if ($entries.Count -lt 2) {
        throw 'SAMPLE_ATTACH_PAYLOAD_LAYOUT_INVALID: Mindestens primaere MDF- und Log-LDF-Payload sind erforderlich.'
    }

    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $primaryCount = 0
    $logCount = 0
    $validated = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $entries) {
        $path = (([string]$entry.path -replace '\\', '/').Trim()).TrimStart('/')
        $role = [string]$entry.role
        if ([string]::IsNullOrWhiteSpace($path) -or
            $path -match '^(?:[A-Za-z]:|/)' -or
            @($path -split '/' | Where-Object { $_ -in @('.', '..') }).Count -gt 0 -or
            $path -notmatch '(?i)\.(mdf|ndf|ldf)$') {
            throw "SAMPLE_ATTACH_PAYLOAD_LAYOUT_INVALID: '$($entry.path)' ist kein sicherer relativer MDF/NDF/LDF-Pfad."
        }
        if (-not $paths.Add($path)) {
            throw "SAMPLE_ATTACH_PAYLOAD_LAYOUT_INVALID: '$path' ist mehrfach katalogisiert."
        }

        $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
        switch ($role) {
            'primary' {
                if ($extension -ne '.mdf') { throw "SAMPLE_ATTACH_PAYLOAD_LAYOUT_INVALID: Primaere Payload '$path' muss eine MDF-Datei sein." }
                $primaryCount++
            }
            'data' {
                if ($extension -notin @('.mdf', '.ndf')) { throw "SAMPLE_ATTACH_PAYLOAD_LAYOUT_INVALID: Daten-Payload '$path' muss MDF oder NDF sein." }
            }
            'log' {
                if ($extension -ne '.ldf') { throw "SAMPLE_ATTACH_PAYLOAD_LAYOUT_INVALID: Log-Payload '$path' muss eine LDF-Datei sein." }
                $logCount++
            }
            default { throw "SAMPLE_ATTACH_PAYLOAD_LAYOUT_INVALID: Rolle '$role' ist nicht unterstuetzt." }
        }

        $validated.Add([PSCustomObject]@{ Path = $path; Role = $role })
    }

    if ($primaryCount -ne 1 -or $logCount -lt 1) {
        throw 'SAMPLE_ATTACH_PAYLOAD_LAYOUT_INVALID: Der Attach-Vertrag verlangt genau eine primaere MDF und mindestens eine Log-LDF.'
    }

    return @($validated)
}

function Get-LabArchiveAttachPayloads {
    <#
    .SYNOPSIS
        Extrahiert ausschliesslich die katalogisierten Attach-Dateien eines ZIP-Archivs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][object[]]$PayloadLayout,
        [Parameter(Mandatory)][ValidateSet('zip')][string]$ArchiveFormat,
        [string]$RunDirectory
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "SAMPLE_ARCHIVE_NOT_FOUND: $ArchivePath"
    }
    $layout = @(Get-LabAttachPayloadLayout -PayloadLayout $PayloadLayout)
    $temporaryBase = if ($RunDirectory -and (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
        Join-Path $RunDirectory 'artifact-work'
    } else {
        Join-Path ([System.IO.Path]::GetTempPath()) 'sql-server-lab-artifacts'
    }
    $workingDirectory = Join-Path $temporaryBase ([guid]::NewGuid().ToString('N'))
    New-Item -Path $workingDirectory -ItemType Directory -Force | Out-Null

    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        try {
            $targetRoot = [System.IO.Path]::GetFullPath($workingDirectory + [System.IO.Path]::DirectorySeparatorChar)
            $payloads = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $layout) {
                $matches = @($archive.Entries | Where-Object { $_.FullName.Replace('\\', '/') -ieq $item.Path })
                if ($matches.Count -ne 1 -or $matches[0].Length -le 0) {
                    throw "SAMPLE_ATTACH_PAYLOAD_NOT_FOUND: ZIP muss genau die katalogisierte Payload '$($item.Path)' enthalten."
                }
                $targetPath = [System.IO.Path]::GetFullPath((Join-Path $workingDirectory ($item.Path -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
                if (-not $targetPath.StartsWith($targetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "SAMPLE_ATTACH_PAYLOAD_INVALID: '$($item.Path)' verlaesst das temporaere Arbeitsverzeichnis."
                }
                New-Item -Path (Split-Path -Parent $targetPath) -ItemType Directory -Force | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($matches[0], $targetPath, $false)
                $payloads.Add([PSCustomObject]@{ Path = $targetPath; Role = $item.Role; ArchivePath = $item.Path })
            }
            return [PSCustomObject]@{ Payloads = @($payloads); WorkingDirectory = $workingDirectory }
        }
        finally { $archive.Dispose() }
    }
    catch {
        if (Test-Path -LiteralPath $workingDirectory) { Remove-Item -LiteralPath $workingDirectory -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Expand-LabScriptBundlePayload {
    <#
    .SYNOPSIS
        Extrahiert katalogisierte SQL-Dateien eines ZIP-Script-Bundles sicher.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$Entrypoint,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$RunDirectory
    )

    if (-not (Test-Path -LiteralPath $BundlePath -PathType Leaf)) {
        throw "SAMPLE_BUNDLE_NOT_FOUND: $BundlePath"
    }

    $normalizeRelativePath = {
        param([string]$Value, [string]$Label, [switch]$AllowCurrentDirectory)

        $normalized = ([string]$Value -replace '\\', '/').Trim()
        if ($AllowCurrentDirectory -and $normalized -eq '.') {
            return ''
        }
        if ([string]::IsNullOrWhiteSpace($normalized) -or
            $normalized -match '^(?:[A-Za-z]:|/)' -or
            @($normalized -split '/' | Where-Object { $_ -in @('.', '..') }).Count -gt 0) {
            throw "SAMPLE_BUNDLE_PATH_INVALID: $Label '$Value' ist kein sicherer relativer Pfad."
        }
        return ($normalized.Trim('/'))
    }

    $bundleSubdirectory = & $normalizeRelativePath $WorkingDirectory 'workingDirectory' -AllowCurrentDirectory
    $entrypointRelative = & $normalizeRelativePath $Entrypoint 'entrypoint'
    if ($entrypointRelative -notmatch '(?i)\.sql$') {
        throw "SAMPLE_BUNDLE_ENTRYPOINT_INVALID: '$Entrypoint' ist kein SQL-Skript."
    }

    $entrypointArchivePath = if ($bundleSubdirectory) {
        "$bundleSubdirectory/$entrypointRelative"
    }
    else {
        $entrypointRelative
    }

    $temporaryBase = if ($RunDirectory -and (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
        Join-Path $RunDirectory 'artifact-work'
    }
    else {
        Join-Path ([System.IO.Path]::GetTempPath()) 'sql-server-lab-artifacts'
    }
    $extractionRoot = Join-Path $temporaryBase ([guid]::NewGuid().ToString('N'))
    New-Item -Path $extractionRoot -ItemType Directory -Force | Out-Null

    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        $archive = [System.IO.Compression.ZipFile]::OpenRead($BundlePath)
        try {
            $entrypointMatches = [System.Collections.Generic.List[string]]::new()
            $targetRoot = [System.IO.Path]::GetFullPath($extractionRoot + [System.IO.Path]::DirectorySeparatorChar)
            $workingPrefix = if ($bundleSubdirectory) { "$bundleSubdirectory/" } else { '' }

            foreach ($entry in $archive.Entries) {
                if ([string]::IsNullOrEmpty($entry.Name)) {
                    continue
                }

                $archivePath = & $normalizeRelativePath $entry.FullName 'archive entry'
                if ($workingPrefix -and -not $archivePath.StartsWith($workingPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                $relativePath = if ($workingPrefix) { $archivePath.Substring($workingPrefix.Length) } else { $archivePath }
                if ($relativePath -notmatch '(?i)\.sql$') {
                    continue
                }

                $targetPath = Join-Path $extractionRoot ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                $fullTargetPath = [System.IO.Path]::GetFullPath($targetPath)
                if (-not $fullTargetPath.StartsWith($targetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw "SAMPLE_BUNDLE_PATH_INVALID: Archiveintrag '$archivePath' verlaesst den Bundle-Scope."
                }

                $targetDirectory = Split-Path -Parent $fullTargetPath
                New-Item -Path $targetDirectory -ItemType Directory -Force | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $fullTargetPath, $false)

                if ($archivePath -ieq $entrypointArchivePath) {
                    $entrypointMatches.Add($fullTargetPath)
                }
            }

            if ($entrypointMatches.Count -ne 1) {
                throw "SAMPLE_BUNDLE_ENTRYPOINT_NOT_FOUND: ZIP muss genau den katalogisierten Entrypoint '$entrypointArchivePath' enthalten."
            }

            return [PSCustomObject]@{
                Path             = $entrypointMatches[0]
                BundleRoot       = $extractionRoot
                WorkingDirectory = $extractionRoot
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    catch {
        if (Test-Path -LiteralPath $extractionRoot) {
            Remove-Item -LiteralPath $extractionRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Convert-LabScriptBundleToSql {
    <#
    .SYNOPSIS
        Loest erlaubte sqlcmd-Direktiven innerhalb eines Bundle-Roots auf.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EntrypointPath,
        [Parameter(Mandatory)][string]$BundleRoot,
        [string[]]$AllowedSqlcmdFeatures = @()
    )

    $rootPath = [System.IO.Path]::GetFullPath($BundleRoot)
    $rootPrefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
    $allowedFeatures = @($AllowedSqlcmdFeatures | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $variables = @{}
    $activePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $substituteVariables = {
        param([string]$Text)

        return [regex]::Replace($Text, '\$\(([A-Za-z_][A-Za-z0-9_]*)\)', {
            param($match)
            $variableName = $match.Groups[1].Value
            if (-not $variables.ContainsKey($variableName)) {
                throw "SAMPLE_BUNDLE_VARIABLE_UNDEFINED: '$variableName'"
            }
            return [string]$variables[$variableName]
        })
    }

    $expandScript = $null
    $expandScript = {
        param([string]$ScriptPath)

        $fullScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
        if (-not $fullScriptPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            $fullScriptPath -notmatch '(?i)\.sql$' -or
            -not (Test-Path -LiteralPath $fullScriptPath -PathType Leaf)) {
            throw "SAMPLE_BUNDLE_INCLUDE_INVALID: '$ScriptPath' liegt nicht als SQL-Datei im Bundle-Scope."
        }
        if (-not $activePaths.Add($fullScriptPath)) {
            throw "SAMPLE_BUNDLE_INCLUDE_CYCLE: '$fullScriptPath' wurde rekursiv eingebunden."
        }

        try {
            foreach ($line in Get-Content -LiteralPath $fullScriptPath -Encoding utf8) {
                if ($line -match '^\s*(?::connect\b|:!!\b|!!\b)') {
                    throw "SAMPLE_BUNDLE_SQLCMD_UNSAFE: Unsichere Direktive in '$fullScriptPath'."
                }
                if ($line -match '^\s*:setvar\s+([A-Za-z_][A-Za-z0-9_]*)\s+(.+?)\s*$') {
                    if ($allowedFeatures -notcontains 'setvar') {
                        throw "SAMPLE_BUNDLE_SQLCMD_FEATURE_NOT_ALLOWED: setvar"
                    }
                    $value = $Matches[2].Trim()
                    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                        ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                        $value = $value.Substring(1, $value.Length - 2)
                    }
                    $variables[$Matches[1]] = $value
                    continue
                }
                if ($line -match '^\s*:r\s+(.+?)\s*$') {
                    if ($allowedFeatures -notcontains 'include') {
                        throw "SAMPLE_BUNDLE_SQLCMD_FEATURE_NOT_ALLOWED: include"
                    }
                    $includeValue = & $substituteVariables $Matches[1].Trim()
                    if (($includeValue.StartsWith('"') -and $includeValue.EndsWith('"')) -or
                        ($includeValue.StartsWith("'") -and $includeValue.EndsWith("'"))) {
                        $includeValue = $includeValue.Substring(1, $includeValue.Length - 2)
                    }
                    $includeValue = $includeValue -replace '/', [System.IO.Path]::DirectorySeparatorChar
                    if ([System.IO.Path]::IsPathRooted($includeValue) -or
                        @($includeValue -split '[\\/]' | Where-Object { $_ -eq '..' }).Count -gt 0) {
                        throw "SAMPLE_BUNDLE_INCLUDE_INVALID: '$includeValue' verlaesst den Bundle-Scope."
                    }
                    $includePath = Join-Path (Split-Path -Parent $fullScriptPath) $includeValue
                    & $expandScript $includePath
                    continue
                }
                if ($line -match '^\s*:' ) {
                    throw "SAMPLE_BUNDLE_SQLCMD_DIRECTIVE_UNSUPPORTED: '$($line.Trim())'"
                }
                if ($line -match '(?i)^\s*GO\s*(?:--.*)?$' -and $allowedFeatures -notcontains 'go') {
                    throw "SAMPLE_BUNDLE_SQLCMD_FEATURE_NOT_ALLOWED: go"
                }

                & $substituteVariables $line
            }
        }
        finally {
            $null = $activePaths.Remove($fullScriptPath)
        }
    }

    $flattenedLines = @(& $expandScript $EntrypointPath)
    $flattenedPath = Join-Path $rootPath "bundle-$([guid]::NewGuid().ToString('N')).sql"
    [System.IO.File]::WriteAllLines($flattenedPath, $flattenedLines, [System.Text.UTF8Encoding]::new($false))
    return $flattenedPath
}

function Invoke-LabContainerBacpacImport {
    <#
    .SYNOPSIS
        Importiert ein verifiziertes BACPAC in einen scopegebundenen Container.
    .DESCRIPTION
        Der Handler akzeptiert ausschließlich einen bereits vom Lab erstellten
        Docker- oder Podman-Container mit dem katalogisierten SqlPackage-Tool.
        Vor der Mutation wird dessen Version read-only geprüft. Das BACPAC wird
        unter einem zufälligen, ausschließlich vom Handler erzeugten /tmp-Pfad
        übertragen und unabhängig vom Importergebnis wieder entfernt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [string]$ExpectedRuntimeVersion,
        [string]$StateRoot,
        [ValidateRange(30, 3600)][int]$TimeoutSeconds = 900
    )

    if ($DatabaseName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$') {
        throw "BACPAC_DATABASE_NAME_INVALID: '$DatabaseName'"
    }
    $resolvedArtifactPath = (Resolve-Path -LiteralPath $ArtifactPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedArtifactPath -PathType Leaf) -or
        [IO.Path]::GetExtension($resolvedArtifactPath) -notmatch '(?i)^\.bacpac$') {
        throw 'BACPAC_ARTIFACT_INVALID: Erwartet wird eine vorhandene .bacpac-Datei.'
    }

    $run = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $runtime = Get-LabHostToolInvocation -Name $Provider
    $inspect = @((& $runtime inspect $ContainerName 2>$null | ConvertFrom-Json -Depth 30))[0]
    if (-not $inspect -or [string]$inspect.Config.Labels.'sql-server-lab.run-id' -ne $RunId -or
        [string]$inspect.Config.Labels.'sql-server-lab.scope-id' -ne [string]$run.scopeId -or
        [string]$inspect.Config.Labels.'sql-server-lab.instance-id' -ne $InstanceId) {
        throw 'BACPAC_CONTAINER_OWNERSHIP_MISMATCH'
    }
    if ([string]$inspect.State.Status -ne 'running' -or
        [string]$inspect.Config.Labels.'sql-server-lab.container-tool.ids' -ne 'sqlpackage') {
        throw 'BACPAC_SQLPACKAGE_TOOL_NOT_READY'
    }

    $probeOutput = @(& $runtime exec --user mssql $ContainerName /opt/sql-server-lab/tools/sqlpackage/sqlpackage /Version 2>&1)
    if ($LASTEXITCODE -ne 0 -or (@($probeOutput) -join "`n") -notmatch '(?<version>[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)') {
        throw 'BACPAC_SQLPACKAGE_VERSION_PROBE_FAILED'
    }
    $runtimeVersion = [string]$Matches.version
    if ($ExpectedRuntimeVersion -and $runtimeVersion -ne $ExpectedRuntimeVersion) {
        throw "BACPAC_SQLPACKAGE_VERSION_MISMATCH: erwartete $ExpectedRuntimeVersion, erhielt $runtimeVersion"
    }

    $containerArtifactPath = "/tmp/sql-server-lab-bacpac-$([guid]::NewGuid().ToString('N')).bacpac"
    $copied = $false
    $importSucceeded = $false
    $importFailure = $null
    try {
        $copyOutput = @(& $runtime cp $resolvedArtifactPath "${ContainerName}:$containerArtifactPath" 2>&1)
        if ($LASTEXITCODE -ne 0) { throw 'BACPAC_CONTAINER_COPY_FAILED' }
        $copied = $true

        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
        try {
            $saPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            $command = 'exec /opt/sql-server-lab/tools/sqlpackage/sqlpackage /Action:Import "/SourceFile:$1" /TargetServerName:localhost "/TargetDatabaseName:$2" /TargetUser:sa /TargetTrustServerCertificate:True "/TargetPassword:$SQLSERVERLAB_SA_PASSWORD" /p:CommandTimeout=' + $TimeoutSeconds
            $importOutput = @(& $runtime exec --env "SQLSERVERLAB_SA_PASSWORD=$saPlain" --user mssql $ContainerName sh -ceu $command -- $containerArtifactPath $DatabaseName 2>&1)
            if ($LASTEXITCODE -ne 0) {
                $safeOutput = (($importOutput -join ' ') -replace [regex]::Escape($saPlain), '***') -replace '(?i)(password\s*[=:]\s*)[^;\s]+', '$1***'
                throw "BACPAC_IMPORT_FAILED: $safeOutput"
            }
            $importSucceeded = $true
        }
        finally {
            $saPlain = $null
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
    catch {
        $importFailure = $_.Exception.Message
    }
    finally {
        if ($copied) {
            $cleanupOutput = @(& $runtime exec --user root $ContainerName rm -f -- $containerArtifactPath 2>&1)
            if ($LASTEXITCODE -ne 0) {
                if ($importFailure) { throw "BACPAC_IMPORT_AND_CLEANUP_FAILED: $importFailure" }
                throw 'BACPAC_IMPORT_CLEANUP_FAILED'
            }
        }
    }
    if ($importFailure) { throw $importFailure }

    return [PSCustomObject]@{
        Status = 'BACPAC_IMPORTED'; Provider = $Provider; RunId = $RunId; InstanceId = $InstanceId
        DatabaseName = $DatabaseName; RuntimeVersion = $runtimeVersion; TimeoutSeconds = $TimeoutSeconds
    }
}

function Install-LabSampleDatabase {
    <#
    .SYNOPSIS
        Installiert ein katalogisiertes Sample ueber den gemeinsamen Handler-Lifecycle.
    .DESCRIPTION
        Acquire und VerifyIntegrity laufen ueber Resolve-LabArtifact mit der
        vollstaendigen Sample-Identitaet, damit Trust Store und Run Lock den
        Katalogbezug enthalten. Danach prueft der Handler die Idempotenzregel
        (fail-if-exists), fuehrt den typisierten Handler aus und verifiziert
        die erwartete Datenbank als ONLINE.
    #>
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [ValidateSet('docker','podman','hyperv')][string]$Provider,
        [string]$ContainerName,
        [string]$RunId,
        [string]$InstanceId = 'primary',
        $ContainerTools,
        [PSCredential]$GuestCredential,
        [Parameter(Mandatory)]$RestoreDefinition,
        [switch]$NonInteractive,
        [switch]$TrustUnknownArtifact,
        [string]$SqlVersion,
        [string]$RunDirectory,
        [string]$StateRoot,
        [string]$TestDataRoot
    )

    if ($RunId) {
        $runTarget = Resolve-LabRunInstance -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        if ($Provider -and [string]$runTarget.Provider -ne $Provider) {
            throw 'SAMPLE_HANDLER_RUN_PROVIDER_MISMATCH'
        }
        $Provider = [string]$runTarget.Provider
        $HostName = [string]$runTarget.HostName
        $Port = [int]$runTarget.Port
        $ContainerName = [string]$runTarget.ContainerName
        if (-not $RunDirectory) {
            $effectiveStateRoot = if ($StateRoot) { $StateRoot } else { Get-LabStateRoot }
            $RunDirectory = Join-Path (Join-Path $effectiveStateRoot 'runs') $RunId
        }
    }
    if ($Provider -eq 'hyperv' -and (-not $RunId -or -not $GuestCredential)) {
        throw 'SAMPLE_HANDLER_HYPERV_RUN_AND_GUEST_CREDENTIAL_REQUIRED'
    }
    if ($Provider -ne 'hyperv' -and [string]::IsNullOrWhiteSpace($ContainerName)) {
        throw 'SAMPLE_HANDLER_CONTAINER_NAME_REQUIRED'
    }

    $databaseNames = @(
        $RestoreDefinition.expectedOutputs |
            Where-Object { $_.kind -eq 'database' } |
            ForEach-Object { [string]$_.name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    if ($databaseNames.Count -eq 0 -or $databaseNames.Count -ne @($RestoreDefinition.expectedOutputs).Count) {
        throw 'SAMPLE_OUTPUTS_INVALID: Der Handler benoetigt eine eindeutige Liste erwarteter Datenbanken.'
    }

    $databaseName = $databaseNames[0]
    $result = [ordered]@{
        Status        = $null
        Message       = $null
        SampleId      = [string]$RestoreDefinition.sampleId
        SampleVariant = [string]$RestoreDefinition.sampleVariant
        DatabaseName  = $databaseName
        DatabaseNames = $databaseNames
        Artifact      = $null
        Baseline      = $null
        Success       = $false
    }

    $baselineRequest = if ($SqlVersion) {
        Get-LabSampleBaselineRequest `
            -RestoreDefinition $RestoreDefinition `
            -SqlVersion $SqlVersion `
            -StateRoot $StateRoot `
            -TestDataRoot $TestDataRoot
    }
    else {
        $null
    }

    $resolverArguments = @{
        Source                 = [string]$RestoreDefinition.source
        ArtifactType           = [string]$RestoreDefinition.artifactType
        TrustPolicy            = if ($RestoreDefinition.trustPolicy) { [string]$RestoreDefinition.trustPolicy } else { 'interactive-once' }
        SampleId               = [string]$RestoreDefinition.sampleId
        SampleVariant          = [string]$RestoreDefinition.sampleVariant
        Category               = [string]$RestoreDefinition.category
        HandlerContractVersion = [string]$RestoreDefinition.handlerContractVersion
        ExpectedOutputs        = @($RestoreDefinition.expectedOutputs)
        NonInteractive         = $NonInteractive
        TrustUnknownArtifact   = $TrustUnknownArtifact
        RunDirectory           = $RunDirectory
        StateRoot              = $StateRoot
        TestDataRoot           = $TestDataRoot
    }
    if ($RestoreDefinition.expectedSha256) {
        $resolverArguments.ExpectedSha256 = [string]$RestoreDefinition.expectedSha256
    }
    if ($RestoreDefinition.compatibility) {
        $resolverArguments.Compatibility = [int]$RestoreDefinition.compatibility
    }

    $artifactResolution = if ($baselineRequest) {
        Write-LabInfo "LAB_GENERATED-Baseline verwenden ($($baselineRequest.Selection.MatchType)): $($baselineRequest.Selection.KeyId)"
        [PSCustomObject]@{
            Status          = 'ARTIFACT_READY'
            Path            = [string]$baselineRequest.Selection.Path
            Sha256          = [string]$baselineRequest.Selection.Sha256
            IntegrityOrigin = 'LAB_GENERATED'
            ArtifactFormat  = [string]$baselineRequest.Selection.ArtifactFormat
            Message         = 'Verifizierte LAB_GENERATED-Baseline ausgewaehlt.'
        }
    }
    else {
        Resolve-LabArtifact @resolverArguments
    }
    $result.Artifact = $artifactResolution
    if ($artifactResolution.Status -ne 'ARTIFACT_READY') {
        $result.Status = $artifactResolution.Status
        $result.Message = $artifactResolution.Message
        return [PSCustomObject]$result
    }
    if ($baselineRequest -and $RunDirectory) {
        $baselineLockArtifact = [PSCustomObject]@{
            Source                 = [string]$RestoreDefinition.source
            Sha256                 = [string]$baselineRequest.SourceSha256
            IntegrityOrigin        = [string]$baselineRequest.SourceIntegrityOrigin
            ArtifactType           = [string]$RestoreDefinition.artifactType
            SampleId               = [string]$RestoreDefinition.sampleId
            SampleVariant          = [string]$RestoreDefinition.sampleVariant
            HandlerContractVersion = [string]$RestoreDefinition.handlerContractVersion
            Compatibility          = $RestoreDefinition.compatibility
            ExpectedOutputs        = @($RestoreDefinition.expectedOutputs)
            ResolvedArtifact       = [PSCustomObject]@{
                Origin         = 'LAB_GENERATED'
                KeyId          = [string]$baselineRequest.Selection.KeyId
                MatchType      = [string]$baselineRequest.Selection.MatchType
                Sha256         = [string]$baselineRequest.Selection.Sha256
                ArtifactFormat = [string]$baselineRequest.Selection.ArtifactFormat
            }
        }
        Add-LabArtifactManifestLockEntry -RunDirectory $RunDirectory -Artifact $baselineLockArtifact | Out-Null
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    $temporaryArchivePayload = $null
    $temporaryBundlePayload = $null
    $temporaryBaselineBundle = $null
    try {
        $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    try {
        $invokeRestore = {
            param([string]$BackupSource, [string]$ExpectedSha256, [string]$TargetDatabaseName)
            $restoreArguments = @{
                SaPassword=$SaPassword; BackupSource=$BackupSource
                DatabaseName=$TargetDatabaseName; StateRoot=$StateRoot
            }
            if ($ExpectedSha256) { $restoreArguments.ExpectedSha256 = $ExpectedSha256 }
            if ($Provider -eq 'hyperv') {
                $restoreArguments.RunId = $RunId
                $restoreArguments.InstanceId = $InstanceId
                $restoreArguments.GuestCredential = $GuestCredential
                $restoreArguments.RunDirectory = $RunDirectory
            }
            else {
                $restoreArguments.HostName = $HostName
                $restoreArguments.Port = $Port
                $restoreArguments.ContainerName = $ContainerName
                if ($Provider) { $restoreArguments.Provider = $Provider }
            }
            return Restore-SqlServerLabDatabase @restoreArguments
        }
        $idempotencyMode = if ($RestoreDefinition.idempotencyMode) { [string]$RestoreDefinition.idempotencyMode } else { 'fail-if-exists' }
        foreach ($expectedDatabaseName in $databaseNames) {
            $escapedExpectedName = $expectedDatabaseName.Replace("'", "''")
            $existsOutput = Invoke-SqlQuery `
                -HostName $HostName `
                -Port $Port `
                -SaPlain $saPlain `
                -Query "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name = N'$escapedExpectedName';"
            $existsText = (@($existsOutput) | ForEach-Object { ([string]$_).Trim() })

            if ($existsText -contains $expectedDatabaseName -and $idempotencyMode -eq 'fail-if-exists') {
                $result.Status = 'SAMPLE_OUTPUT_CONFLICT'
                $result.Message = "Datenbank '$expectedDatabaseName' existiert bereits; Idempotenzregel fail-if-exists blockiert die Installation."
                return [PSCustomObject]$result
            }
        }

        $effectiveArtifactType = if ($baselineRequest -and $databaseNames.Count -gt 1) { 'baseline-bundle' } elseif ($baselineRequest) { 'backup' } else { [string]$RestoreDefinition.artifactType }
        switch ($effectiveArtifactType) {
            'backup' {
                $restoreResult = & $invokeRestore `
                    ([string]$artifactResolution.Path) `
                    ([string]$artifactResolution.Sha256) `
                    $databaseName
                if (-not $restoreResult.Success) {
                    $result.Status = 'SAMPLE_INSTALLATION_FAILED'
                    $result.Message = $restoreResult.Message
                    return [PSCustomObject]$result
                }
            }
            'archive-backup' {
                $archiveFormat = [string]$RestoreDefinition.installation.archiveFormat
                if ($archiveFormat -notin @('zip', '7z')) {
                    throw "SAMPLE_ARCHIVE_FORMAT_UNSUPPORTED: '$($RestoreDefinition.installation.archiveFormat)'"
                }
                $temporaryArchivePayload = Get-LabArchiveBackupPayload `
                    -ArchivePath $artifactResolution.Path `
                    -PayloadPath ([string]$RestoreDefinition.installation.payloadPath) `
                    -ArchiveFormat $archiveFormat `
                    -RunDirectory $RunDirectory
                $restoreResult = & $invokeRestore `
                    ([string]$temporaryArchivePayload.Path) `
                    $null `
                    $databaseName
                if (-not $restoreResult.Success) {
                    $result.Status = 'SAMPLE_INSTALLATION_FAILED'
                    $result.Message = $restoreResult.Message
                    return [PSCustomObject]$result
                }
            }
            'sql-script' {
                $executionMode = [string]$RestoreDefinition.installation.executionMode
                if ($executionMode -eq 'existing-database') {
                    $createArguments = @{
                        HostName=$HostName; Port=$Port; SaPassword=$SaPassword
                        DatabaseName=$databaseName; StateRoot=$StateRoot
                    }
                    if ($Provider -eq 'hyperv') {
                        $createArguments.RunId=$RunId; $createArguments.InstanceId=$InstanceId
                    }
                    $createResult = New-SqlServerLabDatabase @createArguments
                    if (-not $createResult.Success) {
                        $result.Status = 'SAMPLE_INSTALLATION_FAILED'
                        $result.Message = "Zieldatenbank '$databaseName' konnte nicht erstellt werden."
                        return [PSCustomObject]$result
                    }
                }
                elseif ($executionMode -ne 'self-creates-databases') {
                    throw "SAMPLE_SCRIPT_EXECUTION_MODE_UNSUPPORTED: '$executionMode'"
                }

                $scriptDatabase = if ($executionMode -eq 'existing-database') { $databaseName } else { 'master' }
                $scriptResult = Invoke-LabSqlScript `
                    -ScriptPath $artifactResolution.Path `
                    -HostName $HostName `
                    -Port $Port `
                    -SaPassword $SaPassword `
                    -Database $scriptDatabase `
                    -KeepConnection `
                    -TimeoutSeconds ([int]$RestoreDefinition.installation.timeoutSeconds)
                if (-not $scriptResult.Success) {
                    $result.Status = 'SAMPLE_INSTALLATION_FAILED'
                    $result.Message = $scriptResult.Message
                    return [PSCustomObject]$result
                }
            }
            'script-bundle' {
                if ([string]$RestoreDefinition.installation.partialFailurePolicy -ne 'recovery-required') {
                    throw "SAMPLE_BUNDLE_PARTIAL_FAILURE_POLICY_UNSUPPORTED: '$($RestoreDefinition.installation.partialFailurePolicy)'"
                }

                $temporaryBundlePayload = Expand-LabScriptBundlePayload `
                    -BundlePath $artifactResolution.Path `
                    -Entrypoint ([string]$RestoreDefinition.installation.entrypoint) `
                    -WorkingDirectory ([string]$RestoreDefinition.installation.workingDirectory) `
                    -RunDirectory $RunDirectory
                $flattenedScriptPath = Convert-LabScriptBundleToSql `
                    -EntrypointPath $temporaryBundlePayload.Path `
                    -BundleRoot $temporaryBundlePayload.BundleRoot `
                    -AllowedSqlcmdFeatures @($RestoreDefinition.installation.allowedSqlcmdFeatures)

                $executionMode = [string]$RestoreDefinition.installation.executionMode
                if ($executionMode -eq 'existing-database') {
                    if ($databaseNames.Count -ne 1) {
                        throw 'SAMPLE_BUNDLE_EXISTING_DATABASE_AMBIGUOUS: existing-database erlaubt genau einen erwarteten Output.'
                    }
                    $createArguments = @{
                        HostName=$HostName; Port=$Port; SaPassword=$SaPassword
                        DatabaseName=$databaseName; StateRoot=$StateRoot
                    }
                    if ($Provider -eq 'hyperv') {
                        $createArguments.RunId=$RunId; $createArguments.InstanceId=$InstanceId
                    }
                    $createResult = New-SqlServerLabDatabase @createArguments
                    if (-not $createResult.Success) {
                        $result.Status = 'SAMPLE_INSTALLATION_FAILED'
                        $result.Message = "Zieldatenbank '$databaseName' konnte nicht erstellt werden."
                        return [PSCustomObject]$result
                    }
                    $scriptDatabase = $databaseName
                }
                elseif ($executionMode -in @('master', 'self-creates-databases')) {
                    $scriptDatabase = 'master'
                }
                else {
                    throw "SAMPLE_SCRIPT_EXECUTION_MODE_UNSUPPORTED: '$executionMode'"
                }

                $scriptResult = Invoke-LabSqlScript `
                    -ScriptPath $flattenedScriptPath `
                    -HostName $HostName `
                    -Port $Port `
                    -SaPassword $SaPassword `
                    -Database $scriptDatabase `
                    -KeepConnection `
                    -TimeoutSeconds ([int]$RestoreDefinition.installation.timeoutSeconds)
                if (-not $scriptResult.Success) {
                    $result.Status = 'RECOVERY_REQUIRED'
                    $result.Message = "Script Bundle wurde nicht vollstaendig ausgefuehrt: $($scriptResult.Message)"
                    return [PSCustomObject]$result
                }
            }
            'bacpac' {
                if ($Provider -notin @('docker', 'podman') -or -not $RunId) {
                    throw 'BACPAC_CONTAINER_RUN_REQUIRED'
                }
                $bacpacResult = Invoke-LabContainerBacpacImport `
                    -Provider $Provider `
                    -ContainerName $ContainerName `
                    -RunId $RunId `
                    -InstanceId $InstanceId `
                    -ArtifactPath ([string]$artifactResolution.Path) `
                    -DatabaseName $databaseName `
                    -SaPassword $SaPassword `
                    -ExpectedRuntimeVersion ([string]$ContainerTools.RuntimeVersion) `
                    -StateRoot $StateRoot
                if ([string]$bacpacResult.Status -ne 'BACPAC_IMPORTED') {
                    throw 'BACPAC_IMPORT_RESULT_INVALID'
                }
            }
            'baseline-bundle' {
                $temporaryBaselineBundle = Expand-LabSampleBaselineBundle `
                    -BundlePath $artifactResolution.Path `
                    -DatabaseNames $databaseNames `
                    -RunDirectory $RunDirectory
                foreach ($payload in $temporaryBaselineBundle.Payloads) {
                    $restoreResult = & $invokeRestore `
                        ([string]$payload.Path) `
                        ([string]$payload.Sha256) `
                        ([string]$payload.DatabaseName)
                    if (-not $restoreResult.Success) {
                        $result.Status = 'RECOVERY_REQUIRED'
                        $result.Message = "Multi-Output-Baseline wurde nicht vollstaendig wiederhergestellt: $($restoreResult.Message)"
                        return [PSCustomObject]$result
                    }
                }
            }
            default {
                throw "SAMPLE_HANDLER_UNSUPPORTED: '$($RestoreDefinition.artifactType)'"
            }
        }

        foreach ($expectedDatabaseName in $databaseNames) {
            $escapedExpectedName = $expectedDatabaseName.Replace("'", "''")
            $stateOutput = Invoke-SqlQuery `
                -HostName $HostName `
                -Port $Port `
                -SaPlain $saPlain `
                -Query "SET NOCOUNT ON; SELECT state_desc FROM sys.databases WHERE name = N'$escapedExpectedName';"
            $stateText = (@($stateOutput) | ForEach-Object { ([string]$_).Trim() })

            if ($stateText -notcontains 'ONLINE') {
                $result.Status = if ($RestoreDefinition.artifactType -eq 'script-bundle') { 'RECOVERY_REQUIRED' } else { 'SAMPLE_VERIFICATION_FAILED' }
                $result.Message = "Erwartete Datenbank '$expectedDatabaseName' ist nach der Installation nicht ONLINE."
                return [PSCustomObject]$result
            }
        }

        if (-not $baselineRequest -and
            $SqlVersion -and
            [string]$RestoreDefinition.installation.baselinePolicy -eq 'eligible-after-verification' -and
            $databaseNames.Count -ge 1) {
            try {
                $baselineKey = New-LabSampleBaselineRequestKey `
                    -RestoreDefinition $RestoreDefinition `
                    -SourceSha256 ([string]$artifactResolution.Sha256) `
                    -SqlVersion $SqlVersion
                $baselineArguments = @{
                    HostName = $HostName
                    Port = $Port
                    SaPassword = $SaPassword
                    ContainerName = $ContainerName
                    RunId = $RunId
                    InstanceId = $InstanceId
                    GuestCredential = $GuestCredential
                    Key = $baselineKey
                    RunDirectory = $RunDirectory
                    StateRoot = $StateRoot
                    TestDataRoot = $TestDataRoot
                }
                if ($Provider) { $baselineArguments.Provider = $Provider }
                $result.Baseline = if ($databaseNames.Count -eq 1) {
                    New-LabSampleBaselineBackup -DatabaseName $databaseName @baselineArguments
                }
                else {
                    New-LabSampleBaselineBundle -DatabaseNames $databaseNames @baselineArguments
                }
            }
            catch {
                $result.Baseline = [PSCustomObject]@{
                    Status  = 'BASELINE_GENERATION_FAILED'
                    Message = $_.Exception.Message
                }
                Write-LabWarning "Sample ist verifiziert, LAB_GENERATED-Backup konnte jedoch nicht erzeugt werden: $($_.Exception.Message)"
            }
        }

        $result.Status = 'DATASET_READY'
        $result.Message = "Sample '$($result.SampleId)' Variante '$($result.SampleVariant)' installiert und verifiziert: $($databaseNames -join ', ')."
        $result.Success = $true
        return [PSCustomObject]$result
    }
    finally {
        $saPlain = $null
        if ($temporaryArchivePayload -and (Test-Path -LiteralPath $temporaryArchivePayload.WorkingDirectory)) {
            Remove-Item -LiteralPath $temporaryArchivePayload.WorkingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($temporaryBundlePayload -and (Test-Path -LiteralPath $temporaryBundlePayload.WorkingDirectory)) {
            Remove-Item -LiteralPath $temporaryBundlePayload.WorkingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($temporaryBaselineBundle -and (Test-Path -LiteralPath $temporaryBaselineBundle.WorkingDirectory)) {
            Remove-Item -LiteralPath $temporaryBaselineBundle.WorkingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

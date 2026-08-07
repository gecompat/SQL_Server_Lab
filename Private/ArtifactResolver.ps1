<#
.SYNOPSIS
    Lokale Acquisition-, Integrity- und Lock-Verwaltung fuer Sample-Artifacts.
.DESCRIPTION
    Verwaltet ausschliesslich lokale Runtime-Dateien unter StateRoot. Der
    Resolver laedt HTTP(S)-Artifacts zuerst in einen Staging-Bereich, prueft
    deren SHA-256 und uebernimmt sie danach in einen inhaltsadressierten Cache.
    Fehlende Katalogpruefsummen duerfen nur im interaktiven, explizit
    bestaetigten Trust-Pfad erzeugt werden.
#>

function Get-LabArtifactStorePaths {
    [CmdletBinding()]
    param(
        [string]$StateRoot
    )

    if (-not $StateRoot) {
        $StateRoot = Get-LabStateRoot
    }

    return [PSCustomObject]@{
        StateRoot       = $StateRoot
        TrustDirectory  = Join-Path $StateRoot 'trust'
        TrustStorePath  = Join-Path $StateRoot 'trust/sample-artifacts.json'
        CacheRoot       = Join-Path $StateRoot 'cache/artifacts/sha256'
        StagingRoot     = Join-Path $StateRoot 'cache/staging'
        QuarantineRoot  = Join-Path $StateRoot 'cache/quarantine'
    }
}

function Initialize-LabArtifactStore {
    [CmdletBinding()]
    param(
        [string]$StateRoot
    )

    $null = Initialize-LabStateRoot -StateRoot $StateRoot
    $paths = Get-LabArtifactStorePaths -StateRoot $StateRoot
    foreach ($directory in @($paths.TrustDirectory, $paths.CacheRoot, $paths.StagingRoot, $paths.QuarantineRoot)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
    }

    if (-not (Test-Path -LiteralPath $paths.TrustStorePath -PathType Leaf)) {
        Write-LabArtifactJsonAtomic -Path $paths.TrustStorePath -InputObject ([PSCustomObject]@{
            formatVersion = '1'
            records       = @()
        })
    }

    return $paths
}

function Write-LabArtifactJsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$InputObject
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $InputObject | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
        [System.IO.File]::Move($temporaryPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Invoke-LabArtifactStoreLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$StateRoot
    )

    if (-not $StateRoot) {
        $StateRoot = Get-LabStateRoot
    }

    $rootHash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($StateRoot))
    $mutexName = "SQL_Server_Lab_Artifact_Store_$(([Convert]::ToHexString($rootHash)).Substring(0, 16))"
    $mutex = [System.Threading.Mutex]::new($false, $mutexName)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
        if (-not $acquired) {
            throw 'ARTIFACT_STORE_LOCK_TIMEOUT: Der lokale Artifact Store wird bereits bearbeitet.'
        }
        return & $ScriptBlock
    }
    finally {
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Get-LabCanonicalArtifactSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source
    )

    try {
        $uri = [System.Uri]::new($Source)
    }
    catch {
        throw "ARTIFACT_SOURCE_INVALID: Ungueltige Artifact-URL: $Source"
    }

    if ($uri.Scheme -notin @('http', 'https') -or -not $uri.IsAbsoluteUri) {
        throw "ARTIFACT_SOURCE_INVALID: Nur absolute HTTP(S)-URLs sind fuer Acquisition erlaubt: $Source"
    }
    if ($uri.UserInfo) {
        throw 'ARTIFACT_SOURCE_INVALID: URLs mit Benutzerinformationen duerfen nicht im Trust Store gespeichert werden.'
    }
    if ($uri.Query) {
        throw 'ARTIFACT_SOURCE_INVALID: URLs mit Query-Parametern duerfen nicht im Trust Store gespeichert werden.'
    }

    return $uri.GetComponents([System.UriComponents]::HttpRequestUrl, [System.UriFormat]::UriEscaped)
}

function Get-LabArtifactTrustStore {
    [CmdletBinding()]
    param(
        [string]$StateRoot
    )

    $paths = Initialize-LabArtifactStore -StateRoot $StateRoot
    $store = Get-Content -LiteralPath $paths.TrustStorePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    if (-not $store.records) {
        $store | Add-Member -NotePropertyName records -NotePropertyValue @() -Force
    }
    return $store
}

function Get-LabArtifactTrustRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [string]$SampleId,
        [string]$SampleVariant,
        [string]$StateRoot
    )

    $canonicalSource = Get-LabCanonicalArtifactSource -Source $Source
    $store = Get-LabArtifactTrustStore -StateRoot $StateRoot
    return @($store.records |
        Where-Object {
            $_.source -eq $canonicalSource -and
            ([string]$_.sampleId -eq [string]$SampleId) -and
            ([string]$_.sampleVariant -eq [string]$SampleVariant)
        } |
        Sort-Object trustedAt -Descending |
        Select-Object -First 1)[0]
}

function Register-LabArtifactTrustRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$Sha256,
        [string]$SampleId,
        [string]$SampleVariant,
        [string]$ArtifactType = 'backup',
        [string]$HandlerContractVersion = '1',
        [string]$StateRoot
    )

    $canonicalSource = Get-LabCanonicalArtifactSource -Source $Source
    return Invoke-LabArtifactStoreLock -StateRoot $StateRoot -ScriptBlock {
        $paths = Initialize-LabArtifactStore -StateRoot $StateRoot
        $store = Get-Content -LiteralPath $paths.TrustStorePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
        $records = @($store.records)
        $normalizedSha256 = $Sha256.ToLowerInvariant()
        $existing = @($records | Where-Object {
            $_.source -eq $canonicalSource -and
            $_.sha256 -eq $normalizedSha256 -and
            ([string]$_.sampleId -eq [string]$SampleId) -and
            ([string]$_.sampleVariant -eq [string]$SampleVariant)
        } | Select-Object -First 1)
        if ($existing.Count -gt 0) {
            return $existing[0]
        }

        $previous = @($records | Where-Object {
            $_.source -eq $canonicalSource -and
            ([string]$_.sampleId -eq [string]$SampleId) -and
            ([string]$_.sampleVariant -eq [string]$SampleVariant)
        } | Sort-Object trustedAt -Descending | Select-Object -First 1)
        $record = [PSCustomObject]@{
            trustId                = New-LabGuid
            source                 = $canonicalSource
            sampleId               = $SampleId
            sampleVariant          = $SampleVariant
            artifactType           = $ArtifactType
            handlerContractVersion = $HandlerContractVersion
            sha256                 = $normalizedSha256
            integrityOrigin        = 'user-trusted-generated'
            trustedAt              = Get-LabTimestamp
            supersedesTrustId      = if ($previous.Count -gt 0) { [string]$previous[0].trustId } else { $null }
        }
        $store.records = @($records + $record)
        Write-LabArtifactJsonAtomic -Path $paths.TrustStorePath -InputObject $store
        return $record
    }
}

function Get-LabArtifactCacheEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$Sha256,
        [string]$StateRoot
    )

    $paths = Initialize-LabArtifactStore -StateRoot $StateRoot
    $digest = $Sha256.ToLowerInvariant()
    $directory = Join-Path $paths.CacheRoot $digest
    $artifactPath = Join-Path $directory 'artifact.bak'
    $metadataPath = Join-Path $directory 'metadata.json'
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        return $null
    }

    $actualSha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $digest) {
        Move-LabArtifactToQuarantine -Path $directory -Reason 'cache-hash-mismatch' -StateRoot $StateRoot | Out-Null
        return $null
    }

    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    return [PSCustomObject]@{
        Path     = $artifactPath
        Sha256   = $digest
        Metadata = $metadata
    }
}

function Move-LabArtifactToQuarantine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Reason,
        [string]$StateRoot
    )

    $paths = Initialize-LabArtifactStore -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $quarantineId = "$(Get-LabTimestamp -replace '[:T-]', '')-$([guid]::NewGuid().ToString('N'))"
    $target = Join-Path $paths.QuarantineRoot $quarantineId
    Move-Item -LiteralPath $Path -Destination $target -Force
    Write-LabArtifactJsonAtomic -Path (Join-Path $target 'quarantine.json') -InputObject ([PSCustomObject]@{
        reason        = $Reason
        quarantinedAt = Get-LabTimestamp
    })
    return $target
}

function Add-LabArtifactManifestLockEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)]$Artifact
    )

    if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
        throw "ARTIFACT_LOCK_INVALID: Run-Verzeichnis nicht gefunden: $RunDirectory"
    }

    $canonicalSource = Get-LabCanonicalArtifactSource -Source $Artifact.Source
    $lockPath = Join-Path $RunDirectory 'manifest.lock.json'
    $lock = if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        Get-Content -LiteralPath $lockPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    }
    else {
        [PSCustomObject]@{ formatVersion = '1'; artifacts = @() }
    }

    $entry = [PSCustomObject]@{
        sampleId                = $Artifact.SampleId
        sampleVariant           = $Artifact.SampleVariant
        artifactType            = $Artifact.ArtifactType
        source                  = $canonicalSource
        sha256                  = $Artifact.Sha256
        integrityOrigin         = $Artifact.IntegrityOrigin
        handlerContractVersion  = $Artifact.HandlerContractVersion
        compatibility           = $Artifact.Compatibility
        expectedOutputs         = @($Artifact.ExpectedOutputs)
    }
    $existing = @($lock.artifacts | Where-Object {
        $_.source -eq $entry.source -and $_.sha256 -eq $entry.sha256 -and
        ([string]$_.sampleId -eq [string]$entry.sampleId) -and
        ([string]$_.sampleVariant -eq [string]$entry.sampleVariant)
    })
    if ($existing.Count -eq 0) {
        $lock.artifacts = @($lock.artifacts + $entry)
        Write-LabArtifactJsonAtomic -Path $lockPath -InputObject $lock
    }
    return $lockPath
}

function Export-LabPortableArtifactLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$Path
    )

    $lockPath = Join-Path $RunDirectory 'manifest.lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw "ARTIFACT_LOCK_NOT_FOUND: Kein Manifest Lock fuer '$RunDirectory' vorhanden."
    }
    $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    foreach ($artifact in @($lock.artifacts)) {
        if ($artifact.source) {
            $null = Get-LabCanonicalArtifactSource -Source $artifact.source
        }
    }
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $lock
    return $Path
}

function Resolve-LabArtifact {
    <#
    .SYNOPSIS
        Erwirbt ein Backup-Artifact sicher und liefert einen strukturierten Status.
    .DESCRIPTION
        Diese interne Funktion mutiert nur den lokalen Artifact Store. Sie fuehrt
        keine SQL-Installation aus. Nicht interaktive Aufrufe ohne bekannte
        Pruefsumme geben TRUST_REQUIRED zurueck.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [ValidateSet('backup', 'archive-backup', 'sql-script')][string]$ArtifactType = 'backup',
        [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256,
        [ValidateSet('catalog-only', 'interactive-once')][string]$TrustPolicy = 'interactive-once',
        [string]$SampleId,
        [string]$SampleVariant,
        [string]$HandlerContractVersion = '1',
        [int]$Compatibility,
        [array]$ExpectedOutputs = @(),
        [switch]$NonInteractive,
        [switch]$TrustUnknownArtifact,
        [string]$RunDirectory,
        [string]$StateRoot
    )

    $canonicalSource = Get-LabCanonicalArtifactSource -Source $Source
    $sourceUri = [System.Uri]::new($canonicalSource)
    $expectedExtension = switch ($ArtifactType) {
        'backup' { '\.bak$' }
        'archive-backup' { '\.zip$' }
        'sql-script' { '\.sql$' }
    }
    if ($sourceUri.AbsolutePath -notmatch "(?i)$expectedExtension") {
        throw "ARTIFACT_SOURCE_INVALID: Artifact Type '$ArtifactType' verweist nicht auf eine passende direkte Quelle: $canonicalSource"
    }
    $paths = Initialize-LabArtifactStore -StateRoot $StateRoot
    $expected = if ($ExpectedSha256) { $ExpectedSha256.ToLowerInvariant() } else { $null }
    $integrityOrigin = if ($expected) { 'catalog-verified' } else { $null }

    if (-not $expected) {
        $trustRecord = Get-LabArtifactTrustRecord -Source $canonicalSource -SampleId $SampleId -SampleVariant $SampleVariant -StateRoot $StateRoot
        if ($trustRecord) {
            $expected = [string]$trustRecord.sha256
            $integrityOrigin = [string]$trustRecord.integrityOrigin
        }
    }

    if ($expected) {
        $cached = Get-LabArtifactCacheEntry -Sha256 $expected -StateRoot $StateRoot
        if ($cached) {
            $ready = [PSCustomObject]@{
                Status                 = 'ARTIFACT_READY'
                Message                = 'Verifiziertes Artifact aus lokalem Cache verwendet.'
                Source                 = $canonicalSource
                Path                   = $cached.Path
                Sha256                 = $expected
                IntegrityOrigin        = $integrityOrigin
                ArtifactType           = $ArtifactType
                SampleId               = $SampleId
                SampleVariant          = $SampleVariant
                HandlerContractVersion = $HandlerContractVersion
                Compatibility          = $Compatibility
                ExpectedOutputs        = @($ExpectedOutputs)
                CacheStatus            = 'HIT'
            }
            if ($RunDirectory) { Add-LabArtifactManifestLockEntry -RunDirectory $RunDirectory -Artifact $ready | Out-Null }
            return $ready
        }
    }
    elseif ($TrustPolicy -ne 'interactive-once' -or $NonInteractive) {
        return [PSCustomObject]@{
            Status  = 'TRUST_REQUIRED'
            Message = 'Keine erwartete SHA-256-Pruefsumme vorhanden. Ein nicht interaktiver Lauf darf kein Vertrauen erzeugen.'
            Source  = $canonicalSource
        }
    }
    elseif (-not $TrustUnknownArtifact -and -not (Read-LabConfirm -Prompt "Artifact ohne bekannte SHA-256 von '$canonicalSource' einmalig vertrauen und lokal pruefen?" -Default $false)) {
        return [PSCustomObject]@{
            Status  = 'TRUST_REQUIRED'
            Message = 'Benutzer hat keine Vertrauensfreigabe erteilt.'
            Source  = $canonicalSource
        }
    }

    $stagingDirectory = Join-Path $paths.StagingRoot (New-LabGuid)
    $stagingPath = Join-Path $stagingDirectory 'artifact.download'
    New-Item -Path $stagingDirectory -ItemType Directory -Force | Out-Null
    $previousProgressPreference = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $canonicalSource -OutFile $stagingPath
    }
    catch {
        if (Test-Path -LiteralPath $stagingDirectory) { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force }
        return [PSCustomObject]@{
            Status  = 'ARTIFACT_ACQUISITION_FAILED'
            Message = "Download fehlgeschlagen: $($_.Exception.Message)"
            Source  = $canonicalSource
        }
    }
    finally {
        $ProgressPreference = $previousProgressPreference
    }

    $observed = (Get-FileHash -LiteralPath $stagingPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $expected) {
        $expected = $observed
        $trustRecord = Register-LabArtifactTrustRecord `
            -Source $canonicalSource `
            -Sha256 $observed `
            -SampleId $SampleId `
            -SampleVariant $SampleVariant `
            -ArtifactType $ArtifactType `
            -HandlerContractVersion $HandlerContractVersion `
            -StateRoot $StateRoot
        $integrityOrigin = $trustRecord.integrityOrigin
    }
    elseif ($observed -ne $expected) {
        $canRetrust = $integrityOrigin -eq 'user-trusted-generated' -and -not $NonInteractive
        if ($canRetrust -and (Read-LabConfirm -Prompt "Die Quelle liefert andere Bytes. Neues SHA-256 $observed explizit vertrauen?" -Default $false)) {
            $trustRecord = Register-LabArtifactTrustRecord `
                -Source $canonicalSource `
                -Sha256 $observed `
                -SampleId $SampleId `
                -SampleVariant $SampleVariant `
                -ArtifactType $ArtifactType `
                -HandlerContractVersion $HandlerContractVersion `
                -StateRoot $StateRoot
            $expected = $observed
            $integrityOrigin = $trustRecord.integrityOrigin
        }
        else {
            $quarantinePath = Move-LabArtifactToQuarantine -Path $stagingDirectory -Reason 'download-hash-mismatch' -StateRoot $StateRoot
            return [PSCustomObject]@{
                Status           = 'ARTIFACT_INTEGRITY_MISMATCH'
                Message          = 'Die geladene SHA-256 stimmt nicht mit der erwarteten Pruefsumme ueberein.'
                Source           = $canonicalSource
                ExpectedSha256   = $expected
                ObservedSha256   = $observed
                QuarantinePath   = $quarantinePath
            }
        }
    }

    $cacheDirectory = Join-Path $paths.CacheRoot $expected
    $cachePath = Join-Path $cacheDirectory 'artifact.bak'
    Invoke-LabArtifactStoreLock -StateRoot $StateRoot -ScriptBlock {
        if (-not (Test-Path -LiteralPath $cacheDirectory -PathType Container)) {
            New-Item -Path $cacheDirectory -ItemType Directory -Force | Out-Null
        }
        $existing = Get-LabArtifactCacheEntry -Sha256 $expected -StateRoot $StateRoot
        if (-not $existing) {
            Move-Item -LiteralPath $stagingPath -Destination $cachePath -Force
            Write-LabArtifactJsonAtomic -Path (Join-Path $cacheDirectory 'metadata.json') -InputObject ([PSCustomObject]@{
                formatVersion           = '1'
                source                  = $canonicalSource
                sha256                  = $expected
                integrityOrigin         = $integrityOrigin
                artifactType            = $ArtifactType
                sampleId                = $SampleId
                sampleVariant           = $SampleVariant
                handlerContractVersion  = $HandlerContractVersion
                acquiredAt              = Get-LabTimestamp
            })
        }
    } | Out-Null
    if (Test-Path -LiteralPath $stagingDirectory) { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force }

    $ready = [PSCustomObject]@{
        Status                 = 'ARTIFACT_READY'
        Message                = 'Artifact geladen, SHA-256 verifiziert und lokal zwischengespeichert.'
        Source                 = $canonicalSource
        Path                   = $cachePath
        Sha256                 = $expected
        IntegrityOrigin        = $integrityOrigin
        ArtifactType           = $ArtifactType
        SampleId               = $SampleId
        SampleVariant          = $SampleVariant
        HandlerContractVersion = $HandlerContractVersion
        Compatibility          = $Compatibility
        ExpectedOutputs        = @($ExpectedOutputs)
        CacheStatus            = 'MISS'
    }
    if ($RunDirectory) { Add-LabArtifactManifestLockEntry -RunDirectory $RunDirectory -Artifact $ready | Out-Null }
    return $ready
}

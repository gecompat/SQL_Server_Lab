function Save-SqlServerLabMediaSource {
    <#
    .SYNOPSIS
        Lädt ein katalogisiertes SQL-Server-Basismedium oder einen Bootstrapper.
    .DESCRIPTION
        Verwendet ausschließlich den versionierten Medienquellenkatalog. Jede
        automatisierbare Quelle besitzt eine erwartete Länge und SHA-256. EXE-
        Dateien müssen zusätzlich eine gültige Microsoft-Authenticode-Signatur
        tragen. Erst danach wird die Datei atomar im Media Root veröffentlicht
        und eine gespiegelte SHA-256-Sidecar-Datei geschrieben.

        Manuelle Lizenzmedien sowie nicht katalogisierte URLs werden bewusst
        nicht geladen. Bereits vorhandene Dateien werden erneut geprüft und bei
        Abweichung nicht überschrieben.
    .PARAMETER Id
        ID aus Catalogs/sql-server-media-sources.json.
    .PARAMETER MediaRoot
        Ziel-Media-Root. Ohne Angabe wird der lokal konfigurierte Media Root
        verwendet.
    .EXAMPLE
        Save-SqlServerLabMediaSource -Id sql-server-2016-developer-sp3-iso -MediaRoot 'D:\Lab1_Base'
    .EXAMPLE
        Save-SqlServerLabMediaSource -Id sql-server-2005-express-sp4-archive -MediaRoot 'D:\Lab1_Base' -WhatIf
    .OUTPUTS
        PSCustomObject mit Status, Quelle, Ziel, Länge, SHA-256 und Signaturstatus.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^sql-server-[a-z0-9.-]+$')]
        [string]$Id,

        [string]$MediaRoot
    )

    if ([string]::IsNullOrWhiteSpace($MediaRoot)) { $MediaRoot = Get-LabMediaRootDefault }
    if ([string]::IsNullOrWhiteSpace($MediaRoot)) {
        throw 'SQL_MEDIA_ROOT_REQUIRED: -MediaRoot angeben oder den Media Root im Lab konfigurieren.'
    }
    if (-not (Test-Path -LiteralPath $MediaRoot -PathType Container)) {
        throw "SQL_MEDIA_ROOT_NOT_FOUND: $MediaRoot"
    }
    $resolvedRoot = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    $entry = @(Get-LabMediaSourceCatalog -MediaRoot $resolvedRoot | Where-Object { $_.Id -eq $Id })
    if ($entry.Count -ne 1) { throw "SQL_MEDIA_SOURCE_NOT_FOUND: $Id" }
    $source = $entry[0]
    if (-not $source.Automatable -or [string]::IsNullOrWhiteSpace([string]$source.DownloadUrl)) {
        throw "SQL_MEDIA_SOURCE_MANUAL_REQUIRED: $Id / $($source.Note)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$source.ExpectedSha256) -or -not $source.ExpectedBytes) {
        throw "SQL_MEDIA_SOURCE_INTEGRITY_METADATA_MISSING: $Id"
    }

    $targetPath = [System.IO.Path]::GetFullPath([string]$source.TargetPath)
    $rootPrefix = $resolvedRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $targetPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "SQL_MEDIA_SOURCE_TARGET_UNSAFE: $targetPath"
    }

    $verifyFile = {
        param([string]$Path, [object]$Definition)
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($file.Length -ne [long]$Definition.ExpectedBytes) {
            throw "SQL_MEDIA_SOURCE_SIZE_MISMATCH: $($Definition.Id) / erwartet $($Definition.ExpectedBytes), erhalten $($file.Length)"
        }
        $sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sha256 -ne ([string]$Definition.ExpectedSha256).ToLowerInvariant()) {
            throw "SQL_MEDIA_SOURCE_HASH_MISMATCH: $($Definition.Id) / erhalten $sha256"
        }
        $signatureStatus = 'NOT_APPLICABLE'
        if ([System.IO.Path]::GetExtension($Path) -ieq '.exe') {
            $signature = Get-AuthenticodeSignature -FilePath $Path
            $signatureStatus = [string]$signature.Status
            if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
                $signature.SignerCertificate.Subject -notmatch '(?i)\bO=Microsoft Corporation\b') {
                throw "SQL_MEDIA_SOURCE_SIGNATURE_INVALID: $($Definition.Id) / $signatureStatus"
            }
        }
        [PSCustomObject]@{ File = $file; Sha256 = $sha256; SignatureStatus = $signatureStatus }
    }

    $alreadyPresent = Test-Path -LiteralPath $targetPath -PathType Leaf
    if ($alreadyPresent) {
        $verification = & $verifyFile $targetPath $source
        return [PSCustomObject][ordered]@{
            Contract = 'SqlServerLab.MediaSource/1.0'; Id = $Id; Status = 'READY'
            Acquisition = 'NONE'; AlreadyPresent = $true; SourceUrl = [string]$source.DownloadUrl
            TargetPath = $targetPath; Bytes = $verification.File.Length; Sha256 = $verification.Sha256
            SignatureStatus = $verification.SignatureStatus; SourceStatus = [string]$source.SourceStatus
        }
    }

    if (-not $PSCmdlet.ShouldProcess($targetPath, "$Id herunterladen, verifizieren und veröffentlichen")) {
        return [PSCustomObject][ordered]@{
            Contract = 'SqlServerLab.MediaSource/1.0'; Id = $Id; Status = 'PLANNED'
            Acquisition = [string]$source.Acquisition; AlreadyPresent = $false; SourceUrl = [string]$source.DownloadUrl
            TargetPath = $targetPath; Bytes = [long]$source.ExpectedBytes; Sha256 = [string]$source.ExpectedSha256
            SignatureStatus = if ([System.IO.Path]::GetExtension($targetPath) -ieq '.exe') { 'MICROSOFT_REQUIRED' } else { 'NOT_APPLICABLE' }
            SourceStatus = [string]$source.SourceStatus
        }
    }

    $targetDirectory = Split-Path -Parent $targetPath
    [System.IO.Directory]::CreateDirectory($targetDirectory) | Out-Null
    $partialPath = Join-Path $targetDirectory ('.' + [System.IO.Path]::GetFileName($targetPath) + '.partial.' + [guid]::NewGuid().ToString('N'))
    try {
        Invoke-WebRequest -Uri ([string]$source.DownloadUrl) -OutFile $partialPath -UseBasicParsing
        $verification = & $verifyFile $partialPath $source
        Move-Item -LiteralPath $partialPath -Destination $targetPath -ErrorAction Stop

        $sidecarPath = Join-Path (Join-Path $resolvedRoot 'Hashes') (([string]$source.TargetRelativePath -replace '/', '\') + '.sha256')
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $sidecarPath)) | Out-Null
        Set-Content -LiteralPath $sidecarPath -Value ("{0}  {1}" -f $verification.Sha256, [System.IO.Path]::GetFileName($targetPath)) -Encoding ascii

        return [PSCustomObject][ordered]@{
            Contract = 'SqlServerLab.MediaSource/1.0'; Id = $Id; Status = 'READY'
            Acquisition = [string]$source.Acquisition; AlreadyPresent = $false; SourceUrl = [string]$source.DownloadUrl
            TargetPath = $targetPath; Bytes = $verification.File.Length; Sha256 = $verification.Sha256
            SignatureStatus = $verification.SignatureStatus; SourceStatus = [string]$source.SourceStatus
        }
    }
    finally {
        if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
            Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
        }
    }
}

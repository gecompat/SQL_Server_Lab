#Requires -Version 7.2
<#
.SYNOPSIS
Installiert den portablen, hashgebundenen WIM-Metadatenprüfer für Lab1_Base.

.DESCRIPTION
Lädt die offizielle Windows-x64-Distribution von wimlib 1.14.5, prüft den vom
Hersteller veröffentlichten SHA-256-Wert, entpackt sie in einen versionierten
Tools-Pfad und prüft zusätzlich die erwartete wimlib-imagex.exe. Ein bereits
abweichend belegtes Ziel wird nicht überschrieben.

.PARAMETER MediaRoot
Kanonischer externer Media Root.
#>
[CmdletBinding(SupportsShouldProcess)]
param([string]$MediaRoot='D:\Lab1_Base')

$ErrorActionPreference='Stop'
$version='1.14.5'
$uri='https://wimlib.net/downloads/wimlib-1.14.5-windows-x86_64-bin.zip'
$expectedZipSha256='2f446d6fa3866582175f1a22a7be198eeee0aec7aba5b4e04ad25c99eae2d265'
$expectedExeSha256='34c0c4165591ad1f592837ed99d08273c58d6ed3fe0ed6360cf34e7b0739b353'
$toolParent=Join-Path ([IO.Path]::GetFullPath($MediaRoot)) 'Tools\wimlib'
$target=Join-Path $toolParent $version
$targetZip=Join-Path $target "wimlib-$version-windows-x86_64-bin.zip"
$targetExe=Join-Path $target 'wimlib-imagex.exe'

if (Test-Path -LiteralPath $target) {
    if ((Test-Path -LiteralPath $targetZip -PathType Leaf) -and
        (Test-Path -LiteralPath $targetExe -PathType Leaf) -and
        (Get-FileHash -LiteralPath $targetZip -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedZipSha256 -and
        (Get-FileHash -LiteralPath $targetExe -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedExeSha256) {
        return [pscustomobject]@{Status='ALREADY_READY';Version=$version;Path=$targetExe;DistributionSha256=$expectedZipSha256}
    }
    throw 'WINDOWS_SERVER_MEDIA_INSPECTOR_TARGET_CONFLICT'
}
if (-not $PSCmdlet.ShouldProcess($target, "wimlib $version herunterladen, verifizieren und installieren")) {
    return [pscustomobject]@{Status='PLANNED';Version=$version;Path=$targetExe;DistributionSha256=$expectedZipSha256}
}

New-Item -Path $toolParent -ItemType Directory -Force | Out-Null
$staging=Join-Path $toolParent ('.staging-'+[guid]::NewGuid().ToString('N'))
try {
    New-Item -Path $staging -ItemType Directory -ErrorAction Stop | Out-Null
    $stagedZip=Join-Path $staging "wimlib-$version-windows-x86_64-bin.zip"
    Invoke-WebRequest -Uri $uri -OutFile $stagedZip -ErrorAction Stop
    $zipSha256=(Get-FileHash -LiteralPath $stagedZip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($zipSha256 -ne $expectedZipSha256) { throw "WINDOWS_SERVER_MEDIA_INSPECTOR_ARCHIVE_HASH_MISMATCH: $zipSha256" }
    Expand-Archive -LiteralPath $stagedZip -DestinationPath $staging -Force
    $stagedExe=Join-Path $staging 'wimlib-imagex.exe'
    if (-not (Test-Path -LiteralPath $stagedExe -PathType Leaf)) { throw 'WINDOWS_SERVER_MEDIA_INSPECTOR_EXECUTABLE_MISSING' }
    $exeSha256=(Get-FileHash -LiteralPath $stagedExe -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($exeSha256 -ne $expectedExeSha256) { throw "WINDOWS_SERVER_MEDIA_INSPECTOR_EXECUTABLE_HASH_MISMATCH: $exeSha256" }
    Move-Item -LiteralPath $staging -Destination $target -ErrorAction Stop
    $staging=$null
    [pscustomobject]@{Status='INSTALLED';Version=$version;Path=$targetExe;DistributionSha256=$zipSha256;ExecutableSha256=$exeSha256}
}
finally {
    if ($staging -and (Test-Path -LiteralPath $staging)) {
        $resolvedStaging=[IO.Path]::GetFullPath($staging)
        $resolvedParent=[IO.Path]::GetFullPath($toolParent).TrimEnd('\')+'\'
        if ($resolvedStaging.StartsWith($resolvedParent,[StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedStaging) -match '^\.staging-[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $resolvedStaging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

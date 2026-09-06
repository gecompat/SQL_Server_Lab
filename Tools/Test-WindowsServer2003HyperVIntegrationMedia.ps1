#Requires -Version 7.2
<#
.SYNOPSIS
Prüft die archivierte Hyper-V-Integrations-DVD für Windows Server 2003 SP2.

.DESCRIPTION
Das Skript bindet das exakt hashgebundene vmguest.iso read-only ein und prüft
Volume, x86-Setup-Version sowie Microsoft-Authenticode-Signaturen von Setup und
Windows-5.x-MSI. Es installiert keine Treiber und verändert keinen Gast.

.PARAMETER IsoPath
Pfad zu Hyper-V-Integration-Services-6.3.9600.16384-vmguest.iso.

.PARAMETER ExpectedSha256
Erwarteter SHA-256 des katalogisierten Archiv-ISOs.

.PARAMETER ExpectedBytes
Erwartete Dateigröße des katalogisierten Archiv-ISOs.

.PARAMETER ShowHelp
Zeigt diese Hilfe und beendet das Skript.
#>
[CmdletBinding()]
param(
    [Alias('h', 'help', '?')]
    [switch] $ShowHelp,

    [ValidateNotNullOrEmpty()]
    [string] $IsoPath,

    [ValidatePattern('^[a-fA-F0-9]{64}$')]
    [string] $ExpectedSha256 = 'd1037fd8e788ce8ed0df16ec21f057e74512d5b3d551cc9396c7ae95dccba10f',

    [ValidateRange(1, [long]::MaxValue)]
    [long] $ExpectedBytes = 27590656,

    [Parameter(ValueFromRemainingArguments)]
    [string[]] $RemainingArgs
)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or
    @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or
    @($RemainingArgs) -contains '--help'
if ($showHelpRequested) {
    Get-Help -Full -Name $PSCommandPath | Out-Host
    return
}
if ([string]::IsNullOrWhiteSpace($IsoPath)) {
    throw 'WS2003_HYPERV_INTEGRATION_MEDIA_ARGUMENT_REQUIRED: IsoPath ist erforderlich.'
}

$ErrorActionPreference = 'Stop'
$resolvedIso = (Resolve-Path -LiteralPath $IsoPath).Path
$isoFile = Get-Item -LiteralPath $resolvedIso
if ($isoFile.Length -ne $ExpectedBytes) {
    throw "WS2003_HYPERV_INTEGRATION_MEDIA_SIZE_MISMATCH: erwartet $ExpectedBytes, erhalten $($isoFile.Length)"
}
$actualSha256 = (Get-FileHash -LiteralPath $resolvedIso -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
    throw "WS2003_HYPERV_INTEGRATION_MEDIA_HASH_MISMATCH: erwartet $($ExpectedSha256.ToLowerInvariant()), erhalten $actualSha256"
}

$mountedByThisRun = $false
$diskImage = $null
try {
    $diskImage = Get-DiskImage -ImagePath $resolvedIso -ErrorAction SilentlyContinue
    if (-not $diskImage -or -not $diskImage.Attached) {
        $diskImage = Mount-DiskImage -ImagePath $resolvedIso -PassThru
        $mountedByThisRun = $true
    }
    $volume = $diskImage | Get-Volume | Select-Object -First 1
    if (-not $volume.DriveLetter -or $volume.FileSystemLabel -ne 'VMGUEST') {
        throw 'WS2003_HYPERV_INTEGRATION_MEDIA_VOLUME_INVALID: Volume VMGUEST wurde nicht gefunden.'
    }

    $x86Root = Join-Path "$($volume.DriveLetter):\" 'support\x86'
    $setupPath = Join-Path $x86Root 'setup.exe'
    $msiPath = Join-Path $x86Root 'Windows5.x-HyperVIntegrationServices-x86.msi'
    foreach ($requiredPath in @($setupPath, $msiPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "WS2003_HYPERV_INTEGRATION_MEDIA_FILE_MISSING: $([IO.Path]::GetFileName($requiredPath))"
        }
    }

    $setupVersion = (Get-Item -LiteralPath $setupPath).VersionInfo.FileVersion
    if ($setupVersion -notlike '6.3.9600.16384*') {
        throw "WS2003_HYPERV_INTEGRATION_MEDIA_VERSION_INVALID: erwartet 6.3.9600.16384, erhalten $setupVersion"
    }

    $signatureResults = foreach ($signedPath in @($setupPath, $msiPath)) {
        $signature = Get-AuthenticodeSignature -LiteralPath $signedPath
        $subject = if ($signature.SignerCertificate) { [string] $signature.SignerCertificate.Subject } else { '' }
        if ($signature.Status -ne 'Valid' -or $subject -notmatch '(?i)\bO=Microsoft Corporation\b') {
            throw "WS2003_HYPERV_INTEGRATION_MEDIA_SIGNATURE_INVALID: $([IO.Path]::GetFileName($signedPath)) / $($signature.Status)"
        }
        [pscustomobject]@{
            File = [IO.Path]::GetFileName($signedPath)
            Status = [string] $signature.Status
            Publisher = 'Microsoft Corporation'
        }
    }

    [pscustomobject]@{
        Status = 'VERIFIED'
        IsoPath = $resolvedIso
        Bytes = $isoFile.Length
        Sha256 = $actualSha256
        Volume = $volume.FileSystemLabel
        SetupVersion = $setupVersion
        SignedFiles = @($signatureResults)
        InstallsDrivers = $false
    }
}
finally {
    if ($mountedByThisRun -and $diskImage) {
        Dismount-DiskImage -ImagePath $resolvedIso -ErrorAction SilentlyContinue | Out-Null
    }
}

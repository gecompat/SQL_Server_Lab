#Requires -Version 7.2
<#
.SYNOPSIS
Erzeugt aus dem offiziellen Windows-Server-2003-SP2-x86-ISO ein Sysprep-Hilfsmedium.

.DESCRIPTION
Das Skript prüft das SP2-ISO per SHA-256, extrahiert die dazugehörigen
Deployment Tools und erzeugt ein nicht bootfähiges ISO. Dessen Autorun kopiert
Sysprep und Setupcl nach C:\Sysprep und führt anschließend
`sysprep -reseal -mini -quiet -forceshutdown` aus.

Das Medium enthält weder Product Key noch Kennwort. Der nächste Start muss auf
einem abgeleiteten Klon erfolgen und durchläuft Mini-Setup einschließlich der
für diesen Klon geltenden Aktivierung.

.PARAMETER Sp2IsoPath
Pfad zum offiziellen x86-SP2-ISO `w2k3sp2_3959_usa_x86fre_spcd.iso`.

.PARAMETER OutputIsoPath
Zielpfad des lokalen Sysprep-Hilfsmediums.

.PARAMETER ExpectedSp2Sha256
Erwarteter SHA-256 des offiziellen SP2-ISOs.

.PARAMETER Force
Ersetzt ausschließlich die explizit angegebene Zieldatei.

.PARAMETER ShowHelp
Zeigt diese Hilfe und beendet das Skript ohne Mutation.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Alias('h', 'help', '?')]
    [switch] $ShowHelp,

    [ValidateNotNullOrEmpty()]
    [string] $Sp2IsoPath,

    [ValidateNotNullOrEmpty()]
    [string] $OutputIsoPath,

    [ValidatePattern('^[a-fA-F0-9]{64}$')]
    [string] $ExpectedSp2Sha256 = '30cbd649cfd879bc35a94c41366380d64b5c1745393bcf5604390d3ce566529c',

    [switch] $Force,

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

if ([string]::IsNullOrWhiteSpace($Sp2IsoPath) -or [string]::IsNullOrWhiteSpace($OutputIsoPath)) {
    throw 'WS2003_SYSPREP_MEDIA_ARGUMENT_REQUIRED: Sp2IsoPath und OutputIsoPath sind erforderlich.'
}

$ErrorActionPreference = 'Stop'
$resolvedSp2Iso = (Resolve-Path -LiteralPath $Sp2IsoPath).Path
$resolvedOutputIso = [IO.Path]::GetFullPath($OutputIsoPath)
$resolvedOutputParent = Split-Path -Parent $resolvedOutputIso
$actualSp2Sha256 = (Get-FileHash -LiteralPath $resolvedSp2Iso -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSp2Sha256 -ne $ExpectedSp2Sha256.ToLowerInvariant()) {
    throw "WS2003_SP2_ISO_HASH_MISMATCH: erwartet $($ExpectedSp2Sha256.ToLowerInvariant()), erhalten $actualSp2Sha256"
}

if (Test-Path -LiteralPath $resolvedOutputIso) {
    if (-not $Force) {
        throw "WS2003_SYSPREP_ISO_EXISTS: $resolvedOutputIso"
    }
    if ($PSCmdlet.ShouldProcess($resolvedOutputIso, 'vorhandenes Sysprep-Hilfsmedium ersetzen')) {
        Remove-Item -LiteralPath $resolvedOutputIso -Force
    }
}

if (-not $PSCmdlet.ShouldProcess($resolvedOutputIso, 'Windows-Server-2003-SP2-Sysprep-Hilfsmedium erzeugen')) {
    return [pscustomobject]@{
        Status = 'PLANNED'
        SourceSha256 = $actualSp2Sha256
        OutputIsoPath = $resolvedOutputIso
    }
}

if (-not (Test-Path -LiteralPath $resolvedOutputParent -PathType Container)) {
    New-Item -Path $resolvedOutputParent -ItemType Directory -Force | Out-Null
}

$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$stagingRoot = Join-Path $temporaryBase "sql-lab-ws2003-sysprep-$([guid]::NewGuid().ToString('N'))"
$resolvedStagingRoot = [IO.Path]::GetFullPath($stagingRoot)
if (-not $resolvedStagingRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw "WS2003_SYSPREP_TEMP_SCOPE_INVALID: $resolvedStagingRoot"
}

$mountedByThisRun = $false
$diskImage = $null
$image = $null
$imageRoot = $null
$result = $null
$resultImageStream = $null
try {
    $sysprepDirectory = Join-Path $resolvedStagingRoot 'Sysprep'
    New-Item -Path $sysprepDirectory -ItemType Directory -Force | Out-Null

    $diskImage = Get-DiskImage -ImagePath $resolvedSp2Iso -ErrorAction SilentlyContinue
    if (-not $diskImage -or -not $diskImage.Attached) {
        $diskImage = Mount-DiskImage -ImagePath $resolvedSp2Iso -PassThru
        $mountedByThisRun = $true
    }
    $volume = $diskImage | Get-Volume | Select-Object -First 1
    if (-not $volume.DriveLetter -or $volume.FileSystemLabel -ne 'CR0SP2_EN') {
        throw 'WS2003_SP2_ISO_VOLUME_INVALID: Volume CR0SP2_EN wurde nicht gefunden.'
    }

    $deployCab = Join-Path "$($volume.DriveLetter):\" 'SUPPORT\TOOLS\DEPLOY.CAB'
    if (-not (Test-Path -LiteralPath $deployCab -PathType Leaf)) {
        throw 'WS2003_SP2_DEPLOY_CAB_MISSING: SUPPORT\TOOLS\DEPLOY.CAB fehlt.'
    }
    & "$env:WINDIR\System32\expand.exe" $deployCab '-F:sysprep.exe' $sysprepDirectory | Out-Null
    & "$env:WINDIR\System32\expand.exe" $deployCab '-F:setupcl.exe' $sysprepDirectory | Out-Null
    & "$env:WINDIR\System32\expand.exe" $deployCab '-F:factory.exe' $sysprepDirectory | Out-Null

    $sysprepVersion = (Get-Item -LiteralPath (Join-Path $sysprepDirectory 'sysprep.exe')).VersionInfo.ProductVersion
    if ($sysprepVersion -ne '5.2.3790.3959') {
        throw "WS2003_SP2_SYSPREP_VERSION_INVALID: erwartet 5.2.3790.3959, erhalten $sysprepVersion"
    }

    @'
[autorun]
open=prepare-template.cmd
action=Prepare Windows Server 2003 SP2 template
'@ | Set-Content -LiteralPath (Join-Path $resolvedStagingRoot 'autorun.inf') -Encoding ascii

    @'
@echo off
setlocal
set "TARGET=%SystemDrive%\Sysprep"
if not exist "%TARGET%" md "%TARGET%"
copy /Y "%~dp0Sysprep\sysprep.exe" "%TARGET%\sysprep.exe" >nul
copy /Y "%~dp0Sysprep\setupcl.exe" "%TARGET%\setupcl.exe" >nul
copy /Y "%~dp0Sysprep\factory.exe" "%TARGET%\factory.exe" >nul
start "" "%TARGET%\sysprep.exe" -reseal -mini -quiet -forceshutdown
endlocal
'@ | Set-Content -LiteralPath (Join-Path $resolvedStagingRoot 'prepare-template.cmd') -Encoding ascii

    if (-not ('SqlServerLabIsoStreamWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class SqlServerLabIsoStreamWriter
{
    public static void Write(string path, object imageStream, int blockSize, int totalBlocks)
    {
        IStream stream = (IStream)imageStream;
        byte[] buffer = new byte[blockSize * 256];
        IntPtr readPointer = Marshal.AllocHGlobal(sizeof(int));
        try
        {
            using (FileStream output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                long remaining = (long)blockSize * totalBlocks;
                while (remaining > 0)
                {
                    int requested = (int)Math.Min(buffer.Length, remaining);
                    stream.Read(buffer, requested, readPointer);
                    int read = Marshal.ReadInt32(readPointer);
                    if (read <= 0) throw new EndOfStreamException("IMAPI image stream ended early.");
                    output.Write(buffer, 0, read);
                    remaining -= read;
                }
                output.Flush(true);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(readPointer);
        }
    }
}
'@
    }

    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $image.VolumeName = 'WS03SP2SYSPREP'
    $image.FileSystemsToCreate = 3
    $imageRoot = $image.Root
    $imageRoot.AddTree($resolvedStagingRoot, $false)
    $result = $image.CreateResultImage()
    $resultImageStream = $result.ImageStream
    [SqlServerLabIsoStreamWriter]::Write(
        $resolvedOutputIso,
        $resultImageStream,
        $result.BlockSize,
        $result.TotalBlocks)

    [pscustomobject]@{
        Status = 'CREATED'
        SourceSha256 = $actualSp2Sha256
        SysprepVersion = $sysprepVersion
        OutputIsoPath = $resolvedOutputIso
        OutputBytes = (Get-Item -LiteralPath $resolvedOutputIso).Length
        OutputSha256 = (Get-FileHash -LiteralPath $resolvedOutputIso -Algorithm SHA256).Hash.ToLowerInvariant()
        ContainsSecrets = $false
        ResealCommand = 'sysprep -reseal -mini -quiet -forceshutdown'
    }
}
finally {
    if ($mountedByThisRun -and $diskImage) {
        Dismount-DiskImage -ImagePath $resolvedSp2Iso | Out-Null
    }
    foreach ($comObject in @($resultImageStream, $result, $imageRoot, $image)) {
        if ($comObject) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
        }
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    if (Test-Path -LiteralPath $resolvedStagingRoot -PathType Container) {
        $confirmedStagingRoot = [IO.Path]::GetFullPath($resolvedStagingRoot)
        if ($confirmedStagingRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $confirmedStagingRoot -Recurse -Force
        }
    }
}

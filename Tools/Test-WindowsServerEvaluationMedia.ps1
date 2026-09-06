#Requires -Version 7.2
<#
.SYNOPSIS
Prüft katalogisierte Windows-Server-Evaluations-ISOs und deren Installationsabbilder.

.DESCRIPTION
Das Skript verifiziert ausschließlich die im Medienkatalog hashgebundenen
Windows-Server-ISOs und liest die Editionen direkt aus install.wim oder
install.esd. Erhöht verwendet es Microsoft Get-WindowsImage; ohne Elevation
verwendet es die hashgebundene portable wimlib-Distribution und 7-Zip. Es
installiert nichts und entfernt portable Extraktionsdaten nach jeder ISO.

.PARAMETER MediaRoot
Kanonischer externer Media Root, beispielsweise D:\Lab1_Base.

.PARAMETER Version
Zu prüfende Windows-Server-Versionen. Standard sind 2008R2 bis 2025.

.PARAMETER CatalogPath
Optionaler Pfad zum maschinenlesbaren Medienkatalog.

.PARAMETER OutputPath
Optionales JSON-Ziel für die abgeleitete, geheimnisfreie Prüfevidenz.

.PARAMETER InspectionMode
Auto wählt Microsoft bei Elevation und sonst den portablen wimlib-Fallback.

.PARAMETER ShowHelp
Zeigt diese Hilfe und beendet das Skript.
#>
[CmdletBinding()]
param(
    [Alias('h', 'help', '?')]
    [switch] $ShowHelp,

    [ValidateNotNullOrEmpty()]
    [string] $MediaRoot = 'D:\Lab1_Base',

    [ValidateSet('2008R2', '2012R2', '2016', '2019', '2022', '2025')]
    [string[]] $Version = @('2008R2', '2012R2', '2016', '2019', '2022', '2025'),

    [ValidateNotNullOrEmpty()]
    [string] $CatalogPath = (Join-Path $PSScriptRoot '..\Catalogs\sql-server-media-sources.json'),

    [string] $OutputPath,

    [ValidateSet('Auto', 'Microsoft', 'Wimlib')]
    [string] $InspectionMode = 'Auto',

    [string] $SevenZipPath = 'C:\Program Files\7-Zip\7z.exe',

    [string] $WimlibPath,

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

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'WINDOWS_SERVER_MEDIA_VALIDATION_WINDOWS_ONLY' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$resolvedMediaRoot = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
$resolvedCatalog = (Resolve-Path -LiteralPath $CatalogPath -ErrorAction Stop).Path
$effectiveInspectionMode = if ($InspectionMode -eq 'Auto') {
    if ($isElevated -and (Get-Command Get-WindowsImage,Mount-DiskImage -ErrorAction SilentlyContinue).Count -eq 2) { 'Microsoft' }
    else { 'Wimlib' }
} else { $InspectionMode }
if ($effectiveInspectionMode -eq 'Microsoft' -and -not $isElevated) {
    throw 'WINDOWS_SERVER_MEDIA_VALIDATION_MICROSOFT_MODE_REQUIRES_ELEVATED_RUNNER'
}
$inspectionTool = $null
if ($effectiveInspectionMode -eq 'Wimlib') {
    if (-not $WimlibPath) { $WimlibPath = Join-Path $resolvedMediaRoot 'Tools\wimlib\1.14.5\wimlib-imagex.exe' }
    $WimlibPath = (Resolve-Path -LiteralPath $WimlibPath -ErrorAction Stop).Path
    $SevenZipPath = (Resolve-Path -LiteralPath $SevenZipPath -ErrorAction Stop).Path
    $wimlibDirectory = Split-Path -Parent $WimlibPath
    $wimlibZip = Join-Path $wimlibDirectory 'wimlib-1.14.5-windows-x86_64-bin.zip'
    $wimlibZipHash = (Get-FileHash -LiteralPath $wimlibZip -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $wimlibExeHash = (Get-FileHash -LiteralPath $WimlibPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($wimlibZipHash -ne '2f446d6fa3866582175f1a22a7be198eeee0aec7aba5b4e04ad25c99eae2d265' -or
        $wimlibExeHash -ne '34c0c4165591ad1f592837ed99d08273c58d6ed3fe0ed6360cf34e7b0739b353') {
        throw 'WINDOWS_SERVER_MEDIA_VALIDATION_WIMLIB_INTEGRITY_MISMATCH'
    }
    $inspectionTool = [pscustomobject]@{
        Name='wimlib-imagex'; Version='1.14.5'; ExecutableSha256=$wimlibExeHash
        DistributionSha256=$wimlibZipHash
        SevenZipSha256=(Get-FileHash -LiteralPath $SevenZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$catalog = Get-Content -LiteralPath $resolvedCatalog -Raw -Encoding utf8 |
    ConvertFrom-Json -Depth 30 -ErrorAction Stop
$selectedVersions = @($Version | Select-Object -Unique)
$entries = @($catalog.entries | Where-Object {
    [string]$_.mediaKind -eq 'ISO' -and
    [string]$_.targetRelativePath -like 'WindowsServer/*/Eval/ISO/*' -and
    [string]$_.version -in $selectedVersions
})
if ($entries.Count -ne $selectedVersions.Count) {
    $found = @($entries.version | Sort-Object -Unique)
    $missing = @($selectedVersions | Where-Object { $_ -notin $found })
    throw "WINDOWS_SERVER_MEDIA_CATALOG_ENTRY_MISSING: $($missing -join ', ')"
}

$results = [Collections.Generic.List[object]]::new()
foreach ($entry in @($entries | Sort-Object { [array]::IndexOf($selectedVersions, [string]$_.version) })) {
    $mountedByThisRun = $false
    $diskImage = $null
    $portableExtractionRoot = $null
    $portableExtractionBase = Join-Path $resolvedMediaRoot 'Temp\windows-server-media-validation'
    $isoPath = Join-Path $resolvedMediaRoot ([string]$entry.targetRelativePath -replace '/', '\')
    try {
        $resolvedIso = (Resolve-Path -LiteralPath $isoPath -ErrorAction Stop).Path
        $isoFile = Get-Item -LiteralPath $resolvedIso -Force
        if ([long]$isoFile.Length -ne [long]$entry.expectedBytes) {
            throw "SIZE_MISMATCH: erwartet $($entry.expectedBytes), erhalten $($isoFile.Length)"
        }
        $actualSha256 = (Get-FileHash -LiteralPath $resolvedIso -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha256 -ne ([string]$entry.expectedSha256).ToLowerInvariant()) {
            throw "SHA256_MISMATCH: erwartet $($entry.expectedSha256), erhalten $actualSha256"
        }

        $installImageName = $null
        if ($effectiveInspectionMode -eq 'Microsoft') {
            $diskImage = Get-DiskImage -ImagePath $resolvedIso -ErrorAction SilentlyContinue
            if (-not $diskImage -or -not $diskImage.Attached) {
                $diskImage = Mount-DiskImage -ImagePath $resolvedIso -Access ReadOnly -PassThru -ErrorAction Stop
                $mountedByThisRun = $true
            }
            $volumes = @($diskImage | Get-Volume -ErrorAction Stop | Where-Object DriveLetter)
            $installImages = @($volumes | ForEach-Object {
                foreach ($name in @('install.wim', 'install.esd')) {
                    $candidate = '{0}:\sources\{1}' -f [string]$_.DriveLetter, $name
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate -Force }
                }
            })
            if ($installImages.Count -ne 1) { throw "INSTALL_IMAGE_NOT_UNIQUE: $($installImages.Count)" }
            $installImageName = [string]$installImages[0].Name
            $images = @(Get-WindowsImage -ImagePath $installImages[0].FullName -ErrorAction Stop |
                ForEach-Object {
                    [pscustomobject]@{
                        Index = [int]$_.ImageIndex; Name = [string]$_.ImageName
                        Description = [string]$_.ImageDescription; Architecture = [string]$_.Architecture
                        EditionId = [string]$_.EditionId; InstallationType = [string]$_.InstallationType
                        Version = [string]$_.Version; Languages = @($_.Languages | ForEach-Object { [string]$_ })
                    }
                })
        }
        else {
            $listing = @(& $SevenZipPath l -slt $resolvedIso 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "SEVENZIP_ISO_LIST_FAILED: $LASTEXITCODE" }
            $installImagePaths = @($listing | ForEach-Object {
                if ([string]$_ -match '^Path = (?<path>sources\\install\.(?:wim|esd))$') { $Matches.path }
            } | Sort-Object -Unique)
            if ($installImagePaths.Count -ne 1) { throw "INSTALL_IMAGE_NOT_UNIQUE: $($installImagePaths.Count)" }
            $portableExtractionRoot = Join-Path $portableExtractionBase ([guid]::NewGuid().ToString('N'))
            New-Item -Path $portableExtractionRoot -ItemType Directory -Force | Out-Null
            $null = & $SevenZipPath x $resolvedIso $installImagePaths[0] "-o$portableExtractionRoot" -y
            if ($LASTEXITCODE -ne 0) { throw "SEVENZIP_INSTALL_IMAGE_EXTRACT_FAILED: $LASTEXITCODE" }
            $portableInstallImage = Join-Path $portableExtractionRoot $installImagePaths[0]
            if (-not (Test-Path -LiteralPath $portableInstallImage -PathType Leaf)) { throw 'PORTABLE_INSTALL_IMAGE_MISSING' }
            $installImageName = Split-Path -Leaf $portableInstallImage
            $wimXmlPath = Join-Path $portableExtractionRoot 'wim-information.xml'
            $null = & $WimlibPath info $portableInstallImage --extract-xml $wimXmlPath
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $wimXmlPath -PathType Leaf)) {
                throw "WIMLIB_INFO_FAILED: $LASTEXITCODE"
            }
            [xml]$wimXml = Get-Content -LiteralPath $wimXmlPath -Raw -Encoding Unicode
            $images = @($wimXml.WIM.IMAGE | ForEach-Object {
                $windows = $_.WINDOWS; $imageVersion = $windows.VERSION
                [pscustomobject]@{
                    Index = [int]$_.INDEX
                    Name = if ($_.DISPLAYNAME) { [string]$_.DISPLAYNAME } else { [string]$_.NAME }
                    Description = if ($_.DISPLAYDESCRIPTION) { [string]$_.DISPLAYDESCRIPTION } else { [string]$_.DESCRIPTION }
                    Architecture = if ([string]$windows.ARCH -eq '9') { 'x64' } else { [string]$windows.ARCH }
                    EditionId = [string]$windows.EDITIONID
                    InstallationType = [string]$windows.INSTALLATIONTYPE
                    Version = '{0}.{1}.{2}.{3}' -f $imageVersion.MAJOR,$imageVersion.MINOR,$imageVersion.BUILD,$imageVersion.SPBUILD
                    Languages = @($windows.LANGUAGES.LANGUAGE | ForEach-Object { [string]$_ })
                }
            })
        }
        if ($images.Count -eq 0) { throw 'INSTALL_IMAGE_EMPTY' }
        if (@($images | Where-Object Architecture -notin @('x64', '9')).Count -gt 0) {
            throw 'INSTALL_IMAGE_ARCHITECTURE_UNEXPECTED'
        }

        $requiredGeneration = if ([string]$entry.version -eq '2008R2') { 1 } else { 2 }
        $results.Add([pscustomobject]@{
            Status = 'VERIFIED'
            CatalogId = [string]$entry.id
            WindowsVersion = [string]$entry.version
            IsoPath = $resolvedIso
            Bytes = [long]$isoFile.Length
            Sha256 = $actualSha256
            SourceStatus = [string]$entry.sourceStatus
            Acquisition = [string]$entry.acquisition
            InspectionMode = $effectiveInspectionMode
            InstallImage = $installImageName
            Images = $images
            RequiredVmGeneration = $requiredGeneration
            SecureBoot = $requiredGeneration -eq 2 -and [string]$entry.version -ne '2012R2'
            CheckedAt = [datetime]::UtcNow.ToString('o')
        })
    }
    catch {
        $results.Add([pscustomobject]@{
            Status = 'FAILED'
            CatalogId = [string]$entry.id
            WindowsVersion = [string]$entry.version
            IsoPath = $isoPath
            Error = $_.Exception.Message
            CheckedAt = [datetime]::UtcNow.ToString('o')
        })
    }
    finally {
        if ($mountedByThisRun -and $diskImage) {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
        }
        if ($portableExtractionRoot -and (Test-Path -LiteralPath $portableExtractionRoot)) {
            $resolvedPortableRoot = [IO.Path]::GetFullPath($portableExtractionRoot)
            $resolvedPortableBase = [IO.Path]::GetFullPath($portableExtractionBase).TrimEnd('\') + '\'
            if (-not $resolvedPortableRoot.StartsWith($resolvedPortableBase, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'PORTABLE_EXTRACTION_CLEANUP_SCOPE_INVALID'
            }
            Remove-Item -LiteralPath $resolvedPortableRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$document = [pscustomobject]@{
    ContractVersion = '1'
    Kind = 'windows-server-evaluation-media-validation'
    MediaRoot = $resolvedMediaRoot
    CatalogPath = $resolvedCatalog
    InspectionMode = $effectiveInspectionMode
    InspectionTool = $inspectionTool
    CheckedAt = [datetime]::UtcNow.ToString('o')
    Results = @($results)
}
if ($OutputPath) {
    $fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $fullOutputPath
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
    }
    $temporaryOutput = "$fullOutputPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText(
            $temporaryOutput,
            ($document | ConvertTo-Json -Depth 20),
            [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryOutput -Destination $fullOutputPath -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryOutput -Force -ErrorAction SilentlyContinue
    }
}

$document
$failed = @($results | Where-Object Status -eq 'FAILED')
if ($failed.Count -gt 0) {
    throw "WINDOWS_SERVER_MEDIA_VALIDATION_FAILED: $(@($failed.WindowsVersion) -join ', ')"
}
